// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClipVault",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ClipVault", targets: ["ClipVault"]),
        .library(name: "ClipVaultCore", targets: ["ClipVaultCore"])
    ],
    targets: [
        .target(
            name: "ClipVaultCore",
            linkerSettings: [
                .unsafeFlags([
                    "-L", "rust/SearchIndexCore/target/release",
                    "-lsearch_index_core"
                ])
            ]
        ),
        .executableTarget(
            name: "ClipVault",
            dependencies: ["ClipVaultCore"]
        ),
        .testTarget(
            name: "ClipVaultCoreTests",
            dependencies: ["ClipVaultCore"]
        )
    ]
)
