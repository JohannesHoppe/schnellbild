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
            path: "Sources/Schnellbild",
            linkerSettings: [
                // SwiftUIs VideoPlayer referenziert AVKit nur intern — ohne
                // explizites Linken fehlt AVPlayerView zur Laufzeit (Crash).
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
