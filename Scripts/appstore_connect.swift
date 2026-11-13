// Puts the App Store texts and screenshots (AppStore/metadata, AppStore/screenshots)
// into App Store Connect through its API, for the version in Resources/Info.plist,
// and with --build picks the uploaded build for that version. Nothing is submitted
// for review: that stays a click in App Store Connect.
//
//   swift Scripts/appstore_connect.swift metadata [--build]
//
// Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the API key's .p8; a key with
// the role App Manager or Admin). Optional ASC_REVIEW_CONTACT, a JSON object with
// firstName, lastName, phone, email, for a version that has no review contact yet.
// Run by appstore.yml (-f metadata=true).
import Foundation
import CryptoKit

// MARK: - Setup

let env = ProcessInfo.processInfo.environment
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}
func say(_ message: String) { print(message); fflush(stdout) }

guard CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "metadata" else {
    fail("usage: swift Scripts/appstore_connect.swift metadata [--build]")
}
let pickBuild = CommandLine.arguments.contains("--build")
guard let keyID = env["ASC_KEY_ID"], let issuer = env["ASC_ISSUER_ID"], let keyPath = env["ASC_KEY_PATH"] else {
    fail("ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH are needed")
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let metadata = root.appendingPathComponent("AppStore/metadata")

func readJSON(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail("can't read \(url.path)") }
    return object
}
let app = readJSON(metadata.appendingPathComponent("app.json"))
func setting(_ key: String) -> String {
    guard let value = app[key] as? String else { fail("app.json has no \(key)") }
    return value
}
guard let info = NSDictionary(contentsOf: root.appendingPathComponent("Resources/Info.plist")),
      let versionString = info["CFBundleShortVersionString"] as? String,
      let buildNumber = info["CFBundleVersion"] as? String else { fail("can't read Resources/Info.plist") }

func text(_ locale: String, _ field: String) -> String? {
    let url = metadata.appendingPathComponent("\(locale)/\(field).txt")
    guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
let locales = ((try? FileManager.default.contentsOfDirectory(atPath: metadata.path)) ?? [])
    .filter { $0.contains("-") && !$0.hasPrefix(".") }.sorted()

// MARK: - API

let privateKey: P256.Signing.PrivateKey = {
    guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { fail("can't read the key at ASC_KEY_PATH") }
    return key
}()

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
// A token for at most 20 minutes, made again before it runs out.
var token = ""
var tokenMade = Date.distantPast
func bearer() throws -> String {
    if Date().timeIntervalSince(tokenMade) < 15 * 60 { return token }
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let claims = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"])
    let input = base64URL(header) + "." + base64URL(claims)
    let signature = try privateKey.signature(for: Data(input.utf8))
    token = input + "." + base64URL(signature.rawRepresentation)
    tokenMade = Date()
    return token
}

typealias JSON = [String: Any]

@discardableResult
func api(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
    let url = path.hasPrefix("https://") ? URL(string: path)! : URL(string: "https://api.appstoreconnect.apple.com" + path)!
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(try bearer())", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let object = (try? JSONSerialization.jsonObject(with: data) as? JSON) ?? [:]
    guard (200..<300).contains(status) else {
        let errors = (object["errors"] as? [JSON] ?? []).map { "\($0["title"] ?? ""): \($0["detail"] ?? "")" }
        let hint = status == 403 ? " (the API key's role may be too low: App Manager or Admin is needed)" : ""
        fail("\(method) \(url.path) → \(status)\(hint)\n  " + (errors.isEmpty ? String(decoding: data, as: UTF8.self) : errors.joined(separator: "\n  ")))
    }
    return object
}

func items(_ object: JSON) -> [JSON] { object["data"] as? [JSON] ?? [] }
func id(_ item: JSON) -> String { item["id"] as? String ?? "" }
func attributes(_ item: JSON) -> JSON { item["attributes"] as? JSON ?? [:] }
func relation(_ type: String, _ id: String) -> JSON { ["data": ["type": type, "id": id]] }
func query(_ path: String, _ parameters: [String: String]) -> String {
    var components = URLComponents()
    components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    return path + "?" + (components.percentEncodedQuery ?? "")
}

/// Sets the attributes of an item, or makes it (with the relationship) if there is none.
/// `creating` adds attributes only a new item gets (its locale, platform).
@discardableResult
func upsert(_ type: String, existing: JSON?, attributes values: JSON, creating: JSON = [:], create relationships: JSON) async throws -> JSON {
    if let existing {
        let current = attributes(existing)
        let changed = values.filter { key, value in "\(current[key] ?? "")" != "\(value)" }
        if changed.isEmpty { return existing }
        let result = try await api("PATCH", "/v1/\(type)/\(id(existing))",
                                   ["data": ["type": type, "id": id(existing), "attributes": changed]])
        return result["data"] as? JSON ?? existing
    }
    let result = try await api("POST", "/v1/\(type)",
                               ["data": ["type": type, "attributes": values.merging(creating) { a, _ in a }, "relationships": relationships]])
    return result["data"] as? JSON ?? [:]
}

// MARK: - Run

let editableStates: Set<String> = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]

