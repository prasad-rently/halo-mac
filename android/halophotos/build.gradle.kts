plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    jvmToolchain(17)
}

// Plain Kotlin/JVM on purpose, like :haloshare and :halocloud: the perceptual-hash core, clustering and the
// review/delete state machine have no Android dependency, so the parity fixture, invariants and the 5,000-photo
// benchmark all run on the JVM in seconds. Deliberately NO dependencies — and no network classes (PhotoPathNoNetworkTest).
dependencies {
    testImplementation("junit:junit:4.13.2")
    // Parity fixture is JSON; the test parses it with kotlinx-serialization (already a project dependency elsewhere).
    testImplementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
}

tasks.test {
    useJUnit()
    testLogging { events("failed", "skipped"); showStandardStreams = true }
    maxHeapSize = "1g"
    // The structural tests read these files; declare them so Gradle re-runs the tests when they change.
    inputs.dir(rootProject.projectDir.resolve("app/src/main/kotlin/app/halo/mobile/photos"))
    inputs.file(rootProject.projectDir.parentFile.resolve("docs/specs/phash-parity.v1.json"))
    inputs.file(projectDir.resolve("build.gradle.kts"))
    systemProperty("halo.phashParity", rootProject.projectDir.parentFile.resolve("docs/specs/phash-parity.v1.json").absolutePath)
    systemProperty("halo.photosSrc", projectDir.resolve("src/main").absolutePath)
    systemProperty("halo.appPhotosSrc", rootProject.projectDir.resolve("app/src/main/kotlin/app/halo/mobile/photos").absolutePath)
}
