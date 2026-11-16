import Foundation

/// Where each video of the pane's list stood when the user left it (⌘← ⌘→,
/// another tile, back to the grid), so coming back goes on from there.
/// The memory belongs to one folder (or archive; its
/// search results, the Atlas's subfolders and a slideshow started there
/// included): another folder clears it, so a folder opened again starts
/// every video from the beginning. Kept in memory only, one per pane.
struct PlaybackPositions {
    /// A place this close to the start is the start: nothing to go on from.
    static let startMargin = 1.0
    /// A place this close to the end (or the end itself) counts as watched:
    /// the video starts from the beginning again.
    static let endMargin = 3.0

    /// Where a video goes on, and whether it was playing then.
    struct Place: Equatable {
        let seconds: Double
        let playing: Bool
    }

    /// The folder the places belong to (canonical path).
    private(set) var folder: String?
    /// Counts the folders: a video left after the pane went on to another
    /// folder (its view goes a moment later) belongs to none.
    private(set) var list = 0
    private var places: [String: Place] = [:]

    /// The pane shows `folder`: another one than before clears the memory.
    mutating func enter(_ folder: URL) {
        let path = BrowserModel.canonicalPath(folder)
        guard path != self.folder else { return }
        self.folder = path
        list += 1
        places = [:]
    }

    /// The user left the video at `url` at `seconds` (nil: not known yet,
    /// nothing changes). `list` is `self.list` from when it began to play.
    mutating func leave(_ url: URL, at seconds: Double?, length: Double?, playing: Bool, list: Int) {
        guard list == self.list, let seconds, seconds.isFinite else { return }
        let key = BrowserModel.canonicalPath(url)
        let watched = length.map { seconds >= $0 - Self.endMargin } ?? false
        if seconds < Self.startMargin || watched {
            places[key] = nil
        } else {
            places[key] = Place(seconds: seconds, playing: playing)
        }
    }

    /// Where the video at `url` goes on; nil: from the beginning.
    func place(of url: URL) -> Place? { places[BrowserModel.canonicalPath(url)] }

    /// Renamed, moved or trashed by the app: the places follow, as does the
    /// folder when it is the one renamed.
    mutating func follow(_ changes: FileChanges) {
        if let folder { self.folder = changes.path(folder) ?? folder }
        guard !places.isEmpty else { return }
        var followed: [String: Place] = [:]
        for (path, place) in places {
            if let moved = changes.path(path) { followed[moved] = place }
        }
        places = followed
    }
}
