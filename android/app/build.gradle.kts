plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "app.halo.mobile"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.halo.mobile"
        minSdk = 26                 // Android 8.0 (requirements §5)
        targetSdk = 36
        versionCode = 2
        versionName = "0.2.0"
    }

    buildTypes {
        // Sideload distribution (F-049 D7): no store submission, so the debug signing key is enough
        // for now and there is no release keystore to manage.
        release { isMinifyEnabled = false }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation(project(":haloshare"))
    implementation(project(":halocloud"))

    implementation("androidx.core:core-ktx:1.17.0")
    // Background SMS sync: survives process death, honours the network constraint, backs off on failure (F-044 D8).
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    // QR pairing without Google Play Services (the phone must pair on a de-Googled device too). Brings its own
    // camera-permission request; the pairing code can also be pasted, so the camera is never required.
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")

    implementation(platform("androidx.compose:compose-bom:2025.10.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
}

// Version note: the newest Compose (1.12) requires AGP 9.1+ and compileSdk 37. This build is on
// AGP 8.13 / API 36, so Compose is pinned to the BOM from that era. Move AGP and Compose together.

dependencies {
    testImplementation("junit:junit:4.13.2")
}
