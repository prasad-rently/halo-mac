plugins {
    id("org.jetbrains.kotlin.jvm")
    id("org.jetbrains.kotlin.plugin.serialization")
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // api: the Rtdb surface exposes JsonElement, so the app module needs it on its own compile classpath.
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    useJUnit()
    testLogging { events("failed", "skipped"); showStandardStreams = false }
    // Hand the shared contract + the opt-in cross-implementation output path to the tests.
    systemProperty("halo.vectors", rootProject.projectDir.parentFile.resolve("docs/specs/crypto-parity-vectors.v2.json").absolutePath)
    System.getenv("HALO_KOTLIN_SEALED_OUT")?.let { systemProperty("halo.sealedOut", it) }
}
