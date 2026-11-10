// swift-tools-version:5.9
import PackageDescription

/// UnRAR's library build: OBJECTS and LIB_OBJ of its makefile (the other
/// .cpp files are included by these or belong to the command-line tool).
let unrarSources = [
    "rar", "strlist", "strfn", "pathfn", "smallfn", "global", "file", "filefn", "filcreat",
    "archive", "arcread", "unicode", "system", "crypt", "crc", "rawread", "encname",
    "resource", "match", "timefn", "rdwrfn", "consio", "options", "errhnd", "rarvm", "secpassword",
    "rijndael", "getbits", "sha1", "sha256", "blake2s", "hash", "extinfo", "extract", "volume",
    "list", "find", "unpack", "headers", "threadpool", "rs16", "cmddata", "ui", "largepage",
    "filestr", "scantree", "dll", "qopen"
]

let package = Package(
    name: "Schnellbild",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Schnellbild",
            dependencies: ["VLCKit", "VLCFrames", "CArchives"],
            path: "Schnellbild",
            linkerSettings: [
                // Linked explicitly: without it, AVPlayerView can be missing
                // at runtime (crash).
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        // What the app and its thumbnail extension share of VLC: one frame of
        // a video, and what VLC may do with a file someone else made.
        .target(
            name: "VLCFrames",
            dependencies: ["VLCKit"],
            path: "VLCFrames"
        ),
        // The QuickLook thumbnail extension for the videos QuickLook can't
        // read (MKV, WebM, AVI …): Scripts/build_app.sh wraps the binary into
        // Contents/PlugIns/SchnellbildThumbnails.appex. Its entry point is the
        // system's extension main (no main of its own: the system's calls
        // `main` if there is one).
        .executableTarget(
            name: "SchnellbildThumbnails",
            dependencies: ["VLCKit", "VLCFrames"],
            path: "ThumbnailExtension",
            exclude: ["Info.plist", "ThumbnailExtension.entitlements"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        ),
        // Archives: the official UnRAR source (Scripts/fetch_unrar.sh vendors
        // it; Native/CArchives/unrar points there) behind a small C face, and
        // the system's libarchive for ZIP and 7z.
        .target(
            name: "CArchives",
            path: "Native/CArchives",
            sources: ["rar_shim.cpp"] + unrarSources.map { "unrar/\($0).cpp" },
            publicHeadersPath: "include",
            cxxSettings: [
                .define("RARDLL"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("RAR_SMP"),
                .unsafeFlags(["-Wno-logical-op-parentheses", "-Wno-switch", "-Wno-dangling-else", "-w"])
            ],
            linkerSettings: [.linkedLibrary("archive")]
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
            path: "Tests/SchnellbildTests",
            resources: [.copy("Archives")]
        )
    ],
    cxxLanguageStandard: .cxx17
)
