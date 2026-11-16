import Foundation

/// The endings download tools give a file while it is still being written:
/// "film.mp4.part" is a cut-off "film.mp4" and counts as one everywhere
/// (the grid, the players, archives, thumbnails), with the ending only
/// marking it as not finished. Shared by the app and the thumbnail extension.
public enum DownloadName {
    /// The in-progress endings, lower case: Firefox, JDownloader and
    /// Transmission ".part" (Firefox's `nsIBackgroundFileSaver.idl`,
    /// Transmission's `PartialFileSuffix`), ".partial", Chrome and other
    /// Chromium browsers ".crdownload" (Chromium's `kCrdownloadSuffix`),
    /// Opera ".opdownload", qBittorrent ".!qB" (its `QB_EXT`), µTorrent and
    /// BitTorrent ".!ut" / ".!bt", ".download".
    public static let suffixes = ["part", "partial", "crdownload", "opdownload", "!qb", "!ut", "!bt", "download"]

    /// The name without a download's in-progress ending ("film.mp4.part" →
    /// "film.mp4"); the name itself when it has none.
    public static func finalName(of name: String) -> String {
        let lower = name.lowercased()
        for suffix in suffixes where lower.hasSuffix("." + suffix) && lower.count > suffix.count + 1 {
            return String(name.dropLast(suffix.count + 1))
        }
        return name
    }

    /// Whether the name carries an in-progress ending.
    public static func isPartial(_ name: String) -> Bool { finalName(of: name) != name }

    /// The extension of the name the file will have, lower case
    /// ("film.MP4.part" → "mp4"; "x.part1.rar" → "rar"; "notes.part" → "").
    public static func finalExtension(of url: URL) -> String {
        (finalName(of: url.lastPathComponent) as NSString).pathExtension.lowercased()
    }
}
