package com.example.xianyu_music_mobile

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.util.SparseArray
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * SAF 引擎：让用户选择一个目录树并持久化读取授权，随后递归枚举其中的音频文件，
 * 并把每个文件以 Android fd 交给 Dart（Rust 侧经 `/proc/self/fd/N` 复用路径式解析）。
 */
class SafEngine(private val context: Context) {

    private val resolver: ContentResolver = context.applicationContext.contentResolver

    /** 已打开的 fd -> 持有其生命周期的 ParcelFileDescriptor（防 GC/保持打开）。 */
    private val openFds = SparseArray<android.os.ParcelFileDescriptor>()

    /** 目录树选择的异步回填目标（由 MainActivity 的 ActivityResult 回调写入）。 */
    var pendingTreeResult: MethodChannel.Result? = null

    fun onTreeResult(uri: Uri?) {
        val result = pendingTreeResult
        pendingTreeResult = null
        if (uri != null) {
            try {
                resolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: Exception) {
                // 权限已拥有或无法持久化均不致命
            }
        }
        result?.success(uri?.toString() ?: "")
    }

    fun persistPermission(treeUriStr: String) {
        try {
            resolver.takePersistableUriPermission(
                Uri.parse(treeUriStr), Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Exception) { /* 已授权时抛出，忽略 */ }
    }

    /** 递归枚举 tree 下的音频文件，返回 JSONArray[{docId,name,ext,size}]。 */
    fun listAudioTree(treeUriStr: String, whitelist: List<String>): String {
        val out = JSONArray()
        val treeUri = Uri.parse(treeUriStr)
        val extSet: Set<String> = whitelist
            .map { it.trim().lowercase().trimStart('.') }
            .filter { it.isNotEmpty() }
            .toSet()
        val root = DocumentsContract.getTreeDocumentId(treeUri)
        walk(treeUri, root, extSet, out, 0)
        return out.toString()
    }

    private fun walk(
        treeUri: Uri,
        docId: String,
        extSet: Set<String>,
        out: JSONArray,
        depth: Int,
    ) {
        if (depth > 24) return
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
        val cursor = try {
            resolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                ),
                null, null, null,
            )
        } catch (_: Exception) {
            null
        } ?: return
        cursor.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0) ?: continue
                val name = c.getString(1) ?: continue
                val mime = c.getString(2) ?: ""
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walk(treeUri, id, extSet, out, depth + 1)
                    continue
                }
                val ext = name.substringAfterLast('.', "").lowercase()
                if (ext.isNotEmpty() && extSet.contains(ext)) {
                    val o = JSONObject()
                    o.put("docId", id)
                    o.put("name", name)
                    o.put("ext", ext)
                    o.put("size", c.getLong(3))
                    out.put(o)
                }
            }
        }
    }

    /** 打开 tree 下某个 document，返回其 fd（fd 由本引擎持有保活，需 closeFd）。 */
    fun openFd(treeUriStr: String, docId: String): Int {
        val treeUri = Uri.parse(treeUriStr)
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        val pfd = resolver.openFileDescriptor(docUri, "r") ?: return -1
        val fd = pfd.fd
        openFds.append(fd, pfd)
        return fd
    }

    fun closeFd(fd: Int) {
        val pfd = openFds.get(fd)
        openFds.delete(fd)
        pfd?.close()
    }
}