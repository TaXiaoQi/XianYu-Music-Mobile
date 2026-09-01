package com.xianyumusic.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat

object DownloadNotification {
    const val CHANNEL = "xianyu/download_notification"
    const val NOTIFICATION_ID = 8052
    private const val CHANNEL_ID = "cc.xymusic.mobile.channel.download"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var dismissRunnable: Runnable? = null

    fun showOrUpdate(
        context: Context,
        currentTitle: String,
        currentArtist: String,
        doneCount: Int,
        totalCount: Int,
        progressPercent: Int,
        isFinished: Boolean,
        isFailed: Boolean
    ) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannel(context, nm)

        // 每次更新时移除旧的定时关闭任务
        dismissRunnable?.let { mainHandler.removeCallbacks(it) }
        dismissRunnable = null

        val launchIntent = PendingIntent.getActivity(
            context,
            0,
            context.packageManager.getLaunchIntentForPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setOnlyAlertOnce(true)
            .setContentIntent(launchIntent)
            .setCategory(Notification.CATEGORY_PROGRESS)

        if (isFinished) {
            builder.setContentTitle("下载完成")
                .setContentText("已成功下载 $totalCount 首歌曲")
                .setSubText("已完成 $totalCount/$totalCount")
                .setOngoing(false)
                .setProgress(0, 0, false)
                .setAutoCancel(true)

            nm.notify(NOTIFICATION_ID, builder.build())

            // 5秒后自动关闭消失
            val runnable = Runnable {
                cancel(context)
            }
            dismissRunnable = runnable
            mainHandler.postDelayed(runnable, 5000L)
        } else {
            val titleText = if (totalCount > 1) {
                "正在下载 ($doneCount/$totalCount): $currentTitle"
            } else {
                "正在下载: $currentTitle"
            }

            val subInfo = if (currentArtist.isNotBlank()) "$currentArtist · " else ""
            val contentText = if (totalCount > 1) {
                "${subInfo}进度 $progressPercent% | 共 $totalCount 首"
            } else {
                "${subInfo}进度 $progressPercent%"
            }

            builder.setContentTitle(titleText)
                .setContentText(contentText)
                .setSubText("已完成 $doneCount/$totalCount")
                .setOngoing(true)
                .setProgress(100, progressPercent.coerceIn(0, 100), false)

            nm.notify(NOTIFICATION_ID, builder.build())
        }
    }

    fun cancel(context: Context) {
        dismissRunnable?.let { mainHandler.removeCallbacks(it) }
        dismissRunnable = null
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(NOTIFICATION_ID)
    }

    private fun ensureChannel(context: Context, nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "下载进度",
            NotificationManager.IMPORTANCE_LOW
        ).apply { description = "显示歌曲下载进度通知与实时状态" }
        nm.createNotificationChannel(channel)
    }
}
