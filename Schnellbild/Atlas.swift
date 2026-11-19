import Foundation
import CoreGraphics
import OfflineMap

// MARK: - The Atlas view's items, clusters, timeline and tour (no UI here)

/// A photo or video in the Atlas view: where and when it was taken.
struct AtlasItem: Identifiable, Equatable, Sendable {
    let url: URL
    let isVideo: Bool
    /// Where it was taken; nil: it goes into the strip under the map.
    var coordinate: Coordinate?
    /// When it was taken (`CaptureFacts`), else the file's modification
    /// date; `Date.distantPast` without either (`isDated`).
    var date: Date
    /// Seconds east of UTC its clock showed; nil: the Mac's time zone.
    var offset: Int?
    /// The time is the capture time, not the modification date.
    var hasCaptureTime: Bool
    /// The time was read as a moment in UTC (a movie header, GPS) with no
    /// offset of its own.
    var timeIsUTC = false
    /// A video's GPS track (GoPro, DJI), for the tour's route.
    var track: [Coordinate] = []

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// It has a time (its own or the file's date). Items without one come
    /// first in the order of time and stay out of the timeline's span.
    var isDated: Bool { date != .distantPast }

    /// The time zone its time is shown in.
    var zone: TimeZone { offset.flatMap(TimeZone.init(secondsFromGMT:)) ?? .current }

    /// From what `LocationCache` read; `modified` stands in for a time the file doesn't state.
    static func make(url: URL, isVideo: Bool, facts: CaptureFacts?, modified: Date?) -> AtlasItem {
        let place = facts?.place?.location.point
        let time = facts?.time
        // A camera clock without zone was read in the Mac's time zone: shown there
        // it reads as the camera showed it. A time from a UTC source (a movie
        // header, GPS) has no offset of its own: `AtlasItems.prepared` lends it one.
        return AtlasItem(url: url, isVideo: isVideo,
                         coordinate: place.map(\.coordinate),
                         date: time?.date ?? modified ?? .distantPast,
                         offset: time?.isCameraClock == false ? time?.offset : nil,
                         hasCaptureTime: time != nil,
                         timeIsUTC: time.map { !$0.isCameraClock && $0.offset == nil } ?? false,
                         track: facts?.track?.points.map(\.point.coordinate) ?? [])
    }
}

enum AtlasItems {
    /// The items in the order of time (the path where two share one), and
    /// a time read in UTC (a movie header, GoPro's GPS) without an offset
    /// given the offset of the nearest item within a day that states one, so
    /// a video shows the same local time as the photos around it.
    static func prepared(_ items: [AtlasItem]) -> [AtlasItem] {
        var probes = 0
        return prepared(items, probes: &probes)
    }

    /// The same, counting how many stated offsets were looked at (tests count
    /// the work): a binary search per time read in UTC, as the items with an
    /// offset are in the order of time too.
    static func prepared(_ items: [AtlasItem], probes: inout Int) -> [AtlasItem] {
        var sorted = items.sorted { $0.date != $1.date ? $0.date < $1.date : $0.url.path < $1.url.path }
        let stated = sorted.compactMap { item in item.offset.map { (date: item.date, offset: $0) } }
        guard !stated.isEmpty else { return sorted }
        for index in sorted.indices where sorted[index].offset == nil && sorted[index].timeIsUTC {
            let date = sorted[index].date
            var low = 0, high = stated.count
            while low < high {
                probes += 1
                let mid = (low + high) / 2
                if stated[mid].date < date { low = mid + 1 } else { high = mid }
            }
            // The nearest is the last one before the time or the first one at or after it
            var nearest: (date: Date, offset: Int)?
            for candidate in [low - 1, low] where stated.indices.contains(candidate) {
                probes += 1
                let c = stated[candidate]
                if nearest.map({ abs(c.date.timeIntervalSince(date)) < abs($0.date.timeIntervalSince(date)) }) ?? true { nearest = c }
            }
            if let nearest, abs(nearest.date.timeIntervalSince(date)) <= 86_400 { sorted[index].offset = nearest.offset }
        }
        return sorted
    }

    /// The calendar day an item was taken on, by its own clock.
    static func day(of item: AtlasItem) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = item.zone
        return calendar.dateComponents([.year, .month, .day], from: item.date)
    }

    /// The same day as a number (days since 1970 by the item's clock), with
    /// no calendar per item: the tour's stations of 100 000 items are made at once.
    static func dayNumber(of item: AtlasItem) -> Int {
        // The offset `zone` takes (a time zone holds up to 18 hours), else the Mac's at that moment
        let offset = item.offset.flatMap { abs($0) <= 18 * 3600 ? $0 : nil } ?? TimeZone.current.secondsFromGMT(for: item.date)
        return Int(((item.date.timeIntervalSince1970 + Double(offset)) / 86_400).rounded(.down))
    }
}

