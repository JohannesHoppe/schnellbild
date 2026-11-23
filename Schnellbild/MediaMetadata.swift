import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// One line of the Inspector: a label in the user's language and its value.
struct InfoRow: Equatable, Sendable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// A group of the Inspector's "All Metadata": every key a file's EXIF, GPS,
/// TIFF, IPTC, maker, XMP or QuickTime metadata holds, as written.
struct MetadataGroup: Equatable, Sendable, Identifiable {
    let name: String
    var entries: [Entry]
    var id: String { name }

    struct Entry: Equatable, Sendable, Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }
}

/// What a file's header says, for the Inspector's sections. Read once per
/// file, off the main thread, without decoding the picture.
struct MediaReport: Equatable, Sendable {
    var capture: [InfoRow] = []
    var location: MediaLocation?
    /// Where the place was read, how exact it is, and a video's route.
    var placeSource: MetadataSource?
    var placeAccuracy: PlaceAccuracy?
    var track: GeoTrack?
    /// The picture's or video's own facts (size, colours, codecs, tracks).
    var media: [InfoRow] = []
    var groups: [MetadataGroup] = []

    var isEmpty: Bool { capture.isEmpty && location == nil && media.isEmpty && groups.isEmpty }

    /// Takes the time and place from every source (`CaptureReader`): they
    /// stand in for, or come before, what the header alone said.
    mutating func adopt(_ facts: CaptureFacts) {
        let taken = String(localized: "Date Taken"), from = String(localized: "Date Source")
        capture.removeAll { $0.label == from }
        if let time = facts.time {
            let row = InfoRow(label: taken, value: time.text)
            if let index = capture.firstIndex(where: { $0.label == taken }) { capture[index] = row } else { capture.insert(row, at: 0) }
            if let note = time.source.timeText, let index = capture.firstIndex(where: { $0.label == taken }) {
                capture.insert(InfoRow(label: from, value: note), at: index + 1)
            }
        }
        if let place = facts.place {
            location = place.location
            placeSource = place.source
            placeAccuracy = place.accuracy
        }
        track = facts.track
    }
}

// MARK: - Values as text

enum MetadataText {
    /// Longer values are cut here (a maker note, an embedded thumbnail).
    static let longest = 300

    /// Any value ImageIO or AVFoundation hands over, as one line of text.
    static func describe(_ value: Any, depth: Int = 0) -> String {
        let text: String
        switch value {
        case let string as String:
            text = string
        case let number as NSNumber:
            text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        case let data as Data:
            text = describe(data)
        case let date as Date:
            text = date.formatted(.iso8601)
        case let array as [Any]:
            guard depth < 4 else { return "…" }
            let shown = array.prefix(64).map { describe($0, depth: depth + 1) }
            text = "(" + shown.joined(separator: ", ") + (array.count > 64 ? ", …" : "") + ")"
        case let dictionary as [AnyHashable: Any]:
            guard depth < 4 else { return "…" }
            let shown = dictionary.map { ("\($0.key)", describe($0.value, depth: depth + 1)) }.sorted { $0.0 < $1.0 }
            text = "{" + shown.prefix(64).map { "\($0.0) = \($0.1)" }.joined(separator: "; ") + (shown.count > 64 ? "; …" : "") + "}"
        default:
            text = String(describing: value)
        }
        return shortened(text)
    }

    /// "<1 234 bytes: ff d8 ff e1 …>" for binary values.
    static func describe(_ data: Data) -> String {
        let head = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        let count = data.count.formatted()
        return "<" + String(localized: "\(count) bytes") + (data.isEmpty ? "" : ": " + head + (data.count > 16 ? " …" : "")) + ">"
    }

    static func shortened(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\0", with: "")
        guard flat.count > longest else { return flat }
        let total = flat.count.formatted()
        return String(flat.prefix(longest)) + "… (" + String(localized: "\(total) characters") + ")"
    }
}

// MARK: - Pictures

