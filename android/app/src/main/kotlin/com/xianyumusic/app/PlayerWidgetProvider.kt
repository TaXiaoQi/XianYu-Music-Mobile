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
import android.view.View
import android.widget.RemoteViews
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 桌面播放组件共享渲染与控制逻辑
 * （SquareWidgetProvider / RecognizeWidgetProvider 共用）。
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
    const val LAYOUT_PREFIX = "layout_"

    const val MODE_TALL = "tall"
    const val MODE_2X2 = "2x2"
    const val MODE_4X2 = "4x2"

    // 尺寸估算：平均每格约 70dp、左右边距合计 16dp。
    private const val CELL_TARGET_DP = 70
    private const val CELL_MARGIN_DP = 16

    // 封面位图边长（dp）：横版 60、2×2/识曲用大图保证清晰。
    private const val COVER_TALL_DP = 60
    private const val COVER_RECOGNIZE_DP = 120
    private const val COVER_2X2_SMALL_DP = 85

    // 卡片容器圆角（widget_bg 固定 24dp）：2×2/识曲封面按此绝对值渲染，
    // 避免按位图边长比例（0.26×）换算后随组件尺寸缩放导致的圆角错位。
    private const val CARD_CORNER_DP = 24f

    // 识曲（已改分享）深链：右上按钮经拉起 App 分享当前歌曲。
    private const val RECOGNIZE_LINK = "xianyu://open?target=share"

    // 模糊背景态的固定白字/白图标色（类播放详情页暗底白字）。
    private const val WHITE = -0x1
    private const val WHITE_SECONDARY = 0xB8FFFFFF.toInt()
    private const val WHITE_TIME = 0xAAFFFFFF.toInt()

    private val mainHandler = Handler(Looper.getMainLooper())

    // 进度/时间实时外推：Flutter 仅在状态推送时上报 position，播放中按墙钟外推
    // 周期性地用 partiallyUpdateAppWidget 局部刷新 progress + 时间，
    // 让进度条随播放平滑前进，而非「唱完一句才跳一下」。
    private const val PROGRESS_INTERVAL_MS = 300L
    private val progressOwner = HashMap<Int, Any>() // id -> 外推 token（状态变化即失效）

    // ---- 识曲/横条组件切歌时封面「平移 + 淡入淡出」----
    // RemoteViews 无补间动画：双封面叠层 + 多次局部 setAlpha/setTranslationX 逐帧推进；
    // 用「起始墙钟 + 已流逝」重算中间帧，即使期间被 5s 心跳等全量重建打断也能续帧。
    private const val COVER_ANIM_MS = 420L
    private const val COVER_ANIM_FRAME_MS = 40L
    // dir: +1=下一首（新封面自右滑入），-1=上一首（新封面自左滑入）。
    private class CoverSwap(
        val start: Long,
        val duration: Long,
        val slidePx: Float,
        val dir: Int,
        val layoutRes: Int,
        val mode: String,
        val sizeDp: Pair<Int, Int>?,
    )
    private val coverSwap = HashMap<Int, CoverSwap>()   // id -> 进行中的切歌动画（含起点）
    private val coverFrameScheduled = HashSet<Int>()     // id -> 是否已排程下一帧（防重复链）
    private val coverLivePath = HashMap<Int, String>()   // id -> 已稳定显示的封面路径
    private val coverLiveBitmap = HashMap<Int, Bitmap>() // id -> 已稳定显示的封面位图（作旧封面）

    /**
     * 进度条/时间实时外推。Flutter 仅在状态推送时刻上报 position/progress，播放中
     * 本端以「上报 position + 墙钟流逝」周期性局部刷新 progress 与当前时间，让进度条
     * 随播放平滑前进。封面切歌动画期间暂停外推，避免与动画同帧更新干扰观感；
     * 状态变化会 replace token 使旧外推失效。
     */
    private fun scheduleProgress(
        ctx: Context,
        mgr: AppWidgetManager,
        id: Int,
        mode: String,
        positionSec: Int,
        durationSec: Int,
        playing: Boolean,
    ) {
        val token = Any()
        progressOwner[id] = token
        if (!playing || durationSec <= 0) return
        val layout = layoutOf(mode)
        val anchorPos = positionSec
        val anchorWall = System.currentTimeMillis()
        val r = object : Runnable {
            override fun run() {
                if (progressOwner[id] !== token) return
                if (coverSwap[id] != null) {
                    // 封面切歌动画进行中：延后一帧，避免与动画帧交错。
                    mainHandler.postDelayed(this, PROGRESS_INTERVAL_MS)
                    return
                }
                val est = (anchorPos +
                    (System.currentTimeMillis() - anchorWall) / 1000L)
                    .coerceAtMost(durationSec.toLong()).toInt()
                try {
                    val v = RemoteViews(ctx.packageName, layout)
                    v.setProgressBar(R.id.progress, 100,
                        (est * 100 / durationSec).coerceIn(0, 100), false)
                    v.setTextViewText(R.id.timeCur, fmt(est))
                    v.setTextViewText(R.id.timeDur, fmt(durationSec))
                    mgr.partiallyUpdateAppWidget(id, v)
                } catch (_: Exception) {
                }
                mainHandler.postDelayed(this, PROGRESS_INTERVAL_MS)
            }
        }
        mainHandler.postDelayed(r, PROGRESS_INTERVAL_MS)
    }

    fun stateJson(ctx: Context): JSONObject? = try {
        val raw = ctx.getSharedPreferences(SP_NAME, Context.MODE_PRIVATE)
            .getString(SP_KEY, null) ?: return null
        JSONObject(raw)
    } catch (_: Exception) {
        null
    }

    private fun cellCount(size: Int): Int =
        ((size - 2 * CELL_MARGIN_DP + CELL_TARGET_DP - 1) / CELL_TARGET_DP).coerceAtLeast(1)

    fun cellsOf(newOptions: Bundle): Pair<Int, Int> = Pair(
        cellCount(newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)),
        cellCount(newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)))

    /** 多档判定（两个组件入口共用，歌词卡已移除）：宽≥3 → 4×2 横条，其余 → 2×2 方形。 */
    fun squareCellMode(o: Bundle): String {
        val (cw, ch) = cellsOf(o)
        return when {
            cw >= 3 -> MODE_4X2
            else -> MODE_2X2
        }
    }

    /** 按已存档档位构建组件（onAppWidgetOptionsChanged 写入档位；无存档用默认档）。 */
    fun buildEntry(
        ctx: Context,
        s: JSONObject,
        id: Int,
        provider: Class<out AppWidgetProvider>,
        rc: Int,
        defaultMode: String,
        enableRecognize: Boolean,
    ): RemoteViews {
        val mode = ctx.getSharedPreferences(SP_NAME, Context.MODE_PRIVATE)
            .getString(LAYOUT_PREFIX + id, null) ?: defaultMode
        val mgr = AppWidgetManager.getInstance(ctx)
        // 模糊背景按卡片实际显示尺寸生成，fitXY 铺满卡片时零拉伸，保证圆形圆角不会长成椭圆。
        val raw = widgetSizeDp(mgr, id)
        val cardDp = when (mode) {
            // 识别矮卡：扣上下留白 20×2（卡片比格子矮）。
            MODE_4X2 -> raw?.let { it.first to (it.second - 40).coerceAtLeast(1) }
            // 方块窄卡：扣左右留白 14×2（卡片比格子窄）。
            MODE_2X2 -> raw?.let { (it.first - 28).coerceAtLeast(1) to it.second }
            else -> raw
        }
        return buildViews(ctx, s, mode, provider, rc, id, cardDp, enableRecognize)
    }

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
    private const val PREVIEW_GEN_VERSION = 12
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
            SquareWidgetProvider::class.java to R.layout.player_widget_2x2,
            RecognizeWidgetProvider::class.java to R.layout.player_widget_recognize,
        )
        var ok = 0
        for ((cls, layout) in defs) {
            try {
                mgr.setWidgetPreview(
                    ComponentName(ctx, cls),
                    AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN,
                    RemoteViews(ctx.packageName, layout))
                ok++
            } catch (_: Exception) {
            }
        }
        if (ok == defs.size) {
            prefs.edit().putInt("preview_gen_version", PREVIEW_GEN_VERSION).apply()
        }
    }

    /** 刷新所有已放置的组件（三个 Provider 的全部 id），按各自尺寸/入口构建。 */
    fun updateAll(ctx: Context) {
        val mgr = AppWidgetManager.getInstance(ctx)
        val s = stateJson(ctx) ?: JSONObject()
        for (id in mgr.getAppWidgetIds(
            ComponentName(ctx, SquareWidgetProvider::class.java))) {
            mgr.updateAppWidget(id, buildEntry(ctx, s, id, SquareWidgetProvider::class.java, 4000, MODE_2X2, false))
        }
        for (id in mgr.getAppWidgetIds(
            ComponentName(ctx, RecognizeWidgetProvider::class.java))) {
            mgr.updateAppWidget(id, buildEntry(ctx, s, id, RecognizeWidgetProvider::class.java, 2000, MODE_4X2, true))
        }
    }

    /** 按显式布局模式构建（方形/识别固定样式共用）。 */
    fun buildViews(
        ctx: Context,
        s: JSONObject,
        mode: String,
        provider: Class<out AppWidgetProvider>,
        rc: Int,
        id: Int,
        sizeDp: Pair<Int, Int>? = null,
        enableRecognize: Boolean = false,
    ): RemoteViews {
        val layout = when (mode) {
            MODE_2X2 -> R.layout.player_widget_2x2
            MODE_4X2 -> R.layout.player_widget_recognize
            else -> R.layout.player_widget
        }
        val views = RemoteViews(ctx.packageName, layout)

        val title = s.optString("title").takeUnless { it.isBlank() } ?: "弦予音乐"
        val artist = s.optString("artist").takeUnless { it.isBlank() } ?: "未在播放"
        val playing = s.optBoolean("playing")
        val favorite = s.optBoolean("favorite")
        val floatingLyrics = s.optBoolean("floatingLyrics")
        val coverPath = s.optString("coverPath")
        views.setTextViewText(R.id.songText, title)
        views.setTextViewText(R.id.artistText, artist)
        views.setImageViewResource(
            R.id.btnPlay, if (playing) R.drawable.ic_pause else R.drawable.ic_play)

        when (mode) {
            MODE_2X2 -> {
                views.setOnClickPendingIntent(R.id.root, openPending(ctx, rc))
                views.setOnClickPendingIntent(
                    R.id.btnPrev, pending(ctx, "previous", rc + 1, provider))
                views.setOnClickPendingIntent(
                    R.id.btnPlay, pending(ctx, "toggle", rc + 2, provider))
                views.setOnClickPendingIntent(
                    R.id.btnNext, pending(ctx, "next", rc + 3, provider))
                // 封面模糊作整卡底色（老传统：100% 模糊），有背景时文字/图标置白。
                val blur2 = blurredBackground(ctx, coverPath, sizeDp)
                if (blur2 != null) {
                    views.setImageViewBitmap(R.id.bgCover, blur2)
                    views.setTextColor(R.id.songText, WHITE)
                    views.setTextColor(R.id.artistText, WHITE_SECONDARY)
                    views.setInt(R.id.btnPrev, "setColorFilter", WHITE)
                    views.setInt(R.id.btnPlay, "setColorFilter", WHITE)
                    views.setInt(R.id.btnNext, "setColorFilter", WHITE)
                }
            }

            MODE_4X2 -> {
                views.setProgressBar(
                    R.id.progress, 100, s.optInt("progress").coerceIn(0, 100), false)
                views.setTextViewText(R.id.timeCur, fmt(s.optInt("position")))
                views.setTextViewText(R.id.timeDur, fmt(s.optInt("duration")))
                scheduleProgress(
                    ctx, AppWidgetManager.getInstance(ctx), id, MODE_4X2,
                    s.optInt("position"), s.optInt("duration"), playing)
                // 封面模糊作整卡底色（老传统：缩 24px 再放大 = 100% 模糊），
                // 有背景时文字/图标置白；无封面回退主题平面底。
                val blur = blurredBackground(ctx, coverPath, sizeDp)
                if (blur != null) {
                    views.setImageViewBitmap(R.id.bgCover, blur)
                    views.setTextColor(R.id.songText, WHITE)
                    views.setTextColor(R.id.artistText, WHITE_SECONDARY)
                    views.setTextColor(R.id.timeCur, WHITE_TIME)
                    views.setTextColor(R.id.timeDur, WHITE_TIME)
                    views.setInt(R.id.btnPrev, "setColorFilter", WHITE)
                    views.setInt(R.id.btnPlay, "setColorFilter", WHITE)
                    views.setInt(R.id.btnNext, "setColorFilter", WHITE)
                    views.setInt(R.id.btnRecognize, "setColorFilter", WHITE)
                }
                // 识曲入口显示右上听歌识曲钮（定位后经深链拉起识曲页），其他入口隐藏。
                if (enableRecognize) {
                    views.setViewVisibility(R.id.btnRecognize, android.view.View.VISIBLE)
                    views.setOnClickPendingIntent(R.id.btnRecognize, recognizePending(ctx, rc + 4))
                } else {
                    views.setViewVisibility(R.id.btnRecognize, android.view.View.GONE)
                }
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
                scheduleProgress(
                    ctx, AppWidgetManager.getInstance(ctx), id, mode,
                    s.optInt("position"), s.optInt("duration"), playing)

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

        if (mode == MODE_2X2 || mode == MODE_4X2) {
            // 带封面的组件形态：双封面叠层，切歌时做平移 + 淡入淡出。
            applyCoverSwap(
                ctx,
                AppWidgetManager.getInstance(ctx),
                views,
                id,
                coverPath,
                s.optInt("coverDir", 1),
                layoutOf(mode),
                mode,
                sizeDp)
        } else {
            // 三行大卡等其余形态：单封面。
            val cover = roundedCover(ctx, coverPath, COVER_TALL_DP)
            if (cover != null) {
                views.setImageViewBitmap(R.id.cover, cover)
            } else {
                views.setImageViewResource(R.id.cover, R.drawable.ic_widget_music_note)
            }
        }

        // 三行大卡：封面模糊 + 暗色蒙层作整卡背景（类播放详情页），
        // 有背景时文字/图标运行时置白；无封面回退主题平面底。
        if (mode == MODE_TALL) {
            val blur = blurredBackground(ctx, coverPath, sizeDp)
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

    // ---- 4×2 封面切歌动画（平移 + 淡入淡出）----

    /** 各组件形态对应的布局 res id（动画逐帧局部更新按此布局构建 RemoteViews）。 */
    private fun layoutOf(mode: String): Int = when (mode) {
        MODE_2X2 -> R.layout.player_widget_2x2
        MODE_4X2 -> R.layout.player_widget_recognize
        else -> R.layout.player_widget
    }

    /** 按形态渲染当前封面位图（清晰度与圆角随形态而定）。 */
    private fun renderCoverBitmap(
        ctx: Context, mode: String, path: String, sizeDp: Pair<Int, Int>?,
    ): Bitmap? {
        if (path.isBlank()) return null
        return when (mode) {
            // 2×2：缩小居中方形封面。
            MODE_2X2 -> roundedCover(ctx, path, COVER_2X2_SMALL_DP)
            // 4×2：固定尺寸方形封面（与卡片边缘留间距）。
            MODE_4X2 -> roundedCover(ctx, path, COVER_RECOGNIZE_DP)
            else -> roundedCover(ctx, path, COVER_TALL_DP)
        }
    }

    /** 封面平移滑距（px）：取各形态封面的显示宽度。 */
    private fun coverSlidePx(ctx: Context, mode: String, sizeDp: Pair<Int, Int>?): Float {
        val density = ctx.resources.displayMetrics.density
        return when (mode) {
            MODE_2X2 -> COVER_2X2_SMALL_DP * density
            MODE_4X2 -> COVER_RECOGNIZE_DP * density
            else -> COVER_TALL_DP * density
        }
    }

    private fun coverPlaceholder(ctx: Context, views: RemoteViews, mode: String) {
        views.setImageViewResource(R.id.coverNew, R.drawable.ic_widget_music_note)
        views.setViewVisibility(R.id.coverNew, View.VISIBLE)
    }

    /**
     * 带封面组件（2×2 / 4×2 / 歌词卡）的双封面渲染：封面路径变化时起一次
     * 「新封面自右/左滑入 + 淡入、旧封面反向滑出 + 淡出」的动画（滑向随切歌
     * 方向 dir）；无变化直接绘制 coverNew、隐藏 coverOld。以「起始墙钟 + 已流逝」
     * 在每次全量重建中重算中间帧，保证动画不被 5s 心跳等 rebuild 打断。
     */
    private fun applyCoverSwap(
        ctx: Context,
        mgr: AppWidgetManager,
        views: RemoteViews,
        id: Int,
        newPath: String,
        dir: Int,
        layoutRes: Int,
        mode: String,
        sizeDp: Pair<Int, Int>?,
    ) {
        // 归一化到 ±1（默认向前）。
        val d = if (dir >= 1) 1 else -1
        val cur = coverSwap[id]
        if (cur != null) {
            // 动画进行中：按已流逝渲染中间帧。
            val p = ((System.currentTimeMillis() - cur.start) / cur.duration.toFloat())
                .coerceIn(0f, 1f)
            if (p >= 1f) {
                val newBmp = renderCoverBitmap(ctx, mode, newPath, sizeDp)
                if (newBmp != null) views.setImageViewBitmap(R.id.coverNew, newBmp)
                else coverPlaceholder(ctx, views, mode)
                settleCoverSwap(ctx, mgr, id, layoutRes, newPath, newBmp)
                return
            }
            // 平移 + 淡入淡出（二层一致，位移掩盖小图 alpha 抖动）。
            val old = coverLiveBitmap[id]
            if (old != null) {
                views.setImageViewBitmap(R.id.coverOld, old)
                views.setFloat(R.id.coverOld, "setAlpha", 1f - p)
                views.setFloat(R.id.coverOld, "setTranslationX", -p * cur.slidePx * cur.dir)
            } else {
                views.setViewVisibility(R.id.coverOld, View.GONE)
            }
            val np = renderCoverBitmap(ctx, mode, newPath, sizeDp)
            if (np != null) views.setImageViewBitmap(R.id.coverNew, np)
            else coverPlaceholder(ctx, views, mode)
            views.setFloat(R.id.coverNew, "setAlpha", p)
            views.setFloat(R.id.coverNew, "setTranslationX", (1f - p) * cur.slidePx * cur.dir)
            scheduleCoverSwap(ctx, mgr, id)
            return
        }
        if (newPath == coverLivePath[id] && newPath.isNotEmpty()) {
            // 封面未变：兜底强制归位中心，直接绘制 coverNew、隐藏 coverOld。
            val bmp = renderCoverBitmap(ctx, mode, newPath, sizeDp)
            if (bmp != null) views.setImageViewBitmap(R.id.coverNew, bmp)
            else coverPlaceholder(ctx, views, mode)
            views.setFloat(R.id.coverNew, "setTranslationX", 0f)
            views.setViewVisibility(R.id.coverOld, View.GONE)
            return
        }
        // 封面变化（第一次渲染/切歌：无旧封面则仅淡入新封面）。
        val newBmp = renderCoverBitmap(ctx, mode, newPath, sizeDp)
        val old = coverLiveBitmap[id]
        val slide = coverSlidePx(ctx, mode, sizeDp)
        coverSwap[id] = CoverSwap(
            System.currentTimeMillis(), COVER_ANIM_MS, slide, d, layoutRes, mode, sizeDp)
        if (old != null) {
            views.setImageViewBitmap(R.id.coverOld, old)
            views.setFloat(R.id.coverOld, "setAlpha", 1f)
            views.setFloat(R.id.coverOld, "setTranslationX", 0f)
        } else {
            views.setViewVisibility(R.id.coverOld, View.GONE)
        }
        if (newBmp != null) views.setImageViewBitmap(R.id.coverNew, newBmp)
        else coverPlaceholder(ctx, views, mode)
        views.setFloat(R.id.coverNew, "setAlpha", 0f)
        views.setFloat(R.id.coverNew, "setTranslationX", d * slide)
        scheduleCoverSwap(ctx, mgr, id)
    }

    /** 动画结束：双封面归位（coverNew 满显、coverOld 隐藏）并落库稳定封面。 */
    private fun settleCoverSwap(
        ctx: Context,
        mgr: AppWidgetManager,
        id: Int,
        layoutRes: Int,
        newPath: String,
        newBmp: Bitmap?,
    ) {
        coverSwap.remove(id)
        coverLivePath[id] = newPath
        if (newBmp != null) coverLiveBitmap[id] = newBmp else coverLiveBitmap.remove(id)
        try {
            val v = RemoteViews(ctx.packageName, layoutRes)
            v.setFloat(R.id.coverNew, "setAlpha", 1f)
            v.setFloat(R.id.coverNew, "setTranslationX", 0f)
            v.setFloat(R.id.coverOld, "setAlpha", 0f)
            v.setFloat(R.id.coverOld, "setTranslationX", 0f)
            v.setViewVisibility(R.id.coverOld, View.GONE)
            mgr.partiallyUpdateAppWidget(id, v)
        } catch (_: Exception) {}
    }

    /** 排程下一帧；同一 id 已排程则不重复入队，避免重建设下的帧链爆炸。 */
    private fun scheduleCoverSwap(ctx: Context, mgr: AppWidgetManager, id: Int) {
        if (!coverFrameScheduled.add(id)) return
        mainHandler.postDelayed({
            coverFrameScheduled.remove(id)
            val cur = coverSwap[id] ?: return@postDelayed
            val p = ((System.currentTimeMillis() - cur.start) / cur.duration.toFloat())
                .coerceIn(0f, 1f)
            if (p >= 1f) {
                val curPath = stateJson(ctx)?.optString("coverPath").orEmpty()
                settleCoverSwap(
                    ctx, mgr, id, cur.layoutRes, curPath,
                    renderCoverBitmap(ctx, cur.mode, curPath, cur.sizeDp))
                return@postDelayed
            }
            try {
                val v = RemoteViews(ctx.packageName, cur.layoutRes)
                v.setFloat(R.id.coverNew, "setAlpha", p)
                v.setFloat(R.id.coverNew, "setTranslationX", (1f - p) * cur.slidePx * cur.dir)
                v.setFloat(R.id.coverOld, "setAlpha", 1f - p)
                v.setFloat(R.id.coverOld, "setTranslationX", -p * cur.slidePx * cur.dir)
                mgr.partiallyUpdateAppWidget(id, v)
            } catch (_: Exception) {}
            scheduleCoverSwap(ctx, mgr, id)
        }, COVER_ANIM_FRAME_MS)
    }

    /** 组件被移除时清理封面动画/缓存状态，避免孤儿引用。 */
    fun clearId(id: Int) {
        coverSwap.remove(id)
        coverFrameScheduled.remove(id)
        coverLivePath.remove(id)
        coverLiveBitmap.remove(id)
        progressOwner.remove(id)
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
    private fun blurredBackground(
        ctx: Context, path: String, sizeDp: Pair<Int, Int>?,
    ): Bitmap? {
        if (path.isBlank()) return null
        return try {
            val bmp = BitmapFactory.decodeFile(path) ?: return null
            val density = ctx.resources.displayMetrics.density
            // 位图宽高 = 卡片实际像素尺寸（与卡片同宽高比，fitXY 渲染零变形），
            // 圆角用与卡片一致的绝对 24dp，避免往昔比例圆角+centerCrop 顶坏卡片圆角。
            val w = ((sizeDp?.first ?: 300) * density).toInt().coerceAtLeast(1)
            val h = ((sizeDp?.second ?: 150) * density).toInt().coerceAtLeast(1)
            val radius = CARD_CORNER_DP * density
            val smallW = 12
            val smallH = (smallW.toLong() * bmp.height / bmp.width).toInt().coerceAtLeast(1)
            val small = Bitmap.createScaledBitmap(bmp, smallW, smallH, true)
            val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val cv = Canvas(out)

            // 圆角裁剪（卡片绝对 24dp）。
            val corner = Path().apply {
                addRoundRect(
                    RectF(0f, 0f, w.toFloat(), h.toFloat()),
                    radius, radius, Path.Direction.CW)
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
            // 桌面歌词页氛围：全局压暗一层收敛明亮封面色，再叠上浅下深渐变出深底观感。
            val dim = Paint().apply { color = 0x38000000.toInt() }
            cv.drawRect(0f, 0f, w.toFloat(), h.toFloat(), dim)

            val scrim = Paint().apply {
                shader = LinearGradient(
                    0f, 0f, 0f, h.toFloat(),
                    0x88000000.toInt(), 0xE6000000.toInt(), Shader.TileMode.CLAMP)
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
            // 圆角固定为卡片容器圆角（widget_bg 24dp），与卡片精确重合；外加一圈细描边增强卡片感。
            val r = CARD_CORNER_DP * density
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

    /** 秒 -> "m:ss" 时间文本。 */
    private fun fmt(sec: Int): String {
        val s = sec.coerceAtLeast(0)
        val m = s / 60
        val r = s % 60
        return String.format(java.util.Locale.US, "%d:%02d", m, r)
    }
}