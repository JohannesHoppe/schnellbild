import XCTest
@testable import Schnellbild

/// Archives as folders: names, reading RAR (UnRAR) and ZIP / 7z
/// (libarchive), passwords, split and unfinished archives, and the model
/// browsing them. RAR and 7z fixtures: Tests/SchnellbildTests/Archives
/// (see its README); ZIPs are made here with /usr/bin/zip.
@MainActor
final class ArchiveTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        try super.setUpWithError()
        ArchiveStore.shared.passwords = .memory()
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Archives"), "missing fixture \(name)")
    }

    /// Copies fixtures into a fresh folder (the store knows each path once).
    private func copy(_ names: [String], into tree: TempTree, renaming: [String: String] = [:]) throws -> URL {
        for name in names {
            try FileManager.default.copyItem(at: fixture(name), to: tree.root.appendingPathComponent(renaming[name] ?? name))
        }
        return tree.root.appendingPathComponent(renaming[names[0]] ?? names[0])
    }

    /// Runs /usr/bin/zip in `folder` (store only, so sizes stay as written).
    private func zip(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-0"] + arguments
        process.currentDirectoryURL = folder
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip \(arguments)")
    }

    private func paths(_ index: ArchiveStore.Index) -> [String] {
        index.byPath.values.filter { !$0.isDirectory }.map(\.path).sorted()
    }

    // MARK: Names and paths

    func testWhichNamesAreArchives() {
        XCTAssertEqual(ArchiveName.format(of: "Holiday.zip"), .zip)
        XCTAssertEqual(ArchiveName.format(of: "comic.CBR"), .rar)
        XCTAssertEqual(ArchiveName.format(of: "x.7z"), .sevenZip)
        XCTAssertEqual(ArchiveName.format(of: "x.part1.rar"), .rar, "the first volume stands for the set")
        XCTAssertEqual(ArchiveName.format(of: "x.part01.rar"), .rar)
        XCTAssertNil(ArchiveName.format(of: "x.part2.rar"), "later volumes aren't shown")
        XCTAssertEqual(ArchiveName.format(of: "x.7z.001"), .sevenZip)
        XCTAssertNil(ArchiveName.format(of: "x.7z.002"))
        XCTAssertNil(ArchiveName.format(of: "x.z01"))
        XCTAssertNil(ArchiveName.format(of: "x.r00"))
        XCTAssertEqual(ArchiveName.format(of: "x.rar.part"), .rar, "a download in progress")
        XCTAssertEqual(ArchiveName.format(of: "x.zip.crdownload"), .zip)
        XCTAssertNil(ArchiveName.format(of: "notes.part"))
        XCTAssertNil(ArchiveName.format(of: "._x.zip"))
        XCTAssertTrue(ArchiveName.isPartial("x.rar.part"))
    }

    func testPathsRunThroughTheArchive() {
        let url = URL(fileURLWithPath: "/Volumes/NAS/Holiday.zip/Day 1/a.jpg")
        let split = ArchivePath.split(url)
        XCTAssertEqual(split?.archive.path, "/Volumes/NAS/Holiday.zip")
        XCTAssertEqual(split?.inner, "Day 1/a.jpg")
        XCTAssertTrue(ArchivePath.isInside(url))
        XCTAssertFalse(ArchivePath.isInside(URL(fileURLWithPath: "/Volumes/NAS/Holiday.zip")))
        XCTAssertNil(ArchivePath.split(URL(fileURLWithPath: "/Volumes/NAS/a.jpg")))
    }

    // MARK: RAR

    func testRarFoldersAndUnicodeNames() async throws {
        let tree = try TempTree(self)
        let rar = try copy(["rar5-subdirs.rar"], into: tree)
        let index = try await ArchiveStore.shared.index(of: rar)
        XCTAssertEqual(paths(index), ["sub/dir1/file1.txt", "sub/dir2/file2.txt", "sub/with space/long fn.txt", "sub/üȵĩöḋè/file.txt"])
        XCTAssertTrue(index.complete)
        let entries = try await ArchiveStore.shared.listing(in: rar).entries
        XCTAssertEqual(entries.map(\.name), ["sub"])
        let data = try await ArchiveStore.shared.data(of: rar.appendingPathComponent("sub/with space/long fn.txt"))
        XCTAssertEqual(data.count, 8)

        let unicode = try copy(["unicode.rar"], into: tree)
        let names = try await paths(ArchiveStore.shared.index(of: unicode))
        XCTAssertEqual(Set(names), ["уииоотивл.txt", "𝐀𝐁𝐁𝐂.txt"])
    }

    func testSolidRarReadsEveryFile() async throws {
        let tree = try TempTree(self)
        for name in ["rar5-solid.rar", "rar3-solid.rar"] {
            let rar = try copy([name], into: tree)
            async let first = ArchiveStore.shared.data(of: rar.appendingPathComponent("stest1.txt"))
            async let second = ArchiveStore.shared.data(of: rar.appendingPathComponent("stest2.txt"))
            let sizes = try await [first.count, second.count]
            XCTAssertEqual(sizes, [2048, 2048], name)
        }
    }

    /// A password typed once opens the archive and is remembered; the next
    /// protected archive opens with it, no question asked.
    func testRarPasswordIsAskedOnceAndRemembered() async throws {
        let tree = try TempTree(self)
        let rar = try copy(["rar5-psw.rar"], into: tree)
        do {
            _ = try await ArchiveStore.shared.index(of: rar)
            XCTFail("protected, no password known")
        } catch ArchiveError.needsPassword {}
        do {
            _ = try await ArchiveStore.shared.index(of: rar, trying: "wrong")
            XCTFail("a wrong password")
        } catch ArchiveError.needsPassword {}
        XCTAssertEqual(ArchiveStore.shared.passwords.all, [], "a wrong one isn't remembered")
        _ = try await ArchiveStore.shared.index(of: rar, trying: "password")
        XCTAssertEqual(ArchiveStore.shared.passwords.all, ["password"])
        let data = try await ArchiveStore.shared.data(of: rar.appendingPathComponent("stest1.txt"))
        XCTAssertEqual(data.count, 2048)

        // Encrypted names too, in RAR5 and RAR3: opened with the remembered one
        for name in ["rar5-hpsw.rar", "rar3-comment-hpsw.rar"] {
            let other = try copy([name], into: tree)
            let index = try await ArchiveStore.shared.index(of: other)
            XCTAssertFalse(paths(index).isEmpty, name)
        }
    }

    /// Several remembered passwords: each is tried until one opens it.
    func testRememberedPasswordsAreTriedInTurn() async throws {
        let tree = try TempTree(self)
        let store = PasswordStore.memory()
        store.remember("password")
        store.remember("other")
        store.remember("third")
        ArchiveStore.shared.passwords = store
        let rar = try copy(["rar5-hpsw.rar"], into: tree)
        let index = try await ArchiveStore.shared.index(of: rar)
        XCTAssertEqual(index.password, "password")
        XCTAssertEqual(store.all.first, "password", "the one that worked comes first now")
    }

    func testRarVolumesReadAsOne() async throws {
        let tree = try TempTree(self)
        for set in [["rar5-vols.part1.rar", "rar5-vols.part2.rar", "rar5-vols.part3.rar"], ["rar3-old.rar", "rar3-old.r00", "rar3-old.r01"]] {
            let rar = try copy(set, into: tree)
            let index = try await ArchiveStore.shared.index(of: rar)
            XCTAssertEqual(paths(index), ["vols/bigfile.txt", "vols/smallfile.txt"], set[0])
            XCTAssertTrue(index.complete)
            let big = try await ArchiveStore.shared.data(of: rar.appendingPathComponent("vols/bigfile.txt"))
            XCTAssertEqual(big.count, 205000)
        }
    }

    /// Later volumes still downloading: what the first holds is listed, a
    /// file reaching into the missing volume says so.
    func testRarWithAMissingVolume() async throws {
        let tree = try TempTree(self)
        let rar = try copy(["rar5-vols.part1.rar"], into: tree)
        let index = try await ArchiveStore.shared.index(of: rar)
        XCTAssertFalse(index.complete)
        XCTAssertEqual(paths(index), ["vols/bigfile.txt"])
        do {
            _ = try await ArchiveStore.shared.data(of: rar.appendingPathComponent("vols/bigfile.txt"))
            XCTFail("half of it is missing")
        } catch ArchiveError.incomplete {}
    }

    /// A download in progress ("x.rar.part"): the files before the cut.
    func testUnfinishedRarDownload() async throws {
        let tree = try TempTree(self)
        let cut = tree.root.appendingPathComponent("photos.rar.part")
        try Data(try Data(contentsOf: fixture("rar5-subdirs.rar")).prefix(300)).write(to: cut)
        let index = try await ArchiveStore.shared.index(of: cut)
        XCTAssertGreaterThanOrEqual(paths(index).count, 3)
        let data = try await ArchiveStore.shared.data(of: cut.appendingPathComponent("sub/dir2/file2.txt"))
        XCTAssertEqual(data.count, 6)
    }

    // MARK: RAR made with RAR 7 (UITests/Fixtures/rar)

    /// The RAR archives the UI tests use: three photos and a video, made
    /// with the official RAR 7.23 (packed, stored, solid, in volumes, with a
    /// password, with encrypted names, a download cut off).
    private func realRar(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UITests/Fixtures/rar/\(name)")
    }

    private func uiFixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("UITests/Fixtures/\(name)"))
    }

    func testRealRarArchivesReadByteForByte() async throws {
        ArchiveStore.shared.passwords.remember("secret")
        let big = try uiFixture("huge.jpg"), clip = try uiFixture("clip.mp4")
        for name in ["photos-rar5.rar", "photos-stored.rar", "photos-solid.rar", "photos-vols.part1.rar",
                     "photos-psw.rar", "photos-hpsw.rar"] {
            let tree = try TempTree(self)
            for file in try FileManager.default.contentsOfDirectory(atPath: realRar("").path)
            where file == name || (name.hasPrefix("photos-vols") && file.hasPrefix("photos-vols")) {
                try FileManager.default.copyItem(at: realRar(file), to: tree.root.appendingPathComponent(file))
            }
            let rar = tree.root.appendingPathComponent(name)
            let index = try await ArchiveStore.shared.index(of: rar)
            XCTAssertEqual(paths(index), ["Day 1/big.jpg", "Day 1/sun.jpg", "beach.jpg", "clip.mp4"], name)
            XCTAssertTrue(index.complete, name)
            let picture = try await ArchiveStore.shared.data(of: rar.appendingPathComponent("Day 1/big.jpg"))
            XCTAssertEqual(picture, big, "\(name): the picture byte for byte")
            let stream = try await ArchiveStore.shared.stream(of: rar.appendingPathComponent("clip.mp4"),
                                                              chunkSize: 8 << 10, unreadLimit: 2, readLimit: 2)
            for offset in [40_000, 0, 20_000, 46_000] {
                XCTAssertEqual(try stream.read(at: Int64(offset), count: 4000), clip[offset..<min(offset + 4000, clip.count)],
                               "\(name): the video at \(offset)")
            }
            stream.close()
        }
    }

    /// A download cut off: the files before the cut are there, whole; the
    /// one it cuts says so. And it doesn't spoil reading other archives
    /// (UnRAR keeps its error state for the whole process).
    func testACutRarDownloadAndTheNextArchive() async throws {
        let tree = try TempTree(self)
        let cut = tree.root.appendingPathComponent("photos-cut.rar.part")
        try FileManager.default.copyItem(at: realRar("photos-cut.rar.part"), to: cut)
        let index = try await ArchiveStore.shared.index(of: cut)
        XCTAssertFalse(index.complete)
        XCTAssertEqual(paths(index), ["Day 1/big.jpg", "beach.jpg", "clip.mp4"])
        let beach = try await ArchiveStore.shared.data(of: cut.appendingPathComponent("beach.jpg"))
        XCTAssertEqual(beach, try uiFixture("dark.jpg"))
        do {
            _ = try await ArchiveStore.shared.data(of: cut.appendingPathComponent("Day 1/big.jpg"))
            XCTFail("cut off in the middle")
        } catch {}

        let good = try copy(["rar5-subdirs.rar"], into: tree)
        let data = try await ArchiveStore.shared.data(of: good.appendingPathComponent("sub/dir1/file1.txt"))
        XCTAssertEqual(data.count, 6, "the next archive reads as usual")
    }

    // MARK: ZIP and 7z

    func testZipWithPassword() async throws {
        let tree = try TempTree(self)
        try tree.file("src/a.jpg", bytes: 5000)
        try zip(["-P", "secret", "-r", "../locked.zip", "."], in: tree.root.appendingPathComponent("src"))
        let locked = tree.root.appendingPathComponent("locked.zip")
        do {
            _ = try await ArchiveStore.shared.index(of: locked)
            XCTFail("protected")
        } catch ArchiveError.needsPassword {}
        _ = try await ArchiveStore.shared.index(of: locked, trying: "secret")
        let data = try await ArchiveStore.shared.data(of: locked.appendingPathComponent("a.jpg"))
        XCTAssertEqual(data.count, 5000)
    }

    /// Split ("x.z01", "x.z02" … "x.zip") and unfinished ("x.zip.crdownload").
    func testSplitAndUnfinishedZip() async throws {
        let tree = try TempTree(self)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try tree.file("src/\(name)", bytes: 100_000) }
        let src = tree.root.appendingPathComponent("src")
        try zip(["-s", "64k", "-r", "../split.zip", "."], in: src)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("split.z01").path))
        let split = tree.root.appendingPathComponent("split.zip")
        let index = try await ArchiveStore.shared.index(of: split)
        XCTAssertEqual(paths(index), ["a.jpg", "b.jpg", "c.jpg"])
        let b = try await ArchiveStore.shared.data(of: split.appendingPathComponent("b.jpg"))
        XCTAssertEqual(b.count, 100_000)

        try zip(["-r", "../whole.zip", "."], in: src)
        let whole = try Data(contentsOf: tree.root.appendingPathComponent("whole.zip"))
        let cut = tree.root.appendingPathComponent("photos.zip.crdownload")
        try Data(whole.prefix(whole.count * 2 / 3)).write(to: cut)
        let partial = try await ArchiveStore.shared.index(of: cut)
        XCTAssertFalse(partial.complete)
        XCTAssertGreaterThanOrEqual(paths(partial).count, 2, "the files before the cut")
    }

    func testSevenZip() async throws {
        let tree = try TempTree(self)
        let archive = try copy(["deflate.7z"], into: tree)
        let index = try await ArchiveStore.shared.index(of: archive)
        XCTAssertEqual(paths(index), ["file1"])
        let data = try await ArchiveStore.shared.data(of: archive.appendingPathComponent("file1"))
        XCTAssertEqual(data.count, 2844)

        // LZMA (7-Zip's default): macOS 15's libarchive lacks the codec,
        // later ones have it. Either it reads, or it says why.
        let lzma = try copy(["lzma2.7z"], into: tree)
        do {
            let read = try await ArchiveStore.shared.data(of: lzma.appendingPathComponent("file1"))
            XCTAssertEqual(read.count, 2844)
        } catch ArchiveError.unreadable(let reason) {
            XCTAssertTrue(reason.contains("unsupported"), reason)
        }

        let encrypted = try copy(["encrypted.7z"], into: tree)
        do {
            _ = try await ArchiveStore.shared.index(of: encrypted)
            XCTFail("encrypted 7z")
        } catch ArchiveError.encryptionUnsupported {}
    }

    // MARK: Streaming

    /// Reads at offsets all over the file, forward and back, with chunks
    /// small enough to be dropped from memory and unpacked again: every
    /// byte as in the original. Stored and packed ZIP, a packed RAR across
    /// volumes, a password-protected RAR.
    /// A store that can't be read now (a locked keychain) is never written
    /// over: a password that opened something is used, and written into the
    /// stored list once it can be read; a store that refuses isn't asked
    /// again at once.
    func testPasswordsAreNotLostWhenTheStoreCantBeRead() {
        var saved: [[String]] = []
        var readable = false
        var loads = 0
        let store = PasswordStore(load: { loads += 1; return readable ? ["old"] : nil }, save: { saved.append($0) }, retryAfter: 0)
        store.remember("new")
        XCTAssertTrue(saved.isEmpty, "the stored list isn't overwritten")
        XCTAssertEqual(store.all, ["new"])
        readable = true
        store.remember("newer")
        XCTAssertEqual(saved.last, ["newer", "new", "old"], "readable again: both added to what is stored")
        XCTAssertEqual(store.all, ["newer", "new", "old"])

        loads = 0
        let refusing = PasswordStore(load: { loads += 1; return nil }, save: { _ in })
        for _ in 0..<5 { _ = refusing.all }
        XCTAssertEqual(loads, 1, "asked once, not for every archive")
    }

    /// Names beyond ASCII ("Übersicht.jpg") in a ZIP with UTF-8 names.
    func testNamesBeyondASCII() async throws {
        let tree = try TempTree(self)
        try tree.file("src/März/Übersicht.jpg")
        try zip(["-r", "../umlaut.zip", "März"], in: tree.root.appendingPathComponent("src"))
        let index = try await ArchiveStore.shared.index(of: tree.root.appendingPathComponent("umlaut.zip"))
        XCTAssertEqual(paths(index).map { $0.precomposedStringWithCanonicalMapping }, ["März/Übersicht.jpg"])
    }

    func testStreamingReadsAnyOffset() async throws {
        let tree = try TempTree(self)
        var original = Data(count: 3_000_000)
        original.withUnsafeMutableBytes { bytes in
            for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: (i &* 2654435761) >> 13) }
        }
        try tree.folder("src")
        try original.write(to: tree.root.appendingPathComponent("src/movie.mp4"))
        let src = tree.root.appendingPathComponent("src")
        try zip(["../stored.zip", "movie.mp4"], in: src)
        let packing = Process()
        packing.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        packing.arguments = ["-q", "-9", "../packed.zip", "movie.mp4"]
        packing.currentDirectoryURL = src
        try packing.run(); packing.waitUntilExit()

        let offsets: [Int] = [0, 2_900_000, 70_000, 1_500_000, 10, 2_999_990, 500_000, 0]
        for name in ["stored.zip", "packed.zip"] {
            let url = tree.root.appendingPathComponent(name).appendingPathComponent("movie.mp4")
            let stream = try await ArchiveStore.shared.stream(of: url, chunkSize: 64 << 10, unreadLimit: 4, readLimit: 4)
            XCTAssertEqual(stream.size, Int64(original.count))
            for offset in offsets {
                let read = try stream.read(at: Int64(offset), count: 100_000)
                XCTAssertEqual(read, original[offset..<min(offset + 100_000, original.count)], "\(name) at \(offset)")
            }
            XCTAssertEqual(try stream.read(at: Int64(original.count), count: 10), Data(), "past the end")
            stream.close()
        }

        let rar = try copy(["rar5-vols.part1.rar", "rar5-vols.part2.rar", "rar5-vols.part3.rar"], into: tree)
        let big = rar.appendingPathComponent("vols/bigfile.txt")
        let whole = try await ArchiveStore.shared.data(of: big)
        let stream = try await ArchiveStore.shared.stream(of: big, chunkSize: 16 << 10, unreadLimit: 2, readLimit: 2)
        for offset in [150_000, 0, 204_000, 30_000] {
            XCTAssertEqual(try stream.read(at: Int64(offset), count: 5000), whole[offset..<min(offset + 5000, whole.count)], "rar at \(offset)")
        }
        stream.close()

        ArchiveStore.shared.passwords.remember("password")
        let locked = try copy(["rar5-psw.rar"], into: tree)
        let protected = try await ArchiveStore.shared.stream(of: locked.appendingPathComponent("stest2.txt"), chunkSize: 512, unreadLimit: 2, readLimit: 2)
        XCTAssertEqual(try protected.read(at: 1000, count: 100).count, 100)
        XCTAssertEqual(try protected.read(at: 0, count: 2048).count, 2048)
        protected.close()
    }

    /// Two readers far apart taking turns (AVFoundation asks for several
    /// ranges at once): the chunks just after the one behind are kept, so
    /// the entry isn't unpacked from its start at every turn.
    func testTwoReadersTakingTurnsDontRestartTheUnpackingEachTurn() async throws {
        let tree = try TempTree(self)
        var original = Data(count: 3_000_000)
        original.withUnsafeMutableBytes { bytes in
            for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: (i &* 2654435761) >> 13) }
        }
        try tree.folder("src")
        try original.write(to: tree.root.appendingPathComponent("src/movie.mp4"))
        try zip(["../stored.zip", "movie.mp4"], in: tree.root.appendingPathComponent("src"))
        let url = tree.root.appendingPathComponent("stored.zip/movie.mp4")
        let chunk = 64 << 10
        let stream = try await ArchiveStore.shared.stream(of: url, chunkSize: chunk, unreadLimit: 8, readLimit: 8)
        let turns = 12
        for turn in 0..<turns {
            for start in [30, 2] {
                let offset = (start + turn) * chunk
                XCTAssertEqual(try stream.read(at: Int64(offset), count: chunk), original[offset..<offset + chunk], "chunk \(start + turn)")
            }
        }
        XCTAssertLessThanOrEqual(stream.passCount, 2 + turns / 4, "a pass per few turns, not per turn")
        stream.close()
    }

    // MARK: The model

    private func makeZip(_ tree: TempTree, name: String = "Holiday.zip", password: String? = nil) throws -> URL {
        try tree.file("src/a.jpg", bytes: 2000)
        try tree.file("src/Day 1/b.jpg", bytes: 2000)
        try tree.file("src/notes.txt", bytes: 10)
        try zip((password.map { ["-P", $0] } ?? []) + ["-r", "../\(name)", "."], in: tree.root.appendingPathComponent("src"))
        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("src"))
        return tree.root.appendingPathComponent(name)
    }

    func testAnArchiveBrowsesLikeAFolder() async throws {
        let tree = try TempTree(self)
        let archive = try makeZip(tree)
        let m = makeModel()
        await openAndWait(m, tree.root)
        XCTAssertEqual(m.names, ["..", "Holiday.zip"])
        XCTAssertEqual(m.selectedEntry?.kind, .folder)
        m.selectEntry(named: "Holiday.zip")
        m.activateSelection()
        await waitUntil { m.isAt(archive) }
        XCTAssertEqual(m.names, ["..", "Day 1", "a.jpg"], "pictures and folders, not the text file")
        m.selectEntry(named: "Day 1")
        m.activateSelection()
        await waitUntil { m.isAt(archive.appendingPathComponent("Day 1")) }
        XCTAssertEqual(m.names, ["..", "b.jpg"])
        m.handleKey(.backspace, command: false)
        await waitUntil { m.isAt(archive) }
        XCTAssertEqual(m.selectedEntry?.name, "Day 1")
        m.handleKey(.backspace, command: false)
        await waitUntil { m.isAt(tree.root) }

        // Search inside the archive
        await openAndWait(m, archive)
        await searchAndWait(m, "b.j")
        XCTAssertEqual(m.names, ["b.jpg"])
        let data = try await MediaData.read(m.entries[0].url)
        XCTAssertEqual(data.count, 2000)
    }

    func testThePasswordSheetAsksUntilOneOpensIt() async throws {
        let tree = try TempTree(self)
        let archive = try makeZip(tree, password: "secret")
        let m = makeModel()
        m.open(folder: archive)
        await waitUntil { m.passwordRequest != nil }
        XCTAssertEqual(m.passwordRequest?.archive, "Holiday.zip")
        XCTAssertEqual(m.passwordRequest?.wrong, false)
        XCTAssertFalse(m.handleKey(.right, command: false), "the sheet keeps the keys")
        m.submitPassword("nope")
        await waitUntil { m.passwordRequest != nil }
        XCTAssertEqual(m.passwordRequest?.wrong, true)
        m.submitPassword("secret")
        await waitUntil { m.isAt(archive) && m.names.contains("a.jpg") }
        XCTAssertNil(m.passwordRequest)
        XCTAssertEqual(ArchiveStore.shared.passwords.all, ["secret"])

        // Another archive with the same password: no question
        let other = try makeZip(tree, name: "Other.zip", password: "secret")
        await openAndWait(m, other)
        XCTAssertNil(m.passwordRequest)
        XCTAssertTrue(m.names.contains("a.jpg"))
    }

    func testCancellingThePasswordGoesBack() async throws {
        let tree = try TempTree(self)
        let archive = try makeZip(tree, password: "secret")
        let m = makeModel()
        await openAndWait(m, tree.root)
        m.open(folder: archive)
        await waitUntil { m.passwordRequest != nil }
        m.cancelPassword()
        await waitUntil { m.isAt(tree.root) }
        XCTAssertNil(m.passwordRequest)
    }

    /// Archives are only read: nothing inside is renamed or trashed; the
    /// archive itself goes to the Trash with all its volumes.
    func testInsideArchivesNothingChanges() async throws {
        let tree = try TempTree(self)
        let archive = try makeZip(tree)
        for name in ["set.part1.rar", "set.part2.rar", "set.part3.rar"] { try tree.file(name) }
        let spy = FileActionsSpy()
        let m = makeModel(spy)
        await openAndWait(m, archive)
        m.selectEntry(named: "a.jpg")
        XCTAssertFalse(m.selectionIsChangeable)
        XCTAssertFalse(m.beginRename())
        m.moveSelectionToTrash()
        XCTAssertTrue(spy.trashed.isEmpty)
        m.revealInFinder()
        XCTAssertEqual(spy.revealed.map(\.lastPathComponent), ["Holiday.zip"], "Finder shows the archive")

        await openAndWait(m, tree.root)
        XCTAssertEqual(m.names, ["..", "Holiday.zip", "set.part1.rar"], "one tile for the split archive")
        m.selectEntry(named: "set.part1.rar")
        XCTAssertFalse(m.beginRename(), "a split archive isn't renamed by one volume")
        m.moveSelectionToTrash()
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent).sorted(), ["set.part1.rar", "set.part2.rar", "set.part3.rar"])
    }

    func testPasswordStoreKeepsTheNewestFirst() {
        let store = PasswordStore.memory()
        store.remember("a")
        store.remember("b")
        store.remember("a")
        XCTAssertEqual(store.all, ["a", "b"])
    }
}
