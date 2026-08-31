package com.xianyumusic.app

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 系统分享（ACTION_SEND）：复刻原生应用的标准发法——两参 Intent.createChooser
 * + 普通 startActivity。
 *
 * 为什么不用 share_plus：它的 Android 端为了向 Dart 回报分享结果，走的是
 * startActivityForResult + 三参 createChooser（带 PendingIntent intentSender）。
 * 国产 ROM（HyperOS 等）的自家分享面板只接管普通 startActivity 发起的 chooser，
 * 该路径会落回 AOSP 原生 sharesheet（即「安卓公用的」面板）。
 * 参考实现：RwaS-Music PlayerAudioShare.launchAudioShare。
 */
internal object SystemShare {
    const val CHANNEL = "xianyu/system_share"

    fun register(messenger: BinaryMessenger, activity: MainActivity) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "share" -> {
                    val text = call.argument<String>("text") ?: ""
                    val filePath = call.argument<String>("filePath")
                    result.success(share(activity, text, filePath))
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 发起系统分享；返回是否成功弹出。 */
    private fun share(activity: MainActivity, text: String, filePath: String?): Boolean {
        val send = Intent(Intent.ACTION_SEND)
        val uri: Uri? = if (!filePath.isNullOrBlank()) {
            runCatching {
                FileProvider.getUriForFile(
                    activity, "${activity.packageName}.share_files", File(filePath))
            }.getOrNull()
        } else {
            null
        }
        if (uri != null) {
            send.type = resolveMimeType(filePath!!)
            send.putExtra(Intent.EXTRA_STREAM, uri)
            send.clipData = ClipData.newUri(activity.contentResolver, "cover", uri)
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } else {
            send.type = "text/plain"
        }
        if (text.isNotEmpty()) send.putExtra(Intent.EXTRA_TEXT, text)
        val chooser = Intent.createChooser(send, null)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            activity.startActivity(chooser)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun resolveMimeType(path: String): String {
        val ext = path.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?.takeIf { it.startsWith("image/") }
            ?: "image/*"
    }
}
