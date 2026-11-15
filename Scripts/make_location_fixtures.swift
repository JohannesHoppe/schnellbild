// Draws the fixtures with places and camera metadata for the Inspector and
// for sorting by distance: photos with EXIF and GPS at public landmarks, one
// without a place, and a QuickTime video with an ISO 6709 location, a
// creation date and a camera, as iPhones write them. Made-up camera names,
// no personal data. Always the same output.
//
//   swift Scripts/make_location_fixtures.swift Tests/SchnellbildTests/Locations UITests/Fixtures
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let folders = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
guard !folders.isEmpty else { print("usage: make_location_fixtures.swift <folder>…"); exit(1) }

/// A small picture: a gradient with a warm patch (any content would do).
func picture(width: Int = 64, height: Int = 48, tint: Double) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in 0..<width {
        let v = 0.2 + 0.6 * Double(x) / Double(width - 1)
        ctx.setFillColor(CGColor(srgbRed: v, green: v * (1 - tint * 0.3), blue: v * (1 - tint), alpha: 1))
        ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.6, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: width / 3, y: height / 3, width: width / 3, height: height / 3))
    return ctx.makeImage()!
}

/// EXIF's GPS dictionary for a place (positive values, the hemisphere in the refs).
func gps(_ latitude: Double, _ longitude: Double, altitude: Double? = nil, direction: Double? = nil) -> [CFString: Any] {
    var dictionary: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: abs(latitude), kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
        kCGImagePropertyGPSLongitude: abs(longitude), kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E",
    ]
    if let altitude {
        dictionary[kCGImagePropertyGPSAltitude] = abs(altitude)
        dictionary[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
    }
    if let direction {
        dictionary[kCGImagePropertyGPSImgDirection] = direction
        dictionary[kCGImagePropertyGPSImgDirectionRef] = "T"
    }
    return dictionary
}

func writeJPEG(_ name: String, tint: Double, properties: [CFString: Any]) throws {
    for folder in folders {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var all = properties
        all[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(dest, picture(tint: tint), all as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

// Marienplatz, Munich: every capture field the Inspector shows
try writeJPEG("geo.jpg", tint: 0.2, properties: [
    kCGImagePropertyOrientation: 1,
    kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Example",
        kCGImagePropertyTIFFModel: "Example Camera One",
        kCGImagePropertyTIFFSoftware: "Fixture 1.0",
    ],
    kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2024:06:18 22:31:09",
        kCGImagePropertyExifDateTimeDigitized: "2024:06:18 22:31:09",
        kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
        kCGImagePropertyExifFNumber: 1.8,
        kCGImagePropertyExifExposureTime: 1.0 / 250,
        kCGImagePropertyExifISOSpeedRatings: [100],
        kCGImagePropertyExifFocalLength: 4.2,
        kCGImagePropertyExifFocalLenIn35mmFilm: 26,
        kCGImagePropertyExifFlash: 16,
        kCGImagePropertyExifExposureProgram: 2,
        kCGImagePropertyExifExposureBiasValue: 0.7,
        kCGImagePropertyExifWhiteBalance: 0,
        kCGImagePropertyExifLensMake: "Example",
        kCGImagePropertyExifLensModel: "Example Lens 4.2mm f/1.8",
    ],
    kCGImagePropertyGPSDictionary: gps(48.137154, 11.576124, altitude: 519, direction: 123.4),
    kCGImagePropertyIPTCDictionary: [
        kCGImagePropertyIPTCObjectName: "Fixture",
        kCGImagePropertyIPTCKeywords: ["fixture", "location"],
    ],
])
// Other landmarks, one in each quarter of the globe
try writeJPEG("geo-paris.jpg", tint: 0.4, properties: [kCGImagePropertyGPSDictionary: gps(48.858370, 2.294481)])
try writeJPEG("geo-sydney.jpg", tint: 0.6, properties: [kCGImagePropertyGPSDictionary: gps(-33.856784, 151.215297)])
try writeJPEG("geo-newyork.jpg", tint: 0.8, properties: [kCGImagePropertyGPSDictionary: gps(40.689247, -74.044502)])
// A capture date, no place
try writeJPEG("nogeo.jpg", tint: 0.0, properties: [
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2023:01:02 03:04:05"],
])

/// One second of the picture as an H.264 QuickTime movie with the metadata
/// an iPhone writes: place (ISO 6709), creation date, make and model.
func writeMovie(_ name: String) throws {
    for folder in folders {
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        writer.metadata = [
            item(.quickTimeMetadataLocationISO6709, "+48.1372+011.5761+519.000/"),
            item(.quickTimeMetadataCreationDate, "2024-06-18T22:31:09+0200"),
            item(.quickTimeMetadataMake, "Example"),
            item(.quickTimeMetadataModel, "Example Camera One"),
        ]
        let width = 64, height = 48
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        let image = CIImage(cgImage: picture(width: width, height: height, tint: 0.5))
        for i in 0..<10 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            context.render(image, to: buffer!)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
try writeMovie("geo.mov")
print("Wrote the location fixtures to " + folders.map(\.path).joined(separator: ", "))
