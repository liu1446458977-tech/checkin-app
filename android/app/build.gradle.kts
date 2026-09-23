plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.yuzi.checkin_app"
    compileSdk = flutter.compileSdkVersion

    // 刻意**不设置** ndkVersion。
    // 本工程没有任何 C/C++ 源码（Flutter 引擎的 .so 是官方预编译好的，
    // sqflite / shared_preferences 也都不编原生代码），所以根本用不到 NDK。
    // 一旦写了 ndkVersion，AGP 就会去下整个 NDK（约 1GB，dl.google.com 国内几十 KB/s），
    // 首次构建会被它拖住十几分钟甚至更久。
    // 如果将来真加了原生代码，再把这行加回来：
    //   ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.yuzi.checkin_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 刻意**没有** ndk { abiFilters } 块。
        // 它唯一的作用是防止第三方 AAR（androidx.datastore）捎带的 x86_64 jniLibs
        // 在 APK 里留下「声明支持 x86_64、却没有 libflutter.so」的空 ABI 目录——
        // 而这件事下面的 packaging.jniLibs.excludes 已经做了，属于重复。
        // 更要命的是：只要有 ndk{} 块（或 ndkVersion），AGP 就会去解析 NDK，
        // 在本机没装 NDK 时会触发 ~1GB 的自动下载（dl.google.com 国内极慢），
        // 首次构建直接被拖死。本工程没有任何 C/C++ 源码，不需要 NDK。
    }

    packaging {
        jniLibs {
            // androidx.datastore 的 AAR 会捎带一份 x86_64 的 jniLibs，而本包没有任何
            // x86_64 的 Flutter 引擎；留着会让 APK「谎报」支持 x86_64（装得上、起不来），直接排除。
            excludes += listOf("lib/x86_64/**")
        }
    }

    lint {
        // lint 分析在内存小的机器上会 Metaspace OOM；release 包不做 lint 门禁。
        // （CI 上可以删掉这两行，但保留也无害。）
        checkReleaseBuilds = false
        abortOnError = false
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
