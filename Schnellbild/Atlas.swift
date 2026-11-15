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
    /// When it was taken (`CaptureFacts`), else the file's modification date.
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
                         coordinate: place.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) },
                         date: time?.date ?? modified ?? .distantPast,
                         offset: time?.isCameraClock == false ? time?.offset : nil,
                         hasCaptureTime: time != nil,
                         timeIsUTC: time.map { !$0.isCameraClock && $0.offset == nil } ?? false,
                         track: facts?.track?.points.map { Coordinate(latitude: $0.point.latitude, longitude: $0.point.longitude) } ?? [])
    }
}

enum AtlasItems {
    /// The items in the order of time (the path where two share one), and
    /// a time read in UTC (a movie header, GoPro's GPS) without an offset
    /// given the offset of the nearest item within a day that states one, so
    /// a video shows the same local time as the photos around it.
    static func prepared(_ items: [AtlasItem]) -> [AtlasItem] {
        var sorted = items.sorted { $0.date != $1.date ? $0.date < $1.date : $0.url.path < $1.url.path }
        let stated = sorted.compactMap { item in item.offset.map { (date: item.date, offset: $0) } }
        guard !stated.isEmpty else { return sorted }
        for index in sorted.indices where sorted[index].offset == nil && sorted[index].timeIsUTC {
            let date = sorted[index].date
            let nearest = stated.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }!
            if abs(nearest.date.timeIntervalSince(date)) <= 86_400 { sorted[index].offset = nearest.offset }
        }
        return sorted
    }

    /// The calendar day an item was taken on, by its own clock.
    static func day(of item: AtlasItem) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = item.zone
        return calendar.dateComponents([.year, .month, .day], from: item.date)
    }
}

// MARK: - Clusters

/// Items close together on screen drawn as one tile with their count.
struct AtlasCluster: Equatable, Sendable, Identifiable {
    /// The items, in the order of time.
    var ids: [URL]
    /// Where the tile stands: the middle of its items (in the map's projection).
    var coordinate: Coordinate
    var id: URL { ids[0] }
    var count: Int { ids.count }
}

enum AtlasClustering {
    /// Tiles closer than this (points) join one cluster.
    static let spacing = 58.0

    /// Greedy clustering in screen space at a zoom: in the given order (by
    /// time), each item joins the cluster whose first item lies nearest
    /// within `spacing`, else starts one. Distances are measured in the
    /// map's world points at that zoom, so moving the map changes nothing
    /// and only a zoom asks again. A grid of `spacing` cells finds the
    /// neighbours, so thousands of items take milliseconds.
    static func clusters(of points: [(id: URL, coordinate: Coordinate)], zoom: Double,
                         spacing: Double = spacing) -> [AtlasCluster] {
        let world = WebMercator.worldSize(zoom: zoom)
        struct Building { var ids: [URL]; var leader: CGPoint; var sum: CGPoint }
        var built: [Building] = []
        var cells: [Int64: [Int]] = [:]
        func key(_ x: Int64, _ y: Int64) -> Int64 { x &* 1_000_003 &+ y }
        for point in points {
            let unit = WebMercator.unitPoint(point.coordinate)
            let p = CGPoint(x: unit.x * world, y: unit.y * world)
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
                built[best.index].ids.append(point.id)
                built[best.index].sum.x += unit.x
                built[best.index].sum.y += unit.y
            } else {
                cells[key(cx, cy), default: []].append(built.count)
                built.append(Building(ids: [point.id], leader: p, sum: unit))
            }
        }
        return built.map { cluster in
            let n = CGFloat(cluster.ids.count)
            return AtlasCluster(ids: cluster.ids,
                                coordinate: WebMercator.coordinate(unit: CGPoint(x: cluster.sum.x / n, y: cluster.sum.y / n)))
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
    /// From the first to the last item's time; nil without items.
    static func span(of items: [AtlasItem]) -> ClosedRange<Date>? {
        guard let first = items.map(\.date).min(), let last = items.map(\.date).max() else { return nil }
        return first...last
    }

    /// The items whose time lies in the range (all of them without one).
    static func filter(_ items: [AtlasItem], to range: ClosedRange<Date>?) -> [AtlasItem] {
        guard let range else { return items }
        return items.filter { range.contains($0.date) }
    }

    /// How many items fall into each of `bins` equal parts of the span.
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
        let placed = AtlasItems.prepared(items.filter { $0.coordinate != nil })
        var stations: [TourStation] = []
        var current: [AtlasItem] = []
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
            if let first = current.first,
               AtlasItems.day(of: first) != AtlasItems.day(of: item) || first.coordinate!.distance(to: item.coordinate!) > radius {
                close()
            }
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
    /// The zoom a station is shown at: its items, at most a town's view.
    static func zoom(for station: TourStation, size: CGSize) -> Double {
        let coordinates = station.items.compactMap(\.coordinate)
        let fitted = MapCamera.fitting(coordinates, in: size, padding: 120, maxZoom: 11)?.zoom ?? 11
        return min(11, max(3, fitted))
    }

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
