import Combine
import XCTest
import OfflineMap
@testable import Schnellbild

/// The Atlas with a tree of 100 000 photos: clustering, narrowing the
/// timeline and merging the walk's batches into the pane's list within
/// time budgets (`TimeBudget`); the facts read in the order
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

    func testClusteringOneHundredThousand() {
        let points = manyItems().compactMap { item in item.coordinate.map { (id: item.url, coordinate: $0) } }
        XCTAssertEqual(points.count, 90_000)
        for zoom in [2.0, 6.0, 10.0] {
            var clusters: [AtlasCluster] = []
            TimeBudget.check("zoom \(zoom)", under: 2.0) { clusters = AtlasClustering.clusters(of: points, zoom: zoom) }
            XCTAssertEqual(clusters.reduce(0) { $0 + $1.count }, 90_000)
        }
        // On the globe, through its projection (the far side in none)
        let projection = GlobeProjection(camera: MapCamera(center: Coordinate(latitude: 50, longitude: 10), zoom: 2),
                                         size: CGSize(width: 1200, height: 800))
        TimeBudget.check("on the globe", under: 2.0) {
            _ = AtlasClustering.clusters(of: points) { projection.isVisible($0) ? projection.point(for: $0) : nil }
        }
    }

    func testTheTimelineNarrowsOneHundredThousandQuickly() async {
        let atlas = AtlasModel(browser: nil) { _ in [:] }
        let items = manyItems()
        TimeBudget.check("made ready", under: 4.0) { atlas.load(items) }
        XCTAssertEqual(atlas.placed.count + atlas.unplaced.count, 100_000)
        let span = try! XCTUnwrap(atlas.span)
        // A month in the middle
        let from = span.lowerBound.addingTimeInterval(150 * 86_400), to = from.addingTimeInterval(30 * 86_400)
        // Once: the same range again changes nothing
        TimeBudget.check("narrowed", under: 0.2, runs: 1) { atlas.range = from...to }
        let expected = items.filter { (from...to).contains($0.date) }
        XCTAssertEqual(atlas.placed.count + atlas.unplaced.count, expected.count)
        XCTAssertEqual(Set(atlas.shown.map(\.url)), Set(expected.map(\.url)))
        // What the timeline draws: a bar per 4 points of a wide window, a thumbnail per 46
        var counts: [Int] = []
        TimeBudget.check("bars, 10 times", under: 10 * 0.02) {
            for _ in 0..<10 { counts = AtlasTimeline.histogram(sorted: atlas.items, span: span, bins: 600) }
        }
        XCTAssertEqual(counts, AtlasTimeline.histogram(atlas.items, span: span, bins: 600), "the same as counting them all")
        TimeBudget.check("thumbnails' slots", under: 0.02) { _ = AtlasTimeline.firstOfSlots(sorted: atlas.items, span: span, slots: 50) }
        XCTAssertEqual(AtlasTimeline.nearest(to: from, sorted: atlas.items[...])?.url,
                       AtlasTimeline.nearest(to: from, in: atlas.items)?.url)
        atlas.range = nil
        XCTAssertEqual(atlas.shown.count, 100_000)
    }

    /// The walk's batches go into the pane's list in its order, with work
    /// that grows with the batch, not with the list: counted comparisons
    /// (a binary search per new item; merging by comparing with every item
    /// listed would take hundreds of times as many), and the time of one
    /// batch into a list ten times as long against a short one, each the
    /// best of five runs in CPU time (the same runner for both: copying the list
    /// grows with it, comparing barely; inserting item by item into the
    /// array would take about ten times as long).
    func testTheWalksBatchesMergeIntoTheListWithWorkThatGrowsWithTheBatch() {
        let order = BrowserModel.EntryOrder(key: .name, ascending: true, captured: [:])
        let entries = manyItems().map { GridEntry(url: $0.url, kind: .image) }
        // In the pane's order, as the walk brings them: a folder's worth at a time, in no order
        var list: [GridEntry] = []
        for batch in stride(from: 0, to: entries.count, by: 500).map({ Array(entries[$0..<min($0 + 500, entries.count)]) }).reversed() {
            list = order.merged(list, batch)
        }
        XCTAssertEqual(list.count, 100_000)
        XCTAssertEqual(list.map(\.url), order.sorted(entries).map(\.url), "in the pane's order")

        // Comparisons: 500 new into 100 000 listed
        let listed = Array(stride(from: 0, to: 200_000, by: 2)), added = (0..<500).map { $0 * 397 + 1 }
        var comparisons = 0
        let places = BrowserModel.EntryOrder.insertionPoints(into: listed.count, adding: added.count) { i, j in
            comparisons += 1
            return listed[i] < added[j]
        }
        XCTAssertEqual(places, added.map { ($0 + 1) / 2 }, "each where it goes")
        let bound = added.count * (Int(log2(Double(listed.count))) + 2)
        XCTAssertLessThanOrEqual(comparisons, bound, "about log2(n) comparisons per new item, not n")

        // Time: a batch into 100 000 against one into 10 000
        func best(into count: Int) -> Double {
            let base = Array(list.prefix(count))
            let batch = (0..<500).map { GridEntry(url: URL(fileURLWithPath: "/tree/new/IMG_\($0 * 7).jpg"), kind: .image) }
            return (0..<5).map { _ in TimeBudget.seconds(.thread) { _ = order.merged(base, batch) } }.min()!
        }
        let short = best(into: 10_000), long = best(into: 100_000)
        print("500 merged into 10 000: \(short) s, into 100 000: \(long) s")
        XCTAssertLessThan(long / short, 4, "the work grows with the list: \(short) s, \(long) s")
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
    /// never hold the main thread long. Two measures: the Atlas's own count
    /// of the items its passes walk on the main thread (none: deterministic),
    /// and a timer on the main queue whose lateness is how long the main
    /// thread was held. A gap counts against the app only when the app's
    /// work ran in it: the pane or the Atlas published a change between the
    /// timer's two firings (their publishers run on the main thread, inside
    /// the work that holds it). A gap with none of that is the runner's (a
    /// virtual Mac descheduled: CI saw one lone 0.253 s gap in 8 s of walking,
    /// with not one other over 50 ms); it is reported, not failed.
    func testWalkingAndReadingALargeTreeDoesNotHoldTheMainThread() async throws {
        let tree = try TempTree(self)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])   // a JPEG's start and end, no picture
        for folder in 0..<200 {
            let url = try tree.folder("Day \(folder)")
            for file in 0..<100 { try bytes.write(to: url.appendingPathComponent("IMG_\(file).jpg")) }
        }
        let m = makeModel()
        await openAndWait(m, tree.root)
        // (everything here runs on the main thread: the timer's queue and the publishers alike)
        final class Watch: @unchecked Sendable {
            var last = Date()
            var gaps: [(at: Double, held: Double, app: [String])] = []
            var events: [(Date, String)] = []
            let began = Date()

            func note(_ what: String) { events.append((Date(), what)) }

            /// What the app published since `from` (dropping what is older).
            func appWork(since from: Date) -> [String] {
                let inside = events.filter { $0.0 > from }.map(\.1)
                events.removeAll()
                return Array(Set(inside)).sorted()
            }
        }
        let watch = Watch()
        let observers = [m.objectWillChange.sink { watch.note("pane") },
                         m.atlas.objectWillChange.sink { watch.note("atlas") },
                         m.atlas.strip.objectWillChange.sink { watch.note("strip") },
                         m.atlas.cameraState.objectWillChange.sink { watch.note("camera") }]
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler {
            let now = Date()
            let held = now.timeIntervalSince(watch.last) - 0.01
            let app = watch.appWork(since: watch.last)
            if held > 0.05 { watch.gaps.append((now.timeIntervalSince(watch.began), held, app)) }
            watch.last = now
        }
        timer.resume()
        let start = Date()
        m.viewMode = .atlas
        await waitUntil({ !m.deepWalking && m.entries.count == 20_000 && m.atlas.isComplete && m.atlas.items.count == 20_000 },
                        timeout: 180)
        timer.cancel()
        _ = observers
        let longest = watch.gaps.map(\.held).max() ?? 0
        let report = watch.gaps.map { String(format: "%.2f s in: %.3f s", $0.at, $0.held) + ($0.app.isEmpty ? " (no app work)" : " (\($0.app.joined(separator: ", ")))") }
        print("walked and read 20 000 files in \(Date().timeIntervalSince(start)) s, the main thread held at most \(longest) s")
        print("the main thread held over 50 ms: \(report)")
        XCTAssertEqual(m.entries.count, 20_000)
        XCTAssertEqual(m.atlas.work.counts.onMain, 0, "no pass of the Atlas over the items on the main thread")
        let byTheApp = watch.gaps.filter { !$0.app.isEmpty }
        XCTAssertLessThan(byTheApp.map(\.held).max() ?? 0, 0.25, "the app held the main thread: \(report)")
    }

    /// A video's UTC time takes the offset of the nearest photo through a
    /// binary search: 10 000 videos among 50 000 photos look at about
    /// log2(50 000) photos each (comparing each with every photo would be
    /// 500 million), and the offsets lent are those the nearest photo states.
    func testUTCTimesFindTheirOffsetByBinarySearch() {
        func items(photos: Int, videos: Int) -> [AtlasItem] {
            var seed: UInt64 = 11
            func random() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 11) / Double(1 << 53)
            }
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            let photo = (0..<photos).map { i in
                AtlasItem(url: URL(fileURLWithPath: "/tree/IMG_\(i).jpg"), isVideo: false, coordinate: nil,
                          date: start.addingTimeInterval(random() * 365 * 86_400), offset: 3600 * (Int(random() * 25) - 12),
                          hasCaptureTime: true)
            }
            let video = (0..<videos).map { i in
                AtlasItem(url: URL(fileURLWithPath: "/tree/VID_\(i).mp4"), isVideo: true, coordinate: nil,
                          date: start.addingTimeInterval(random() * 400 * 86_400), offset: nil, hasCaptureTime: true, timeIsUTC: true)
            }
            var order = Seeded(seed: 3)
            return (photo + video).shuffled(using: &order)
        }
        // The work: probes of the photos' offsets
        var probes = 0
        let large = AtlasItems.prepared(items(photos: 50_000, videos: 10_000), probes: &probes)
        XCTAssertEqual(large.count, 60_000)
        let bound = 10_000 * (Int(log2(50_000.0).rounded(.up)) + 3)
        XCTAssertLessThanOrEqual(probes, bound, "about log2(n) photos per video, not every photo: \(probes)")
        XCTAssertGreaterThan(probes, 10_000, "every video looked")
        // The answers: the offset of the nearest photo within a day, as comparing with every photo gives
        let small = items(photos: 2_000, videos: 500)
        let prepared = AtlasItems.prepared(small)
        let photos = small.filter { $0.offset != nil }
        for item in prepared where item.timeIsUTC {
            let nearest = photos.min { abs($0.date.timeIntervalSince(item.date)) < abs($1.date.timeIntervalSince(item.date)) }!
            let expected = abs(nearest.date.timeIntervalSince(item.date)) <= 86_400 ? nearest.offset : nil
            XCTAssertEqual(item.offset, expected, item.name)
        }
        XCTAssertTrue(prepared.contains { $0.timeIsUTC && $0.offset == nil }, "a video further than a day from every photo keeps none")
    }

    /// 100 000 files read through the model (the pane's list taken over,
    /// the facts read chunk by chunk, the items made again twice a second,
    /// the map fitted and clustered, the timeline narrowed): every pass over
    /// all the items runs off the main thread. The model counts the items
    /// each pass walks and where (`AtlasModel.work`); the main thread only
    /// takes the results and narrows them by binary search.
    func testReadingOneHundredThousandWalksNoItemsOnTheMainThread() async throws {
        let items = manyItems()
        let byURL = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0) })
        let atlas = AtlasModel(browser: nil) { files in
            Dictionary(uniqueKeysWithValues: files.map { file in
                let item = byURL[file.url]!
                let place = item.coordinate.flatMap { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) }
                return (file.url, CaptureFacts(time: CaptureTime(ClockReading(floating: item.date.addingTimeInterval(7200), offset: 7200),
                                                                source: .file),
                                               place: place.map { CapturePlace(location: MediaLocation(point: $0), source: .file) }, track: nil))
            })
        }
        atlas.mapSize = CGSize(width: 960, height: 600)
        let entries = items.map { GridEntry(url: $0.url, kind: $0.isVideo ? .video : .image, modDate: $0.date) }
        atlas.entriesChanged(entries, context: "tree")
        await waitUntil({ atlas.isComplete && atlas.items.count == 100_000 }, timeout: 300)
        XCTAssertEqual(atlas.placed.count, 90_000)
        XCTAssertEqual(atlas.unplaced.count, 10_000)
        // Fitted to Europe (off the main thread) and clustered
        await waitUntil({ atlas.camera != MapCamera.world && !atlas.clusters.isEmpty }, timeout: 30)
        XCTAssertEqual(atlas.camera.center.latitude, 53, accuracy: 10, "the map over the places: \(atlas.camera)")
        // A month narrowed, the map moved on the globe: the clusters follow
        let span = try XCTUnwrap(atlas.span)
        let from = span.lowerBound.addingTimeInterval(150 * 86_400)
        atlas.range = from...from.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(atlas.placed.count + atlas.unplaced.count, items.filter { atlas.range!.contains($0.date) }.count)
        for longitude in stride(from: 0.0, through: 30, by: 10) {
            atlas.moveByUser(to: MapCamera(center: Coordinate(latitude: 50, longitude: longitude), zoom: 2))
            await Task.yield()
        }
        await waitUntil({ atlas.clusterCamera == atlas.camera }, timeout: 30)
        let work = atlas.work.counts
        print("items walked on the main thread: \(work.onMain), off it: \(work.offMain)")
        XCTAssertEqual(work.onMain, 0, "no pass over the items on the main thread")
        XCTAssertGreaterThanOrEqual(work.offMain, 3 * 100_000, "the list taken over, the items made and fitted off it")
    }
}

/// A seeded generator: the same order every run.
struct Seeded: RandomNumberGenerator {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed
    }
}
