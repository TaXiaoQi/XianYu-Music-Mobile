// 版本号自动同步（仅 release 构建）：version.ts -> pubspec.yaml / account_api.dart /
// local.properties。让裸 `flutter build apk --release` 等价旧 build-release.ps1 的
// 版本同步步骤。时序：flutter 工具在启动 gradle 前已把「旧」版本写进 local.properties，
// 故同步后须刷新该行，app 模块读 flutter.versionName 时拿到的才是新值；
// account_api.dart 的改动发生在 kernel 编译前，本次 AOT 即包含新版本号。
// XIANMU_SKIP_VERSION_SYNC=1 可跳过（debug/profile 模式自动跳过）。
run {
    val props = java.util.Properties()
    file("local.properties").inputStream().use { props.load(it) }
    if (props.getProperty("flutter.buildMode") == "release" &&
        System.getenv("XIANMU_SKIP_VERSION_SYNC") != "1"
    ) {
        val flutterSdk = props.getProperty("flutter.sdk")
        val dartBin = file("$flutterSdk/bin/cache/dart-sdk/bin/dart.exe")
        if (dartBin.exists()) {
            val rootDir = file("..").canonicalFile
            val proc = ProcessBuilder(dartBin.absolutePath, "run", "tool/sync_version.dart")
                .directory(rootDir)
                .redirectErrorStream(true)
                .start()
            val output = proc.inputStream.bufferedReader().readText()
            proc.waitFor()
            if (proc.exitValue() != 0) {
                throw GradleException("版本号同步失败:\n$output")
            }
            println(output.trim())
            // 刷新 local.properties 的 flutter.versionName（逐行替换，避免 Properties.store
            // 破坏含中文的 sdk.dir/cmake.dir 行）
            val pub = File(rootDir, "pubspec.yaml").readText()
            val ver = Regex("(?m)^version:\\s*(.+)$").find(pub)?.groupValues?.get(1)?.trim()
                ?.substringBefore('+')?.trim()
            if (ver != null) {
                val lp = file("local.properties")
                val lines = lp.readLines().toMutableList()
                var replaced = false
                for (i in lines.indices) {
                    if (lines[i].startsWith("flutter.versionName=")) {
                        lines[i] = "flutter.versionName=$ver"
                        replaced = true
                    }
                }
                if (replaced) lp.writeText(lines.joinToString("\n") + "\n")
            }
        }
    }
}

pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // 国内镜像优先（阿里云），加速 dl.google.com / repo1.maven.org 的依赖下载
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // 所有依赖统一走阿里云镜像（覆盖 file_picker 等模块的依赖解析）
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
