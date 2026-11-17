import XCTest

/// What the build and release scripts decide: which release "Finish Mac
/// release" completes (Scripts/unfinished_releases.jq), that a tag names the
/// app's version (Scripts/check_release_version.sh), when a VLCKit of one's
/// own is used as it is (Scripts/check_vlckit.sh), and the scripts' safety rules.
final class BuildScriptsTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func run(_ arguments: [String], input: String = "") throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = repository
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, assets: [String] = []) -> String {
        let names = assets.map { "{\"name\": \"\($0)\"}" }.joined(separator: ", ")
        return "{\"tag_name\": \"\(tag)\", \"prerelease\": \(prerelease), \"draft\": \(draft), \"assets\": [\(names)]}"
    }

    /// An app release waiting for its DMG is found however many data and
    /// VLCKit pre-releases came after it, also on a later page of the list.
    func testFinishMacReleaseFindsTheAppReleaseBehindManyPreReleases() throws {
        var first = (1...30).map { release("globe-202611\($0)", prerelease: true, assets: ["schnellbild-sky.jpg"]) }
        first.insert(release("v0.13.0", draft: true), at: 0)
        first += (1...70).map { release("vlckit-3.7.5-lgpl-\($0)", prerelease: true, assets: ["VLCKit-lgpl.xcframework.zip"]) }
        let second = [release("v0.12.0", assets: ["source.zip"]), release("v0.11.1", assets: ["Schnellbild.dmg"]),
                      release("build-deps", prerelease: true), release("v0.2.0", assets: ["Schnellbild-v0.2.0.zip"])]
        // gh api --paginate writes each page's array, one after the other
        let pages = "[" + first.joined(separator: ",") + "]\n[" + second.joined(separator: ",") + "]\n"
        let result = try run(["jq", "-r", "-f", "Scripts/unfinished_releases.jq"], input: pages)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output.split(separator: "\n"), ["v0.12.0", "v0.2.0"])
    }

    /// A VLCKit that fails the module check stops the build, unless it is one's
    /// own (SCHNELLBILD_OWN_VLCKIT=1, used as it is, as THIRD-PARTY-NOTICES.md
    /// promises) in a build not signed for release.
    func testAnOwnVLCKitIsUsedAsItIsOutsideReleases() throws {
        let clean = ["-u", "SCHNELLBILD_OWN_VLCKIT", "-u", "MACOS_SIGN_IDENTITY", "-u", "APPSTORE_SIGN_IDENTITY"]
        let check = ["Scripts/check_vlckit.sh", "/bin/ls"]   // no VLC modules: fails the check
        let ours = try run(clean + check)
        XCTAssertEqual(ours.status, 1, ours.output)
        let own = try run(clean + ["SCHNELLBILD_OWN_VLCKIT=1"] + check)
        XCTAssertEqual(own.status, 0, own.output)
        XCTAssertTrue(own.output.contains("warning:"), own.output)
        let signed = try run(clean + ["SCHNELLBILD_OWN_VLCKIT=1", "MACOS_SIGN_IDENTITY=Developer ID Application: X"] + check)
        XCTAssertEqual(signed.status, 1, signed.output)
        let store = try run(clean + ["SCHNELLBILD_OWN_VLCKIT=1", "APPSTORE_SIGN_IDENTITY=Apple Distribution: X"] + check)
        XCTAssertEqual(store.status, 1, store.output)
    }

    /// macOS's bash 3.2 ends a script aborted by an unset variable with status
    /// 0 once an EXIT trap runs: every such trap fails unless the script set
    /// `finished` at its end (sign_app.sh's caller would go on with a half-signed app).
    func testEveryExitTrapFailsAScriptThatDidntFinish() throws {
        // CIPathsTests reads the same pattern: CI runs when one of them changes
        let pattern = "Scripts/*.sh"
        let folder = repository.appendingPathComponent((pattern as NSString).deletingLastPathComponent)
        let suffix = String(pattern.split(separator: "*").last ?? "")
        var checked = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(suffix) {
            let source = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            let traps = source.components(separatedBy: "\n").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("trap ") && $0.hasSuffix(" EXIT")
            }
            for trap in traps {
                checked += 1
                XCTAssertTrue(trap.contains("[ -n \"${finished:-}\" ]"), "\(name): \(trap)")
                XCTAssertTrue(source.contains("\nfinished=1\n"), "\(name) never sets finished=1 at its end")
            }
        }
        XCTAssertGreaterThan(checked, 5)
    }

    /// A build leaves the tracked files alone: what build_app.sh writes into
    /// Resources/ is gitignored (the icon's master), the rest goes to build/.
    func testTheAppBuildWritesNoTrackedFile() throws {
        let script = try String(contentsOf: repository.appendingPathComponent("Scripts/build_app.sh"), encoding: .utf8)
        let ignored = Set(try String(contentsOf: repository.appendingPathComponent(".gitignore"), encoding: .utf8)
            .components(separatedBy: "\n"))
        let write = try NSRegularExpression(pattern: #"(?:--out|-o|>|make_icon\.swift)\s+"\$RES/([^"]+)""#)
        let written = write.matches(in: script, range: NSRange(script.startIndex..., in: script))
            .compactMap { Range($0.range(at: 1), in: script).map { "Resources/" + script[$0] } }
        XCTAssertEqual(written, ["Resources/icon_1024.png"])
        for path in written {
            XCTAssertTrue(ignored.contains(path), "build_app.sh writes \(path), which git tracks")
        }
        XCTAssertFalse(script.contains("$(mktemp"), "a temporary folder build_app.sh leaves behind")
    }

    /// The signing material (a .p12 with the private key, its PEM, the API
    /// key) is written for this user only.
    func testSigningFilesAreWrittenForTheUserOnly() throws {
        let source = try String(contentsOf: repository.appendingPathComponent("Scripts/macos-signing.sh"), encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let umask = try XCTUnwrap(lines.firstIndex(of: "umask 077"), "umask 077 at the top level")
        let firstWrite = try XCTUnwrap(lines.firstIndex { $0.contains("RUNNER_TEMP/") && $0.contains(">") })
        XCTAssertLessThan(umask, firstWrite)
        XCTAssertLessThan(umask, try XCTUnwrap(lines.firstIndex { $0.hasPrefix("make_keychain()") }))
    }

    func testTheReleaseTagMustNameTheAppsVersion() throws {
        let plist = repository.appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist))
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        let script = "Scripts/check_release_version.sh"

        let matching = try run([script, "v\(version)"])
        XCTAssertEqual(matching.status, 0, matching.output)
        let other = try run([script, "v\(version).1"])
        XCTAssertEqual(other.status, 1, "a tag that isn't Info.plist's version")
        XCTAssertTrue(other.output.contains("doesn't name the app's version"), other.output)

        // project.yml behind Info.plist (only one of the two bumped)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.createDirectory(at: copy.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: plist, to: copy.appendingPathComponent("Resources/Info.plist"))
        let project = try String(contentsOf: repository.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("MARKETING_VERSION: \"\(version)\""))
        XCTAssertTrue(project.contains("CURRENT_PROJECT_VERSION: \"\(build)\""))
        try project.write(to: copy.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try run([script, "v\(version)", copy.path]).status, 0)

        try project.replacingOccurrences(of: "MARKETING_VERSION: \"\(version)\"", with: "MARKETING_VERSION: \"0.0.1\"")
            .write(to: copy.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        let stale = try run([script, "v\(version)", copy.path])
        XCTAssertEqual(stale.status, 1)
        XCTAssertTrue(stale.output.contains("MARKETING_VERSION"), stale.output)

        try project.replacingOccurrences(of: "CURRENT_PROJECT_VERSION: \"\(build)\"", with: "CURRENT_PROJECT_VERSION: \"0\"")
            .write(to: copy.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        let staleBuild = try run([script, "v\(version)", copy.path])
        XCTAssertEqual(staleBuild.status, 1)
        XCTAssertTrue(staleBuild.output.contains("CURRENT_PROJECT_VERSION"), staleBuild.output)
    }
}
