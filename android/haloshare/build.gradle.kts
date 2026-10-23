plugins {
    id("org.jetbrains.kotlin.jvm")
    id("org.jetbrains.kotlin.plugin.serialization")
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    useJUnit()
    // The large-file and stall tests are deliberately real; give them room.
    testLogging { events("failed", "skipped"); showStandardStreams = false }
    maxHeapSize = "1g"
}
