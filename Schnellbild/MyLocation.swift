import Foundation
import CoreLocation

/// Why the Mac's position isn't there.
enum LocationFailure: Error, Equatable, Sendable {
    /// The user said no (or said no before), in the prompt or in System Settings.
    case denied
    /// A profile or parental controls keep location from apps.
    case restricted
    /// Location Services are off for the whole Mac.
    case servicesOff
    /// Asked and allowed, but no position came (no Wi-Fi nearby, a timeout).
    case unavailable

    /// What the sheet says, with where to change it.
    var message: String {
        switch self {
        case .denied:
            return String(localized: "Schnellbild may not use your location. Allow it in System Settings → Privacy & Security → Location Services.")
        case .restricted:
            return String(localized: "Location is restricted on this Mac.")
        case .servicesOff:
            return String(localized: "Location Services are off. Turn them on in System Settings → Privacy & Security → Location Services.")
        case .unavailable:
            return String(localized: "Your location can't be found right now.")
        }
    }
}

/// Where the Mac is, asked for once (the sorting sheet's Use My Location).
/// A protocol so tests stand in for macOS.
@MainActor
protocol LocationProvider: AnyObject {
    func currentLocation() async -> Result<GeoPoint, LocationFailure>
}

/// What `CoreLocationProvider` asks of Core Location, one request each
/// (tests stand in). Its answers go to the provider's `authorizationChanged`,
/// `located` and `failed`.
@MainActor
protocol LocationRequester: AnyObject {
    var status: CLAuthorizationStatus { get }
    /// macOS asks the user (the first time).
    func askPermission()
    /// One position (`requestLocation`, no updates after it).
    func requestPosition()
    /// No more answers from it.
    func stop()
}

/// The Mac's position through Core Location, only when asked: macOS asks
/// the user the first time (`NSLocationUsageDescription` in Info.plist, the
/// App Sandbox's `com.apple.security.personal-information.location`), then
/// one position is requested (`requestLocation`, no updates after it). The
/// position stays on the Mac: it becomes the distance origin and nothing else.
/// The time limit runs from the request for the position, not while macOS
/// asks the user; a second click ends the first request at once and gets a
/// limit of its own.
@MainActor
final class CoreLocationProvider: LocationProvider {
    /// How long a position may take.
    nonisolated static let limit: Duration = .seconds(30)

    typealias Wait = @Sendable (Duration) async -> Void
    private let limit: Duration
    private let servicesEnabled: @Sendable () async -> Bool
    private let wait: Wait
    private let makeRequester: @MainActor (CoreLocationProvider) -> LocationRequester
    private var requester: LocationRequester?
    private var requested = false
    private var waiting: CheckedContinuation<Result<GeoPoint, LocationFailure>, Never>?
    private var timeout: Task<Void, Never>?

    init(limit: Duration = CoreLocationProvider.limit,
         // (it may wait for the system: not on the main thread)
         servicesEnabled: @escaping @Sendable () async -> Bool = { await Blocking.run(.userInitiated) { CLLocationManager.locationServicesEnabled() } },
         wait: @escaping Wait = { try? await Task.sleep(for: $0) },
         makeRequester: @escaping @MainActor (CoreLocationProvider) -> LocationRequester = { SystemLocationRequester(provider: $0) }) {
        self.limit = limit
        self.servicesEnabled = servicesEnabled
        self.wait = wait
        self.makeRequester = makeRequester
    }

    func currentLocation() async -> Result<GeoPoint, LocationFailure> {
        guard await servicesEnabled() else { return .failure(.servicesOff) }
        // One request at a time: a second click answers the first one's way
        finish(.failure(.unavailable))
        return await withCheckedContinuation { continuation in
            waiting = continuation
            requested = false
            let requester = makeRequester(self)
            self.requester = requester
            proceed(requester.status, on: requester)
        }
    }

    /// What a state of the user's permission means for the request: nil
    /// to go on (ask, or request the position). On macOS a granted request
    /// reads `.authorizedAlways` (`authorizedWhenInUse` is unavailable there).
    nonisolated static func failure(for status: CLAuthorizationStatus) -> LocationFailure? {
        switch status {
        case .denied: return .denied
        case .restricted: return .restricted
        default: return nil
        }
    }

    private func proceed(_ status: CLAuthorizationStatus, on requester: LocationRequester) {
        if let failure = Self.failure(for: status) { finish(.failure(failure)); return }
        if status == .notDetermined {
            requester.askPermission()   // the answer comes to `authorizationChanged`
        } else if !requested {
            requested = true
            startTimer()
            requester.requestPosition()
        }
    }

    private func startTimer() {
        timeout?.cancel()
        let wait = self.wait, limit = self.limit
        timeout = Task { [weak self] in
            await wait(limit)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(.unavailable))
        }
    }

    private func finish(_ result: Result<GeoPoint, LocationFailure>) {
        timeout?.cancel()
        timeout = nil
        requester?.stop()
        requester = nil
        guard let waiting else { return }
        self.waiting = nil
        waiting.resume(returning: result)
    }

    /// The user answered (or the permission changed).
    func authorizationChanged(_ status: CLAuthorizationStatus, from requester: LocationRequester) {
        guard self.requester === requester, status != .notDetermined else { return }
        proceed(status, on: requester)
    }

    /// The position came (nil: none that reads as one).
    func located(_ point: GeoPoint?, from requester: LocationRequester) {
        guard self.requester === requester else { return }
        finish(point.map { .success($0) } ?? .failure(.unavailable))
    }

    /// The request failed. A one-shot request that finds no position ends
    /// with "location unknown" (CLLocationManager.h on `requestLocation`):
    /// that is the end of it, not a "still trying" as for continuous updates.
    func failed(_ code: CLError.Code?, from requester: LocationRequester) {
        guard self.requester === requester else { return }
        finish(.failure(code == .denied ? .denied : .unavailable))
    }
}

/// Core Location's manager for one request, its answers handed to the provider.
@MainActor
final class SystemLocationRequester: NSObject, LocationRequester, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private weak var provider: CoreLocationProvider?

    init(provider: CoreLocationProvider) {
        self.provider = provider
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    func askPermission() { manager.requestWhenInUseAuthorization() }
    func requestPosition() { manager.requestLocation() }
    func stop() { manager.delegate = nil }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.provider?.authorizationChanged(status, from: self) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let point = locations.last.flatMap { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        Task { @MainActor in self.provider?.located(point, from: self) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        Task { @MainActor in self.provider?.failed(code, from: self) }
    }
}
