plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    jvmToolchain(17)
}

// Pure JVM on purpose (like :haloshare / :halocloud): the text transforms, code formatters/highlighter and the
// speed-test engine have no Android dependency, so every test — including the local-HTTP-server speed tests —
// runs on the JVM in seconds with no emulator. kotlinx-serialization-json is used only as a strict JSON *parser*
// (no reflection, no plugin); the printers are ours because the desktop's output format is Python's.
dependencies {
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    useJUnit()
    testLogging { events("failed", "skipped"); showStandardStreams = false }
    // The shared desktop<->mobile fixture (docs/specs/text-transform-vectors.v1.json).
    systemProperty("halo.transformVectors", rootProject.projectDir.parentFile.resolve("docs/specs/text-transform-vectors.v1.json").absolutePath)
}
