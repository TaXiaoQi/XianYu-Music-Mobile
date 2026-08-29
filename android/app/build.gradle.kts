import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名：读取 android/key.properties（已 gitignore，含随机密码）。
// 缺失时回退 debug 签名，保证开发/CI 环境 `flutter run --release` 仍可构建。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.xianyumusic.app"
    // file_picker 依赖的 flutter_plugin_android_lifecycle 要求 compileSdk >= 36；
    // 37：Honor/MagicOS ROM 按 targetSdk 分层下发预测返回进度事件，
    // targetSdk=36 时真手指手势进度恒为 0（页面不跟手），37 正常（对齐 PiliNara）
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.xianyumusic.app"
        manifestPlaceholders["appLabel"] = "弦予音乐"
        minSdk = flutter.minSdkVersion
        // 见 compileSdk 注释：预测返回进度需要 targetSdk 37
        targetSdk = 37
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

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String? ?: ""
            keyPassword = keystoreProperties["keyPassword"] as String? ?: ""
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String? ?: ""
        }
    }

    buildTypes {
        // debug / flutter run 使用独立的包名后缀，与 release 正式包区分开：
        // debug(debug.keystore) 与 release(key.properties 正式密钥) 签名不同，
        // 若共用同一包名会因签名不一致被系统拒绝覆盖安装（需卸载重装）。
        // 加后缀后两者可共存（applicationId = com.xianyumusic.app.debug），
        // FileProvider authorities、QQ 回调等均随 ${applicationId} 自动跟随。
        debug {
            applicationIdSuffix = ".debug"
            // debug 应用显示名加「·测试」后缀，与 release 正式版在一屏内可区分
            manifestPlaceholders["appLabel"] = "弦予音乐·测试"
        }
        release {
            manifestPlaceholders["appLabel"] = "弦予音乐"
            // key.properties 存在时用专用 release 密钥签名，缺失时回退 debug 签名
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
// Rust（绑定 + .so，见 scripts/gradle-rust-hook.ps1）。
// 默认自动检测并编译 Rust（绑定 + .so）；如需完全跳过（直接复用工程中已有 .so 产物），
// 设置 XIANMU_SKIP_RUST=1。（XIANMU_BUILD_RUST 仅作历史兼容保留，已不再需要）
val isWindows = System.getProperty("os.name").lowercase().contains("windows")
tasks.register("rustHook") {
    doLast {
        // 默认自动审查并编译 Rust 后端（与桌面端 tauri dev 行为一致：有变更才编译，
        // 无变更时钩子内部 1 秒静默放行）。如需完全跳过，设置 XIANMU_SKIP_RUST=1。
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
// arm64）复制到 releases/弦予音乐_<版本>_arm64.apk，并把 gen_snapshot 的混淆符号
// (--save-debugging-info=app.symbols，落于项目根) 归档到 releases/symbols/<版本>/，
// 让裸 `flutter build apk --release` 完整等价旧 build-release.ps1。
// 符号用于 `flutter symbolize -d app.symbols` 还原线上混淆堆栈。
tasks.register("archiveReleaseApk") {
    group = "build"
    doLast {
        val apk = layout.buildDirectory.file("outputs/flutter-apk/app-release.apk").get().asFile
        if (!apk.exists()) return@doLast
        val version = runCatching { flutter.versionName }.getOrDefault("0.0.0")
        val projectRoot = rootProject.projectDir.parentFile
        val releasesDir = File(projectRoot, "releases")
        releasesDir.mkdirs()
        val dest = File(releasesDir, "弦予音乐_${version}_arm64.apk")
        apk.copyTo(dest, overwrite = true)
        logger.lifecycle("已归档正式安装包: ${dest.absolutePath} (${"%.1f".format(dest.length() / 1024.0 / 1024.0)} MB)")
        // 混淆符号归档（abiFilters 已限定 arm64 单架构，符号有效）
        val sym = File(projectRoot, "app.symbols")
        if (sym.exists()) {
            val symDir = File(releasesDir, "symbols/$version")
            symDir.mkdirs()
            sym.copyTo(File(symDir, "app.symbols"), overwrite = true)
            sym.delete()
            logger.lifecycle("已归档混淆符号: ${symDir.absolutePath}")
        }
    }
}
tasks.matching { it.name == "assembleRelease" }.configureEach {
    finalizedBy("archiveReleaseApk")
}
