allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // 强制所有 Android 库模块（含 file_picker 等插件）compileSdk 为 36，
    // 避免 flutter_plugin_android_lifecycle 要求 36 而插件默认用 34 导致构建失败。
    // 注意：afterEvaluate 必须在 evaluationDependsOn(":app") 触发求值之前注册。
    afterEvaluate {
        (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)
            ?.compileSdkVersion(36)
    }
}
subprojects {
    project.evaluationDependsOn(":app")
    // 跳过 app 模块：其 compileOptions 已被 Flutter Gradle 插件 finalize（锁定），
    // 且 app 已在自身 build.gradle.kts 显式配置 Java 17，无需覆盖。
    if (name == "app") return@subprojects
    // 统一所有插件子项目的 compileSdk，避免个别插件（如 audio_session 的 34）触发 SDK 自动下载
    fun forceCompileSdk() {
        extensions.findByType<com.android.build.gradle.BaseExtension>()?.apply {
            compileSdkVersion(36)
            // 统一 Java 编译级别为 17：tencent_kit / just_audio /
            // permission_handler_android 仍写死 source/target 8，JDK 21 下
            // 触发「源值 8 已过时」构建警告。字节码向后兼容由 D8 desugar 保证。
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        }
    }
    if (project.state.executed) {
        forceCompileSdk()
    } else {
        afterEvaluate { forceCompileSdk() }
    }
}
// tencent_kit 6.2.0 捆绑的 open_sdk jar 方法签名引用已移除的
// android.support.v4.app.Fragment，AndroidX 工程下编译报「找不到
// android.support.v4.app.Fragment」；注入编译期桩 jar 提供该类
// （仅作用于 tencent_kit 模块，pub get 重装插件后仍生效）。
subprojects {
    if (name == "tencent_kit") {
        afterEvaluate {
            val stubJar = rootProject.file("stubs/android-support-v4-fragment.jar")
            if (stubJar.exists()) {
                dependencies.add("vendorImplementation", files(stubJar))
                println("[stub] injected android.support.v4.app.Fragment stub into tencent_kit")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
