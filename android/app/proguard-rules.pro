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
