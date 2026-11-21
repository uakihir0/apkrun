// OtherInstaller (fixture spec: test-strategy.md §4.2, M06-update-system.md #40).
// Declares REQUEST_INSTALL_PACKAGES and tries to update HelloUpdate through
// PackageInstaller with USER_ACTION_NOT_REQUIRED. Its assets hold the V2 APK the
// update-repos build produces (scripts/build-fixtures.sh).
plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "io.apkrun.fixture.otherinstaller"
    compileSdk = 37

    defaultConfig {
        applicationId = "io.apkrun.fixture.otherinstaller"
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
            signingConfig = signingConfigs.getByName("fixture")
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("fixture")
        }
    }

    sourceSets {
        // build-fixtures.sh builds HelloUpdate V2 into update-repos first; the
        // session streams that APK straight from the committed repo layout.
        getByName("main").assets.srcDir("../../update-repos/local/io.apkrun.fixture.helloupdate/2")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