// MARK: - Clusters

/// Items close together on screen drawn as one tile with their count.
struct AtlasCluster: Equatable, Sendable, Identifiable {
    /// The items, in the order of time.
    var ids: [URL]
    /// Where the tile stands: the middle of its items (in the map's projection).
    var coordinate: Coordinate
    /// Its items stay one tile at the largest zoom (taken at one place):
    /// a click goes through them, zooming in doesn't part them.
    var staysTogether = false
    var id: URL { ids[0] }
    var count: Int { ids.count }
}

enum AtlasClustering {
    /// Tiles closer than this (points) join one cluster.
    static let spacing = 58.0

    /// Greedy clustering in screen space at a zoom: in the given order (by
    /// time), each item joins the cluster whose first item lies nearest
    /// within `spacing`, else starts one. On the flat map distances are
    /// measured in the map's world points at that zoom, so moving the map
    /// changes nothing and only a zoom asks again. A grid of `spacing` cells finds the
    /// neighbours, so thousands of items take milliseconds.
    static func clusters(of points: [(id: URL, coordinate: Coordinate)], zoom: Double,
                         spacing: Double = spacing) -> [AtlasCluster] {
        let world = WebMercator.worldSize(zoom: zoom)
        return clusters(of: points, spacing: spacing) { coordinate in
            let unit = WebMercator.unitPoint(coordinate)
            return CGPoint(x: unit.x * world, y: unit.y * world)
        }
    }

    /// The same through a projection to the screen (the globe's): an item
    /// it gives no point (the far side) is in no cluster. A tile's place is
    /// the middle of its items in the unit square, each taken on the side of
    /// the antimeridian its first item lies on (Fiji and Samoa side by side
    /// on the globe stand in the Pacific, not at longitude 0).
    static func clusters(of points: [(id: URL, coordinate: Coordinate)], spacing: Double = spacing,
                         project: (Coordinate) -> CGPoint?) -> [AtlasCluster] {
        struct Building { var ids: [URL]; var leader: CGPoint; var leaderUnit: CGPoint; var sum: CGPoint; var together: Bool }
        // Closer than this in the unit square: one tile even at the largest zoom
        let apart = spacing / WebMercator.worldSize(zoom: MapViewport.maxZoom)
        var built: [Building] = []
        var cells: [Int64: [Int]] = [:]
        func key(_ x: Int64, _ y: Int64) -> Int64 { x &* 1_000_003 &+ y }
        for point in points {
            guard let p = project(point.coordinate) else { continue }
            var unit = WebMercator.unitPoint(point.coordinate)
            let cx = Int64((Double(p.x) / spacing).rounded(.down)), cy = Int64((Double(p.y) / spacing).rounded(.down))
            var best: (index: Int, distance: Double)?
            for dx in -1...1 {
                for dy in -1...1 {
                    for index in cells[key(cx + Int64(dx), cy + Int64(dy))] ?? [] {
                        let leader = built[index].leader
                        let d = hypot(Double(leader.x - p.x), Double(leader.y - p.y))
                        if d < spacing, d < best?.distance ?? .infinity { best = (index, d) }
                    }
                }
            }
            if let best {
                let leader = built[best.index].leaderUnit
                if unit.x - leader.x > 0.5 { unit.x -= 1 } else if leader.x - unit.x > 0.5 { unit.x += 1 }
                built[best.index].ids.append(point.id)
                built[best.index].sum.x += unit.x
                built[best.index].sum.y += unit.y
                if hypot(Double(unit.x - leader.x), Double(unit.y - leader.y)) >= apart { built[best.index].together = false }
            } else {
                cells[key(cx, cy), default: []].append(built.count)
                built.append(Building(ids: [point.id], leader: p, leaderUnit: unit, sum: unit, together: true))
            }
        }
        return built.map { cluster in
            let n = CGFloat(cluster.ids.count)
            return AtlasCluster(ids: cluster.ids,
                                coordinate: WebMercator.coordinate(unit: CGPoint(x: cluster.sum.x / n, y: cluster.sum.y / n)),
                                staysTogether: cluster.ids.count > 1 && cluster.together)
        }
    }
}

