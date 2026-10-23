package com.xianyumusic.app

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * 蓝牙音频设备（车机 / 蓝牙音箱）连接监听：经 EventChannel(xianyu/bluetooth_audio)
 * 向 Dart 侧推送连接沿事件 {connected, deviceName}，驱动「自动跟随蓝牙接入」。
 *
 * 仅 A2DP（蓝牙音频主通道）监听 SCO 通话通道不适用；监听时机为 Dart 侧
 * 订阅（onListen）起，进程被杀后重连沿不可见属预期——应用被杀时不播放，
 * 重启订阅即拿到 emitCurrent 的当前状态。
 *
 * 权限：注册/接收广播免权限；Android 12+ 读取设备名需 BLUETOOTH_CONNECT
 * 运行时权限（manifest 已声明，手表联动在用时申请），缺失时回退无名称事件，
 * 自动开启逻辑只依赖 connected 布尔值，不受影响。
 */
object BluetoothAudioWatcher {
    private const val CHANNEL = "xianyu/bluetooth_audio"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var sink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    fun register(messenger: BinaryMessenger, context: Context) {
        appContext = context.applicationContext
        EventChannel(messenger, CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                ensureReceiver()
                emitCurrent()
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    /** A2DP 连接状态广播是受保护系统广播且 API 26+ 不支持清单注册，只能动态收。 */
    private fun ensureReceiver() {
        val ctx = appContext ?: return
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED) return
                when (intent.getIntExtra(BluetoothA2dp.EXTRA_STATE, -1)) {
                    BluetoothA2dp.STATE_CONNECTED -> emit(true, deviceName(intent))
                    BluetoothA2dp.STATE_DISCONNECTED -> emit(false, null)
                }
            }
        }
        receiver = r
        ContextCompat.registerReceiver(
            ctx,
            r,
            IntentFilter(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    private fun deviceName(intent: Intent): String? = try {
        val device = IntentCompat.getParcelableExtra(
            intent, BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        device?.name
    } catch (_: Exception) {
        null
    }

    /** 初始状态：AudioManager 枚举输出设备判定（同步、免权限），订阅即推。 */
    private fun emitCurrent() {
        val am = appContext
            ?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val connected = am?.getDevices(AudioManager.GET_DEVICES_OUTPUTS)?.any {
            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
        } == true
        emit(connected, null)
    }

    private fun emit(connected: Boolean, deviceName: String?) {
        val s = sink ?: return
        mainHandler.post {
            runCatching {
                s.success(mapOf("connected" to connected, "deviceName" to deviceName))
            }
        }
    }
}
