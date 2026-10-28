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

// F-056: the phone's expense parser is driven by the SAME pattern pack as the desktop. Package that one file
// (only that one — not the 1000-line fixtures) into this module's resources so there is no second copy to drift.
val patternPacks = rootProject.projectDir.parentFile.resolve("docs/specs/pattern-packs")
tasks.processResources {
    from(patternPacks) { include("india-bank-sms.v1.json") }
}

tasks.test {
    useJUnit()
    testLogging { events("failed", "skipped"); showStandardStreams = false }
    // Hand the shared contract + the opt-in cross-implementation output path to the tests.
    systemProperty("halo.vectors", rootProject.projectDir.parentFile.resolve("docs/specs/crypto-parity-vectors.v2.json").absolutePath)
    systemProperty("halo.expenseFixtures", patternPacks.resolve("expense-fixtures.v1.json").absolutePath)
    systemProperty("halo.expenseSrc", projectDir.resolve("src/main/kotlin/app/halo/cloud/expense").absolutePath)
    System.getenv("HALO_KOTLIN_SEALED_OUT")?.let { systemProperty("halo.sealedOut", it) }
}