// MARK: - Moving among what is on screen

enum AtlasDirection: Sendable { case left, right, up, down }

enum AtlasNavigation {
    /// The point nearest in a direction from `origin`: ahead of it (more
    /// than a point), the distance ahead plus twice the distance to the
    /// side, so the arrow keys move as the eye expects. Nil: nothing there.
    static func next(from origin: CGPoint, among points: [CGPoint], _ direction: AtlasDirection) -> Int? {
        var best: (index: Int, cost: Double)?
        for (index, point) in points.enumerated() {
            let dx = Double(point.x - origin.x), dy = Double(point.y - origin.y)
            let (ahead, aside): (Double, Double)
            switch direction {
            case .left:  (ahead, aside) = (-dx, dy)
            case .right: (ahead, aside) = (dx, dy)
            case .up:    (ahead, aside) = (-dy, dx)
            case .down:  (ahead, aside) = (dy, dx)
            }
            guard ahead > 1 else { continue }
            let cost = ahead + 2 * abs(aside)
            if cost < best?.cost ?? .infinity { best = (index, cost) }
        }
        return best?.index
    }
}

// MARK: - Timeline

enum AtlasTimeline {
    /// From the first to the last item's time (items without a time left
    /// out); nil without such items.
    static func span(of items: [AtlasItem]) -> ClosedRange<Date>? {
        let dated = items.filter(\.isDated).map(\.date)
        guard let first = dated.min(), let last = dated.max() else { return nil }
        return first...last
    }

    /// The span of items in the order of time: those without a time come
    /// first, so the span starts at the first item at or after the earliest time.
    static func span(sorted items: [AtlasItem]) -> ClosedRange<Date>? {
        let start = firstIndex(atOrAfter: Date.distantPast.addingTimeInterval(1), in: items)
        guard start < items.count, let last = items.last else { return nil }
        return items[start].date...last.date
    }

    /// The items whose time lies in the range (all of them without one).
    static func filter(_ items: [AtlasItem], to range: ClosedRange<Date>?) -> [AtlasItem] {
        guard let range else { return items }
        return items.filter { range.contains($0.date) }
    }

    /// How many items fall into each of `bins` equal parts of the span.
    /// The first index in `items` (in the order of time) at or after `date`.
    static func firstIndex(atOrAfter date: Date, in items: [AtlasItem]) -> Int {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].date < date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The items in the range, of items in the order of time: two binary
    /// searches, no walk through all of them.
    static func slice(_ items: [AtlasItem], to range: ClosedRange<Date>?) -> ArraySlice<AtlasItem> {
        guard let range else { return items[...] }
        let start = firstIndex(atOrAfter: range.lowerBound, in: items)
        let end = firstIndex(atOrAfter: range.upperBound.addingTimeInterval(1e-6), in: items)
        return items[start..<max(start, end)]
    }

    /// The item nearest a time, of items in the order of time (a binary search).
    static func nearest(to date: Date, sorted items: ArraySlice<AtlasItem>) -> AtlasItem? {
        guard !items.isEmpty else { return nil }
        var low = items.startIndex, high = items.endIndex
        while low < high {
            let mid = (low + high) / 2
            if items[mid].date < date { low = mid + 1 } else { high = mid }
        }
        let after = low < items.endIndex ? items[low] : nil
        let before = low > items.startIndex ? items[low - 1] : nil
        guard let after else { return before }
        guard let before else { return after }
        return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
    }

    /// How many items fall into each part of the span, of items in the order
    /// of time: a binary search per part's edge.
    static func histogram(sorted items: [AtlasItem], span: ClosedRange<Date>, bins: Int) -> [Int] {
        guard bins > 0, !items.isEmpty else { return Array(repeating: 0, count: max(0, bins)) }
        let length = span.upperBound.timeIntervalSince(span.lowerBound)
        guard length > 0 else {
            var counts = Array(repeating: 0, count: bins)
            counts[bins / 2] = items.count
            return counts
        }
        var counts: [Int] = []
        counts.reserveCapacity(bins)
        var start = firstIndex(atOrAfter: span.lowerBound, in: items)
        for bin in 0..<bins {
            let end = bin == bins - 1 ? items.count
                : firstIndex(atOrAfter: span.lowerBound.addingTimeInterval(length * Double(bin + 1) / Double(bins)), in: items)
            counts.append(max(0, end - start))
            start = max(start, end)
        }
        return counts
    }

