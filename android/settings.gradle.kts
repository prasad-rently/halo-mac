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
include(":app")
