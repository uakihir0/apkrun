// HelloFiles (fixture spec: test-strategy.md §4.2, docs/04-plan/issues/M09-macos-integration.md
// #83).
plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "io.apkrun.fixture.hellofiles"
    compileSdk = 37

    // The unit tests run against the release variant, the one that ships (#17 step 1 names
    // testReleaseUnitTest).
    testBuildType = "release"

    defaultConfig {
        applicationId = "io.apkrun.fixture.hellofiles"
        minSdk = 29
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"
    }

    signingConfigs {
        create("fixture") {
            // Test-only key, committed on purpose (IR-328). It signs no product and is never
            // trusted.
            storeFile = file("../../signing/test-fixture-a.jks")
            storePassword = "apkrun-test-fixture"
            keyAlias = "fixture-a"
            keyPassword = "apkrun-test-fixture"
        }
    }

    buildTypes {
        debug {
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
