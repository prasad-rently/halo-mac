// swift-tools-version: 5.9
import PackageDescription

// HaloShareKit — the iOS/macOS implementation of the HaloShare (LocalSend v2.x) peer.
// Contract: docs/HALOSHARE_PROTOCOL.md. Requirements: docs/specs/F-049-F-050-mobile-requirements.md.
let package = Package(
    name: "HaloShareKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HaloShareKit", targets: ["HaloShareKit"]),
        // The Share Extension's half (F-050 D7): stages shared items into the App Group container.
        // A separate product with NO dependency on HaloShareKit — the extension links only this,
        // so "the extension does no networking" is a property of the link graph, not a promise.
        .library(name: "HaloShareStaging", targets: ["HaloShareStaging"]),
        // A command-line peer, used to drive and test the library against other implementations.
        .executable(name: "halosharecli", targets: ["halosharecli"]),
    ],
    targets: [
        .target(name: "HaloShareKit"),
        .target(name: "HaloShareStaging"),
        .executableTarget(name: "halosharecli", dependencies: ["HaloShareKit"]),
        .testTarget(name: "HaloShareKitTests", dependencies: ["HaloShareKit"]),
        .testTarget(name: "HaloShareStagingTests", dependencies: ["HaloShareStaging"]),
    ]
)
