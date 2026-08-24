package com.example.xianyu_music_mobile

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val CHANNEL = "xianyu/audio_devices"
    private val SAF_CHANNEL = "xianyu/saf"

    private lateinit var saf: SafEngine
    private lateinit var treeLauncher: androidx.activity.result.ActivityResultLauncher<Intent>

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        saf = SafEngine(this)
        treeLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { res -> saf.onTreeResult(res?.data?.data) }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listOutputDevices" -> result.success(listOutputDevices())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SAF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "chooseFolderTree" -> {
                        saf.pendingTreeResult = result
                        treeLauncher.launch(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE))
                    }
                    "persistPermission" -> {
                        saf.persistPermission(call.argument("uri") as String)
                        result.success(null)
                    }
                    "listAudioTree" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        val exts = (call.argument<List<*>>("extensions") ?: emptyList())
                            .map { it.toString() }
                        result.success(saf.listAudioTree(uri, exts))
                    }
                    "openFd" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        val docId = call.argument<String>("docId") ?: ""
                        result.success(saf.openFd(uri, docId))
                    }
                    "closeFd" -> {
                        saf.closeFd((call.argument<Int>("fd")) ?: -1)
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