package com.xianyumusic.app.watch

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 手表联动 RFCOMM 传输层（手机端 = 服务端）。
 *
 * 职责边界：Kotlin 只做蓝牙 SPP 字节管道（accept / 读写 / 断连感知），
 * 帧编解码、CRC、分片重组、心跳与协议语义全部在 Dart 侧
 * `lib/src/watch_link/`（复用腕上端 lib/src/link/protocol.dart 同一实现）。
 *
 * 连接模型：单手表场景，accept 循环接受连接后关掉旧连接保最新；
 * stop 时关闭全部套接字并中断线程，幂等可重启。
 */
object WatchLink {
    const val CHANNEL = "xianyu/watch_link"

    // 与 lib/src/link/protocol.dart 的 kWatchLinkServiceUuid 严格一致。
    private val SERVICE_UUID: UUID = UUID.fromString("f7a24b6c-9d3e-4f8a-b1c2-2e5d8a7f6b3a")

    private const val READ_BUFFER = 4096
    private const val PERMISSION_REQUEST_CODE = 4201

    private var channel: MethodChannel? = null
    private var activity: android.app.Activity? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private val running = AtomicBoolean(false)
    private var serverSocket: BluetoothServerSocket? = null
    private var socket: BluetoothSocket? = null
    private var out: OutputStream? = null
    private val writeLock = Any()

    /** 手机端主动连接手表进行中标志（防并发连接线程叠加）。 */
    private val connecting = AtomicBoolean(false)

    /**
     * 单线程串行写：蓝牙 SPP 每帧 write+flush 可达百毫秒级，绝不能在主
     * 线程执行——预缓存帧洪峰（5 首 × 封面+歌词 ≈ 数百片 4KB 分片）曾把
     * 主线程占死导致双端卡死。写完回调 [onDone]（回主线程）后 Dart 侧才
     * 发下一帧，形成天然背压。
     */
    private val writeExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    /** 注册 MethodChannel（configureFlutterEngine 时调用）。 */
    fun register(messenger: BinaryMessenger, activity: android.app.Activity) {
        this.activity = activity
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        start()
                        result.success(null)
                    }
                    "stop" -> {
                        stop()
                        result.success(null)
                    }
                    "disconnect" -> {
                        disconnect()
                        result.success(null)
                    }
                    "send" -> {
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        send(bytes) {
                            runCatching { result.success(null) }
                        }
                    }
                    "pairedDevices" -> result.success(pairedDevices())
                    "connect" -> {
                        val address = call.argument<String>("address") ?: ""
                        connect(address)
                        result.success(null)
                    }
                    "hasPermission" -> result.success(hasPermission())
                    "requestPermission" -> {
                        requestPermission()
                        result.success(null)
                    }
                    // ---- Wear Engine（运动健康通道）：查询/授权/远程拉起腕上端 ----
                    "wearHasEngine" -> result.success(WearEngineClient.hasWearEngine(activity))
                    "wearInstallHealth" -> {
                        WearEngineClient.installHealth(activity)
                        result.success(null)
                    }
                    "wearAuthorize" -> {
                        WearEngineClient.authorize(activity) { granted, canceled, message ->
                            runCatching {
                                result.success(
                                    mapOf(
                                        "granted" to granted,
                                        "canceled" to canceled,
                                        "message" to message,
                                    )
                                )
                            }
                        }
                    }
                    "wearDevices" -> {
                        WearEngineClient.devices(activity) { devs ->
                            runCatching { result.success(devs) }
                        }
                    }
                    "wearWake" -> {
                        val bundleName = call.argument<String>("bundleName")
                            ?: WearEngineClient.WATCH_BUNDLE_NAME
                        WearEngineClient.wake(activity, bundleName) { ok, code, message ->
                            runCatching {
                                result.success(mapOf("ok" to ok, "code" to code, "message" to message))
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** 蓝牙运行时权限是否已授予（Android 12+ 需 BLUETOOTH_CONNECT；旧版清单声明即有）。 */
    fun hasPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val ctx = activity ?: return false
        return ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED
    }

    /** 发起 BLUETOOTH_CONNECT 运行时权限请求，结果经 onRequestPermissionsResult 回传 Dart。 */
    fun requestPermission() {
        val act = activity ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            emitPermission(true)
            return
        }
        if (hasPermission()) {
            emitPermission(true)
            return
        }
        act.requestPermissions(
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
            PERMISSION_REQUEST_CODE,
        )
    }

    /** MainActivity.onRequestPermissionsResult 转发进来。 */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        emitPermission(granted)
    }

    private fun emitPermission(granted: Boolean) {
        mainHandler.post {
            runCatching { channel?.invokeMethod("onPermission", granted) }
        }
    }

    private fun adapter(): BluetoothAdapter? {
        val ctx = activity ?: return null
        val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter
    }

