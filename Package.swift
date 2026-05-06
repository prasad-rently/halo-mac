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
            path: "Halo",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "HaloTests",
            dependencies: ["Halo"],
            path: "HaloTests"
        )
    ]
)
