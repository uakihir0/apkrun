// The Gradle project of the fixture apps (build-system.md §8, §8.1). AGP is the version in Guest/, and
// the project has its own wrapper with the same Gradle version.
pluginManagement {
    repositories {
        google()
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "apkrun-fixtures"

include(":HelloText")
include(":HelloGL")
