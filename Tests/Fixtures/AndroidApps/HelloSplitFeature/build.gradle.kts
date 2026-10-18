// Install-time feature split for HelloSplit (#027).
plugins {
    alias(libs.plugins.android.dynamic.feature)
}

android {
    namespace = "io.apkrun.fixture.hellosplit.feature"
    compileSdk = 37

    defaultConfig {
        minSdk = 29
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":HelloSplit"))
}
