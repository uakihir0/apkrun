// Platform-signed instrumentation for the composed Android image (#36).
plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "io.apkrun.fixture.systemservicestest"
    compileSdk = 37

    defaultConfig {
        applicationId = "io.apkrun.fixture.systemservicestest"
        minSdk = 34
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig =
                signingConfigs.create("fixture") {
                    storeFile = file("../../signing/test-fixture-a.jks")
                    storeType = "jks"
                    storePassword = "apkrun-test-fixture"
                    keyAlias = "fixture-a"
                    keyPassword = "apkrun-test-fixture"
                }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
