import XCTest
@testable import Schnellbild

/// Archives made to break a reader: headers that make UnRAR call itself,
/// damaged headers, references to other entries, names in legacy code
/// pages, entries far larger than a picture, sizes near Int64.max, and
/// entries shorter than they say. Built here byte by byte.
final class CraftedArchiveTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        ArchiveStore.shared.passwords = .memory()
    }

    // MARK: RAR5, stored

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    private static func vint(_ value: Int) -> Data {
        var n = UInt64(value), out = Data()
        repeat {
            var byte = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 { byte |= 0x80 }
            out.append(byte)
        } while n != 0
        return out
    }

    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// One RAR5 block: CRC32, size, type, flags, sizes, fields, extra, data.
    private static func block(_ type: Int, flags: Int = 0, fields: Data = Data(), extra: Data = Data(),
                              data: Data = Data(), hasData: Bool = false, breakCRC: Bool = false) -> Data {
        var flags = flags
        if !extra.isEmpty { flags |= 0x0001 }
        if hasData || !data.isEmpty { flags |= 0x0002 }
        var body = vint(type) + vint(flags)
        if !extra.isEmpty { body += vint(extra.count) }
        if flags & 0x0002 != 0 { body += vint(data.count) }
        body += fields + extra
        let size = vint(body.count)
        var crc = crc32(size + body)
        if breakCRC { crc ^= 0x5A5A_5A5A }
        return le32(crc) + size + body + data
    }

    private static func file(_ name: String, _ data: Data = Data(), splitBefore: Bool = false, extra: Data = Data(),
                             size: Int? = nil, breakCRC: Bool = false) -> Data {
        let withCRC = !splitBefore && extra.isEmpty
        var fields = vint(withCRC ? 0x0004 : 0) + vint(size ?? data.count) + vint(0x20)
        if withCRC { fields += le32(crc32(data)) }
        let nameBytes = Data(name.utf8)
        fields += vint(0) + vint(1) + vint(nameBytes.count) + nameBytes   // stored; Unix
        return block(2, flags: splitBefore ? 0x0008 : 0, fields: fields, extra: extra, data: data, hasData: true, breakCRC: breakCRC)
    }

    /// A hard link (4) or file copy (5) of `target`.
    private static func redirect(_ type: Int, to target: String) -> Data {
        let t = Data(target.utf8)
        let record = vint(0x05) + vint(type) + vint(0) + vint(t.count) + t
        return vint(record.count) + record
    }

    private static func rar(_ files: [Data]) -> Data {
        Data("Rar!\u{1A}\u{07}\u{01}\u{00}".utf8) + block(1, fields: vint(0)) + files.reduce(Data(), +) + block(5, fields: vint(0))
    }

    private func write(_ data: Data, _ name: String, in tree: TempTree) throws -> URL {
        let url = tree.root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// UnRAR's list mode skips headers of files continued from an earlier
    /// volume by calling itself once per header: tens of thousands of them
    /// would overflow the archive queue's stack.
    func testManySplitHeadersDontCrash() async throws {
        let tree = try TempTree(self)
        let headers = (0..<50_000).map { Self.file(String(format: "s%05d.jpg", $0), splitBefore: true) }
        let url = try write(Self.rar(headers + [Self.file("last.jpg", Data("LAST".utf8))]), "split.rar", in: tree)
        let index = try await ArchiveStore.shared.index(of: url)
        XCTAssertEqual(index.byPath.keys.sorted(), ["last.jpg"])
        let last = try await ArchiveStore.shared.data(of: url.appendingPathComponent("last.jpg"))
        XCTAssertEqual(last, Data("LAST".utf8))
    }

    /// A flood of entries stops at the index's limit: the archive counts as
    /// read in part, its memory stays bounded (the limit lowered here).
    func testAnIndexStopsAtItsLimit() async throws {
        let tree = try TempTree(self)
        let url = try write(Self.rar((0..<10).map { Self.file("f\($0).jpg", Data("X".utf8)) }), "many.rar", in: tree)
        let limit = ArchiveStore.indexLimit
        ArchiveStore.indexLimit = 4
        defer { ArchiveStore.indexLimit = limit }
        let index = try await ArchiveStore.shared.index(of: url)
        XCTAssertEqual(index.byPath.count, 4)
        XCTAssertFalse(index.complete)
    }

    /// A header that fails its checksum ends the listing there.
    func testADamagedHeaderEndsTheListing() async throws {
        let tree = try TempTree(self)
        let url = try write(Self.rar([Self.file("a.jpg", Data("AAAA".utf8)), Self.file("b.jpg", Data("BBBB".utf8), breakCRC: true),
                                      Self.file("c.jpg", Data("CCCC".utf8))]), "bad.rar", in: tree)
        let index = try await ArchiveStore.shared.index(of: url)
        XCTAssertEqual(index.byPath.keys.sorted(), ["a.jpg"])
        XCTAssertFalse(index.complete)
    }

    /// Identical files stored as references (`rar -oi`) and hard links are
    /// files: listed, and read through the entry they refer to.
    func testFileCopiesAndHardLinksReadTheirSource() async throws {
        let tree = try TempTree(self)
        let page = Data("PAGE-THREE".utf8)
        for (type, name) in [(5, "copies.rar"), (4, "links.rar")] {
            let url = try write(Self.rar([Self.file("p03.jpg", page),
                                          Self.file("p12.jpg", extra: Self.redirect(type, to: "p03.jpg"), size: page.count),
                                          Self.file("p13.jpg", Data("PAGE-13".utf8))]), name, in: tree)
            let index = try await ArchiveStore.shared.index(of: url)
            XCTAssertEqual(index.byPath.keys.sorted(), ["p03.jpg", "p12.jpg", "p13.jpg"], name)
            let copy = try await ArchiveStore.shared.data(of: url.appendingPathComponent("p12.jpg"))
            XCTAssertEqual(copy, page, name)
        }
    }

    // MARK: ZIP

    /// A stored ZIP with names given as raw bytes, without the UTF-8 flag.
    private static func zip(_ entries: [(name: Data, data: Data)]) -> Data {
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var out = Data(), central = Data()
        for (name, data) in entries {
            let offset = out.count
            // version, flags (no UTF-8), method stored, time, date, CRC, sizes
            var common = le16(0) + le16(0) + le16(0)
            common += le16(0x21) + le32(crc32(data))
            common += le32(UInt32(data.count)) + le32(UInt32(data.count))
            common += le16(name.count) + le16(0)
            out += le32(0x0403_4B50) + le16(10) + common
            out += name + data
            central += le32(0x0201_4B50) + le16(20) + le16(10) + common
            central += le16(0) + le16(0) + le16(0) + le32(0)   // comment, disk, attributes
            central += le32(UInt32(offset)) + name
        }
        var end = le32(0x0605_4B50) + le16(0) + le16(0)
        end += le16(entries.count) + le16(entries.count)
        end += le32(UInt32(central.count)) + le32(UInt32(out.count)) + le16(0)
        return out + central + end
    }

    /// Names in a DOS code page (Windows' Explorer writes them so) stay
    /// distinct: "Müller" (0x81) and "Möller" (0x94) are two files.
    func testLegacyZipNamesStayDistinct() async throws {
        let tree = try TempTree(self)
        let url = try write(Self.zip([(Data([0x4D, 0x81, 0x6C, 0x6C, 0x65, 0x72, 0x2E, 0x6A, 0x70, 0x67]), Data("first".utf8)),
                                      (Data([0x4D, 0x94, 0x6C, 0x6C, 0x65, 0x72, 0x2E, 0x6A, 0x70, 0x67]), Data("second".utf8))]),
                            "legacy.zip", in: tree)
        let index = try await ArchiveStore.shared.index(of: url)
        XCTAssertEqual(index.byPath.count, 2, "\(index.byPath.keys.sorted())")
        for (path, item) in index.byPath {
            let data = try await ArchiveStore.shared.data(of: url.appendingPathComponent(path))
            XCTAssertEqual(data.count, item.knownSize, path)
        }
        XCTAssertEqual(LibArchiveReader.legacyName(Data("Übersicht".utf8)), "Übersicht", "valid UTF-8 stays as it is")
    }

    /// A decompression bomb isn't unpacked into memory: refused by its
    /// stated size, and, where the size isn't stated, stopped at the limit.
    func testAnEntryLargerThanAnyPictureIsRefused() async throws {
        let tree = try TempTree(self)
        let src = try tree.folder("src")
        let big = src.appendingPathComponent("cover.jpg")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ArchiveStore.largestRead) + 1_000_000)
        try handle.close()
        let zipping = Process()
        zipping.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipping.arguments = ["-q", "-1", "../bomb.zip", "cover.jpg"]
        zipping.currentDirectoryURL = src
        try zipping.run(); zipping.waitUntilExit()
        let bomb = tree.root.appendingPathComponent("bomb.zip")
        do {
            _ = try await ArchiveStore.shared.data(of: bomb.appendingPathComponent("cover.jpg"))
            XCTFail("unpacked")
        } catch ArchiveError.tooLarge {}

        // Without its central directory (still downloading) the ZIP is read
        // front to back, and an entry written with a data descriptor has
        // no size before its data (zip names an entry packed from its
        // input "-")
        let streamed = tree.root.appendingPathComponent("streamed.zip.part")
        let piping = Process()
        piping.executableURL = URL(fileURLWithPath: "/bin/sh")
        piping.arguments = ["-c", "/bin/cat cover.jpg | /usr/bin/zip -q -1 - - | /bin/cat > \"$1\"", "sh", streamed.path]
        piping.currentDirectoryURL = src
        try piping.run(); piping.waitUntilExit()
        let whole = try Data(contentsOf: streamed)
        try whole.prefix(whole.count - 120).write(to: streamed)
        let index = try await ArchiveStore.shared.index(of: streamed)
        let item = try XCTUnwrap(index.byPath["-"])
        XCTAssertEqual(item.size, -1, "no size stated")
        do {
            _ = try await ArchiveStore.shared.data(of: streamed.appendingPathComponent("-"))
            XCTFail("unpacked")
        } catch ArchiveError.tooLarge {}
    }

    /// Requests for entries a pass has already gone by (asked again after
    /// a cancelled request) are served by the next pass.
    func testRequestsAfterCancelledOnesAreServed() async throws {
        let tree = try TempTree(self)
        let src = try tree.folder("src")
        for i in 0..<30 { try Data(repeating: UInt8(i), count: 200_000).write(to: src.appendingPathComponent(String(format: "p%02d.jpg", i))) }
        let zipping = Process()
        zipping.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipping.arguments = ["-q", "-9", "-r", "../pages.zip", "."]
        zipping.currentDirectoryURL = src
        try zipping.run(); zipping.waitUntilExit()
        let zip = tree.root.appendingPathComponent("pages.zip")
        _ = try await ArchiveStore.shared.index(of: zip)
        let tasks = (0..<30).map { i in Task { try await ArchiveStore.shared.data(of: zip.appendingPathComponent(String(format: "p%02d.jpg", i))) } }
        for (i, task) in tasks.enumerated() where i % 3 != 0 { task.cancel() }
        for i in 0..<30 {
            let data = try await ArchiveStore.shared.data(of: zip.appendingPathComponent(String(format: "p%02d.jpg", i)))
            XCTAssertEqual(data.first, UInt8(i), "p\(i)")
        }
    }

    // MARK: Streams

    /// An entry that unpacks to `actual` bytes whatever it states.
    private struct Short: ArchiveReader {
        let stated: Int64
        let actual: Int
        func walk(password: String?, listOnly: Bool, _ visit: (ArchiveItem) -> ArchiveVisit) throws -> Bool {
            let item = ArchiveItem(path: "movie.mkv", isDirectory: false, size: stated, modified: nil, encrypted: false)
            if case .read(let sink, let done) = visit(item) {
                let bytes = [UInt8](repeating: 7, count: actual)
                _ = bytes.withUnsafeBytes { sink($0) }
                done(nil)
            }
            return true
        }
    }

    /// Past where an entry really ends a read fails (an empty answer would
    /// read as the end, and AVFoundation asks again forever); a size near
    /// Int64.max is no overflow.
    func testReadsPastAShortEntryFail() throws {
        let short = ArchiveEntryStream(size: 10_000, reader: Short(stated: 10_000, actual: 5_000), path: "movie.mkv", password: nil, chunkSize: 4096)
        XCTAssertEqual(try short.read(at: 0, count: 4096).count, 4096)
        XCTAssertEqual(try short.read(at: 4096, count: 4096).count, 5_000 - 4096, "what there is")
        XCTAssertThrowsError(try short.read(at: 6_000, count: 100), "past the end of what there is")
        short.close()

        let huge = ArchiveEntryStream(size: .max, reader: Short(stated: .max, actual: 1_000), path: "movie.mkv", password: nil, chunkSize: 4096)
        XCTAssertThrowsError(try huge.read(at: .max - 2, count: 1 << 20))
        XCTAssertEqual(try huge.read(at: 0, count: 1 << 20).count, 1_000)
        huge.close()
    }

    /// A sink that ends the walk ends it there: the reader doesn't go on to
    /// the next entry (which for 7z means unpacking the rest of this one).
    func testASinkEndsTheWalk() async throws {
        let tree = try TempTree(self)
        let src = try tree.folder("src")
        try Data(repeating: 1, count: 3_000_000).write(to: src.appendingPathComponent("a.mp4"))
        try Data(repeating: 2, count: 10).write(to: src.appendingPathComponent("b.jpg"))
        let zipping = Process()
        zipping.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipping.arguments = ["-q", "-9", "../two.zip", "a.mp4", "b.jpg"]
        zipping.currentDirectoryURL = src
        try zipping.run(); zipping.waitUntilExit()
        let reader = try XCTUnwrap(ArchiveStore.reader(for: tree.root.appendingPathComponent("two.zip")))
        var visited: [String] = []
        _ = try reader.walk(password: nil, listOnly: false) { item in
            visited.append(item.path)
            return .read(sink: { _ in false }, done: { _ in })
        }
        XCTAssertEqual(visited, ["a.mp4"])
    }
}
