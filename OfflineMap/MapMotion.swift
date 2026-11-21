import AppKit

/// Whether the map and the globe move on their own (glides, a drag's throw,
/// the globe fading out over the flat map): not with Reduce motion. The UI
/// tests set `reduceOverride` (the app's `--reduce-motion`) and read what
/// moved in `counts`.
public enum MapMotion {
    /// Set: taken instead of the system's Reduce motion (set once at launch)
    nonisolated(unsafe) public static var reduceOverride: Bool?
    public static var reduced: Bool { reduceOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Where the map and the globe say what they did when (the app's test log under `--test-log`)
    nonisolated(unsafe) public static var trace: ((String) -> Void)?

    /// How often each kind of movement began ("glide", "throw", "fade"; on the main thread)
    nonisolated(unsafe) public private(set) static var counts: [String: Int] = [:]
    static func began(_ kind: String) { counts[kind, default: 0] += 1 }

    /// How far throws carried the map after the mouse came up, in points of
    /// the drag, all added up (not folded into a turn of the globe; on the main thread)
    nonisolated(unsafe) public private(set) static var thrownPoints = 0.0
    static func threw(_ points: Double) { thrownPoints += points }
}
