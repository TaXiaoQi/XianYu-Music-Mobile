package com.xianyumusic.app

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.SparseArray
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * SAF 引擎：让用户选择一个目录树并持久化读取授权，随后递归枚举其中的音频文件，
 * 并把每个文件以 Android fd 交给 Dart（Rust 侧经 `/proc/self/fd/N` 复用路径式解析）。
 */
class SafEngine(private val context: Context) {

    private val resolver: ContentResolver = context.applicationContext.contentResolver

    /** 已打开的 fd -> 持有其生命周期的 ParcelFileDescriptor（防 GC/保持打开）。 */
    private val openFds = SparseArray<android.os.ParcelFileDescriptor>()

    companion object {
        /**
         * 目录树选择的异步回填目标。
         *
         * 必须放 companion：系统选择器是独立 Activity，期间本 Activity 可能被
         * 回收重建（onActivityResult 时是全新实例），实例字段会丢失回填目标，
         * 导致 Dart 侧 Future 永久挂起。engine 同进程存活时静态引用依然有效。
         */
        var pendingTreeResult: MethodChannel.Result? = null
    }

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

    /** 该目录树的读取授权是否仍在本应用的持久化名单中（重启后依然有效的前提）。 */
    fun isTreePersisted(treeUriStr: String): Boolean {
        val treeUri = Uri.parse(treeUriStr)
        return resolver.persistedUriPermissions.any {
            it.isReadPermission && it.uri.toString() == treeUri.toString()
        }
    }

    /**
     * 目录树当前是否真正可读：持久化名单命中 + 实际探测根 document 可 query。
     *
     * 名单缺失（清除数据/系统撤销/ROM 限制）或探测失败（SD 卡拔出）都算失效。
     */
    fun isTreeAvailable(treeUriStr: String): Boolean {
        if (!isTreePersisted(treeUriStr)) return false
        return try {
            val treeUri = Uri.parse(treeUriStr)
            val rootDoc = DocumentsContract.buildDocumentUriUsingTree(
                treeUri, DocumentsContract.getTreeDocumentId(treeUri))
            resolver.query(
                rootDoc,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null, null, null,
            )?.use { it.count > 0 } ?: false
        } catch (_: Exception) {
            false
        }
    }

    /** 释放目录树的持久化读取授权（移除扫描目录时调用，避免耗尽系统名额）。 */
    fun releasePermission(treeUriStr: String) {
        try {
            resolver.releasePersistableUriPermission(
                Uri.parse(treeUriStr), Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Exception) { }
    }

    /**
     * 经 MediaStore 聚合设备上包含音频的真实目录，返回 JSONArray[{path,count}]。
     *
     * 已授予 READ_MEDIA_AUDIO / READ_EXTERNAL_STORAGE 后媒体库即可看到全部音频，
     * 应用内目录选择器以此构建目录树——添加目录不再弹系统 SAF 授权框
     * （音乐权限只授一次；SAF 选择器仅作 DSD / USB 等特殊目录的兜底）。
     * path 为真实绝对路径（如 `/storage/emulated/0/Music`），count 为该目录
     * 直属歌曲数，可被 Rust 路径式扫描直接消费。
     */
    fun listMediaAudioFolders(): String {
        val counts = LinkedHashMap<String, Int>()
        val projection = arrayOf(MediaStore.Audio.Media.DATA)
        resolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection, null, null, null,
        )?.use { c ->
            val dataIdx = c.getColumnIndex(MediaStore.Audio.Media.DATA)
            if (dataIdx >= 0) {
                while (c.moveToNext()) {
                    val data = c.getString(dataIdx) ?: continue
                    val parent = data.substringBeforeLast('/', "")
                    if (parent.isEmpty()) continue
                    counts[parent] = (counts[parent] ?: 0) + 1
                }
            }
        }
        val arr = JSONArray()
        counts.entries.sortedBy { it.key }.forEach { (path, count) ->
            arr.put(JSONObject().put("path", path).put("count", count))
        }
        return arr.toString()
    }

    /** 把 tree URI 转成用户可读的路径（如 `primary:Music/Flac` → `内部存储/Music/Flac`）。 */
    fun friendlyTreeName(treeUriStr: String): String {
        val docId = try {
            DocumentsContract.getTreeDocumentId(Uri.parse(treeUriStr))
        } catch (_: Exception) {
            return treeUriStr
        }
        val idx = docId.indexOf(':')
        if (idx < 0) return docId
        val volume = docId.substring(0, idx)
        val path = docId.substring(idx + 1)
        val label = when (volume) {
            "primary", "home" -> "内部存储"
            else -> "存储卡"
        }
        return if (path.isEmpty()) label else "$label/$path"
    }

    /** 递归枚举 tree 下的音频文件，返回 JSONArray[{docId,name,ext,size}]。 */
    fun listAudioTree(treeUriStr: String, whitelist: List<String>): String {
        // 授权失效时显式抛错，让 Dart 收到明确原因而非静默的空列表
        // （用户会误以为目录里没有音乐）。
        if (!isTreeAvailable(treeUriStr)) {
            throw SecurityException("目录授权已失效，请在扫描文件夹页重新授权")
        }
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

    /**
     * 把 tree 下某个 document 的内容流式复制到应用内部临时目录，返回真实文件路径。
     *
     * just_audio 无法可靠播放 `content://` 树文档 URI，故播放时将文件物化为
     * 本地真实路径后再交给 ExoPlayer。需要应用对该 tree 持有读取授权。
     */
    fun copyTreeDocToInternal(treeUriStr: String, docId: String, destDir: String): String {
        val dir = File(destDir)
        if (!dir.exists()) dir.mkdirs()
        val treeUri = Uri.parse(treeUriStr)
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)

        val rawName = docId.substringAfterLast('/').ifBlank { "song" }
        val dot = rawName.lastIndexOf('.')
        val stem = if (dot >= 0) rawName.substring(0, dot) else rawName
        val ext = if (dot >= 0) rawName.substring(dot + 1) else "dat"
        val safeStem = stem.replace(Regex("[^A-Za-z0-9_\\-]"), "_").take(80)
        val dest = File(dir, "${safeStem}_${System.currentTimeMillis()}.$ext")

        val input = try {
            resolver.openInputStream(docUri)
        } catch (_: Exception) {
            null
        } ?: return ""
        input.use { ins ->
            dest.outputStream().use { out -> ins.copyTo(out) }
        }
        return dest.absolutePath
    }
}