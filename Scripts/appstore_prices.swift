// The Mac App Store price per country, through the App Store Connect API.
//
//   swift Scripts/appstore_prices.swift list  <out.json>   # what Apple offers per country
//   swift Scripts/appstore_prices.swift apply               # sets AppStore/metadata/prices.json
//
// `list` writes, for every country, its currency, the price Apple derives from
// the base price by exchange rate (`equalized`) and every price point up to it,
// so `Scripts/price_proposal.py` can pick a price that fits the country's
// purchasing power. `apply` makes the price schedule: the base country with its
// price, every listed country with its own price; the rest follow the base by
// exchange rate (Apple's equalization).
//
// Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (a key with the role App
// Manager or Admin). Run by appstore-prices.yml.
import Foundation
import CryptoKit

let env = ProcessInfo.processInfo.environment
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}
func say(_ message: String) { print(message); fflush(stdout) }

let mode = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : ""
guard mode == "list" && CommandLine.arguments.count == 3 || mode == "apply" else {
    fail("usage: swift Scripts/appstore_prices.swift list <out.json> | apply")
}
guard let keyID = env["ASC_KEY_ID"], let issuer = env["ASC_ISSUER_ID"], let keyPath = env["ASC_KEY_PATH"] else {
    fail("ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH are needed")
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
typealias JSON = [String: Any]
func readJSON(_ path: String) -> JSON {
    guard let data = try? Data(contentsOf: root.appendingPathComponent(path)),
          let object = try? JSONSerialization.jsonObject(with: data) as? JSON else { fail("can't read \(path)") }
    return object
}
let prices = readJSON("AppStore/metadata/prices.json")
guard let base = prices["base"] as? JSON, let baseTerritory = base["territory"] as? String,
      let basePrice = base["price"] as? String else { fail("prices.json needs base.territory and base.price") }
guard let bundleID = readJSON("AppStore/metadata/app.json")["bundleId"] as? String else { fail("app.json has no bundleId") }

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
    token = input + "." + base64URL(try privateKey.signature(for: Data(input.utf8)).rawRepresentation)
    tokenMade = Date()
    return token
}

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
        fail("\(method) \(url.path) → \(status)\n  " + (errors.isEmpty ? String(decoding: data, as: UTF8.self) : errors.joined(separator: "\n  ")))
    }
    return object
}
func items(_ object: JSON) -> [JSON] { object["data"] as? [JSON] ?? [] }
func attributes(_ item: JSON) -> JSON { item["attributes"] as? JSON ?? [:] }
/// Every page of a list.
func all(_ path: String) async throws -> (data: [JSON], included: [JSON]) {
    var next: String? = path
    var data: [JSON] = [], included: [JSON] = []
    while let page = next {
        let object = try await api("GET", page)
        data += items(object)
        included += object["included"] as? [JSON] ?? []
        next = (object["links"] as? JSON)?["next"] as? String
    }
    return (data, included)
}
/// The country of a price point (its relationship, else the territory coded in its id).
func territory(of point: JSON) -> String? {
    ((point["relationships"] as? JSON)?["territory"] as? JSON).flatMap { ($0["data"] as? JSON)?["id"] as? String }
}
func points(in territory: String, appID: String) async throws -> [JSON] {
    try await all("/v1/apps/\(appID)/appPricePoints?filter%5Bterritory%5D=\(territory)&include=territory&limit=200").data
}
func price(_ point: JSON) -> Decimal { Decimal(string: attributes(point)["customerPrice"] as? String ?? "") ?? -1 }

// MARK: - Run

let semaphore = DispatchSemaphore(value: 0)
Task {
  do {
    guard let app = items(try await api("GET", "/v1/apps?filter%5BbundleId%5D=\(bundleID)")).first,
          let appID = app["id"] as? String else { fail("no app with the bundle id \(bundleID)") }
    let basePoints = try await points(in: baseTerritory, appID: appID)
    guard let basePoint = basePoints.first(where: { price($0) == Decimal(string: basePrice) }),
          let basePointID = basePoint["id"] as? String else { fail("\(baseTerritory) has no price point \(basePrice)") }

    if mode == "list" {
        // Apple's price in every other country for the base price, then each country's points up to it
        let equalized = try await all("/v3/appPricePoints/\(basePointID)/equalizations?include=territory&limit=200")
        let currencies = Dictionary(equalized.included.filter { $0["type"] as? String == "territories" }
            .map { ($0["id"] as? String ?? "", attributes($0)["currency"] as? String ?? "") }, uniquingKeysWith: { a, _ in a })
        var out: [String: JSON] = [baseTerritory: ["currency": currencies[baseTerritory] ?? "EUR", "equalized": basePrice, "points": [basePrice]]]
        for point in equalized.data {
            guard let country = territory(of: point) else { continue }
            let limit = price(point)
            let available = try await points(in: country, appID: appID).map(price).filter { $0 > 0 && $0 <= limit }.sorted()
            out[country] = ["currency": currencies[country] ?? "", "equalized": "\(limit)", "points": available.map { "\($0)" }]
            say("\(country) \(currencies[country] ?? "") \(limit): \(available.count) points up to it")
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        say("\(out.count) countries written to \(CommandLine.arguments[2])")
    } else {
        // The schedule: the base price, and each listed country's own price
        let own = prices["territories"] as? [String: String] ?? [:]
        var manual: [(local: String, point: String)] = [("${base}", basePointID)]
        for (country, wanted) in own.sorted(by: { $0.key < $1.key }) {
            guard let point = try await points(in: country, appID: appID).first(where: { price($0) == Decimal(string: wanted) }),
                  let pointID = point["id"] as? String else { fail("\(country) has no price point \(wanted)") }
            manual.append(("${\(country)}", pointID))
        }
        let body: JSON = [
            "data": ["type": "appPriceSchedules", "relationships": [
                "app": ["data": ["type": "apps", "id": appID]],
                "baseTerritory": ["data": ["type": "territories", "id": baseTerritory]],
                "manualPrices": ["data": manual.map { ["type": "appPrices", "id": $0.local] }]]],
            "included": manual.map { ["type": "appPrices", "id": $0.local, "attributes": ["startDate": NSNull()],
                                      "relationships": ["appPricePoint": ["data": ["type": "appPricePoints", "id": $0.point]]]] }]
        try await api("POST", "/v1/appPriceSchedules", body)
        say("Price schedule set: \(baseTerritory) \(basePrice), \(own.count) countries with their own price, the rest by exchange rate")
    }
  } catch { fail("\(error)") }
    semaphore.signal()
}
semaphore.wait()
