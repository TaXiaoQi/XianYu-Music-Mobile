# Flutter 引擎 Java 侧 keep 兜底（引擎本体是 native，dex 增量极小）
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# 平台通道与 MethodChannel 反射调用的入口类
-keep class com.xianyumusic.app.** { *; }
-dontwarn com.xianyumusic.app.**

# 音频前台服务/通知（audio_service），被系统以反射方式拉起
-keep class com.ryanheise.audioservice.** { *; }
-dontwarn com.ryanheise.audioservice.**

# tencent_kit（QQ 分享）内置的 TencentOpenSDK 引用 okhttp3 作可选 HTTP 客户端，
# 但插件未声明 okhttp 依赖；SDK 运行时缺 okhttp 会回退 HttpURLConnection
# （debug 构建无 okhttp 也能正常分享），故仅跳过 R8 缺失类检查，不额外引入依赖。
-dontwarn okhttp3.**

# QQ OpenSDK 3.5.19 运行时硬编码调用 android.support.v4.content.FileProvider
# （app 内有对应的继承 androidx 的存根类），防止 R8 误删
-keep class android.support.v4.content.FileProvider { *; }

# 华为 Wear Engine SDK：回调接口经 Binder 跨进程派发，混淆会破坏 AIDL/反射
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-keep class com.huawei.wearengine.** { *; }
-dontwarn com.huawei.wearengine.**
-keep class com.huawei.hmf.tasks.** { *; }
-dontwarn com.huawei.hmf.tasks.**

# Kotlin 标准库整体保名：本 app 有多处按「原始名」加载 Kotlin 桥接类的路径
# （shared_preferences_android ≥2.5 的 jnigen 经 JNI 反射调 suspend 方法——上游
# 未带 consumer proguard 规则、华为 wearengine SDK 内部协程、自定义 channel 的
# Kotlin 侧实现），R8 的优化会逐个删掉它们——真机 release 先后炸过三茬：
# Continuation 被重命名（JNI 查不到签名，prefs 全盘 NoSuchMethodError）→
# CoroutineSingletons 被删类 → kotlin.Result 被消除（R8 的 Result 消除优化），
# ClassNotFound 遍布同步/推送/通知全部 channel（debug 不混淆故 run 正常、仅
# release 复现）。逐个追 keep 成本过高，整体保留一步到位（dex 增量约数百 KB）。
-keep class kotlin.** { *; }
-dontwarn kotlin.**
