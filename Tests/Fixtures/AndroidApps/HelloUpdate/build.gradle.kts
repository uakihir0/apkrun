// HelloUpdate (fixture spec: docs/04-plan/issues/M06-update-system.md #38).
// Two versions come out of the same source: -Papkrun.versionCode=1 or 2 selects the version the
// local update fixture serves from Tests/Fixtures/update-repos/local/.
plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "io.apkrun.fixture.helloupdate"
    compileSdk = 37

    defaultConfig {
        applicationId = "io.apkrun.fixture.helloupdate"
        minSdk = 29
        targetSdk = 37
        val version = (findProperty("apkrun.versionCode") as? String)?.toInt() ?: 1
        versionCode = version
        versionName = "$version.0"
    }

    signingConfigs {
        create("fixture") {
            // Test-only key, committed on purpose (IR-328). It signs no product and is never trusted.
            storeFile = file("../../signing/test-fixture-a.jks")
            storePassword = "apkrun-test-fixture"
            keyAlias = "fixture-a"
            keyPassword = "apkrun-test-fixture"
        }
        create("fixtureB") {
            // Second test-only key. Not applied to a build type: scripts/build-fixtures.sh
            // re-signs the rotation variants with it through apksigner.
            storeFile = file("../../signing/test-fixture-b.jks")
            storePassword = "apkrun-test-fixture"
            keyAlias = "fixture-b"
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
