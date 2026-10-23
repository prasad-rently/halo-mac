// swift-tools-version: 5.9
import PackageDescription

// HaloShareKit — the iOS/macOS implementation of the HaloShare (LocalSend v2.x) peer.
// Contract: docs/HALOSHARE_PROTOCOL.md. Requirements: docs/specs/F-049-F-050-mobile-requirements.md.
let package = Package(
    name: "HaloShareKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HaloShareKit", targets: ["HaloShareKit"]),
        // A command-line peer, used to drive and test the library against other implementations.
        .executable(name: "halosharecli", targets: ["halosharecli"]),
    ],
    targets: [
        .target(name: "HaloShareKit"),
        .executableTarget(name: "halosharecli", dependencies: ["HaloShareKit"]),
        .testTarget(name: "HaloShareKitTests", dependencies: ["HaloShareKit"]),
    ]
)
