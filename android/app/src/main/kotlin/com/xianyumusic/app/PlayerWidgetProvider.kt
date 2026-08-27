package com.xianyumusic.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.RemoteViews
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 桌面播放组件共享渲染与控制逻辑
 * （PlayerWidgetProvider / RecognizeWidgetProvider / LyricWidgetProvider 共用）。
 *
 * 渲染：读 SharedPreferences("player_widget"/"state") 的 JSON（由 Flutter 侧随播放状态
 * 写入），按组件尺寸/组件入口构建对应 RemoteViews。卡片/文字/图标颜色随系统明暗主题
 * （values vs values-night）。
 * 控制：按钮 PendingIntent 发广播到对应 Provider，若 App 进程存活 → 经 MethodChannel
 * ('xianyu/player_widget') 回调 Flutter 驱动播放器；否则拉起 MainActivity 兜底。
 */
internal object WidgetShared {
    const val ACTION_PREFIX = "xianyu.widget.action."
    const val SP_NAME = "player_widget"
    private const val SP_KEY = "state"
    private const val LAYOUT_PREFIX = "layout_"
    const val PACKAGE = "com.xianyumusic.app"

    const val MODE_TALL = "tall"
    const val MODE_2X2 = "2x2"
    const val MODE_LYRIC = "lyric"

    // 尺寸估算：平均每格约 70dp、左右边距合计 16dp。
    private const val CELL_TARGET_DP = 70
    private const val CELL_MARGIN_DP = 16

    // 封面位图边长（dp）：横版 60、2×2/识曲/歌词卡用大图保证清晰。
    private const val COVER_TALL_DP = 60
    private const val COVER_2X2_DP = 156
    private const val COVER_RECOGNIZE_DP = 160
    private const val COVER_LYRIC_DP = 130

    // 卡片容器圆角（widget_bg 固定 24dp）：2×2/识曲封面按此绝对值渲染，
    // 避免按位图边长比例（0.26×）换算后随组件尺寸缩放导致的圆角错位。
    private const val CARD_CORNER_DP = 24f
    // 2×2 封面区域外的竖向固定占用（dp）：上下 padding 10×2 + 底部信息行 40 + 封面下边距 8。
    private const val SQUARE_PAD_DP = 10
    private const val SQUARE_OVERHEAD_DP = 68

    // 歌词卡五行窗口的 TextView id（index 0..4，当前行固定在第 3 行）。
    private val LYRIC_LINE_IDS = intArrayOf(
        R.id.lyricLine1, R.id.lyricLine2, R.id.lyricLine3,
        R.id.lyricLine4, R.id.lyricLine5)

    // 识曲深链：右上识曲钮经此拉起 App 识曲页。
    private const val RECOGNIZE_LINK = "xianyu://open?target=recognize"

    // 模糊背景态的固定白字/白图标色（类播放详情页暗底白字）。
    private const val WHITE = -0x1
    private const val WHITE_SECONDARY = 0xB8FFFFFF.toInt()
    private const val WHITE_TIME = 0xAAFFFFFF.toInt()

    private val mainHandler = Handler(Looper.getMainLooper())

    fun stateJson(ctx: Context): JSONObject? = try {
        val raw = ctx.getSharedPreferences(SP_NAME, Context.MODE_PRIVATE)
            .getString(SP_KEY, null) ?: return null
        JSONObject(raw)
    } catch (_: Exception) {
        null
    }

    private fun layoutMode(ctx: Context, id: Int): String {
        return ctx.getSharedPreferences(SP_NAME, Context.MODE_PRIVATE)
            .getString(LAYOUT_PREFIX + id, MODE_TALL) ?: MODE_TALL
    }

    private fun cellCount(size: Int): Int =
        ((size - 2 * CELL_MARGIN_DP + CELL_TARGET_DP - 1) / CELL_TARGET_DP).coerceAtLeast(1)

