// Shared build logic for the Kotlin guest modules. Each module applies its own plugins.
//
// ktfmt runs as the pinned com.facebook:ktfmt library instead of the ktfmt Gradle plugin.
// That plugin needs the classic Kotlin Gradle plugin, which AGP 9 does not provide, because
// AGP 9 has built-in Kotlin. The tasks keep the names that scripts/check-format.sh uses.
import org.gradle.api.attributes.Bundling

// The shadowed ktfmt jar carries its own dependencies, so the CLI runs from one pinned artifact.
val ktfmtClasspath by configurations.creating {
    attributes {
        attribute(Bundling.BUNDLING_ATTRIBUTE, objects.named(Bundling.SHADOWED))
    }
}

dependencies {
    ktfmtClasspath(libs.ktfmt)
}

val kotlinSources =
    fileTree(projectDir) {
        include("**/src/**/*.kt", "**/*.kts")
        exclude("**/build/**", "**/.gradle/**")
    }

tasks.register<JavaExec>("ktfmtCheck") {
    group = "verification"
    description = "Checks that the Kotlin sources follow the ktfmt kotlinlang style."
    classpath = ktfmtClasspath
    mainClass.set("com.facebook.ktfmt.cli.Main")
    args("--kotlinlang-style", "--dry-run", "--set-exit-if-changed")
    args(kotlinSources.files.map { it.absolutePath }.sorted())
}

tasks.register<JavaExec>("ktfmtFormat") {
    group = "formatting"
    description = "Formats the Kotlin sources in the ktfmt kotlinlang style."
    classpath = ktfmtClasspath
    mainClass.set("com.facebook.ktfmt.cli.Main")
    args("--kotlinlang-style")
    args(kotlinSources.files.map { it.absolutePath }.sorted())
}
