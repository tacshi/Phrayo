plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.capyvibe.phrayo"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    buildFeatures { buildConfig = true }
    sourceSets["main"].java.srcDir("../../native/android-voice/kotlin")
    sourceSets["main"].jniLibs.srcDir("../../build/android-native/jniLibs-OFF")
    sourceSets["main"].assets.srcDir("../../build/android-native/probe-assets")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.capyvibe.phrayo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 31
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        targetSdk = 36
        ndk { abiFilters += "arm64-v8a" }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.10.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.mlkit:translate:17.0.3")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("com.ibm.icu:icu4j:77.1")
    implementation(files("../../build/android-deps/sherpa-onnx-1.13.8.aar"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

val prepareNativeRuntime by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    commandLine("python3", "scripts/prepare-android-app.py")
    environment("PHRAYO_VULKAN", "OFF")
    environment("PHRAYO_PROFILE", "OFF")
    inputs.files(fileTree("../../native/android-voice") { include("*.json", "*.cpp", "*.h", "CMakeLists.txt", "licenses/**") })
    inputs.files(fileTree("../../scripts") { include("*android-voice*", "prepare-android-app.py") })
    outputs.dir("../../build/android-native/jniLibs-OFF")
    outputs.dir("../../build/android-native/probe-assets")
    outputs.file("../../build/android-deps/sherpa-onnx-1.13.8.aar")
}
tasks.named("preBuild").configure { dependsOn(prepareNativeRuntime) }