enum PictureMetadata {
    /// The report of a picture, from its image source (header only; also a
    /// picture inside an archive).
    static func report(_ source: CGImageSource, named url: URL? = nil) -> MediaReport {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        var props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] ?? [:]
        // A picture the app decoded (QOI, PCX, LibRaw): the file's own
        // bits, not those of the picture handed to ImageIO
        if let url, PictureDecoders.decodes(url), let decoded = PictureDecoders.facts(of: url) {
            props[kCGImagePropertyDepth] = decoded.depth
        }
        var report = MediaReport()
        report.capture = capture(props)
        report.location = MediaLocation.picture(props)
        report.media = pictureRows(props, source: source)
        report.groups = groups(props, metadata: CGImageSourceCopyMetadataAtIndex(source, 0, options))
        return report
    }

    static func capture(_ props: [CFString: Any]) -> [InfoRow] {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func number(_ key: CFString) -> Double? {
            if let n = exif[key] as? NSNumber { return n.doubleValue }
            if let list = exif[key] as? [NSNumber] { return list.first?.doubleValue }
            return nil
        }
        var rows: [InfoRow] = []
        if let taken = takenText(exif: exif, tiff: tiff) { rows.append(InfoRow(label: String(localized: "Date Taken"), value: taken)) }
        if let camera = camera(tiff) { rows.append(InfoRow(label: String(localized: "Camera"), value: camera)) }
        let lensModel = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let lensMake = (exif[kCGImagePropertyExifLensMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let lens = lensModel.lowercased().hasPrefix(lensMake.lowercased()) ? lensModel : [lensMake, lensModel].filter { !$0.isEmpty }.joined(separator: " ")
        if !lens.isEmpty { rows.append(InfoRow(label: String(localized: "Lens"), value: lens)) }
        if let f = number(kCGImagePropertyExifFNumber), f > 0 {
            rows.append(InfoRow(label: String(localized: "Aperture"), value: "ƒ/" + f.formatted(.number.precision(.fractionLength(0...1)))))
        }
        if let t = number(kCGImagePropertyExifExposureTime), t > 0 {
            rows.append(InfoRow(label: String(localized: "Shutter Speed"), value: shutter(t)))
        }
        if let iso = number(kCGImagePropertyExifISOSpeedRatings) ?? number(kCGImagePropertyExifRecommendedExposureIndex),
           iso.isFinite, iso > 0, iso < 1e7 {
            rows.append(InfoRow(label: "ISO", value: Int(iso.rounded()).formatted()))
        }
        if let focal = number(kCGImagePropertyExifFocalLength), focal > 0 {
            let millimetres = describeMillimetres(focal)
            if let film = number(kCGImagePropertyExifFocalLenIn35mmFilm), film > 0, abs(film - focal) > 0.5 {
                let equivalent = describeMillimetres(film)
                rows.append(InfoRow(label: String(localized: "Focal Length"), value: String(localized: "\(millimetres) (\(equivalent) in 35 mm film)")))
            } else {
                rows.append(InfoRow(label: String(localized: "Focal Length"), value: millimetres))
            }
        }
        if let flash = (exif[kCGImagePropertyExifFlash] as? NSNumber)?.intValue {
            rows.append(InfoRow(label: String(localized: "Flash"), value: flashText(flash)))
        }
        if let program = (exif[kCGImagePropertyExifExposureProgram] as? NSNumber)?.intValue, let text = programText(program) {
            rows.append(InfoRow(label: String(localized: "Exposure Program"), value: text))
        }
        if let bias = number(kCGImagePropertyExifExposureBiasValue), bias.isFinite {
            rows.append(InfoRow(label: String(localized: "Exposure Bias"), value: biasText(bias)))
        }
        if let balance = (exif[kCGImagePropertyExifWhiteBalance] as? NSNumber)?.intValue, balance == 0 || balance == 1 {
            rows.append(InfoRow(label: String(localized: "White Balance"), value: balance == 0 ? String(localized: "Auto") : String(localized: "Manual")))
        }
        if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, let text = orientationText(orientation) {
            rows.append(InfoRow(label: String(localized: "Orientation"), value: text))
        }
        return rows
    }

    /// The camera's own name ("Canon EOS R6"): models often name the make already.
    static func camera(_ tiff: [CFString: Any]) -> String? {
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let camera = model.lowercased().hasPrefix(make.lowercased()) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        return camera.isEmpty ? nil : camera
    }

    /// The capture time as the camera's clock showed it, with its offset
    /// from UTC where the camera wrote one: "Jun 18, 2024, 10:31:09 PM (UTC+02:00)".
    static func takenText(exif: [CFString: Any], tiff: [CFString: Any]) -> String? {
        for case let (text?, offset) in CaptureReader.pictureClocks(exif: exif, tiff: tiff) {
            if let shown = wallClock(text, offset: offset) { return shown }
        }
        return nil
    }

    /// "2024:06:18 22:31:09" and "+02:00" as the user's locale writes a date.
    static func wallClock(_ text: String, offset: String?) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        parser.isLenient = true
        guard let date = parser.date(from: String(text.prefix(19))),
              Calendar(identifier: .gregorian).component(.year, from: date) >= 1900 else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: .standard)
        style.timeZone = TimeZone(identifier: "UTC")!
        let shown = date.formatted(style)
        guard let offset = offset?.trimmingCharacters(in: .whitespaces), offset.range(of: #"^[+-]\d\d:\d\d$"#, options: .regularExpression) != nil else { return shown }
        return "\(shown) (UTC\(offset))"
    }

    /// "1/250 s", "0.5 s", "30 s".
    static func shutter(_ seconds: Double) -> String {
        let text: String
        if seconds < 0.4, (1 / seconds) < 1e15 {
            text = "1/" + Int((1 / seconds).rounded()).formatted()
        } else {
            text = seconds.formatted(.number.precision(.fractionLength(0...1)))
        }
        return String(localized: "\(text) s")
    }

    static func describeMillimetres(_ value: Double) -> String {
        Measurement(value: value, unit: UnitLength.millimeters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// EXIF's Flash: bit 0 fired, bit 5 no flash in the camera.
    static func flashText(_ value: Int) -> String {
        if value & 0x20 != 0 { return String(localized: "No flash") }
        return value & 0x1 != 0 ? String(localized: "Fired") : String(localized: "Did not fire")
    }

    static func programText(_ value: Int) -> String? {
        switch value {
        case 1: return String(localized: "Manual")
        case 2: return String(localized: "Program")
        case 3: return String(localized: "Aperture priority")
        case 4: return String(localized: "Shutter priority")
        case 5: return String(localized: "Creative program")
        case 6: return String(localized: "Action program")
        case 7: return String(localized: "Portrait mode")
        case 8: return String(localized: "Landscape mode")
        default: return nil
        }
    }

    /// "+0.7 EV", "0 EV", "−1.3 EV".
    static func biasText(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let number = abs(rounded).formatted(.number.precision(.fractionLength(0...1)))
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "−" : "")
        return "\(sign)\(number) EV"
    }

    /// EXIF's orientations: how the stored picture is turned to be shown.
    static func orientationText(_ value: Int) -> String? {
        switch value {
        case 1: return String(localized: "Normal")
        case 2: return String(localized: "Mirrored horizontally")
        case 3: return String(localized: "Rotated 180°")
        case 4: return String(localized: "Mirrored vertically")
        case 5: return String(localized: "Mirrored, rotated 90° counterclockwise")
        case 6: return String(localized: "Rotated 90° clockwise")
        case 7: return String(localized: "Mirrored, rotated 90° clockwise")
        case 8: return String(localized: "Rotated 90° counterclockwise")
        default: return nil
        }
    }

    static func pictureRows(_ props: [CFString: Any], source: CGImageSource) -> [InfoRow] {
        var rows: [InfoRow] = []
        if let size = MediaInfo.pixelSize(from: source), size.width > 0, size.height > 0 {
            rows.append(InfoRow(label: String(localized: "Resolution"), value: "\(Int(size.width)) × \(Int(size.height)) px"))
        }
        if let model = props[kCGImagePropertyColorModel] as? String {
            rows.append(InfoRow(label: String(localized: "Colour Space"), value: model))
        }
        if let profile = props[kCGImagePropertyProfileName] as? String {
            rows.append(InfoRow(label: String(localized: "Profile"), value: profile))
        }
        if let depth = (props[kCGImagePropertyDepth] as? NSNumber)?.intValue, depth > 0 {
            rows.append(InfoRow(label: String(localized: "Bit Depth"), value: StreamFacts.describeDepth(depth)))
        }
        if let hdr = hdrText(props, source: source) {
            rows.append(InfoRow(label: "HDR", value: hdr))
        }
        let frames = CGImageSourceGetCount(source)
        if frames > 1 {
            rows.append(InfoRow(label: String(localized: "Frames"), value: frames.formatted()))
        }
        return rows
    }

    /// HDR: a colour profile with the PQ or HLG curve, or a gain map
    /// (Apple's or ISO 21496-1) beside the SDR picture. Only the auxiliary
    /// data's description is asked for, not the picture.
    static func hdrText(_ props: [CFString: Any], source: CGImageSource) -> String? {
        let profile = (props[kCGImagePropertyProfileName] as? String ?? "").uppercased()
        if profile.contains("PQ") || profile.contains("2084") { return "PQ (HDR10)" }
        if profile.contains("HLG") { return "HLG" }
        let gainMap = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap].contains {
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil
        }
        return gainMap ? String(localized: "Gain map") : nil
    }

    /// Every key of every dictionary ImageIO reads, and the XMP tags that
    /// aren't EXIF or TIFF again under another name.
    static func groups(_ props: [CFString: Any], metadata: CGImageMetadata?) -> [MetadataGroup] {
        var groups: [MetadataGroup] = []
        var image: [MetadataGroup.Entry] = []
        for (key, value) in props {
            let name = key as String
            if let dictionary = value as? [AnyHashable: Any] {
                let groupName = name.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                groups.append(MetadataGroup(name: groupName, entries: flatten(dictionary)))
            } else {
                image.append(MetadataGroup.Entry(key: name, value: MetadataText.describe(value)))
            }
        }
        if !image.isEmpty { groups.append(MetadataGroup(name: "Image", entries: image.sorted { $0.key < $1.key })) }
        groups.sort { order($0.name) < order($1.name) || (order($0.name) == order($1.name) && $0.name < $1.name) }
        if let metadata {
            let shown = Set(groups.map { $0.name.lowercased() })
            var xmp: [MetadataGroup.Entry] = []
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
                let key = path as String
                let prefix = key.split(separator: ":").first.map { $0.lowercased() } ?? ""
                // ImageIO also offers EXIF and TIFF as XMP: those are shown above already
                if (prefix == "exif" || prefix == "exifex") && shown.contains("exif") { return true }
                if prefix == "tiff" && shown.contains("tiff") { return true }
                xmp.append(MetadataGroup.Entry(key: key, value: tagText(tag)))
                return true
            }
            if !xmp.isEmpty { groups.append(MetadataGroup(name: "XMP", entries: xmp.sorted { $0.key < $1.key })) }
        }
        return groups.filter { !$0.entries.isEmpty }
    }

    private static func order(_ name: String) -> Int {
        ["Image", "Exif", "ExifAux", "TIFF", "GPS", "IPTC"].firstIndex(of: name) ?? 10
    }

    /// A dictionary's keys, nested ones as "Outer.Inner".
    static func flatten(_ dictionary: [AnyHashable: Any], prefix: String = "", depth: Int = 0) -> [MetadataGroup.Entry] {
        var entries: [MetadataGroup.Entry] = []
        for (key, value) in dictionary {
            let name = prefix + "\(key)"
            if let inner = value as? [AnyHashable: Any], depth < 3 {
                entries += flatten(inner, prefix: name + ".", depth: depth + 1)
            } else {
                entries.append(MetadataGroup.Entry(key: name, value: MetadataText.describe(value)))
            }
        }
        return entries.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    /// An XMP tag's value: text, or its elements (arrays, alternatives, structures).
    private static func tagText(_ tag: CGImageMetadataTag, depth: Int = 0) -> String {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return "" }
        if let text = value as? String { return MetadataText.shortened(text) }
        if depth < 3, let tags = value as? [CGImageMetadataTag] {
            return MetadataText.shortened(tags.map { tagText($0, depth: depth + 1) }.joined(separator: ", "))
        }
        if depth < 3, let fields = value as? [String: CGImageMetadataTag] {
            let parts = fields.sorted { $0.key < $1.key }.map { "\($0.key) = \(tagText($0.value, depth: depth + 1))" }
            return MetadataText.shortened(parts.joined(separator: "; "))
        }
        return MetadataText.describe(value)
    }
}

