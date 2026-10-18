group = "com.ryanheise.audioservice"
version = "1.0-SNAPSHOT"
val args = listOf("-Xlint:deprecation", "-Xlint:unchecked")

buildscript {
    // Uncomment when moving to Kotlin
    // val kotlinVersion = "2.3.20"
    val agpVersion = "9.0.1"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:$agpVersion")
        // Uncomment when moving to Kotlin
        // classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

tasks.withType<JavaCompile>().configureEach {
    options.compilerArgs.addAll(args)
}

// Uncomment when moving to Kotlin
// val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
// if (agpMajor < 9) {
//    apply(plugin = "org.jetbrains.kotlin.android")
// }

android {
    namespace = "com.ryanheise.audioservice"
    // 37：Android 16 Live Updates（ColorOS 16 流体云胶囊）用到 API 36 新通知 API
    //（ProgressStyle / EXTRA_REQUEST_PROMOTED_ONGOING 等），需 36+ 才能编译；
    // 运行时行为按 Build.VERSION.SDK_INT >= 36 门控，minSdk 19 不受影响
    compileSdk = 37

    defaultConfig {
        minSdk = 19
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Uncomment when moving to Kotlin
    // sourceSets {
    //     getByName("main") {
    //         java.srcDirs("src/main/kotlin")
    //     }
    //     getByName("test") {
    //         java.srcDirs("src/test/kotlin")
    //     }
    // }

    lint {
        disable += listOf("InvalidPackage")
    }
}

dependencies {
    implementation("androidx.media:media:1.7.0")
    implementation("androidx.core:core:1.13.1")
}
