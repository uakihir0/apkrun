// The shared runtime of both Guest Agents (guest-components.md §2, §6.2): the reflection wrappers
// of the system services, the socket server with its peer check, and the agent log. It uses the
// Kotlin standard library and kotlinx-coroutines only (guest-components.md §2).
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "io.apkrun.guest.runtime"
    compileSdk {
        version =
            release(37) {
                minorApiLevel = 0
            }
    }

    defaultConfig {
        minSdk = 34
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit)
}