    fun cellsOf(newOptions: Bundle): Pair<Int, Int> = Pair(
        cellCount(newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)),
        cellCount(newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)))

    /**
     * 组件实际尺寸估算（dp，竖屏取向）：宽取 MIN_WIDTH（竖屏更窄），
     * 高取 MIN/MAX_HEIGHT 较大者（竖屏更高）。用于按真实尺寸渲染封面位图，
     * 让圆角以绝对 dp 对齐卡片容器；取不到（部分 launcher 未上报）返回 null。
     */
    fun sizeFromOptions(o: Bundle): Pair<Int, Int>? {
        val w = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
        val h = maxOf(
            o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT),
            o.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT))
        if (w <= 0 || h <= 0) return null
        return w to h
    }

    fun widgetSizeDp(mgr: AppWidgetManager, id: Int): Pair<Int, Int>? = try {
        sizeFromOptions(mgr.getAppWidgetOptions(id))
    } catch (_: Exception) {
        null
    }

    /**
     * Android 15+ 组件选择面板的「生成的预览」：未调用 setWidgetPreview 时系统
     * 回退 previewImage（layer-list 在部分 ROM 上渲染异常）。用各入口的预览布局
     * 推送一次；系统限速约 2 次/小时 → 每小时最多尝试一轮，全部成功后记版本号，
     * 预览布局有改动时递增 PREVIEW_GEN_VERSION 重新推送。
     */
    private const val PREVIEW_GEN_VERSION = 4
    private const val PREVIEW_GEN_RETRY_MS = 55 * 60 * 1000L

    fun ensurePreviewGen(ctx: Context) {
        if (Build.VERSION.SDK_INT < 35) return
        val prefs = ctx.getSharedPreferences(SP_NAME, Context.MODE_PRIVATE)
        if (prefs.getInt("preview_gen_version", 0) >= PREVIEW_GEN_VERSION) return
        val now = System.currentTimeMillis()
        if (now - prefs.getLong("preview_gen_attempt_ts", 0L) < PREVIEW_GEN_RETRY_MS) return
        prefs.edit().putLong("preview_gen_attempt_ts", now).apply()
        val mgr = AppWidgetManager.getInstance(ctx)
        val defs = listOf(
            PlayerWidgetProvider::class.java to R.layout.player_widget_preview,
            SquareWidgetProvider::class.java to R.layout.player_widget_square_preview,
            RecognizeWidgetProvider::class.java to R.layout.player_widget_recognize_preview,
            LyricWidgetProvider::class.java to R.layout.player_widget_lyric_preview,
        )
        var ok = 0
        for ((cls, layout) in defs) {
            try {
                mgr.setWidgetPreview(
                    ComponentName(ctx, cls),
                    AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN,
                    RemoteViews(PACKAGE, layout))
                ok++
            } catch (_: Exception) {
            }
        }
        if (ok == defs.size) {
            prefs.edit().putInt("preview_gen_version", PREVIEW_GEN_VERSION).apply()
        }
    }

    /** 刷新所有已放置的组件（四个 Provider 的全部 id），按各自尺寸/入口构建。 */
    fun updateAll(ctx: Context) {
        val mgr = AppWidgetManager.getInstance(ctx)
        val s = stateJson(ctx) ?: JSONObject()
        for (id in mgr.getAppWidgetIds(
            ComponentName(ctx, PlayerWidgetProvider::class.java))) {
            mgr.updateAppWidget(id, buildViewsForId(ctx, s, id))
        }
        for (id in mgr.getAppWidgetIds(
            ComponentName(ctx, SquareWidgetProvider::class.java))) {
            // 封面按各组件实际尺寸渲染（圆角对齐容器），逐 id 构建。
            mgr.updateAppWidget(
                id, buildViews(ctx, s, MODE_2X2, SquareWidgetProvider::class.java, 4000,
                    widgetSizeDp(mgr, id)))
        }
        for (id in mgr.getAppWidgetIds(
            ComponentName(ctx, RecognizeWidgetProvider::class.java))) {
            mgr.updateAppWidget(id, buildRecognizeViews(ctx, s, widgetSizeDp(mgr, id)))
        }
        for (id in mgr.getAppWidgetIds(
            ComponentName(ctx, LyricWidgetProvider::class.java))) {
            mgr.updateAppWidget(
                id, buildViews(ctx, s, MODE_LYRIC, LyricWidgetProvider::class.java, 5000))
        }
    }

    /** 按已存布局模式构建（主组件：尺寸自适应入口）。 */
    fun buildViewsForId(ctx: Context, s: JSONObject, id: Int): RemoteViews {
        val mode = layoutMode(ctx, id)
        // 2×2 档封面需按该组件实际尺寸渲染，圆角才能对齐容器。
        val size = if (mode == MODE_2X2) {
            widgetSizeDp(AppWidgetManager.getInstance(ctx), id)
        } else null
        return buildViews(ctx, s, mode, PlayerWidgetProvider::class.java, 1000, size)
    }

    /** 按显式布局模式构建（主组件与固定样式组件共用）。 */
    fun buildViews(
        ctx: Context,
        s: JSONObject,
        mode: String,
        provider: Class<out AppWidgetProvider>,
        rc: Int,
        sizeDp: Pair<Int, Int>? = null,
    ): RemoteViews {
        val layout = when (mode) {
            MODE_2X2 -> R.layout.player_widget_2x2
            MODE_LYRIC -> R.layout.player_widget_lyric
            else -> R.layout.player_widget
        }
        val views = RemoteViews(PACKAGE, layout)

        val title = s.optString("title").takeUnless { it.isBlank() } ?: "弦予音乐"
        val artist = s.optString("artist").takeUnless { it.isBlank() } ?: "未在播放"
        // 第二行：有歌词显示当前行歌词，否则回退歌手名（2×2 无此行）。
        val lyric = s.optString("lyric")
        val playing = s.optBoolean("playing")
        val favorite = s.optBoolean("favorite")
        val floatingLyrics = s.optBoolean("floatingLyrics")
        views.setTextViewText(R.id.songText, title)
        // 超长歌名跑马灯：ellipsize=marquee 需视图 selected 才滚动，
        // RemoteViews 经 setBoolean 反射调 setSelected(true) 激活。
        views.setBoolean(R.id.songText, "setSelected", true)
        if (mode != MODE_2X2) {
            views.setTextViewText(
                R.id.artistText, lyric.takeUnless { it.isBlank() } ?: artist)
        }
        views.setImageViewResource(
            R.id.btnPlay, if (playing) R.drawable.ic_pause else R.drawable.ic_play)

        when (mode) {
            MODE_2X2 -> {
                views.setOnClickPendingIntent(R.id.root, openPending(ctx, rc))
                views.setOnClickPendingIntent(
                    R.id.btnPlay, pending(ctx, "toggle", rc + 2, provider))
            }

            MODE_LYRIC -> {
                // 第二行固定为「歌手 · 弦予音乐」（歌词在右侧五行窗口展示）。
                views.setTextViewText(
                    R.id.artistText,
                    artist.takeUnless { it.isBlank() }?.let { "$it · 弦予音乐" }
                        ?: "弦予音乐")
                // 歌词窗口：当前行固定映射到 lyricLine3（布局中加粗主色），
                // 上下邻行渐淡；无窗口/无歌词时中间行显示占位。
                val window = s.optJSONArray("lyricWindow")
                var hasLyric = false
                for (i in 0 until 5) {
                    val text = window?.optString(i)?.takeUnless { it.isBlank() } ?: ""
                    if (text.isNotEmpty()) hasLyric = true
                    views.setTextViewText(LYRIC_LINE_IDS[i], text)
                }
                if (!hasLyric) views.setTextViewText(R.id.lyricLine3, "暂无歌词")
                views.setProgressBar(
                    R.id.progress, 100, s.optInt("progress").coerceIn(0, 100), false)
                views.setOnClickPendingIntent(R.id.root, openPending(ctx, rc))
                views.setOnClickPendingIntent(
                    R.id.btnPrev, pending(ctx, "previous", rc + 1, provider))
                views.setOnClickPendingIntent(
                    R.id.btnPlay, pending(ctx, "toggle", rc + 2, provider))
                views.setOnClickPendingIntent(
                    R.id.btnNext, pending(ctx, "next", rc + 3, provider))
            }

            else -> {
                views.setProgressBar(
                    R.id.progress, 100, s.optInt("progress").coerceIn(0, 100), false)
                views.setTextViewText(R.id.timeCur, fmt(s.optInt("position")))
                views.setTextViewText(R.id.timeDur, fmt(s.optInt("duration")))

                views.setImageViewResource(
                    R.id.btnMode, when (s.optInt("playMode")) {
                        1 -> R.drawable.ic_notif_mode_repeat_one
                        2 -> R.drawable.ic_notif_mode_shuffle
                        else -> R.drawable.ic_notif_mode_repeat
                    })

                views.setImageViewResource(
                    R.id.btnFavorite,
                    if (favorite) R.drawable.ic_notif_favorite_filled
                    else R.drawable.ic_notif_favorite)

                views.setImageViewResource(
                    R.id.btnLyrics,
                    if (floatingLyrics) R.drawable.ic_notif_lyrics_on
                    else R.drawable.ic_notif_lyrics_off)

                views.setOnClickPendingIntent(R.id.root, openPending(ctx, rc))
                views.setOnClickPendingIntent(
                    R.id.btnPrev, pending(ctx, "previous", rc + 1, provider))
                views.setOnClickPendingIntent(
                    R.id.btnPlay, pending(ctx, "toggle", rc + 2, provider))
                views.setOnClickPendingIntent(
                    R.id.btnNext, pending(ctx, "next", rc + 3, provider))
                views.setOnClickPendingIntent(
                    R.id.btnMode, pending(ctx, "cyclePlayMode", rc + 4, provider))
                views.setOnClickPendingIntent(
                    R.id.btnFavorite, pending(ctx, "toggleFavorite", rc + 5, provider))
                views.setOnClickPendingIntent(
                    R.id.btnLyrics, pending(ctx, "toggleFloatingLyrics", rc + 6, provider))
            }
        }

        val coverPath = s.optString("coverPath")
        val cover = when (mode) {
            // 2×2：按实际尺寸渲染矩形封面（填满卡片内封面区），圆角绝对 24dp 对齐容器；
            // 尺寸未知时回退固定大图 + 比例圆角。
            MODE_2X2 -> sizeDp?.let { sz ->
                roundedCoverRect(
                    ctx, coverPath,
                    (sz.first - 2 * SQUARE_PAD_DP).coerceAtLeast(1),
                    (sz.second - SQUARE_OVERHEAD_DP).coerceAtLeast(1),
                    CARD_CORNER_DP)
            } ?: roundedCover(ctx, coverPath, COVER_2X2_DP)
            MODE_LYRIC -> roundedCover(ctx, coverPath, COVER_LYRIC_DP)
            else -> roundedCover(ctx, coverPath, COVER_TALL_DP)
        }
        if (cover != null) {
            views.setImageViewBitmap(R.id.cover, cover)
        } else {
            views.setImageViewResource(R.id.cover, R.drawable.ic_widget_music_note)
            // 歌词卡浅色主题为浅底：白色音符占位需运行时按主题图标色重着色才可见。
            if (mode == MODE_LYRIC) {
                @Suppress("DEPRECATION")
                views.setInt(
                    R.id.cover, "setColorFilter",
                    ctx.resources.getColor(R.color.widget_icon))
            }
        }

        // 三行大卡：封面模糊 + 暗色蒙层作整卡背景（类播放详情页），
        // 有背景时文字/图标运行时置白；无封面回退主题平面底。
        if (mode == MODE_TALL) {
            val blur = blurredBackground(ctx, coverPath)
            if (blur != null) {
                views.setImageViewBitmap(R.id.bgCover, blur)
                views.setTextColor(R.id.songText, WHITE)
                views.setTextColor(R.id.artistText, WHITE_SECONDARY)
                views.setTextColor(R.id.timeCur, WHITE_TIME)
                views.setTextColor(R.id.timeDur, WHITE_TIME)
                views.setInt(R.id.btnPrev, "setColorFilter", WHITE)
                views.setInt(R.id.btnPlay, "setColorFilter", WHITE)
                views.setInt(R.id.btnNext, "setColorFilter", WHITE)
                views.setInt(R.id.btnMode, "setColorFilter", WHITE)
                // 描边态图标置白；实心红（已收藏/歌词开）保留品牌红。
                if (!favorite) views.setInt(R.id.btnFavorite, "setColorFilter", WHITE)
                if (!floatingLyrics) views.setInt(R.id.btnLyrics, "setColorFilter", WHITE)
            }
        }
        return views
    }

    /** 识曲样式组件（固定布局，不随尺寸切换；sizeDp 为实际尺寸，用于封面对齐容器）。 */
    fun buildRecognizeViews(
        ctx: Context,
        s: JSONObject,
        sizeDp: Pair<Int, Int>? = null,
    ): RemoteViews {
        val views = RemoteViews(PACKAGE, R.layout.player_widget_recognize)

        val title = s.optString("title").takeUnless { it.isBlank() } ?: "弦予音乐"
        val artist = s.optString("artist").takeUnless { it.isBlank() } ?: "未在播放"
        val lyric = s.optString("lyric")
        views.setTextViewText(R.id.songText, title)
        // 识曲条歌名/歌手跑马灯（setSelected 激活 marquee）。
        views.setBoolean(R.id.songText, "setSelected", true)
        views.setTextViewText(
            R.id.artistText, lyric.takeUnless { it.isBlank() } ?: artist)
        views.setBoolean(R.id.artistText, "setSelected", true)

        val playing = s.optBoolean("playing")
        views.setImageViewResource(
            R.id.btnPlay, if (playing) R.drawable.ic_pause else R.drawable.ic_play)

        views.setProgressBar(
            R.id.progress, 100, s.optInt("progress").coerceIn(0, 100), false)
        views.setTextViewText(R.id.timeCur, fmt(s.optInt("position")))
        views.setTextViewText(R.id.timeDur, fmt(s.optInt("duration")))

        views.setOnClickPendingIntent(R.id.root, openPending(ctx, 2000))
        views.setOnClickPendingIntent(
            R.id.btnPrev, pending(ctx, "previous", 2001, RecognizeWidgetProvider::class.java))
        views.setOnClickPendingIntent(
            R.id.btnPlay, pending(ctx, "toggle", 2002, RecognizeWidgetProvider::class.java))
        views.setOnClickPendingIntent(
            R.id.btnNext, pending(ctx, "next", 2003, RecognizeWidgetProvider::class.java))
        // 右上识曲钮：经深链拉起识曲页（冷/热启动都由 MainActivity 深链管道处理）。
        views.setOnClickPendingIntent(R.id.btnRecognize, recognizePending(ctx, 2004))

        // 封面顶满容器上下：按实际高度渲染同边长方形位图（adjustViewBounds 顶满左缘），
        // 圆角绝对 24dp 与卡片左上/左下圆弧重合；尺寸未知时回退固定大图。
        val cover = sizeDp?.let {
            roundedCoverRect(ctx, s.optString("coverPath"), it.second, it.second, CARD_CORNER_DP)
        } ?: roundedCover(ctx, s.optString("coverPath"), COVER_RECOGNIZE_DP)
        if (cover != null) {
            views.setImageViewBitmap(R.id.cover, cover)
        } else {
            views.setImageViewResource(R.id.cover, R.drawable.ic_widget_music_note)
        }
        return views
    }

    private fun pending(
        ctx: Context,
        action: String,
        requestCode: Int,
        provider: Class<out AppWidgetProvider>,
    ): PendingIntent = PendingIntent.getBroadcast(
        ctx, requestCode,
        Intent(ctx, provider).setAction(ACTION_PREFIX + action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun openPending(ctx: Context, requestCode: Int): PendingIntent =
        PendingIntent.getActivity(
            ctx, requestCode,
            Intent(ctx, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun recognizePending(ctx: Context, requestCode: Int): PendingIntent =
        PendingIntent.getActivity(
            ctx, requestCode,
            Intent(ctx, MainActivity::class.java)
                .setData(Uri.parse(RECOGNIZE_LINK))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /** 广播控制：进程存活 → MethodChannel 回调 Flutter；进程被杀 → 拉起 App 兜底。 */
    fun handleAction(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (!action.startsWith(ACTION_PREFIX)) return
        val name = action.removePrefix(ACTION_PREFIX)

        val messenger = FlutterMessengerHolder.messenger
        if (messenger != null) {
            // App 进程存活：后台直接控制，不弹界面。
            mainHandler.post {
                runCatching {
                    MethodChannel(messenger, "xianyu/player_widget").invokeMethod(name, null)
                }
            }
        } else {
            // 进程被杀：拉起 App 兜底。
            runCatching {
                context.startActivity(
                    Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP))
            }
        }
    }

    /**
     * 封面 -> 整卡模糊背景位图（三行大卡）：
     * 极小尺寸下采样 + 双线性放大形成快速平滑模糊，叠加上浅下深暗色蒙层
     * （类播放详情页），并按宽度比例裁圆角对齐 widget_bg 的 20dp 圆角。
     */
    private fun blurredBackground(ctx: Context, path: String): Bitmap? {
        if (path.isBlank()) return null
        return try {
            val bmp = BitmapFactory.decodeFile(path) ?: return null
            val w = 600
            val h = 300
            val smallW = 24
            val smallH = (smallW.toLong() * bmp.height / bmp.width).toInt().coerceAtLeast(1)
            val small = Bitmap.createScaledBitmap(bmp, smallW, smallH, true)
            val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val cv = Canvas(out)

            // 圆角裁剪（约 20dp 折算比例）。
            val corner = Path().apply {
                addRoundRect(
                    RectF(0f, 0f, w.toFloat(), h.toFloat()),
                    w * 0.06f, w * 0.06f, Path.Direction.CW)
            }
            cv.clipPath(corner)

            // centerCrop 语义：小图按比例放大铺满，居中采样。
            val scale = maxOf(
                w.toFloat() / small.width, h.toFloat() / small.height)
            val matrix = Matrix().apply {
                setScale(scale, scale)
                postTranslate(
                    (w - small.width * scale) / 2f, (h - small.height * scale) / 2f)
            }
            val paint = Paint(
                Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
                shader = BitmapShader(small, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
                shader.setLocalMatrix(matrix)
            }
            cv.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)

            // 暗色蒙层：上浅下深，保证底部控件/进度条可读。
            val scrim = Paint().apply {
                shader = LinearGradient(
                    0f, 0f, 0f, h.toFloat(),
                    0x8C000000.toInt(), 0xC0000000.toInt(), Shader.TileMode.CLAMP)
            }
            cv.drawRect(0f, 0f, w.toFloat(), h.toFloat(), scrim)
            out
        } catch (_: Throwable) {
            null
        }
    }

    /** 封面 -> 圆角方块位图（无封面/失败返回 null）。 */
    private fun roundedCover(ctx: Context, path: String, sizeDp: Int): Bitmap? {
        if (path.isBlank()) return null
        return try {
            val bmp = BitmapFactory.decodeFile(path) ?: return null
            val density = ctx.resources.displayMetrics.density
            val size = (sizeDp * density).toInt().coerceAtLeast(1)
            val dim = minOf(bmp.width, bmp.height)
            val sx = (bmp.width - dim) / 2f
            val sy = (bmp.height - dim) / 2f
            val crop = Bitmap.createBitmap(bmp, sx.toInt(), sy.toInt(), dim, dim)
            val half = Bitmap.createScaledBitmap(crop, size, size, true)
            val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val cv = Canvas(out)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            paint.setShader(BitmapShader(half, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP))
            // 圆角更圆润，匹配 App 封面比例；外加一圈细描边增强卡片感。
            val r = size * 0.26f
            val rect = RectF(0f, 0f, size.toFloat(), size.toFloat())
            cv.drawRoundRect(rect, r, r, paint)
            val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                color = 0x33FFFFFF
                strokeWidth = 1.5f * density
            }
            cv.drawRoundRect(rect, r, r, stroke)
            out
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * 封面 -> 指定宽高（dp）的圆角矩形位图：源图按 centerCrop 铺满，圆角取绝对 dp
     * 值并对齐组件实际渲染尺寸（2×2 填满封面区 / 识曲顶满左缘），确保与卡片
     * 24dp 容器圆角精确重合；外加一圈细描边增强卡片感。
     */
    private fun roundedCoverRect(
        ctx: Context,
        path: String,
        wDp: Int,
        hDp: Int,
        radiusDp: Float,
    ): Bitmap? {
        if (path.isBlank()) return null
        return try {
            val bmp = BitmapFactory.decodeFile(path) ?: return null
            val density = ctx.resources.displayMetrics.density
            val w = (wDp * density).toInt().coerceAtLeast(1)
            val h = (hDp * density).toInt().coerceAtLeast(1)
            val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val cv = Canvas(out)
            val r = radiusDp * density
            val rect = RectF(0f, 0f, w.toFloat(), h.toFloat())

            // centerCrop 语义：等比放大铺满，居中采样。
            val scale = maxOf(w.toFloat() / bmp.width, h.toFloat() / bmp.height)
            val matrix = Matrix().apply {
                setScale(scale, scale)
                postTranslate(
                    (w - bmp.width * scale) / 2f, (h - bmp.height * scale) / 2f)
            }
            val paint = Paint(
                Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
                shader = BitmapShader(bmp, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
                shader.setLocalMatrix(matrix)
            }

            val save = cv.save()
            cv.clipPath(Path().apply { addRoundRect(rect, r, r, Path.Direction.CW) })
            cv.drawRect(rect, paint)
            cv.restoreToCount(save)

            val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                color = 0x33FFFFFF
                strokeWidth = 1.5f * density
            }
            cv.drawRoundRect(rect, r, r, stroke)
            out
        } catch (_: Throwable) {
            null
        }
    }

    /** 秒 -> "m:ss" 时间文本。 */
    private fun fmt(sec: Int): String {
        val s = sec.coerceAtLeast(0)
        val m = s / 60
        val r = s % 60
        return String.format(java.util.Locale.US, "%d:%02d", m, r)
    }
}

/**
 * 桌面播放组件（尺寸自适应：2×2 方形 / 大卡两档，拖拽 2×2↔2×4↔3×4 无缝切换）。
 */
class PlayerWidgetProvider : AppWidgetProvider() {

    companion object {
        /** 刷新所有已放置的组件（Flutter 推送状态后调用），含识曲样式组件。 */
        fun updateAll(ctx: Context) = WidgetShared.updateAll(ctx)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val s = WidgetShared.stateJson(context) ?: JSONObject()
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, WidgetShared.buildViewsForId(context, s, id))
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        val (cw, ch) = WidgetShared.cellsOf(newOptions)
        // 两档自适应：≤2×2 用方形布局，其余（含 2×4/3×4 等纵向尺寸）用大卡，
        // 拖拽缩放时即时切换布局；横向 4×2 需求由识曲组件承担，此组件不再有横条档。
        val mode = if (cw <= 2 && ch <= 2) WidgetShared.MODE_2X2 else WidgetShared.MODE_TALL
        context.getSharedPreferences(WidgetShared.SP_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString("layout_" + appWidgetId, mode)
            .apply()
        appWidgetManager.updateAppWidget(
            appWidgetId,
            WidgetShared.buildViewsForId(
                context, WidgetShared.stateJson(context) ?: JSONObject(), appWidgetId))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        WidgetShared.handleAction(context, intent)
    }
}