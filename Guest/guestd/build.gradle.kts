// The Guest Agent application, io.apkrun.guest. #033 creates only the empty module, so that
// `./gradlew -p Guest :guestd:assemble` works. The daemon, the services, and the IME arrive
// with #072 and #071 (guest-components.md §2).
plugins {
    alias(libs.plugins.android.application)
}

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
        versionCode = 1
        versionName = "0.0.0-dev"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":protocol"))
}
