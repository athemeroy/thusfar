plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.yedu.zhupi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Same package as 1.7.x so 2.0 installs over it and keeps files/yedu.
        applicationId = "com.yedu.zhupi"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Same private release key as 1.7.x; never copied into the repository.
    val keyPath = System.getenv("YEDU_SIGNING_STORE") ?: "/volume2/docker/book/signing/yedu-release.jks"
    val passwordPath = System.getenv("YEDU_SIGNING_PASSWORD_FILE") ?: "/volume2/docker/book/signing/password"
    val hasSigning = file(keyPath).isFile && file(passwordPath).isFile
    if (hasSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(keyPath)
                storePassword = file(passwordPath).readText().trim()
                keyAlias = "yedu"
                keyPassword = file(passwordPath).readText().trim()
            }
        }
    }

    // "full" replaces 1.7.x in place; "probe" installs beside it for trying 2.0 safely.
    flavorDimensions += "channel"
    productFlavors {
        create("full") {
            dimension = "channel"
        }
        create("probe") {
            dimension = "channel"
            applicationIdSuffix = ".v2probe"
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasSigning) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
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
