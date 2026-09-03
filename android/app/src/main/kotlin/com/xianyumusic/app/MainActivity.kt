package com.xianyumusic.app

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.Surface
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.io.File

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "xianyu/audio_devices"
    private val SAF_CHANNEL = "xianyu/saf"
    private val DEEP_LINK_CHANNEL = "xianyu/deeplink"
    private val ROTATION_EVENT_CHANNEL = "xianyu/rotation/events"
    private val DEVICE_INFO_CHANNEL = "xianyu/device_info"
    private val REQ_CHOOSE_TREE = 1001

    // 横竖屏旋转事件：旋转一开始系统即回调 onConfigurationChanged，把当前屏幕
    // 方向（1 竖 / 2 横）推给 Dart 侧，让布局在旋转开始就切换，尽量第一帧出横屏，
    // 缩短系统旋转期间「拉伸竖屏」的停留。
    private var rotationEvents: EventChannel.EventSink? = null

    // xianyu:// 深链：分享落地页拉起后把 intent 交给 Flutter 解析播放。
    private var deepLinkChannel: MethodChannel? = null
    private var pendingDeepLink: String? = null

    private lateinit var saf: SafEngine
    private val mainHandler = Handler(Looper.getMainLooper())

    // DLNA 渲染器：Wi-Fi 组播锁（SSDP 1900 端口组播接收必需）。
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null

    /** 获取组播锁（引用计数为 0 时真正加锁，幂等）。 */
    private fun dlnaMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
        val lock = multicastLock ?: wifi.createMulticastLock("xianyu_dlna").apply {
            setReferenceCounted(false)
            multicastLock = this
        }
        try {
            lock.acquire()
        } catch (_: Exception) {
        }
    }

    /** 释放组播锁（未持有时为 no-op）。 */
    private fun dlnaMulticastRelease() {
        val lock = multicastLock ?: return
        try {
            if (lock.isHeld) lock.release()
        } catch (_: Exception) {
        }
    }

    // SAF 枚举/复制都是重 I/O，必须离开主线程，否则扫描与切歌时整个 UI 冻结。
    private val safExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    /** 在 SAF 后台线程执行重 I/O，结果回传主线程（MethodChannel.Result 要求主线程回调）。 */
    private fun safAsync(result: MethodChannel.Result, block: () -> Any?) {
        safExecutor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("saf_error", e.message ?: "unknown", null)
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        saf = SafEngine(this)
        super.onCreate(savedInstanceState)
        // 开启挖孔(cutout)窗口模式：允许 UI/背景绘制进摄像头区域。
        // 全程沉浸全屏（含横屏）时若不开此模式，Flutter 渲染会被限制在
        // 摄像头清除安全区之外，挖孔那条只能留黑/被截断，表现为「摄像头位置不可显示 UI」。
        // 这属于窗口布局模式，并非权限授权。API 30+ 用 ALWAYS（任意边均可绘制进挖孔），
        // 28-29 回退 SHORT_EDGES（仅短边，横屏摄像头即落在短边）。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        // Android 15+ 组件选择面板「生成的预览」（幂等 + 限速重试）。
        WidgetShared.ensurePreviewGen(this)
        // 冷启动：Flutter 的 MethodChannel handler 尚未注册，若此时走 onDeepLink
        // 派发，消息会被引擎丢弃且 pendingDeepLink 已被清空，深链彻底丢失。
        // 只暂存链接，交由 Dart 侧 init 时调用 getInitialDeepLink 主动取走。
        processDeepLink(intent, dispatch = false)
    }

    /** singleTop 复用已启动 Activity 时的深链回调。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // 热启动：Flutter handler 已就绪，直接走 onDeepLink 事件派发。
        processDeepLink(intent, dispatch = true)
    }

    /** 旋转一开始系统即回调：把当前屏幕方向推给 Dart 侧，实现旋转即切横竖屏布局。 */
    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        emitRotation()
    }

    /** 推送当前屏幕方向（1 竖 / 2 横）：主动读 Display 旋转角（0/90/180/270），
     *  仅旋转那一瞬上报、非常节能，最贴近原生行为。 */
    private fun emitRotation() {
        val rotation = windowManager.defaultDisplay.rotation
        // Surface.ROTATION_*：0 自然竖 / 90 横 / 180 反向竖 / 270 反向横。
        val landscape = rotation == Surface.ROTATION_90 || rotation == Surface.ROTATION_270
        val orientation =
            if (landscape) Configuration.ORIENTATION_LANDSCAPE else Configuration.ORIENTATION_PORTRAIT
        mainHandler.post { runCatching { rotationEvents?.success(orientation) } }
    }

    private fun processDeepLink(intent: Intent?, dispatch: Boolean) {
        val data = intent?.data ?: return
        if (data.scheme == "xianyu") {
            pendingDeepLink = data.toString()
            if (dispatch) dispatchIfReady()
            return
        }
        // 系统文件管理器/分享面板打开本地音频：ACTION_VIEW 的 data 为 file:// 或
        // content://。just_audio 无法可靠播放 content 流，且这是受让的一次性读权限，
        // 因此先把内容物化到应用缓存目录得到真实路径，再封装成
        // xianyu://open?target=file&file=<path>&name=<原标题> 深链交给 Flutter 直播。
        // 复制为重 I/O，放后台线程；完成后在主线程派发深链。
        // 标题取内容提供者声明的 DisplayName（content:// 的 lastPathSegment 通常是
        // media 数字 ID，直接当歌名就会变成一串数字）。
        val rawName = queryDisplayName(data) ?: data.lastPathSegment ?: "song"
        safExecutor.execute {
            val localPath = copyContentToCache(data, rawName)
            if (localPath == null) return@execute
            val link = "xianyu://open?target=file" +
                "&name=${Uri.encode(rawName)}&file=${Uri.encode(localPath)}"
            pendingDeepLink = link
            mainHandler.post { dispatchIfReady() }
        }
    }

    /** 查询内容提供者声明的展示名（OpenableColumns.DISPLAY_NAME）。
     *  content:// 的 lastPathSegment 常是 media 数字 ID，不能直接当歌名；
     *  用提供者元数据取真实文件名，失败返回 null 走回退。 */
    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && !c.isNull(idx)) c.getString(idx) else null
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }

    /** 把一次性的 file/content 音频读权限物化为应用缓存目录里的真实文件，返回其路径。
     *  类名无法规避重复，用原文件名以保证展示标题干净；失败返回 null（交给 Flutter 报错）。 */
    private fun copyContentToCache(uri: Uri, rawName: String): String? {
        return try {
            val destDir = File(cacheDir, "opened")
            if (!destDir.exists()) destDir.mkdirs()
            // 文件名若被文件管理器追加了随机后缀（.tmp 等），仅保留可识别的主体；否则用原名。
            val name = if (rawName.endsWith(".tmp")) "song" else rawName
            val dest = File(destDir, name)
            val input = contentResolver.openInputStream(uri) ?: return null
            input.use { ins -> dest.outputStream().use { out -> ins.copyTo(out) } }
            dest.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    /** 引擎就绪（warm start / onNewIntent）时走事件通道主动派发。 */
    private fun dispatchIfReady() {
        val link = pendingDeepLink ?: return
        val ch = deepLinkChannel ?: return
        pendingDeepLink = null
        mainHandler.post { runCatching { ch.invokeMethod("onDeepLink", link) } }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_CHOOSE_TREE) {
            saf.onTreeResult(data?.data)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterMessengerHolder.messenger = flutterEngine.dartExecutor.binaryMessenger
        // 系统分享：原生 ACTION_SEND + 普通 startActivity，国产 ROM 才会弹自家分享面板
        SystemShare.register(flutterEngine.dartExecutor.binaryMessenger, this)
        deepLinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, DEEP_LINK_CHANNEL)
            .apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getInitialDeepLink" -> {
                            // 冷启动：返回 onCreate 阶段暂存的深链并清空
                            result.success(pendingDeepLink)
                            pendingDeepLink = null
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DownloadNotification.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateDownloadProgress" -> {
                        val currentTitle = call.argument<String>("currentTitle") ?: ""
                        val currentArtist = call.argument<String>("currentArtist") ?: ""
                        val doneCount = call.argument<Int>("doneCount") ?: 0
                        val totalCount = call.argument<Int>("totalCount") ?: 0
                        val progressPercent = call.argument<Int>("progressPercent") ?: 0
                        val isFinished = call.argument<Boolean>("isFinished") ?: false
                        val isFailed = call.argument<Boolean>("isFailed") ?: false

                        DownloadNotification.showOrUpdate(
                            this,
                            currentTitle,
                            currentArtist,
                            doneCount,
                            totalCount,
                            progressPercent,
                            isFinished,
                            isFailed
                        )
                        result.success(true)
                    }
                    "dismissDownloadNotification" -> {
                        DownloadNotification.cancel(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listOutputDevices" -> result.success(listOutputDevices())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_INFO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceInfo" -> result.success(JSONObject().apply {
                        put("brand", Build.BRAND)
                        put("manufacturer", Build.MANUFACTURER)
                        put("model", Build.MODEL)
                        put("os_version", Build.VERSION.RELEASE + " (API " + Build.VERSION.SDK_INT + ")")
                    }.toString())
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, ROTATION_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    rotationEvents = events
                    emitRotation()
                }
                override fun onCancel(arguments: Any?) {
                    rotationEvents = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SAF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    "chooseFolderTree" -> {
                        SafEngine.pendingTreeResult = result
                        startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_CHOOSE_TREE)
                    }
                    "persistPermission" -> {
                        saf.persistPermission(call.argument<String>("uri") ?: "")
                        result.success(null)
                    }
                    "isTreePersisted" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        safAsync(result) { saf.isTreePersisted(uri) }
                    }
                    "isTreeAvailable" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        safAsync(result) { saf.isTreeAvailable(uri) }
                    }
                    "releasePermission" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        safAsync(result) {
                            saf.releasePermission(uri)
                            null
                        }
                    }
                    "friendlyTreeName" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        safAsync(result) { saf.friendlyTreeName(uri) }
                    }
                    "listMediaAudioFolders" -> {
                        safAsync(result) { saf.listMediaAudioFolders() }
                    }
                    "listAudioTree" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        val exts = (call.argument<List<*>>("extensions") ?: emptyList<Any>())
                            .map { it.toString() }
                        safAsync(result) { saf.listAudioTree(uri, exts) }
                    }
                    "openFd" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        val docId = call.argument<String>("docId") ?: ""
                        safAsync(result) { saf.openFd(uri, docId) }
                    }
                    "closeFd" -> {
                        val fd = (call.argument<Int>("fd")) ?: -1
                        safAsync(result) {
                            saf.closeFd(fd)
                            null
                        }
                    }
                    "copyTreeDocToInternal" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        val docId = call.argument<String>("docId") ?: ""
                        val destDir = call.argument<String>("destDir") ?: ""
                        safAsync(result) { saf.copyTreeDocToInternal(uri, docId, destDir) }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LyricsOverlayService.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        LyricsOverlayService.show(this)
                        result.success(null)
                    }
                    "hide" -> {
                        LyricsOverlayService.hide(this)
                        result.success(null)
                    }
                    "setLyrics" -> {
                        LyricsOverlayService.instance?.setLyrics(
                            call.argument<String>("json") ?: "")
                        result.success(null)
                    }
                    "setPlayback" -> {
                        val posMs = (call.argument<Number>("positionMs")?.toLong()) ?: 0L
                        LyricsOverlayService.instance?.setPlayback(
                            posMs,
                            call.argument<Boolean>("isPlaying") ?: false)
                        result.success(null)
                    }
                    "setSettings" -> {
                        LyricsOverlayService.instance?.setSettings(
                            call.argument<String>("json") ?: "")
                        result.success(null)
                    }
                    "setLocked" -> {
                        LyricsOverlayService.instance?.setLocked(
                            call.argument<Boolean>("locked") ?: false)
                        result.success(null)
                    }
                    "resetPosition" -> {
                        LyricsOverlayService.instance?.resetPosition()
                        result.success(null)
                    }
                    "isPermissionGranted" -> {
                        result.success(LyricsOverlayService.canDraw(this))
                    }
                    "openPermissionSettings" -> {
                        runCatching {
                            startActivity(LyricsOverlayService.permissionIntent(this))
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xianyu/player_widget")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setState" -> {
                        // Flutter 侧经此把组件状态 JSON 落盘（确定性 key，不依赖插件存储格式）。
                        val json = call.argument<String>("json") ?: ""
                        getSharedPreferences("player_widget", MODE_PRIVATE)
                            .edit().putString("state", json).apply()
                        result.success(null)
                    }
                    "update" -> {
                        WidgetShared.updateAll(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xianyu/dlna")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // DLNA 渲染器：SSDP 组播发现/广播依赖接收组播包，
                    // Wi-Fi 组播默认被系统过滤，需持有 MulticastLock。
                    "acquireMulticast" -> {
                        dlnaMulticastLock()
                        result.success(null)
                    }
                    "releaseMulticast" -> {
                        dlnaMulticastRelease()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, StatusBarLyricsNotification.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        StatusBarLyricsNotification.show(
                            this,
                            call.argument<String>("title") ?: "",
                            call.argument<String>("artist") ?: "",
                            call.argument<String>("lyric") ?: "",
                            call.argument<String>("coverPath"))
                        result.success(null)
                    }
                    "cancel" -> {
                        StatusBarLyricsNotification.cancel(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 枚举全部输出音频设备，返回 JSON 数组 JSON。id 与 AAudio setDeviceId 一致。 */
    private fun listOutputDevices(): String {
        val arr = JSONArray()
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.M) {
            return arr.toString()
        }
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        for (d in devices) {
            val o = JSONObject()
            o.put("id", d.id)
            o.put("name", d.productName.toString())
            o.put("type", deviceTypeLabel(d.type))
            o.put("sampleRates", JSONArray(d.sampleRates.toList()))
            o.put("channelCounts", JSONArray(d.channelCounts.toList()))
            arr.put(o)
        }
        return arr.toString()
    }

    private fun deviceTypeLabel(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "听筒"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "扬声器"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "有线耳机(带麦)"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "有线耳机"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "蓝牙通话"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "蓝牙耳机"
        AudioDeviceInfo.TYPE_HDMI -> "HDMI"
        AudioDeviceInfo.TYPE_DOCK -> "底座/扩展坞"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "USB 设备"
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB 附件"
        AudioDeviceInfo.TYPE_AUX_LINE -> "Line 输出"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "BLE 耳机"
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "BLE 音箱"
        else -> "设备#${type}"
    }
}