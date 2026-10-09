// One Gradle build for every Kotlin guest component (guest-components.md §2).
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

rootProject.name = "apkrun-guest"

include(":protocol")

include(":agentruntime")

include(":guestd")
