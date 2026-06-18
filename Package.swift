// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Schnellbild",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Schnellbild",
            path: "Schnellbild",
            linkerSettings: [
                // SwiftUI's VideoPlayer references AVKit only internally — without
                // explicit linking, AVPlayerView is missing at runtime (crash).
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "SchnellbildTests",
            dependencies: ["Schnellbild"],
            path: "Tests/SchnellbildTests"
        )
    ]
)
