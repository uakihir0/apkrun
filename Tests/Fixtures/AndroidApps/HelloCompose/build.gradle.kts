// HelloCompose (fixture spec: docs/04-plan/test-strategy.md §4.2). A Compose LazyColumn and a TextField.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "io.apkrun.fixture.hellocompose"
    compileSdk = 37

    // The unit tests run against the release variant, the one that ships (as in HelloText).
    testBuildType = "release"

    buildFeatures {
        compose = true
    }

    defaultConfig {
        applicationId = "io.apkrun.fixture.hellocompose"
        minSdk = 29
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"
    }

    signingConfigs {
        create("fixture") {
            // Test-only key, committed on purpose (IR-328). It signs no product and is never trusted.
            storeFile = file("../../signing/test-fixture-a.jks")
            storePassword = "apkrun-test-fixture"
            keyAlias = "fixture-a"
            keyPassword = "apkrun-test-fixture"
        }
    }

    buildTypes {
        debug {
            // The debug build adds the ADB receiver of src/debug (IR-920). Same test-only key as the release build.
            signingConfig = signingConfigs.getByName("fixture")
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("fixture")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)

    testImplementation(libs.junit)
}
