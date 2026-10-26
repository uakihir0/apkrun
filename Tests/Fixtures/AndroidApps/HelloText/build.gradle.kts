// HelloText (fixture spec: docs/04-plan/issues/M01-android-bring-up.md #17).
plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "io.apkrun.fixture.hellotext"
    compileSdk = 37

    // The unit tests run against the release variant, the one that ships (#17 step 1 names testReleaseUnitTest).
    testBuildType = "release"

    defaultConfig {
        applicationId = "io.apkrun.fixture.hellotext"
        minSdk = 29
        targetSdk = 37
        val fixtureVersionCode =
            providers.gradleProperty("fixtureVersionCode").orNull?.let {
                it.toIntOrNull() ?: error("fixtureVersionCode must be a positive Int.")
            } ?: 1
        require(fixtureVersionCode > 0) { "fixtureVersionCode must be a positive Int." }
        versionCode = fixtureVersionCode
        versionName = "$fixtureVersionCode.0"
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
            // The debug build adds the ADB receiver of src/debug (IR-920). It is signed with the same test-only key
            // as the release build, so its signature does not depend on the machine's debug keystore. AGP makes unit
            // tests only for testBuildType (release), so the command class is in main and its test in src/test.
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
    testImplementation(libs.junit)
}