    /// The first item of each of `slots` parts of the span (none where a part is empty).
    static func firstOfSlots(sorted items: [AtlasItem], span: ClosedRange<Date>, slots: Int) -> [Int: AtlasItem] {
        guard slots > 0, !items.isEmpty else { return [:] }
        let length = span.upperBound.timeIntervalSince(span.lowerBound)
        guard length > 0 else { return [slots / 2: items[0]] }
        var firsts: [Int: AtlasItem] = [:]
        for slot in 0..<slots {
            let i = firstIndex(atOrAfter: span.lowerBound.addingTimeInterval(length * Double(slot) / Double(slots)), in: items)
            guard i < items.count, AtlasTimeline.bin(of: items[i].date, span: span, bins: slots) == slot else { continue }
            firsts[slot] = items[i]
        }
        return firsts
    }

    static func histogram(_ items: [AtlasItem], span: ClosedRange<Date>, bins: Int) -> [Int] {
        guard bins > 0 else { return [] }
        var counts = Array(repeating: 0, count: bins)
        for item in items { counts[bin(of: item.date, span: span, bins: bins)] += 1 }
        return counts
    }

    /// The part of the span a time falls into.
    static func bin(of date: Date, span: ClosedRange<Date>, bins: Int) -> Int {
        let length = span.upperBound.timeIntervalSince(span.lowerBound)
        guard length > 0 else { return bins / 2 }
        let f = date.timeIntervalSince(span.lowerBound) / length
        return min(bins - 1, max(0, Int(f * Double(bins))))
    }

    /// A share of the span (0 … 1) as a time.
    static func date(at fraction: Double, span: ClosedRange<Date>) -> Date {
        span.lowerBound.addingTimeInterval(span.upperBound.timeIntervalSince(span.lowerBound) * min(1, max(0, fraction)))
    }

    /// Where a time lies in the span (0 … 1).
    static func fraction(of date: Date, span: ClosedRange<Date>) -> Double {
        let length = span.upperBound.timeIntervalSince(span.lowerBound)
        guard length > 0 else { return 0.5 }
        return min(1, max(0, date.timeIntervalSince(span.lowerBound) / length))
    }

    /// The item nearest a time (a click on the timeline jumps there).
    static func nearest(to date: Date, in items: [AtlasItem]) -> AtlasItem? {
        items.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// The time zone a moment is shown in: the clock of the item nearest
    /// to it (a trip's photos in their own zone, wherever the Mac is).
    static func zone(at date: Date, in items: [AtlasItem]) -> TimeZone {
        nearest(to: date, in: items)?.zone ?? .current
    }

    /// A moment as the clock where it was taken showed it.
    static func text(_ date: Date, in zone: TimeZone, time: Bool) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted)
        style.timeZone = zone
        return date.formatted(style)
    }
}

// MARK: - Tour

/// A stop of the tour: items taken at one place on one day.
struct TourStation: Equatable, Sendable {
    var items: [AtlasItem]
    /// The middle of its items.
    var coordinate: Coordinate
    var start: Date { items[0].date }
}

enum TourPlanner {
    /// Items further apart than this from a station's first item start another.
    static let radius = 1_000.0

    /// The items with a place, in the order of time, grouped into stations:
    /// one place (within `radius` of the station's first item) on one day
    /// (by each item's own clock). Going back to a place later is a new station.
    static func stations(from items: [AtlasItem]) -> [TourStation] {
        stations(fromPrepared: AtlasItems.prepared(items.filter { $0.coordinate != nil }))
    }

    /// The same of items prepared already (`AtlasItems.prepared`, all with a
    /// place): the Atlas's `placed`, without sorting them again.
    static func stations<Items: Collection<AtlasItem>>(fromPrepared placed: Items) -> [TourStation] {
        var stations: [TourStation] = []
        var current: [AtlasItem] = []
        var currentDay = 0
        func close() {
            guard !current.isEmpty else { return }
            let lat = current.map { $0.coordinate!.latitude }.reduce(0, +) / Double(current.count)
            // Longitudes averaged around the first item's (a station across the antimeridian)
            let base = current[0].coordinate!.longitude
            let lon = current.map { item -> Double in
                var d = item.coordinate!.longitude - base
                if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                return d
            }.reduce(0, +) / Double(current.count) + base
            stations.append(TourStation(items: current, coordinate: Coordinate(latitude: lat, longitude: lon).normalized))
            current = []
        }
        for item in placed {
            let day = AtlasItems.dayNumber(of: item)
            if let first = current.first, currentDay != day || first.coordinate!.distance(to: item.coordinate!) > radius {
                close()
            }
            if current.isEmpty { currentDay = day }
            current.append(item)
        }
        close()
        return stations
    }

