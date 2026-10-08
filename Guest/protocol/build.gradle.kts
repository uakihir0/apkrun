// The protocol module: the protobuf-javalite classes generated from
// Packages/GuestProtocol/proto, the frame codec, the version rules, and the capability
// names (guest-protocol.md §2, guest-components.md §2).
import org.gradle.api.file.SourceDirectorySet
import org.gradle.api.plugins.ExtensionAware

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.protobuf)
}

android {
    namespace = "io.apkrun.guest.protocol"
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

    sourceSets {
        getByName("main") {
            // The protobuf plugin registers the `proto` source directory as an extension of
            // each source set, so the schema is read from Packages/GuestProtocol (§2).
            (this as ExtensionAware).extensions.configure<SourceDirectorySet>("proto") {
                setSrcDirs(listOf("../../Packages/GuestProtocol/proto"))
            }
        }
    }
}

protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:${libs.versions.protobuf.get()}"
    }
    generateProtoTasks {
        all().forEach { task ->
            task.builtins {
                create("java") {
                    option("lite")
                }
            }
        }
    }
}

dependencies {
    implementation(libs.protobuf.javalite)
    testImplementation(libs.junit)
}
