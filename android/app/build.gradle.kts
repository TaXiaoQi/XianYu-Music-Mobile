plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.xianyu_music_mobile"
    // file_picker 依赖的 flutter_plugin_android_lifecycle 要求 compileSdk >= 36
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.xianyu_music_mobile"
        // You can update these values to match your application needs.
        // For more information, see https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 仅打包 arm64：与发布脚本一致（等价 --target-platform android-arm64），
        // 排除 armv7 / x86_64 引擎。debug 包同步受益（体积减半）。
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    // 安装包压缩：.so 在 APK 内 deflate（安装时解压到本地），
    // 下载/分发体积约省 40%；代价是安装后设备占用 = APK + 解压出的 .so
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // R8 代码收缩 + 资源收缩：dex/资源再省约 0.5~1.5MB
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 禁用 lint 关键检查 task（避免构建时从 dl.google.com 下载 lint 依赖超时）
tasks.configureEach {
    if (name.startsWith("lintVital")) {
        enabled = false
    }
}

// Rust 自动编译钩子：flutter run / flutter build apk 时自动检测并编译
// Rust（绑定 + .so，见 scripts/gradle-rust-hook.ps1）。环境变量 XIANMU_SKIP_RUST=1 可跳过。
val isWindows = System.getProperty("os.name").lowercase().contains("windows")
tasks.register("rustHook") {
    doLast {
        if (isWindows) {
            val proc = ProcessBuilder(
                "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", rootProject.projectDir.resolve("../scripts/gradle-rust-hook.ps1").absolutePath,
            ).apply {
                directory(projectDir)
                inheritIO()
            }.start()
            val code = proc.waitFor()
            if (code != 0) {
                throw GradleException(
                    "Rust 钩子退出码 $code：若上方提示 API 绑定已更新，重新运行一次 flutter run / flutter build 即可",
                )
            }
        }
    }
}
tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn("rustHook")
}

// 正式包自动归档：assembleRelease 完成后把 universal release APK（abiFilters 已限定
// arm64）复制到 releases/弦予音乐_<版本>_arm64.apk，让裸 `flutter build apk --release`
// 直接产出正式安装包。--split-per-abi 构建（build-release.ps1）无 universal 包，自动跳过。
tasks.register("archiveReleaseApk") {
    group = "build"
    doLast {
        val apk = layout.buildDirectory.file("outputs/flutter-apk/app-release.apk").get().asFile
        if (!apk.exists()) return@doLast
        val version = runCatching { flutter.versionName }.getOrDefault("0.0.0")
        val releasesDir = File(rootProject.projectDir.parentFile, "releases")
        releasesDir.mkdirs()
        val dest = File(releasesDir, "弦予音乐_${version}_arm64.apk")
        apk.copyTo(dest, overwrite = true)
        logger.lifecycle("已归档正式安装包: ${dest.absolutePath} (${"%.1f".format(dest.length() / 1024.0 / 1024.0)} MB)")
        // 清理 gen_snapshot 注入参数在项目根落下的符号副产物（多架构互相覆盖，
        // 内容为最后一个架构的符号，无归档价值；正式符号走 build-release.ps1）
        File(rootProject.projectDir.parentFile, "app.symbols").delete()
    }
}
tasks.matching { it.name == "assembleRelease" }.configureEach {
    finalizedBy("archiveReleaseApk")
}
