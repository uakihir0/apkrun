// The Guest Agent application, io.apkrun.guest (guest-components.md §2). In development mode the
// daemon
// runs from this APK's class path, started by app_process under the shell uid (guest-components.md
// §3.2).
// The APK has no launcher activity. The release build is signed with the test-only development key
// of
// Tests/Fixtures/signing/test-guest-dev.jks (guest-components.md §2).
plugins {
    alias(libs.plugins.android.application)
}

// Set by scripts/build-guest.sh. The defaults only serve a direct Gradle run.
val guestVersionCode = (findProperty("apkrunGuestVersionCode") as String?)?.toInt() ?: 1000
val guestVersionName = (findProperty("apkrunGuestVersionName") as String?) ?: "0.1.0-dev"

android {
    namespace = "io.apkrun.guest"
    compileSdk {
        version =
            release(37) {
                minorApiLevel = 0
            }
    }

    defaultConfig {
        applicationId = "io.apkrun.guest"
        minSdk = 34
        targetSdk = 37
        versionCode = guestVersionCode
        versionName = guestVersionName
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        create("developmentTest") {
            storeFile = rootProject.file("../Tests/Fixtures/signing/test-guest-dev.jks")
            storeType = "jks"
            storePassword = "apkrun-test-guest"
            keyAlias = "apkrun-test-guest-dev"
            keyPassword = "apkrun-test-guest"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("developmentTest")
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":protocol"))
    implementation(project(":agentruntime"))
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.protobuf.javalite)
    testImplementation(libs.junit)
}
