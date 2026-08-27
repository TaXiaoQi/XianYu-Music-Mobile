package com.xianyumusic.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.os.Handler
import android.os.Looper
import android.widget.RemoteViews
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 桌面播放组件。
 *
 * 渲染：读 SharedPreferences("player_widget"/"state") 的 JSON（由 Flutter 侧随播放状态
 * 写入），构建 RemoteViews（封面圆角落 draw / 歌名 / 歌手 / 播放暂停 / 进度 / 循环模式）。
 * 控制：按钮 PendingIntent 发广播到本 Provider，若 App 进程存活（FlutterEngine 已挂载，
 * MessengerHolder.messenger 非空）→ 经 MethodChannel('xianyu/player_widget') 回调 Flutter
 * 驱动播放器；否则（进程被杀）→ 拉起 MainActivity 兜底。
 */
class PlayerWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val ACTION_PREFIX = "xianyu.widget.action."
        private const val SP_NAME = "player_widget"
        private const val SP_KEY = "state"
        private const val PACKAGE = "com.xianyumusic.app"

        private val mainHandler = Handler(Looper.getMainLooper())

        private fun stateJson(ctx: Context): JSONObject? = try {
            val raw = ctx.getSharedPreferences(SP_NAME, Context.MODE_PRIVATE)
                .getString(SP_KEY, null) ?: return null
            JSONObject(raw)
        } catch (_: Exception) {
            null
        }

        /** 刷新所有已放置的组件（Flutter 推送状态后调用）。 */
        fun updateAll(ctx: Context) {
            val mgr = AppWidgetManager.getInstance(ctx)
            val ids = mgr.getAppWidgetIds(
                ComponentName(ctx, PlayerWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val views = buildViews(ctx, stateJson(ctx) ?: JSONObject())
            mgr.updateAppWidget(ids, views)
        }

        private fun buildViews(ctx: Context, s: JSONObject): RemoteViews {
            val views = RemoteViews(PACKAGE, R.layout.player_widget)

            val title = s.optString("title").takeUnless { it.isBlank() } ?: "弦予音乐"
            val artist = s.optString("artist").takeUnless { it.isBlank() } ?: "未在播放"
            views.setTextViewText(R.id.songText, title)
            views.setTextViewText(R.id.artistText, artist)

            val playing = s.optBoolean("playing")
            views.setImageViewResource(
                R.id.btnPlay, if (playing) R.drawable.ic_pause else R.drawable.ic_play)

            views.setProgressBar(R.id.progress, 100, s.optInt("progress").coerceIn(0, 100), false)
            views.setTextViewText(R.id.timeCur, fmt(s.optInt("position")))
            views.setTextViewText(R.id.timeDur, fmt(s.optInt("duration")))

            views.setImageViewResource(
                R.id.btnMode, when (s.optInt("playMode")) {
                    1 -> R.drawable.ic_notif_mode_repeat_one
                    2 -> R.drawable.ic_notif_mode_shuffle
                    else -> R.drawable.ic_notif_mode_repeat
                })

            val cover = landscapeCover(ctx, s.optString("coverPath"))
            if (cover != null) {
                views.setImageViewBitmap(R.id.bgCover, cover)
            } else {
                // 无封面：整卡回落到暗色渐变底（拉伸图形资源无副作用），不清不糊。
                views.setImageViewResource(R.id.bgCover, R.drawable.widget_bg)
            }

            views.setOnClickPendingIntent(R.id.root, openPending(ctx, 1000))
            views.setOnClickPendingIntent(R.id.btnPrev, pending(ctx, "previous", 1001))
            views.setOnClickPendingIntent(R.id.btnPlay, pending(ctx, "toggle", 1002))
            views.setOnClickPendingIntent(R.id.btnNext, pending(ctx, "next", 1003))
            views.setOnClickPendingIntent(R.id.btnMode, pending(ctx, "cyclePlayMode", 1004))
            views.setOnClickPendingIntent(R.id.btnOpen, openPending(ctx, 1005))
            return views
        }

        private fun pending(ctx: Context, action: String, requestCode: Int): PendingIntent =
            PendingIntent.getBroadcast(
                ctx, requestCode,
                Intent(ctx, PlayerWidgetProvider::class.java)
                    .setAction(ACTION_PREFIX + action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        private fun openPending(ctx: Context, requestCode: Int): PendingIntent =
            PendingIntent.getActivity(
                ctx, requestCode,
                Intent(ctx, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        /** 封面 -> 圆角横版背景位图（无封面/失败返回 null）。 */
        private fun landscapeCover(ctx: Context, path: String): Bitmap? {
            if (path.isBlank()) return null
            return try {
                val bmp = BitmapFactory.decodeFile(path) ?: return null
                val density = ctx.resources.displayMetrics.density
                // 目标横版尺寸（2:1），radius 随卡片圆角；RemoteViews 无法裁剪子 View，
                // 所以在位图里就把四角裁圆，fitXY 铺满时四角贴合圆角卡。
                val w = (360 * density).toInt().coerceAtLeast(2)
                val h = (180 * density).toInt().coerceAtLeast(2)

                // centerCrop：封面按中心裁满横版，避免拉伸变形。
                val srcW = bmp.width.toFloat()
                val srcH = bmp.height.toFloat()
                val scale = maxOf(w / srcW, h / srcH)
                val cw = (w / scale).coerceAtMost(srcW)
                val ch = (h / scale).coerceAtMost(srcH)
                val sx = ((srcW - cw) / 2f).toInt()
                val sy = ((srcH - ch) / 2f).toInt()
                val crop = Bitmap.createBitmap(
                    bmp, sx, sy, cw.toInt(), ch.toInt())
                val scaled = Bitmap.createScaledBitmap(crop, w, h, true)

                val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                val cv = Canvas(out)
                val paint = Paint(Paint.ANTI_ALIAS_FLAG)
                paint.setShader(BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP))
                val r = 20 * density
                cv.drawRoundRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), r, r, paint)
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

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val views = buildViews(context, stateJson(context) ?: JSONObject())
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
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
}