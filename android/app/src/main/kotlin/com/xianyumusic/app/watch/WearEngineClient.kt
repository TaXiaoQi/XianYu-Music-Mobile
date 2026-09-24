package com.xianyumusic.app.watch

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.huawei.wearengine.HiWear
import com.huawei.wearengine.auth.AuthCallback
import com.huawei.wearengine.auth.Permission
import com.huawei.wearengine.device.Device
import com.huawei.wearengine.p2p.PingCallback

/**
 * 华为 Wear Engine（Android 手机侧）：经华为运动健康通道查询穿戴设备并
 * 远程拉起腕上端 App（对标高德手表版「手机主动唤醒手表」）。
 *
 * 前置条件（缺任一则对应接口报错，Dart 侧降级提示）：
 *  - 手机装有华为运动健康并已登录华为账号（<queries> 已声明包可见性）；
 *  - 手表已在运动健康中绑定、连接正常；
 *  - AGC 已开通 Wear Engine 服务且「设备基础信息（DEVICE_MANAGER）」权限
 *    审批通过（未批时接口报错码 8 等，authorize/wake 全程 try/catch 兜底）。
 *
 * 拉起机制：P2P `ping(device)`——穿戴侧应用已安装未启动时由系统冷启动
 * （errCode 201），已启动返回 202，未安装返回 200。本轮仅用 ping 拉起，
 * P2P 消息/文件收发不做。
 */
object WearEngineClient {
    /** 腕上端鸿蒙工程 bundleName（XianYu-Music-Watch/ohos/AppScope/app.json5）。 */
    const val WATCH_BUNDLE_NAME = "com.xianyumusic.watch"

    /** Wear Engine 服务宿主：华为运动健康。 */
    private const val HEALTH_PACKAGE = "com.huawei.health"

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 运动健康是否已安装（Android 11+ 依赖清单 <queries> 包可见性声明）。 */
    fun hasWearEngine(activity: Activity?): Boolean {
        val ctx = activity ?: return false
        return try {
            ctx.packageManager.getPackageInfo(HEALTH_PACKAGE, 0)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** 跳转应用市场安装运动健康（无市场时回退浏览器打开官网）。 */
    fun installHealth(activity: Activity?) {
        val act = activity ?: return
        try {
            act.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$HEALTH_PACKAGE"))
            )
            return
        } catch (_: ActivityNotFoundException) {
        }
        runCatching {
            act.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://health.huawei.com/")))
        }
    }

    /**
     * 查询 DEVICE_MANAGER 授权状态，未授权时弹华为授权页。
     * [onResult] 恰好回调一次：granted=true 已授权；canceled=true 用户取消；
     * 其余为失败原因文案。
     */
    fun authorize(
        activity: Activity?,
        onResult: (granted: Boolean, canceled: Boolean, message: String) -> Unit,
    ) {
        val act = activity
        if (act == null) {
            onResult(false, false, "activity 不可用")
            return
        }
        if (!hasWearEngine(act)) {
            onResult(false, false, "未安装华为运动健康")
            return
        }
        try {
            // 先查授权（运动健康 11.0.3.512+ 对 DEVICE_MANAGER 默认授予，免弹窗）；
            // 查询接口不可用/失败时直接走弹窗请求兜底。
            HiWear.getAuthClient(act)
                .checkPermission(Permission.DEVICE_MANAGER)
                .addOnSuccessListener { granted ->
                    if (granted == true) {
                        mainHandler.post { onResult(true, false, "") }
                    } else {
                        requestAuthDialog(act, onResult)
                    }
                }
                .addOnFailureListener { _ -> requestAuthDialog(act, onResult) }
        } catch (e: Exception) {
            onResult(false, false, e.message ?: "Wear Engine 不可用")
        }
    }

    private fun requestAuthDialog(
        act: Activity,
        onResult: (Boolean, Boolean, String) -> Unit,
    ) {
        val cb = object : AuthCallback {
            override fun onOk(permissions: Array<out Permission>?) {
                mainHandler.post { onResult(true, false, "") }
            }

            override fun onCancel() {
                mainHandler.post { onResult(false, true, "用户取消授权") }
            }
        }
        try {
            HiWear.getAuthClient(act).requestPermission(cb, Permission.DEVICE_MANAGER)
        } catch (e: Exception) {
            onResult(false, false, e.message ?: "授权请求失败")
        }
    }

    /** 已绑定穿戴设备列表 [{name, connected}]（无设备/失败返回空列表）。 */
    fun devices(activity: Activity?, onResult: (List<Map<String, Any>>) -> Unit) {
        val act = activity
        if (act == null) {
            onResult(emptyList())
            return
        }
        try {
            HiWear.getDeviceClient(act).getBondedDevices()
                .addOnSuccessListener { devs ->
                    mainHandler.post {
                        onResult(
                            devs.orEmpty().map {
                                mapOf("name" to (it.name ?: ""), "connected" to it.isConnected)
                            }
                        )
                    }
                }
                .addOnFailureListener { _ -> mainHandler.post { onResult(emptyList()) } }
        } catch (_: Exception) {
            onResult(emptyList())
        }
    }

    /**
     * ping 拉起穿戴侧应用：优选取第一台已连接设备。
     * [onResult] 恰好回调一次：ok=true 已拉起（201 冷启动 / 202 已在运行）；
     * 200=手表端未安装；其余为失败原因文案。
     */
    fun wake(
        activity: Activity?,
        bundleName: String,
        onResult: (ok: Boolean, code: Int, message: String) -> Unit,
    ) {
        val act = activity
        if (act == null) {
            onResult(false, -1, "activity 不可用")
            return
        }
        try {
            HiWear.getDeviceClient(act).getBondedDevices()
                .addOnSuccessListener { devs ->
                    val dev = devs.orEmpty().firstOrNull { it.isConnected }
                        ?: devs.orEmpty().firstOrNull()
                    if (dev == null) {
                        mainHandler.post {
                            onResult(false, 404, "未找到已绑定的穿戴设备")
                        }
                    } else {
                        ping(act, dev, bundleName, onResult)
                    }
                }
                .addOnFailureListener { e ->
                    mainHandler.post { onResult(false, -1, e.message ?: "获取设备列表失败") }
                }
        } catch (e: Exception) {
            onResult(false, -1, e.message ?: "Wear Engine 不可用")
        }
    }

    private fun ping(
        act: Activity,
        dev: Device,
        bundleName: String,
        onResult: (Boolean, Int, String) -> Unit,
    ) {
        try {
            val p2p = HiWear.getP2pClient(act)
            // 不指定对端包名时默认与手机侧应用包名一致，必须显式指向腕上端
            runCatching { p2p.setPeerPkgName(bundleName) }
            p2p.ping(dev, PingCallback { errCode ->
                mainHandler.post {
                    when (errCode) {
                        202 -> onResult(true, 202, "腕上端已在运行")
                        201 -> onResult(true, 201, "已拉起腕上端")
                        200 -> onResult(false, 200, "手表端未安装弦予音乐")
                        else -> onResult(false, errCode, "拉起失败（code=$errCode）")
                    }
                }
            })
        } catch (e: Exception) {
            onResult(false, -1, e.message ?: "ping 失败")
        }
    }
}
