// swift-tools-version: 6.2
import Foundation
import PackageDescription

let binary: Target = if let artifact = ProcessInfo.processInfo.environment["REPOPROMPT_IROH_LOCAL_ARTIFACT"] {
    .binaryTarget(name: "IrohTransportFFI", path: artifact)
} else if ProcessInfo.processInfo.environment["REPOPROMPT_IROH_USE_LOCAL_ARTIFACT"] == "1" {
    .binaryTarget(name: "IrohTransportFFI", path: "Packages/RepoPromptIrohTransport/Artifacts/IrohTransportFFI.xcframework")
} else {
    .binaryTarget(
        name: "IrohTransportFFI",
        url: "https://github.com/repoprompt/repoprompt-remote/releases/download/iroh-ffi-v0.2.0/IrohTransportFFI.xcframework.zip",
        checksum: "40bc0a90294d010a8fe1c9572f73bcb1cea3406c9b560323136f78fefa74651b"
    )
}

let package = Package(
    name: "RepoPromptRemoteNetworking",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RepoPromptRemoteNetworking", targets: ["RepoPromptRemoteNetworking", "RepoPromptRemoteProtocol", "RepoPromptIrohTransport"]),
        .library(name: "RepoPromptRemoteProtocol", targets: ["RepoPromptRemoteProtocol"]),
    ],
    targets: [
        binary,
        .target(
            name: "RepoPromptIrohTransport",
            dependencies: ["IrohTransportFFI"],
            path: "Packages/RepoPromptIrohTransport/Sources/RepoPromptIrohTransport",
            linkerSettings: [
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .target(name: "RepoPromptRemoteProtocol", path: "Packages/RepoPromptRemoteProtocol/Sources/RepoPromptRemoteProtocol"),
        .target(
            name: "RepoPromptRemoteNetworking",
            dependencies: ["RepoPromptRemoteProtocol", "RepoPromptIrohTransport"],
            path: "Packages/RepoPromptIrohTransport/Sources/RepoPromptRemoteNetworking",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RepoPromptIrohTransportTests",
            dependencies: ["RepoPromptIrohTransport", "RepoPromptRemoteNetworking"],
            path: "Packages/RepoPromptIrohTransport/Tests/RepoPromptIrohTransportTests"
        ),
        .testTarget(
            name: "RepoPromptRemoteProtocolTests",
            dependencies: ["RepoPromptRemoteProtocol"],
            path: "Packages/RepoPromptRemoteProtocol/Tests/RepoPromptRemoteProtocolTests",
            resources: [.process("Fixtures")]
        ),
    ]
)
