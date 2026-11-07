// swift-tools-version: 5.9
import PackageDescription

// HaloCloudKit — the iOS half of Halo's BYOB cloud line (F-049 iOS, backlog V2.7-08).
// A pure-Foundation/CryptoKit/Security library: NO UIKit/SwiftUI, so `swift test` runs on the Mac.
// Contract: docs/specs/crypto-parity.md + crypto-parity-vectors.v2.json (crypto/pairing),
// docs/specs/wire-contract/phone-nodes.v1.json (what the Android writers really produce).
let package = Package(
    name: "HaloCloudKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HaloCloudKit", targets: ["HaloCloudKit"]),
    ],
    targets: [
        .target(name: "HaloCloudKit"),
        .testTarget(
            name: "HaloCloudKitTests",
            dependencies: ["HaloCloudKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
