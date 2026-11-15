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

/// The Mac's position through Core Location, only when asked: macOS asks
/// the user the first time (`NSLocationUsageDescription` in Info.plist, the
/// App Sandbox's `com.apple.security.personal-information.location`), then
/// one position is requested (`requestLocation`, no updates after it). The
/// position stays on the Mac: it becomes the distance origin and nothing else.
@MainActor
final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var waiting: CheckedContinuation<Result<GeoPoint, LocationFailure>, Never>?
    private var timeout: Task<Void, Never>?
    /// How long a position may take.
    static let limit: Duration = .seconds(30)

    func currentLocation() async -> Result<GeoPoint, LocationFailure> {
        // (it may wait for the system: not on the main thread)
        let enabled = await Blocking.run(.userInitiated) { CLLocationManager.locationServicesEnabled() }
        guard enabled else { return .failure(.servicesOff) }
        // One request at a time: a second click answers the first one's way
        if let waiting { self.waiting = nil; waiting.resume(returning: .failure(.unavailable)) }
        return await withCheckedContinuation { continuation in
            waiting = continuation
            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            self.manager = manager
            timeout = Task { [weak self] in
                try? await Task.sleep(for: Self.limit)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(.unavailable))
            }
            proceed(manager.authorizationStatus)
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

    private func proceed(_ status: CLAuthorizationStatus) {
        guard let manager else { return }
        if let failure = Self.failure(for: status) { finish(.failure(failure)); return }
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()   // the answer comes to the delegate
        } else {
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result<GeoPoint, LocationFailure>) {
        timeout?.cancel()
        timeout = nil
        manager?.delegate = nil
        manager = nil
        guard let waiting else { return }
        self.waiting = nil
        waiting.resume(returning: result)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.manager === manager, status != .notDetermined else { return }
            self.proceed(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in
            guard self.manager === manager else { return }
            if let coordinate, let point = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude) {
                self.finish(.success(point))
            } else {
                self.finish(.failure(.unavailable))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        let unknown = (error as? CLError)?.code == .locationUnknown
        Task { @MainActor in
            guard self.manager === manager else { return }
            // "Unknown" for now: Core Location keeps trying until the time is up
            if unknown { return }
            self.finish(.failure(denied ? .denied : .unavailable))
        }
    }
}
