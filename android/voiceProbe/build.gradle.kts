plugins {
    id("com.android.application")
}

android {
    namespace = "app.capyvibe.phrayo.voiceprobe"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    defaultConfig {
        applicationId = "app.capyvibe.phrayo.voiceprobe"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += "arm64-v8a" }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets["main"].jniLibs.srcDir("../../build/android-native/jniLibs-${project.findProperty("voiceBackend") ?: "OFF"}")
    sourceSets["main"].java.srcDir("../../native/android-voice/kotlin")
    sourceSets["main"].assets.srcDir("../../build/android-native/probe-assets")
    buildTypes {
        release {
            // Qualification artifact only; this package is never a store release.
            signingConfig = signingConfigs.getByName("debug")
            isDebuggable = true
            isMinifyEnabled = false
        }
    }
}

kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }

dependencies {
    // Android's public ICU subset does not expose rule-based number spellout.
    implementation("com.ibm.icu:icu4j:77.1")
}
