// The Store Agent application, io.apkrun.store (guest-components.md §8). It is a persistent
// privileged app on the custom image, platform-signed by the image build. The development build
// is signed with the test-only development key of Tests/Fixtures/signing/test-guest-dev.jks.
plugins {
    alias(libs.plugins.android.application)
}

// Set by scripts/build-guest.sh. The defaults only serve a direct Gradle run.
val storeVersionCode = (findProperty("apkrunStoreVersionCode") as String?)?.toInt() ?: 1000
val storeVersionName = (findProperty("apkrunStoreVersionName") as String?) ?: "0.1.0-dev"

android {
    namespace = "io.apkrun.store"
    compileSdk {
        version =
            release(37) {
                minorApiLevel = 0
            }
    }

    defaultConfig {
        applicationId = "io.apkrun.store"
        minSdk = 34
        targetSdk = 37
        versionCode = storeVersionCode
        versionName = storeVersionName
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
