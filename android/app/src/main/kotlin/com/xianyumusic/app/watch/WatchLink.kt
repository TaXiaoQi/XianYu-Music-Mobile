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
                    "send" -> {
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        send(bytes)
                        result.success(null)
                    }
                    "hasPermission" -> result.success(hasPermission())
                    "requestPermission" -> {
                        requestPermission()
                        result.success(null)
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
                while (running.get()) {
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

    /** 发送原始字节（帧由 Dart 层编码；写失败静默，断连由读线程统一上报）。 */
    fun send(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val stream = synchronized(writeLock) { out } ?: return
        try {
            synchronized(writeLock) { stream.write(bytes); stream.flush() }
        } catch (_: Exception) {
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