// MARK: - Videos

enum VideoMetadata {
    /// The report of a video AVFoundation opens (MP4, MOV, M4V, 3GP …),
    /// from its header; nil for a container it doesn't read (then the
    /// player's facts stand in).
    static func report(_ url: URL) async -> MediaReport? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        guard let (duration, tracks) = try? await asset.load(.duration, .tracks), !tracks.isEmpty else { return nil }
        let items = await allMetadata(asset)
        var report = MediaReport()
        report.capture = await capture(items)
        report.location = await MediaLocation.video(items)
        report.media = await videoRows(tracks, duration: duration)
        report.groups = await groups(items)
        return report
    }

    /// The metadata of every format the file holds (QuickTime, iTunes, ID3 …).
    static func allMetadata(_ asset: AVAsset) async -> [AVMetadataItem] {
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return [] }
        var items: [AVMetadataItem] = []
        for format in formats {
            if let found = try? await asset.loadMetadata(for: format) { items += found }
        }
        return items
    }

    static func capture(_ items: [AVMetadataItem]) async -> [InfoRow] {
        var rows: [InfoRow] = []
        let dates: [AVMetadataIdentifier] = [.quickTimeMetadataCreationDate, .commonIdentifierCreationDate, .quickTimeUserDataCreationDate]
        for identifier in dates {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else { continue }
            if let text = try? await item.load(.stringValue), let shown = takenText(text) {
                rows.append(InfoRow(label: String(localized: "Date Taken"), value: shown))
                break
            }
        }
        func text(_ identifiers: [AVMetadataIdentifier]) async -> String? {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                    if let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
                }
            }
            return nil
        }
        let make = await text([.quickTimeMetadataMake, .commonIdentifierMake]) ?? ""
        let model = await text([.quickTimeMetadataModel, .commonIdentifierModel]) ?? ""
        let camera = model.lowercased().hasPrefix(make.lowercased()) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        if !camera.isEmpty { rows.append(InfoRow(label: String(localized: "Camera"), value: camera)) }
        return rows
    }

    /// QuickTime's "2024-06-18T22:31:09+0200": the time as the camera's
    /// clock showed it, with its offset.
    static func takenText(_ text: String) -> String? {
        let pattern = #"^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d))?(?:\.\d+)?(Z|[+-]\d\d:?\d\d)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
        guard let y = group(1), let mo = group(2), let d = group(3), let h = group(4), let mi = group(5) else { return nil }
        let wall = "\(y):\(mo):\(d) \(h):\(mi):\(group(6) ?? "00")"
        var offset = group(7)
        if offset == "Z" { offset = "+00:00" }
        if let o = offset, o.count == 5 { offset = String(o.prefix(3)) + ":" + String(o.suffix(2)) }
        return PictureMetadata.wallClock(wall, offset: offset)
    }

    static func videoRows(_ tracks: [AVAssetTrack], duration: CMTime) async -> [InfoRow] {
        var rows: [InfoRow] = []
        let seconds = duration.isNumeric ? CMTimeGetSeconds(duration) : 0
        if seconds.isFinite, seconds > 0 { rows.append(InfoRow(label: String(localized: "Duration"), value: InspectorView.duration(seconds))) }
        var counts: [AVMediaType: Int] = [:]
        var rate: Float = 0
        var videoDone = false, audioDone = false
        for track in tracks {
            let type = track.mediaType
            guard let (descriptions, size, frameRate, dataRate, transform) = try? await track.load(
                .formatDescriptions, .naturalSize, .nominalFrameRate, .estimatedDataRate, .preferredTransform) else { continue }
            counts[type, default: 0] += 1
            rate += max(dataRate, 0)
            guard let description = descriptions.first else { continue }
            if type == .video, !videoDone {
                videoDone = true
                let shown = size.applying(transform)
                if shown.width != 0, shown.height != 0 {
                    rows.append(InfoRow(label: String(localized: "Resolution"), value: "\(Int(abs(shown.width))) × \(Int(abs(shown.height))) px"))
                }
                let codec = CMFormatDescriptionGetMediaSubType(description)
                rows.append(InfoRow(label: String(localized: "Video"),
                                    value: StreamFacts.describeVideo(codec: StreamFacts.codecName(codec), frameRate: Double(frameRate))))
                let colour = colourRows(description, codec: codec)
                rows += colour
            } else if type == .audio, !audioDone {
                audioDone = true
                let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
                rows.append(InfoRow(label: String(localized: "Audio"),
                                    value: StreamFacts.describeAudio(codec: StreamFacts.codecName(CMFormatDescriptionGetMediaSubType(description)),
                                                                     channels: basic.map { Int($0.mChannelsPerFrame) },
                                                                     sampleRate: basic?.mSampleRate)))
            }
        }
        let subtitles = (counts[.subtitle] ?? 0) + (counts[.text] ?? 0) + (counts[.closedCaption] ?? 0)
        let parts = [(String(localized: "Video"), counts[.video] ?? 0), (String(localized: "Audio"), counts[.audio] ?? 0),
                     (String(localized: "Subtitles"), subtitles)].filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        if !parts.isEmpty { rows.append(InfoRow(label: String(localized: "Tracks"), value: parts.joined(separator: " · "))) }
        if rate > 0 { rows.append(InfoRow(label: String(localized: "Bitrate"), value: StreamFacts.describeBitrate(Double(rate)))) }
        return rows
    }

    /// Colour space, bit depth and HDR from a video track's format description.
    static func colourRows(_ description: CMFormatDescription, codec: FourCharCode) -> [InfoRow] {
        var rows: [InfoRow] = []
        func value(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(description, extensionKey: key) as? String }
        if let primaries = value(kCMFormatDescriptionExtension_ColorPrimaries) {
            let names: [String: String] = [
                kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String: "BT.709",
                kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String: "BT.2020",
                kCMFormatDescriptionColorPrimaries_P3_D65 as String: "Display P3",
                kCMFormatDescriptionColorPrimaries_DCI_P3 as String: "DCI-P3",
                kCMFormatDescriptionColorPrimaries_EBU_3213 as String: "BT.601 (PAL)",
                kCMFormatDescriptionColorPrimaries_SMPTE_C as String: "BT.601 (NTSC)",
            ]
            rows.append(InfoRow(label: String(localized: "Colour Space"), value: names[primaries] ?? primaries))
        }
        if let bits = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber,
           bits.intValue > 0 {
            rows.append(InfoRow(label: String(localized: "Bit Depth"), value: StreamFacts.describeDepth(bits.intValue)))
        }
        let text = String(decoding: [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xFF) }, as: UTF8.self)
        let transfer = value(kCMFormatDescriptionExtension_TransferFunction)
        if text == "dvh1" || text == "dvhe" || text == "dva1" || text == "dvav" {
            rows.append(InfoRow(label: "HDR", value: "Dolby Vision"))
        } else if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String {
            rows.append(InfoRow(label: "HDR", value: "PQ (HDR10)"))
        } else if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String {
            rows.append(InfoRow(label: "HDR", value: "HLG"))
        }
        return rows
    }

    /// Every metadata item, grouped by its key space (QuickTime metadata,
    /// user data, iTunes, ID3 …).
    static func groups(_ items: [AVMetadataItem]) async -> [MetadataGroup] {
        var byGroup: [String: [MetadataGroup.Entry]] = [:]
        for item in items {
            let space = item.keySpace?.rawValue ?? "other"
            let name: String
            switch space {
            case AVMetadataKeySpace.quickTimeMetadata.rawValue: name = "QuickTime"
            case AVMetadataKeySpace.quickTimeUserData.rawValue: name = "QuickTime User Data"
            case AVMetadataKeySpace.iTunes.rawValue: name = "iTunes"
            case AVMetadataKeySpace.id3.rawValue: name = "ID3"
            case AVMetadataKeySpace.common.rawValue: name = "Common"
            default: name = space
            }
            var key = item.identifier?.rawValue ?? "\(item.key ?? "" as NSString)"
            if let slash = key.firstIndex(of: "/") { key = String(key[key.index(after: slash)...]) }
            let value: String
            if let text = try? await item.load(.stringValue) {
                value = MetadataText.shortened(text)
            } else if let data = try? await item.load(.dataValue) {
                value = MetadataText.describe(data)
            } else if let any = try? await item.load(.value) {
                value = MetadataText.describe(any)
            } else {
                continue
            }
            byGroup[name, default: []].append(MetadataGroup.Entry(key: key, value: value))
        }
        return byGroup.map { MetadataGroup(name: $0.key, entries: $0.value) }.sorted { $0.name < $1.name }
    }
}

