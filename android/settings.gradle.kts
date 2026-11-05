// Halo Mobile — Android. Contract: docs/HALOSHARE_PROTOCOL.md;
// requirements: docs/specs/F-049-F-050-mobile-requirements.md.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "halo-mobile-android"

// :haloshare is plain Kotlin/JVM on purpose — the protocol core has no Android dependency, so its
// whole test suite (loopback, raw sockets, curl) runs on the JVM in seconds.
include(":haloshare")
// :halocloud is the Kotlin half of the cloud crypto contract (docs/specs/crypto-parity.md). Plain JVM
// for the same reason as :haloshare — and so the parity vectors run in seconds with no emulator.
include(":halocloud")
// :halophotos is the Similar Photos (F-025) core: pHash, clustering, review/delete state machine. Plain JVM, no deps.
include(":halophotos")
include(":app")