    /// The route through the stations: from station to station, along a
    /// video's GPS track where a station has one. `arrivals[i]` is where
    /// station i is reached on it.
    static func route(through stations: [TourStation]) -> (points: [Coordinate], arrivals: [Int]) {
        var points: [Coordinate] = []
        var arrivals: [Int] = []
        for station in stations {
            arrivals.append(points.count)
            points.append(station.coordinate)
            for item in station.items where item.track.count > 1 {
                points.append(contentsOf: item.track)
            }
        }
        return (points, arrivals)
    }
}

/// Where the tour is: which station, which of its items, flying there or
/// showing; paused or not. Pure state, so the keys and the sequence are
/// tested without a screen.
struct TourPlayer: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case flying, showing }

    let stations: [TourStation]
    private(set) var station = 0
    private(set) var item = 0
    private(set) var phase = Phase.flying
    var paused = false
    private(set) var finished = false

    /// How long a photo is shown, a video plays (a short part), the camera flies.
    static let photoSeconds = 2.5
    static let videoSeconds = 5.0
    static let flightSeconds = 2.0

    init(stations: [TourStation]) {
        self.stations = stations
        finished = stations.isEmpty
    }

    var currentStation: TourStation? { stations.indices.contains(station) ? stations[station] : nil }

    /// The item shown large (nil while flying).
    var currentItem: AtlasItem? {
        guard phase == .showing, let station = currentStation, station.items.indices.contains(item) else { return nil }
        return station.items[item]
    }

    /// How long the current step lasts (flying, or the item shown).
    func duration(reducedMotion: Bool) -> Double {
        switch phase {
        case .flying: return reducedMotion ? 0.6 : Self.flightSeconds
        case .showing: return currentItem?.isVideo == true ? Self.videoSeconds : Self.photoSeconds
        }
    }

    /// The current step is over: the flight ends at the station, an item
    /// gives way to the next, the station's last item to the next flight.
    mutating func advance() {
        guard !finished else { return }
        switch phase {
        case .flying:
            phase = .showing
            item = 0
        case .showing:
            if let station = currentStation, item + 1 < station.items.count {
                item += 1
            } else {
                next()
            }
        }
    }

    /// On to the next station (→); past the last the tour is finished.
    mutating func next() {
        guard !finished else { return }
        if station + 1 < stations.count {
            station += 1
            item = 0
            phase = .flying
        } else {
            finished = true
        }
    }

    /// Back to the previous station (←): the first stays the first.
    mutating func previous() {
        guard !finished else { return }
        station = max(0, station - 1)
        item = 0
        phase = .flying
    }
}

/// The camera's way from one place to the next: the centre moves in the
/// map's square, the zoom dips out on the way when the places lie further
/// apart than a view shows, then in again.
enum TourFlight {
    /// The zoom a station is shown at: its items, at most a valley's view (towns named around it).
    static func zoom(for station: TourStation, size: CGSize) -> Double {
        let coordinates = station.items.compactMap(\.coordinate)
        let fitted = MapCamera.fitting(coordinates, in: CGSize(width: size.width * 0.4, height: size.height),
                                       padding: 60, maxZoom: 10)?.zoom ?? 10
        return min(10, max(3, fitted))
    }

    /// Where across the view the place shown stands (the card takes the right).
    static let placeShare = 0.28

    static func camera(from start: MapCamera, to end: MapCamera, at t: Double, size: CGSize) -> MapCamera {
        let s = t * t * (3 - 2 * t)
        var a = WebMercator.unitPoint(start.center)
        let b = WebMercator.unitPoint(end.center)
        if b.x - a.x > 0.5 { a.x += 1 } else if a.x - b.x > 0.5 { a.x -= 1 }
        let unit = CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s)
        let distance = hypot(Double(b.x - a.x), Double(b.y - a.y))
        let middle = (start.zoom + end.zoom) / 2
        // The zoom at which both places fit into the view
        let both = distance > 0 ? log2(max(1, Double(min(size.width, size.height)) * 0.7) / (distance * WebMercator.tileSize)) : middle
        let dip = max(0, middle - both)
        let zoom = start.zoom + (end.zoom - start.zoom) * s - dip * sin(.pi * s)
        return MapCamera(center: WebMercator.coordinate(unit: unit), zoom: max(0, zoom))
    }
}
