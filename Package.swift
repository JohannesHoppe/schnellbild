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

/// LibRaw's library: LIB_OBJECTS of its Makefile.dist, under src/ (the
/// "_ph" placeholders and the samples are not part of it).
let librawSources = [
    "libraw_datastream", "libraw_c_api", "tables/cameralist", "decoders/fuji_compressed", "decoders/crx",
    "decoders/pana8", "decoders/fp_dng", "decoders/decoders_libraw", "decoders/olympus14", "decoders/sonycc",
    "decompressors/losslessjpeg", "decoders/unpack", "decoders/unpack_thumb", "integration/rawspeed_glue",
    "integration/dngsdk_glue", "tables/colorconst", "utils/utils_libraw", "utils/init_close_utils",
    "utils/decoder_info", "utils/open", "utils/phaseone_processing", "utils/thumb_utils", "write/tiff_writer",
    "preprocessing/subtract_black", "postprocessing/postprocessing_utils", "postprocessing/dcraw_process",
    "preprocessing/raw2image", "postprocessing/mem_image", "x3f/x3f_utils_patched", "x3f/x3f_parse_process",
    "utils/read_utils", "utils/curves", "utils/utils_dcraw", "tables/colordata", "decoders/canon_600",
    "decoders/decoders_dcraw", "decoders/decoders_libraw_dcrdefs", "decoders/generic", "decoders/kodak_decoders",
    "decoders/dng", "decoders/smal", "decoders/load_mfbacks", "metadata/sony", "metadata/nikon",
    "metadata/samsung", "metadata/cr3_parser", "metadata/canon", "metadata/epson", "metadata/olympus",
    "metadata/leica", "metadata/fuji", "metadata/adobepano", "metadata/pentax", "metadata/p1", "metadata/makernotes",
    "metadata/exif_gps", "metadata/kodak", "metadata/tiff", "metadata/ciff", "metadata/mediumformat",
    "metadata/minolta", "metadata/identify_tools", "metadata/hasselblad_model", "metadata/normalize_model",
    "metadata/identify", "metadata/misc_parsers", "tables/wblists", "postprocessing/postprocessing_aux",
    "postprocessing/postprocessing_utils_dcrdefs", "postprocessing/aspect_ratio", "demosaic/misc_demosaic",
    "demosaic/xtrans_demosaic", "demosaic/ahd_demosaic", "demosaic/dht_demosaic", "demosaic/aahd_demosaic",
    "demosaic/dcb_demosaic", "write/file_write", "preprocessing/ext_preprocess", "write/apply_profile",
]

let package = Package(
    name: "Schnellbild",
    platforms: [
        .macOS("15.0")   // (.v15 needs swift-tools-version 6)
    ],
    targets: [
        .executableTarget(
            name: "Schnellbild",
            dependencies: ["VLCKit", "VLCFrames", "CArchives", "CRaw", "OfflineMap"],
            path: "Schnellbild",
            linkerSettings: [
                // Linked explicitly: without it, AVPlayerView can be missing
                // at runtime (crash).
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        // The offline map: OpenStreetMap data (Scripts/fetch_map.sh puts the
        // files into Vendor/Map, the app carries them in Resources/Map) drawn
        // with CoreGraphics and CoreText, the place index, the SwiftUI map view
        .target(
            name: "OfflineMap",
            path: "OfflineMap"
        ),
        // What the app and its thumbnail extension share of VLC: one frame of
        // a video, what VLC may do with a file someone else made, and how
        // such a file is opened (`RegularFile`).
        .target(
            name: "VLCFrames",
            dependencies: ["VLCKit"],
            path: "VLCFrames"
        ),
        // The QuickLook thumbnail extension for the videos QuickLook can't
        // read (MKV, WebM, WMV, ASF, FLV, Ogg, VOB): Scripts/build_app.sh wraps the binary into
        // Contents/PlugIns/SchnellbildThumbnails.appex. Its entry point is the
        // system's extension main (no main of its own: the system's calls
        // `main` if there is one).
        .executableTarget(
            name: "SchnellbildThumbnails",
            dependencies: ["VLCKit", "VLCFrames"],
            path: "ThumbnailExtension",
            exclude: ["Info.plist"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        ),
        // The media extension's container parsers (Matroska, MPEG transport
        // streams), as a module of its own for the tests (Scripts/build_app.sh
        // builds the extension itself with FormatReader.swift, which needs the
        // MediaExtension framework).
        .target(
            name: "VideoContainers",
            path: "FormatReader",
            exclude: ["FormatReader.swift", "Info.plist", "FormatReader.entitlements"]
        ),
        // Archives: the official UnRAR source (Scripts/fetch_unrar.sh vendors
        // it; Native/CArchives/unrar points there) behind a small C face, and
        // the system's libarchive for ZIP and 7z (looked up at run time,
        // libarchive_shim.cpp).
        .target(
            name: "CArchives",
            path: "Native/CArchives",
            sources: ["rar_shim.cpp", "libarchive_shim.cpp"] + unrarSources.map { "unrar/\($0).cpp" },
            publicHeadersPath: "include",
            cxxSettings: [
                .define("RARDLL"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("RAR_SMP"),
                .unsafeFlags(["-Wno-logical-op-parentheses", "-Wno-switch", "-Wno-dangling-else", "-w"])
            ]
        ),
        // Camera RAW formats ImageIO doesn't read: LibRaw's source as LibRaw
        // LLC publishes it (Scripts/fetch_libraw.sh vendors it;
        // Native/CRaw/libraw points there), unchanged, behind a small C face.
        // Built thread-safe (no LIBRAW_NOTHREADS), with no library of its
        // own: no zlib (USE_ZLIB off: VLCKit exports zlib's names, and the
        // app's executable may take nothing but VLC's from it, see
        // build_app.sh; deflate-compressed DNGs stay ImageIO's), libjpeg,
        // LCMS, RawSpeed, DNG SDK or X3F (USE_X3FTOOLS off: Sigma's X3F
        // decoder is left out).
        .target(
            name: "CRaw",
            path: "Native/CRaw",
            sources: ["raw_shim.cpp"] + librawSources.map { "libraw/src/\($0).cpp" },
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("libraw"),
                .define("LIBRAW_MAX_ALLOC_MB_DEFAULT", to: "1024L"),
                .define("LIBRAW_MAX_THUMBNAIL_MB", to: "64L"),
                .unsafeFlags(["-w"])
            ]
        ),
        // Official VideoLAN VLCKit, vendored locally; fetch it first with
        // Scripts/fetch_vlckit.sh. The xcframework is gitignored (large binary).
        .binaryTarget(
            name: "VLCKit",
            path: "Vendor/VLCKit.xcframework"
        ),
        .testTarget(
            name: "SchnellbildTests",
            dependencies: ["Schnellbild", "VLCFrames", "VideoContainers", "OfflineMap"],
            path: "Tests/SchnellbildTests",
            resources: [.copy("Archives"), .copy("Videos"), .copy("Locations"), .copy("Metadata"), .copy("Pictures")]
        )
    ],
    cxxLanguageStandard: .cxx17
)
