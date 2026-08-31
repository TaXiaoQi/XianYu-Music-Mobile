package com.xianyumusic.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * 状态栏/通知栏歌词通知管理器。
 *
 * Flutter 侧 StatusBarLyricsController 经 MethodChannel(xianyu/status_lyric) 推送
 * 当前歌词行，本类把它渲染成一条「歌词跟踪」通知：contentText 随歌词行实时更新，
 * 展示在系统通知栏/锁屏。蓝牙联屏/部分车机可读取通知文本作歌词显示。
 *
 * 与 audio_service 的媒体控制通知相互独立：这里只管歌词文本，不做播放控制。
 */
object StatusBarLyricsNotification {
    const val CHANNEL = "xianyu/status_lyric"
    const val NOTIFICATION_ID = 7041
    private const val CHANNEL_ID = "cc.xymusic.mobile.channel.statuslyric"

    private var lastTitle: String? = null
    private var lastArtist: String? = null
    private var lastLyric: String? = null

    /** 更新歌词通知；歌词行变化时由 Flutter 侧驱动调用，行不变不重复 notify。 */
    fun show(context: Context, title: String, artist: String, lyric: String, coverPath: String?) {
        lastTitle = title
        lastArtist = artist
        lastLyric = lyric
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannel(context, nm)

        val launchIntent = PendingIntent.getActivity(
            context,
            0,
            context.packageManager.getLaunchIntentForPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(lyric)
            .setSubText(if (artist.isBlank()) "弦予音乐" else artist)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .setContentIntent(launchIntent)
            .setShowWhen(false)

        val cover = decodeCover(coverPath)
        if (cover != null) builder.setLargeIcon(cover)

        nm.notify(NOTIFICATION_ID, builder.build())
    }

    fun cancel(context: Context) {
        lastTitle = null
        lastArtist = null
        lastLyric = null
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(NOTIFICATION_ID)
    }

    private fun ensureChannel(context: Context, nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        // 同 ID 重复创建会更新渠道名称/描述，保证改名「车机歌词」对已有安装生效
        val channel = NotificationChannel(
            CHANNEL_ID,
            "车机歌词",
            NotificationManager.IMPORTANCE_LOW
        ).apply { description = "把当前歌词行推送到系统通知，供车机 / 蓝牙屏读取显示" }
        nm.createNotificationChannel(channel)
    }

    private fun decodeCover(path: String?): Bitmap? {
        if (path.isNullOrBlank()) return null
        return try {
            BitmapFactory.decodeFile(path)
        } catch (_: Throwable) {
            null
        }
    }
}