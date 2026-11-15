import XCTest
import OfflineMap
@testable import Schnellbild

/// The Atlas with a tree of 100 000 photos: clustering, narrowing the
/// timeline and merging the walk's batches into the pane's list within
/// time budgets that hold on CI's virtual Macs; the facts read in the order
/// that shows the places first; and a real tree of 20 000 files walked and
/// read without holding the main thread.
@MainActor
final class AtlasScaleTests: XCTestCase {
    /// 100 000 items over Europe and a year, in folders of 100, a tenth
    /// without a place. The same every run (a fixed seed).
    private func manyItems(_ count: Int = 100_000) -> [AtlasItem] {
        var seed: UInt64 = 7
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return (0..<count).map { i in
            let folder = i / 100
            let place = i % 10 == 9 ? nil : Coordinate(latitude: 36 + random() * 34, longitude: -10 + random() * 40)
            return AtlasItem(url: URL(fileURLWithPath: "/tree/\(folder)/IMG_\(i).jpg"), isVideo: i % 50 == 0,
                             coordinate: place, date: start.addingTimeInterval(random() * 365 * 86_400),
                             offset: 7200, hasCaptureTime: true)
        }
    }

    private func seconds(_ work: () -> Void) -> Double {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    func testClusteringOneHundredThousand() {
        let points = manyItems().compactMap { item in item.coordinate.map { (id: item.url, coordinate: $0) } }
        XCTAssertEqual(points.count, 90_000)
        for zoom in [2.0, 6.0, 10.0] {
            var clusters: [AtlasCluster] = []
            let time = seconds { clusters = AtlasClustering.clusters(of: points, zoom: zoom) }
            XCTAssertLessThan(time, 2.0, "zoom \(zoom): \(time) s")
            XCTAssertEqual(clusters.reduce(0) { $0 + $1.count }, 90_000)
        }
        // On the globe, through its projection (the far side in none)
        let projection = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: 50, longitude: 10), zoom: 2),
                                         size: CGSize(width: 1200, height: 800))
        let time = seconds {
            _ = AtlasClustering.clusters(of: points) { projection.isVisible($0) ? projection.point(for: $0) : nil }
        }
        XCTAssertLessThan(time, 2.0, "on the globe: \(time) s")
    }

    func testTheTimelineNarrowsOneHundredThousandQuickly() async {
        let atlas = AtlasModel(browser: nil) { _ in [:] }
        let items = manyItems()
        let load = seconds { atlas.load(items) }
        XCTAssertLessThan(load, 4.0, "made ready: \(load) s")
        XCTAssertEqual(atlas.placed.count + atlas.unplaced.count, 100_000)
        let span = try! XCTUnwrap(atlas.span)
        // A month in the middle
        let from = span.lowerBound.addingTimeInterval(150 * 86_400), to = from.addingTimeInterval(30 * 86_400)
        let narrow = seconds { atlas.range = from...to }
        XCTAssertLessThan(narrow, 0.2, "narrowed: \(narrow) s")
        let expected = items.filter { (from...to).contains($0.date) }
        XCTAssertEqual(atlas.placed.count + atlas.unplaced.count, expected.count)
        XCTAssertEqual(Set(atlas.shown.map(\.url)), Set(expected.map(\.url)))
        // What the timeline draws: a bar per 4 points of a wide window, a thumbnail per 46
        var counts: [Int] = []
        let bars = seconds {
            for _ in 0..<10 { counts = AtlasTimeline.histogram(sorted: atlas.items, span: span, bins: 600) }
        }
        XCTAssertLessThan(bars / 10, 0.02, "bars: \(bars / 10) s")
        XCTAssertEqual(counts, AtlasTimeline.histogram(atlas.items, span: span, bins: 600), "the same as counting them all")
        let slots = seconds { _ = AtlasTimeline.firstOfSlots(sorted: atlas.items, span: span, slots: 50) }
        XCTAssertLessThan(slots, 0.02)
        XCTAssertEqual(AtlasTimeline.nearest(to: from, sorted: atlas.items[...])?.url,
                       AtlasTimeline.nearest(to: from, in: atlas.items)?.url)
        atlas.range = nil
        XCTAssertEqual(atlas.shown.count, 100_000)
    }

    func testTheWalksBatchesMergeIntoTheListQuickly() {
        let order = BrowserModel.EntryOrder(key: .name, ascending: true, captured: [:])
        let entries = manyItems().map { GridEntry(url: $0.url, kind: .image) }
        var list: [GridEntry] = []
        var slowest = 0.0
        let total = seconds {
            // As the walk brings them: a folder's worth at a time, in no order
            for batch in stride(from: 0, to: entries.count, by: 500).map({ Array(entries[$0..<min($0 + 500, entries.count)]) }).reversed() {
                let one = seconds { list = order.merged(list, batch) }
                slowest = max(slowest, one)
            }
        }
        XCTAssertEqual(list.count, 100_000)
        XCTAssertLessThan(total, 6.0, "all batches: \(total) s")
        XCTAssertLessThan(slowest, 0.15, "the slowest batch: \(slowest) s")
        XCTAssertEqual(list.map(\.url), order.sorted(entries).map(\.url), "in the pane's order")
    }

    /// The first files read are one of every folder (each place shows early),
    /// then the folders with a place in view, before the rest.
    func testThePlacesInViewAreReadFirst() async {
        var requested: [[URL]] = []
        // 300 folders of 20: the first 30 in Norway, the others in Australia
        let entries = (0..<6000).map { GridEntry(url: URL(fileURLWithPath: "/tree/\($0 / 20)/IMG_\($0).jpg"), kind: .image) }
        let place: (URL) -> GeoPoint = { url in
            let folder = Int(url.deletingLastPathComponent().lastPathComponent)!
            return folder < 30 ? GeoPoint(latitude: 61, longitude: 8)! : GeoPoint(latitude: -33, longitude: 151)!
        }
        let atlas = AtlasModel(browser: nil) { files in
            await MainActor.run { requested.append(files.map(\.url)) }
            return Dictionary(uniqueKeysWithValues: files.map { file in
                (file.url, CaptureFacts(time: nil, place: CapturePlace(location: MediaLocation(point: place(file.url)), source: .file), track: nil))
            })
        }
        atlas.mapSize = CGSize(width: 960, height: 600)
        atlas.entriesChanged(entries, context: "tree")
        // Looking at Norway (moved there: the map isn't fitted to all the places)
        atlas.moveByUser(to: MapCamera(center: Coordinate(latitude: 61, longitude: 8), zoom: 6))
        await waitUntil({ atlas.isComplete && atlas.items.count == 6000 }, timeout: 20)
        let order = requested.flatMap { $0 }
        XCTAssertEqual(order.count, 6000)
        XCTAssertEqual(Set(order).count, 6000, "each file once")
        func folder(_ url: URL) -> Int { Int(url.deletingLastPathComponent().lastPathComponent)! }
        XCTAssertEqual(Set(order.prefix(300).map(folder)).count, 300, "first one file of every folder")
        // Then Norway's folders (in view) before Australia's
        let next = order.dropFirst(300).prefix(30 * 19)
        XCTAssertTrue(next.allSatisfy { folder($0) < 30 }, "the folders in view next")
        // Again with Australia in view: its folders come first after the sampling
        requested = []
        let other = AtlasModel(browser: nil) { files in
            await MainActor.run { requested.append(files.map(\.url)) }
            return Dictionary(uniqueKeysWithValues: files.map { file in
                (file.url, CaptureFacts(time: nil, place: CapturePlace(location: MediaLocation(point: place(file.url)), source: .file), track: nil))
            })
        }
        other.mapSize = CGSize(width: 960, height: 600)
        other.entriesChanged(entries, context: "tree")
        other.moveByUser(to: MapCamera(center: Coordinate(latitude: -33, longitude: 151), zoom: 6))
        await waitUntil({ other.isComplete && other.items.count == 6000 }, timeout: 20)
        let then = requested.flatMap { $0 }.dropFirst(300).prefix(270 * 19)
        XCTAssertTrue(then.allSatisfy { folder($0) >= 30 })
    }

    /// A real tree of 20 000 tiny files in 200 folders: the walk of the
    /// subfolders and the reading of their facts (through `LocationCache`)
    /// never hold the main thread long; a timer on it measures the gaps.
    func testWalkingAndReadingALargeTreeDoesNotHoldTheMainThread() async throws {
        let tree = try TempTree(self)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])   // a JPEG's start and end, no picture
        for folder in 0..<200 {
            let url = try tree.folder("Day \(folder)")
            for file in 0..<100 { try bytes.write(to: url.appendingPathComponent("IMG_\(file).jpg")) }
        }
        let m = makeModel()
        await openAndWait(m, tree.root)
        // A timer on the main queue itself, every 10 ms: how late it fires is
        // how long the main thread was held (not Swift's executors' timing)
        final class Watch: @unchecked Sendable {
            var last = Date()
            var longest = 0.0
            var gaps: [String] = []
            let began = Date()
        }
        let watch = Watch()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler {
            let now = Date()
            let gap = now.timeIntervalSince(watch.last) - 0.01
            watch.longest = max(watch.longest, gap)
            if gap > 0.05 { watch.gaps.append(String(format: "%.2f s in: %.3f s", now.timeIntervalSince(watch.began), gap)) }
            watch.last = now
        }
        timer.resume()
        let start = Date()
        m.viewMode = .atlas
        await waitUntil({ !m.deepWalking && m.entries.count == 20_000 && m.atlas.isComplete && m.atlas.items.count == 20_000 },
                        timeout: 180)
        timer.cancel()
        print("walked and read 20 000 files in \(Date().timeIntervalSince(start)) s, the main thread held at most \(watch.longest) s")
        print("the main thread held over 50 ms: \(watch.gaps)")
        XCTAssertEqual(m.entries.count, 20_000)
        XCTAssertLessThan(watch.longest, 0.25, "the main thread was held \(watch.longest) s")
    }
}