// MARK: - Files

enum FileReport {
    /// The file's own facts: where it lies, its size, dates and kind.
    static func rows(for entry: GridEntry, format: String?) -> [InfoRow] {
        var rows: [InfoRow] = [InfoRow(label: String(localized: "Kind"), value: kindText(entry))]
        if let format { rows.append(InfoRow(label: String(localized: "Format"), value: format)) }
        if let bytes = entry.byteSize, entry.kind != .folder || entry.isArchive {
            rows.append(InfoRow(label: String(localized: "Size"), value: sizeText(bytes)))
        }
        return rows
    }

    static func kindText(_ entry: GridEntry) -> String {
        switch entry.kind {
        case .video: return String(localized: "Video")
        case .image: return String(localized: "Picture")
        case .folder, .parent: return entry.isArchive ? String(localized: "Archive") : String(localized: "Folder")
        }
    }

    /// "2.4 MB (2,412,345 bytes)".
    static func sizeText(_ bytes: Int) -> String {
        let short = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let count = bytes.formatted()
        return short + " (" + String(localized: "\(count) bytes") + ")"
    }

    /// When the file was made on this disk; nil inside an archive.
    static func created(_ url: URL) -> Date? {
        guard !ArchivePath.isInside(url) else { return nil }
        return try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}