let bundleID = setting("bundleId")
guard let appID = items(try await api("GET", query("/v1/apps", ["filter[bundleId]": bundleID]))).first.map(id) else {
    fail("no app with the bundle ID \(bundleID) in App Store Connect")
}
say("App \(bundleID) (\(appID)), version \(versionString) (\(buildNumber))")

// The version: the one being prepared gets this version string, or a new one is made.
let versions = items(try await api("GET", query("/v1/apps/\(appID)/appStoreVersions", ["filter[platform]": "MAC_OS", "limit": "50"])))
func state(_ version: JSON) -> String { attributes(version)["appStoreState"] as? String ?? attributes(version)["appVersionState"] as? String ?? "" }
let firstInStore = versions.allSatisfy { editableStates.contains(state($0)) }
let version = try await upsert("appStoreVersions",
    existing: versions.first { editableStates.contains(state($0)) },
    attributes: ["versionString": versionString, "copyright": setting("copyright")],
    creating: ["platform": "MAC_OS"],
    create: ["app": relation("apps", appID)])
let versionID = id(version)
say("Version \(versionString): \(state(version).isEmpty ? "made" : state(version))\(firstInStore ? ", the first in the Store (no What's New)" : "")")

// Name, subtitle, privacy policy, categories (the app's information being prepared).
let infos = items(try await api("GET", "/v1/apps/\(appID)/appInfos"))
guard let appInfo = infos.first(where: { editableStates.contains(state($0)) }) ?? infos.first else { fail("the app has no app information") }
try await api("PATCH", "/v1/appInfos/\(id(appInfo))", ["data": ["type": "appInfos", "id": id(appInfo), "relationships": [
    "primaryCategory": relation("appCategories", setting("primaryCategory")),
    "secondaryCategory": relation("appCategories", setting("secondaryCategory")),
]]])
let infoLocalizations = items(try await api("GET", "/v1/appInfos/\(id(appInfo))/appInfoLocalizations"))
for locale in locales {
    var values: JSON = ["privacyPolicyUrl": setting("privacyPolicyUrl")]
    if let name = text(locale, "name") { values["name"] = name }
    if let subtitle = text(locale, "subtitle") { values["subtitle"] = subtitle }
    try await upsert("appInfoLocalizations",
        existing: infoLocalizations.first { attributes($0)["locale"] as? String == locale },
        attributes: values, creating: ["locale": locale],
        create: ["appInfo": relation("appInfos", id(appInfo))])
    say("  \(locale): name, subtitle, privacy policy")
}

// Description, keywords, promotional text, URLs, What's New; then the screenshots.
let versionLocalizations = items(try await api("GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations"))
let screenshotDirectories = app["screenshots"] as? [String: String] ?? [:]
for locale in locales {
    let existing = versionLocalizations.first { attributes($0)["locale"] as? String == locale }
    var values: JSON = ["supportUrl": setting("supportUrl"), "marketingUrl": setting("marketingUrl")]
    for (field, key) in [("description", "description"), ("keywords", "keywords"), ("promotional_text", "promotionalText")] {
        if let value = text(locale, field) { values[key] = value }
    }
    if !firstInStore, let notes = text(locale, "release_notes") { values["whatsNew"] = notes }
    let localization = try await upsert("appStoreVersionLocalizations", existing: existing, attributes: values,
                                        creating: ["locale": locale], create: ["appStoreVersion": relation("appStoreVersions", versionID)])
    say("  \(locale): description, keywords, promotional text, URLs\(values["whatsNew"] == nil ? "" : ", What's New")")
    if let directory = screenshotDirectories[locale] {
        try await screenshots(for: id(localization), from: root.appendingPathComponent(directory), locale: locale)
    }
}

/// Makes the Mac screenshots of a localization those in the folder, in name order;
/// only if they differ (by checksum), so an unchanged set isn't uploaded again.
func screenshots(for localizationID: String, from folder: URL, locale: String) async throws {
    let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else { say("  \(locale): no screenshots in \(folder.path)"); return }
    let local = try files.map { try Data(contentsOf: $0) }
    let checksums = local.map { Insecure.MD5.hash(data: $0).map { String(format: "%02x", $0) }.joined() }

    let sets = items(try await api("GET", "/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets"))
    var set = sets.first { attributes($0)["screenshotDisplayType"] as? String == "APP_DESKTOP" } ?? [:]
    if set.isEmpty {
        set = try await upsert("appScreenshotSets", existing: nil, attributes: ["screenshotDisplayType": "APP_DESKTOP"],
                               create: ["appStoreVersionLocalization": relation("appStoreVersionLocalizations", localizationID)])
    }
    let current = items(try await api("GET", "/v1/appScreenshotSets/\(id(set))/appScreenshots"))
    if current.map({ attributes($0)["sourceFileChecksum"] as? String ?? "" }) == checksums {
        say("  \(locale): \(files.count) screenshots, unchanged"); return
    }
    for shot in current { try await api("DELETE", "/v1/appScreenshots/\(id(shot))") }
    for (index, file) in files.enumerated() {
        let reservation = try await upsert("appScreenshots", existing: nil,
            attributes: ["fileName": file.lastPathComponent, "fileSize": local[index].count],
            create: ["appScreenshotSet": relation("appScreenshotSets", id(set))])
        for operation in attributes(reservation)["uploadOperations"] as? [JSON] ?? [] {
            guard let urlString = operation["url"] as? String, let url = URL(string: urlString),
                  let offset = operation["offset"] as? Int, let length = operation["length"] as? Int else { fail("unexpected upload operation") }
            var request = URLRequest(url: url)
            request.httpMethod = operation["method"] as? String ?? "PUT"
            for header in operation["requestHeaders"] as? [JSON] ?? [] {
                if let name = header["name"] as? String, let value = header["value"] as? String { request.setValue(value, forHTTPHeaderField: name) }
            }
            let (_, response) = try await URLSession.shared.upload(for: request, from: local[index].subdata(in: offset..<(offset + length)))
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { fail("upload of \(file.lastPathComponent) failed") }
        }
        try await api("PATCH", "/v1/appScreenshots/\(id(reservation))", ["data": ["type": "appScreenshots", "id": id(reservation),
            "attributes": ["uploaded": true, "sourceFileChecksum": checksums[index]]]])
    }
    say("  \(locale): \(files.count) screenshots uploaded")
}

// Notes for the review (and the contact, if the version has none yet).
if let notes = try? String(contentsOf: metadata.appendingPathComponent("review_notes.txt"), encoding: .utf8) {
    let detail = try await api("GET", "/v1/appStoreVersions/\(versionID)/appStoreReviewDetail")
    var values: JSON = ["notes": notes.trimmingCharacters(in: .whitespacesAndNewlines), "demoAccountRequired": false]
    let existing = detail["data"] as? JSON
    if existing == nil, let contact = env["ASC_REVIEW_CONTACT"],
       let fields = try? JSONSerialization.jsonObject(with: Data(contact.utf8)) as? [String: String] {
        for (key, field) in [("contactFirstName", "firstName"), ("contactLastName", "lastName"), ("contactPhone", "phone"), ("contactEmail", "email")] {
            values[key] = fields[field]
        }
    }
    try await upsert("appStoreReviewDetails", existing: existing, attributes: values,
                     create: ["appStoreVersion": relation("appStoreVersions", versionID)])
    say("Review notes set\(existing == nil && env["ASC_REVIEW_CONTACT"] == nil ? " (enter the review contact once in App Store Connect)" : "")")
}

// The build: waits until Apple has processed the upload, then picks it.
if pickBuild {
    say("Waiting for build \(buildNumber) of \(versionString) …")
    var build: JSON?
    for _ in 0..<60 {
        build = items(try await api("GET", query("/v1/builds", [
            "filter[app]": appID, "filter[version]": buildNumber,
            "filter[preReleaseVersion.version]": versionString, "filter[processingState]": "VALID",
        ]))).first
        if build != nil { break }
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
    guard let build else { fail("build \(buildNumber) isn't processed after an hour; pick it in App Store Connect later") }
    try await api("PATCH", "/v1/appStoreVersions/\(versionID)/relationships/build", relation("builds", id(build)))
    say("Build \(buildNumber) picked for \(versionString)")
    if attributes(build)["usesNonExemptEncryption"] == nil || attributes(build)["usesNonExemptEncryption"] is NSNull {
        say("Note: the build's export compliance (encryption) is still to be answered in App Store Connect")
    }
}
say("Done. Submit for review in App Store Connect.")
