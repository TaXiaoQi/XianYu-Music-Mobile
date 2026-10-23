package com.xianyumusic.app.hicar

import android.app.Activity
import android.util.Log

/**
 * HiCar 桥接 · 真实现骨架（仅当 app/libs/huawei-hicar-sdk.aar 存在时参与编译）。
 *
 * HiCar SDK 为华为准入制离线分发，无公开 maven 坐标。接入前置条件：
 *  1. 发邮件【HUAWEI HiCar应用接入申请】到 huaweihicar@huawei.com，附
 *     已上架华为应用市场的应用名 / 包名 / 应用类别（音频）；
 *  2. 签署准入协议后获得 huawei-hicar-sdk.aar，放入 app/libs/（勿入库）；
 *  3. 按包名在华为侧开通调试权限（车机端联调需白名单）。
 * 接入步骤（官方 codelab：developer.huawei.com/consumer/cn/codelab/HUAWEIHiCar）：
 *  · AndroidManifest 添加开发者联盟应用的 appid meta-data（name 形如
 *    com.hicompat.* / com.huawei.hicar.*，以 SDK 文档为准）；
 *  · 本 init 内完成 SDK 初始化（HiCarApi.getInstance().init(...) 等）；
 *  · 实现媒体浏览树 / 播放控制桥：车机侧播放、暂停、切歌、收藏等指令
 *    经音频类应用模板转发到 XianYuAudioHandler（play/pause/skipToNext/
 *    skipToPrevious/customAction 已具备，直接复用）；
 *  · 媒体会话元数据已随蓝牙歌词同步更新（player_provider.media_handler）。
 * 本文件仅保留可编译的最小骨架，SDK API 细节以准入后下发的文档为准填写。
 */
object HiCarBridge {
    private const val TAG = "XyHiCar"

    fun init(activity: Activity) {
        // TODO(HiCar): SDK 初始化（准入后按官方文档补齐）
        //  1. 确认 app/libs/huawei-hicar-sdk.aar 已就位（Gradle 已自动接入）
        //  2. HiCarApi 初始化 + 连接状态监听
        //  3. 注册音频类媒体浏览树服务（歌单/歌曲层级 → 车机可见）
        Log.i(TAG, "HiCar bridge init (skeleton, SDK integration pending)")
    }
}
