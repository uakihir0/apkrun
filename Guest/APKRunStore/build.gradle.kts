// The persistent Store Agent, io.apkrun.store, packaged in custom APKRun images.
plugins {
    alias(libs.plugins.android.application)
}

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

androidComponents {
    onVariants(selector().all()) { variant ->
        variant.outputs.forEach { output ->
            output.outputFileName.set("apkrun-store.apk")
        }
    }
}

dependencies {
    implementation(project(":protocol"))
    implementation(project(":agentruntime"))
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.protobuf.javalite)
    testImplementation(libs.junit)
}
