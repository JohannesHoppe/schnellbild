// Reduces a photo to 2048 pixels on its long side and writes the place and
// time into its metadata (EXIF DateTimeOriginal, GPS), keeping the rest:
//   swift Scripts/tag_photo.swift <in.jpg> <out.jpg> <latitude> <longitude> <"YYYY:MM:DD hh:mm:ss">
// Used by Scripts/build_world_photos.py.
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 6, let lat = Double(args[3]), let lon = Double(args[4]) else {
    FileHandle.standardError.write(Data("usage: tag_photo.swift <in> <out> <lat> <lon> <date>\n".utf8))
    exit(1)
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 2048,
          kCGImageSourceCreateThumbnailWithTransform: true,
      ] as CFDictionary),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
else { FileHandle.standardError.write(Data("!! can't read or write\n".utf8)); exit(1) }
var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
var exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
exif[kCGImagePropertyExifDateTimeOriginal] = args[5]
properties[kCGImagePropertyExifDictionary] = exif
properties[kCGImagePropertyGPSDictionary] = [
    kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
    kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
] as [CFString: Any]
// The picture is drawn upright already
properties[kCGImagePropertyOrientation] = 1
properties.removeValue(forKey: kCGImagePropertyPixelWidth)
properties.removeValue(forKey: kCGImagePropertyPixelHeight)
properties[kCGImageDestinationLossyCompressionQuality] = 0.88
CGImageDestinationAddImage(destination, image, properties as CFDictionary)
guard CGImageDestinationFinalize(destination) else { FileHandle.standardError.write(Data("!! can't write\n".utf8)); exit(1) }
