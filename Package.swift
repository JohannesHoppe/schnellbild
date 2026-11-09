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
            dependencies: ["VLCKit"],
            path: "Schnellbild",
            linkerSettings: [
                // Linked explicitly: without it, AVPlayerView can be missing
                // at runtime (crash).
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        // Official VideoLAN VLCKit, vendored locally — fetch it first with
        // Scripts/fetch_vlckit.sh. The xcframework is gitignored (large binary).
        .binaryTarget(
            name: "VLCKit",
            path: "Vendor/VLCKit.xcframework"
        ),
        .testTarget(
            name: "SchnellbildTests",
            dependencies: ["Schnellbild"],
            path: "Tests/SchnellbildTests"
        )
    ]
)
