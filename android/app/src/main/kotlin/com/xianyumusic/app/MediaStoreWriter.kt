package com.xianyumusic.app

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import java.io.File

/**
 * MediaStore 写入回退：部分国产 ROM（sdcardfs/纯净模式沙箱）即便授予
 * 「所有文件访问」（MANAGE_EXTERNAL_STORAGE）也会拦截应用对公共存储的
 * 直接路径写入，表现为 Rust 侧 File::create 报 Permission denied。
 * API 29+ 应用对「自己插入」的媒体条目拥有读写权（无需任何存储权限），
 * 经 ContentResolver 流式写入可绕开直写限制，是标准兼容做法。
 *
 * 音频走 Audio 集合（RELATIVE_PATH 必须在 Music/ 等媒体目录下，由 Dart 侧
 * 映射）；歌词等非媒体文件走 Downloads 集合（RELATIVE_PATH 必须在
 * Download/ 下）。所有 I/O 由调用方（safAsync 线程池）保证不在主线程。
 */
object MediaStoreWriter {

    private fun collectionFor(mime: String): Uri =
        if (mime.startsWith("audio/")) MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        else MediaStore.Downloads.EXTERNAL_CONTENT_URI

    /** 把 srcPath 文件经 MediaStore 写入 relativePath 目录（如 Music/弦予）。
     *  同名冲突由 MediaStore 自动追加 " (n)" 去重，返回以查询到的真实落盘
     *  路径（_data 列）为准；查询失败时按标准卷路径拼接兜底。失败抛异常并
     *  清理 IS_PENDING 条目。 */
    fun writeFromPath(
        context: Context,
        relativePath: String,
        displayName: String,
        mime: String,
        srcPath: String,
    ): String {
        val resolver = context.contentResolver
        val collection = collectionFor(mime)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert 返回 null")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                File(srcPath).inputStream().use { ins -> ins.copyTo(out) }
            } ?: throw IllegalStateException("MediaStore 输出流打开失败")
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null, null,
            )
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw e
        }
        return queryDataPath(resolver, collection, relativePath, displayName)
            ?: "${android.os.Environment.getExternalStorageDirectory().absolutePath}" +
                "/$relativePath/$displayName"
    }

    /** 回查真实落盘路径（IS_PENDING 清零后 _data 稳定）。 */
    private fun queryDataPath(
        resolver: android.content.ContentResolver,
        collection: Uri,
        relativePath: String,
        displayName: String,
    ): String? {
        return try {
            resolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns.DATA),
                "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?",
                arrayOf(displayName, "$relativePath/"),
                null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                    if (idx >= 0 && !c.isNull(idx)) c.getString(idx) else null
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }

    /** 按绝对路径删除媒体条目（仅本应用拥有的条目可删，系统的 Data 列选择
     *  在 30+ 对非自有条目会被拒）。音频与 Downloads 两个集合都尝试。 */
    fun deleteMedia(context: Context, path: String): Boolean {
        val resolver = context.contentResolver
        for (collection in listOf(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
        )) {
            try {
                val deleted = resolver.delete(
                    collection,
                    "${MediaStore.MediaColumns.DATA}=?",
                    arrayOf(path),
                )
                if (deleted > 0) return true
            } catch (_: Exception) {
            }
        }
        return false
    }
}
