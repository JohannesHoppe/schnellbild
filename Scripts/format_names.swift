// The names macOS gives the formats of site/formats.json, in every language of
// the website: `UTType(identifier).localizedDescription` for each entry's
// `uti`, only for types macOS itself declares (the declaring bundle lies in
// /System: a type an installed app declares, VLC's or Chrome's, is left out).
// Written to site/formats-macos.json, which build_site.py shows on the
// formats pages. Run through Scripts/format_names.sh, which builds this with
// an Info.plist: a process without one gets every description in English.
//
//     format_names <repository>               writes site/formats-macos.json
//     format_names --language <repository>    the names in this process's language (JSON)
import CoreServices
import Foundation
import UniformTypeIdentifiers

let languages = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "pl", "sv", "da", "nb", "fi",
                 "cs", "tr", "ru", "uk", "ja", "ko", "zh-Hans", "zh-Hant"]

func types(in repository: URL) throws -> [String] {
    let data = try Data(contentsOf: repository.appendingPathComponent("site/formats.json"))
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let formats = root?["formats"] as? [[String: Any]] ?? []
    return formats.compactMap { $0["uti"] as? String }
}

/// The type's name in this process's language, when macOS declares it.
func name(of identifier: String) -> String? {
    guard let type = UTType(identifier), !type.isDynamic,
          let bundle = UTTypeCopyDeclaringBundleURL(identifier as CFString)?.takeRetainedValue() as URL?,
          bundle.path.hasPrefix("/System/") else { return nil }
    return type.localizedDescription
}

let arguments = Array(CommandLine.arguments.dropFirst().prefix { $0 != "-AppleLanguages" })
if arguments.first == "--language", arguments.count == 2 {
    let repository = URL(fileURLWithPath: arguments[1])
    var names: [String: String] = [:]
    for identifier in try types(in: repository) {
        names[identifier] = name(of: identifier)
    }
    let data = try JSONSerialization.data(withJSONObject: names, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    exit(0)
}
guard arguments.count == 1 else {
    FileHandle.standardError.write("usage: format_names <repository>\n".data(using: .utf8)!)
    exit(2)
}
let repository = URL(fileURLWithPath: arguments[0])
var byType: [String: [String: String]] = [:]
for language in languages {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--language", repository.path, "-AppleLanguages", "(\(language))"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let names = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
        FileHandle.standardError.write("no names for \(language)\n".data(using: .utf8)!)
        exit(1)
    }
    for (identifier, name) in names { byType[identifier, default: [:]][language] = name }
}
let version = ProcessInfo.processInfo.operatingSystemVersion
let output: [String: Any] = [
    "macOS": "\(version.majorVersion).\(version.minorVersion)",
    "names": byType,
]
var data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
data.append(contentsOf: [0x0A])
try data.write(to: repository.appendingPathComponent("site/formats-macos.json"))
print("site/formats-macos.json: \(byType.count) types in \(languages.count) languages, macOS \(output["macOS"]!)")
