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
    // 统一所有插件子项目的 compileSdk，避免个别插件（如 audio_session 的 34）触发 SDK 自动下载
    fun forceCompileSdk() {
        extensions.findByType<com.android.build.gradle.BaseExtension>()?.apply {
            compileSdkVersion(36)
        }
    }
    if (project.state.executed) {
        forceCompileSdk()
    } else {
        afterEvaluate { forceCompileSdk() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
