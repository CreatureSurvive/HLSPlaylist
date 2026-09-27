// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HLSPlaylist",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "HLSPlaylist", targets: ["HLSPlaylist"]),
    ],
    targets: [
        .target(
            name: "HLSPlaylist",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "HLSPlaylistTests",
            dependencies: ["HLSPlaylist"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
