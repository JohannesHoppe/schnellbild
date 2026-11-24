import XCTest
@testable import Schnellbild

/// CI (.github/workflows/ci.yml) runs only for changes its `paths` filter lets
/// through. It must run for every file the build and the tests read, and stay
/// away from the website, texts and the scripts that only make site or data
/// files. The filter is evaluated here as GitHub does: the last pattern a path
/// matches decides, `!` excludes, `*` stops at `/`, `**` doesn't.
@MainActor
final class CIPathsTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }

    /// The `paths` lists of `push` and `pull_request`, in order.
    private func filters() throws -> [[String]] {
        var lists: [[String]] = []
        var current: [String]?
        for line in try text(".github/workflows/ci.yml").components(separatedBy: "\n") {
            if line.hasPrefix("jobs:") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "paths:" { current = []; continue }
            guard current != nil else { continue }
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- ") {
                let pattern = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
                current?.append(pattern)
            } else {
                lists.append(current ?? [])
                current = nil
            }
        }
        if let current { lists.append(current) }
        return lists
    }

    private func pattern(_ glob: String) -> NSRegularExpression {
        var regex = "^"
        var rest = Substring(glob)
        while let character = rest.first {
            if rest.hasPrefix("**") {
                regex += ".*"
                rest = rest.dropFirst(2)
            } else if character == "*" {
                regex += "[^/]*"
                rest = rest.dropFirst()
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(character))
                rest = rest.dropFirst()
            }
        }
        return try! NSRegularExpression(pattern: regex + "$")
    }

    /// Whether a change to `path` starts CI under `filter`.
    private func runs(_ path: String, _ filter: [String]) -> Bool {
        var included = false
        for entry in filter {
            let negated = entry.hasPrefix("!")
            let glob = negated ? String(entry.dropFirst()) : entry
            let range = NSRange(path.startIndex..., in: path)
            if pattern(glob).firstMatch(in: path, range: range) != nil { included = !negated }
        }
        return included
    }

    private func filter() throws -> [String] {
        let lists = try filters()
        XCTAssertEqual(lists.count, 2, "push and pull_request each have a paths filter")
        XCTAssertEqual(lists.first, lists.last, "push and pull_request filter the same paths")
        let filter = try XCTUnwrap(lists.first)
        for entry in filter {
            XCTAssertNil(entry.rangeOfCharacter(from: CharacterSet(charactersIn: "?+[]{}")),
                         "\(entry): only * and ** are evaluated here")
        }
        return filter
    }

    /// Every file below `path` (or `path` itself), relative to the repository;
    /// a path with `*` (a test's pattern, "Scripts/*.sh") the files it matches.
    private func files(at path: String) -> [String] {
        if let star = path.firstIndex(of: "*") {
            // The folder before the first `*`, its files filtered by the pattern
            let folder = (String(path[..<star]) as NSString).deletingLastPathComponent
            let glob = pattern(path)
            return files(at: folder).filter { glob.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
        let url = repository.appendingPathComponent(path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return [] }
        guard isFolder.boolValue else { return [path] }
        let base = url.resolvingSymlinksInPath().path
        let folder = path.hasSuffix("/") ? String(path.dropLast()) : path
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        var found: [String] = []
        while let item = walk?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            found.append(folder + item.resolvingSymlinksInPath().path.dropFirst(base.count))
        }
        return found
    }

    /// The scripts the CI jobs run: the `Scripts/…` named outside comments in
    /// ci.yml's jobs, and in each shell script they run, on down.
    private func scriptsCIRuns() throws -> Set<String> {
        let jobs = try text(".github/workflows/ci.yml").components(separatedBy: "\njobs:\n").last ?? ""
        let reference = try NSRegularExpression(pattern: #"Scripts/[A-Za-z0-9_./-]*[A-Za-z0-9_]"#)
        func references(in source: String) -> [String] {
            source.components(separatedBy: "\n").flatMap { line -> [String] in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") { return [] }
                let code = line.components(separatedBy: " # ").first ?? line
                return reference.matches(in: code, range: NSRange(code.startIndex..., in: code))
                    .compactMap { Range($0.range, in: code).map { String(code[$0]) } }
            }
        }
        var seen = Set<String>()
        var pending = references(in: jobs)
        while let script = pending.popLast() {
            guard seen.insert(script).inserted else { continue }
            if script.hasSuffix(".sh"), let source = try? text(script) { pending += references(in: source) }
        }
        return seen
    }

    /// The repository paths named in the tests' sources (up to an
    /// interpolation), each a file or a folder whose files they read.
    private func pathsTheTestsName() throws -> Set<String> {
        let topLevel = Set(try FileManager.default.contentsOfDirectory(atPath: repository.path))
            .subtracting([".git", ".build", "build", "Vendor", "dist"])
        let literal = try NSRegularExpression(pattern: #""([A-Za-z.][^"\\]*)"#)
        var named = Set<String>()
        for folder in ["Tests", "UITests"] {
            // This file names paths to check the filter with, not to read them
            for file in files(at: folder) where file.hasSuffix(".swift") && !file.hasSuffix("/CIPathsTests.swift") {
                let source = try text(file)
                for match in literal.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    guard let range = Range(match.range(at: 1), in: source) else { continue }
                    let path = String(source[range])
                    guard let first = path.split(separator: "/").first, topLevel.contains(String(first)) else { continue }
                    named.insert(path)
                }
            }
        }
        return named
    }

    func testCIRunsForEveryScriptItRuns() throws {
        let filter = try filter()
        let scripts = try scriptsCIRuns()
        XCTAssertTrue(scripts.contains("Scripts/build_app.sh"))
        XCTAssertTrue(scripts.contains("Scripts/fetch_verified.sh"), "found through fetch_vlckit.sh's scripts")
        for script in scripts {
            let paths = files(at: script)
            XCTAssertFalse(paths.isEmpty, "\(script), run by CI, isn't in the repository")
            for path in paths {
                XCTAssertTrue(runs(path, filter), "a change to \(path), which CI runs, doesn't start CI")
            }
        }
        for path in [".github/workflows/ci.yml", ".github/actions/vendor-cache/action.yml", "Package.swift", "project.yml", "Resources/Info.plist",
                     "Schnellbild/BrowserModel.swift", "LICENSE", "Tests/SchnellbildTests/CIPathsTests.swift"] {
            XCTAssertTrue(runs(path, filter), "a change to \(path) doesn't start CI")
        }
    }

    func testCIRunsForEveryFileTheTestsRead() throws {
        let filter = try filter()
        // The website: only the privacy policy pages the About window links
        let languages = try FileManager.default.contentsOfDirectory(atPath: repository.appendingPathComponent("Resources/Localization").path)
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }
        XCTAssertEqual(languages.count, 20)
        for language in languages {
            let page = AboutPanel.privacyPolicy(for: language)
                .replacingOccurrences(of: "https://schnellbild.haushoppe-its.de/", with: "docs/") + "index.html"
            XCTAssertTrue(runs(page, filter), "\(language): a change to \(page), which AboutPanelTests reads, doesn't start CI")
        }
        let named = try pathsTheTestsName()
        XCTAssertTrue(named.contains("LICENSE"))
        XCTAssertTrue(named.contains("Scripts/fetch_vlckit.sh"))
        // docs/ itself is named only to turn the website's address into the
        // folder of its pages: the tests read the privacy pages above
        for path in named where path != "docs" && !path.hasPrefix("docs/") {
            // A folder's README describes its files; no test reads it
            for file in files(at: path) where file == path || !file.hasSuffix("/README.md") {
                XCTAssertTrue(runs(file, filter), "a change to \(file), which the tests read (\(path)), doesn't start CI")
            }
        }
    }

    func testCIStaysAwayFromTheWebsiteTextsAndDataScripts() throws {
        let filter = try filter()
        var skipped = ["README.md", "CLAUDE.md", "BUILDING.md", "docs/index.html", "docs/de/index.html", "docs/site.css",
                       "docs/screenshots/grid-light.webp", "docs/de/datenschutz/other.html", "site/i18n/en.json",
                       "AppStore/metadata/app.json", "Spike/MediaExtension/Reader.swift",
                       "Scripts/build_site.py", "Scripts/site_alternatives.py", "Scripts/make_site_images.py",
                       "Scripts/make_video_animation.py", "Scripts/build_map_data.py", "Scripts/build_globe_data.py",
                       "Scripts/build_world_photos.py", "Scripts/world_photos.env"]
        skipped += try FileManager.default.contentsOfDirectory(atPath: repository.appendingPathComponent(".github/workflows").path)
            .filter { $0 != "ci.yml" }.map { ".github/workflows/" + $0 }
        for path in skipped {
            XCTAssertFalse(runs(path, filter), "a change to \(path) alone starts CI")
        }
    }
}