    /** 启动 accept 服务（幂等；无适配器/无权限时静默不启动，由 Dart 侧前置检查权限）。 */
    @Synchronized
    fun start() {
        if (running.get()) return
        val adapter = adapter() ?: return
        if (!hasPermission()) return
        running.set(true)
        val server = try {
            adapter.listenUsingRfcommWithServiceRecord("XianYuWatchLink", SERVICE_UUID)
        } catch (_: Exception) {
            running.set(false)
            return
        }
        serverSocket = server
        Thread {
            while (running.get()) {
                val sock = try {
                    server.accept()
                } catch (_: IOException) {
                    break // socket 被关闭（stop）
                }
                if (!running.get()) {
                    runCatching { sock.close() }
                    break
                }
                adoptConnection(sock)
            }
        }.apply {
            setName("xy-watch-accept")
            start()
        }
    }

    /** 停止服务并断开连接（幂等）。 */
    @Synchronized
    fun stop() {
        running.set(false)
        runCatching { serverSocket?.close() }
        serverSocket = null
        closeConnection()
    }

    /** 仅断开当前手表连接：服务端保持 accept，手表可随时重连（幂等）。 */
    @Synchronized
    fun disconnect() {
        closeConnection()
    }

    /** 已配对设备列表 [{address, name}]（无权限/无适配器返回空）。 */
    private fun pairedDevices(): List<Map<String, String>> {
        val adapter = adapter() ?: return emptyList()
        if (!hasPermission()) return emptyList()
        return try {
            adapter.bondedDevices.map { dev ->
                mapOf(
                    "address" to dev.address,
                    "name" to (try { dev.name ?: dev.address } catch (_: Exception) { dev.address }),
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    /**
     * 手机端主动连接手表（反向配对）：作为 SPP 客户端连入手表侧服务端，
     * 手表端会弹「允许/拒绝」确认；采纳后与手表主动连入同流程（adopt）。
     */
    fun connect(address: String) {
        if (address.isEmpty()) return
        if (!connecting.compareAndSet(false, true)) return
        if (!hasPermission()) {
            connecting.set(false)
            return
        }
        val adapter = adapter()
        if (adapter == null || !adapter.isEnabled) {
            connecting.set(false)
            emitConnection(false, "")
            return
        }
        Thread {
            var sock: BluetoothSocket? = null
            try {
                val dev = adapter.getRemoteDevice(address)
                runCatching { adapter.cancelDiscovery() }
                sock = dev.createRfcommSocketToServiceRecord(SERVICE_UUID)
                sock.connect() // 阻塞直至建立或抛 IOException（手表确认前不返回）
                connecting.set(false)
                adoptConnection(sock)
            } catch (_: Exception) {
                connecting.set(false)
                runCatching { sock?.close() }
                emitConnection(false, "")
            }
        }.apply { setName("xy-phone-connect") }.start()
    }

    /** 采纳新连接：关旧保新（最新手表优先），起读线程。 */
    private fun adoptConnection(sock: BluetoothSocket) {
        closeConnection()
        if (!hasPermission()) {
            runCatching { sock.close() }
            return
        }
        val name = try { sock.remoteDevice.name ?: "watch" } catch (_: Exception) { "watch" }
        synchronized(writeLock) {
            socket = sock
            out = try { sock.outputStream } catch (_: Exception) { null }
        }
        emitConnection(true, name)
        Thread {
            val buf = ByteArray(READ_BUFFER)
            try {
                val ins: InputStream = sock.inputStream
                // 不判 running：手机端主动连接时服务端可能未启动；stop()/断开
                // 会关闭套接字使 read 抛异常退出。
                while (true) {
                    val n = ins.read(buf)
                    if (n < 0) break
                    if (n > 0) {
                        val chunk = buf.copyOf(n)
                        mainHandler.post {
                            runCatching { channel?.invokeMethod("onRaw", chunk) }
                        }
                    }
                }
            } catch (_: Exception) {
                // 读异常 = 连接断开
            } finally {
                // 仅当断开的仍是当前连接时才清理并上报（新连接可能已接管）。
                val wasCurrent = synchronized(writeLock) { socket === sock }
                runCatching { sock.close() }
                if (wasCurrent) {
                    synchronized(writeLock) {
                        if (socket === sock) {
                            socket = null
                            out = null
                        }
                    }
                    emitConnection(false, name)
                }
            }
        }.apply { setName("xy-watch-read") }.start()
    }

    private fun closeConnection() {
        val sock = synchronized(writeLock) {
            val s = socket
            socket = null
            out = null
            s
        }
        runCatching { sock?.close() }
    }

    /**
     * 异步串行写一帧到蓝牙（写完回主线程回调 [onDone]，Dart await 该帧
     * 发送后才发下一帧 = 背压）。断连时 [out] 为 null，快速空回调排空队列。
     */
    fun send(bytes: ByteArray, onDone: () -> Unit = {}) {
        if (bytes.isEmpty()) {
            onDone()
            return
        }
        writeExecutor.execute {
            val stream = synchronized(writeLock) { out }
            try {
                if (stream != null) {
                    synchronized(writeLock) { stream.write(bytes); stream.flush() }
                }
            } catch (_: Exception) {
            }
            mainHandler.post { onDone() }
        }
    }

    private fun emitConnection(connected: Boolean, name: String) {
        mainHandler.post {
            runCatching {
                channel?.invokeMethod("onConnection", mapOf("connected" to connected, "name" to name))
            }
        }
    }
}
