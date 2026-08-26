# Flutter 引擎 Java 侧 keep 兜底（引擎本体是 native，dex 增量极小）
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# 平台通道与 MethodChannel 反射调用的入口类
-keep class com.xianyumusic.app.** { *; }
-dontwarn com.xianyumusic.app.**

# 音频前台服务/通知（audio_service），被系统以反射方式拉起
-keep class com.ryanheise.audioservice.** { *; }
-dontwarn com.ryanheise.audioservice.**
