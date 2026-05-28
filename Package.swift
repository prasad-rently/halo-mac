// swift-tools-version: 5.9
// Halo — Package.swift
// Only used if you prefer SPM. Xcode project is the primary build target.

import PackageDescription

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Sentry crash reporting (Iteration 11)
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Halo",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            // Use project root as path so we can add Shared/HaloHelperProtocol.swift
            path: ".",
            // Exclude plists/entitlements and anything SPM should not compile
            // NOTE: exclude must precede sources in SPM manifests
            exclude: [
                "Halo/Resources/Info.plist",
                "Halo/Resources/PrivacyInfo.xcprivacy",
                "Halo/Resources/Assets.xcassets",   // re-added as explicit resource below
                "Halo/Resources/signatures.json",   // re-added as explicit resource below
                "Halo/Halo.entitlements",
                "Halo/Halo-Debug.entitlements",
                // HaloSharedData.swift: Foundation-only, safe to compile in both targets
                "HaloHelper",
                "HaloWidget",
                "HaloTests",
                "docs",
                "Assets",
                "Package.swift",
                "Package.resolved",
                "README.md",
                "CLAUDE.md",
                "LICENSE",
            ],
            sources: [
                "Halo",
                "Shared/HaloHelperProtocol.swift",   // F-002: shared XPC protocol
                "Shared/HaloSharedData.swift",        // HaloWidgetData — Foundation only, no WidgetKit
            ],
            resources: [
                .process("Halo/Resources/Assets.xcassets"),
                .copy("Halo/Resources/signatures.json"),   // F-004: bundled signature database
            ]
        ),
        .testTarget(
            name: "HaloTests",
            dependencies: ["Halo"],
            path: "HaloTests"
        )
    ]
)
