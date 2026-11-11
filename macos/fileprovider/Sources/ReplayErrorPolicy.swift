import Foundation
import FileProvider

/// How change replay treats a failure for a single event.
enum ReplayFailure: Equatable {
    /// Retrying may succeed (network, server 5xx, rate limit). Fail the page; the anchor must not advance.
    case transient
    /// The server definitively rejected this event's lookup. Skip the event and request a bounded refresh.
    case permanent
    /// Credentials are invalid. Fail the page as notAuthenticated.
    case authentication
    /// The operation was cancelled. Fail the page as user-cancelled.
    case cancelled

    static func classify(_ error: Error) -> ReplayFailure {
        if error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || (error as? CocoaError)?.code == .userCancelled {
            return .cancelled
        }
        if let error = error as? CloudreveError {
            switch error {
            case .notAuthenticated:
                return .authentication
            case .http(let status):
                // HTTP 404 is a routing/proxy problem (Cloudreve reports
                // missing objects as envelope codes), so it is transient.
                return status == 404 || status == 429 || status >= 500 ? .transient : .permanent
            case .invalidEnvelope:
                // The server did not speak Cloudreve (proxy page, outage).
                return .transient
            case .api(let code, _):
                return code >= 50000 ? .transient : .permanent
            case .badResponse, .nameCollision, .staleVersion, .lockConflict,
                .unsupportedPackage, .unsupportedStoragePolicy, .noSuchItem:
                return .permanent
            }
        }
        if error is URLError { return .transient }
        if error is DecodingError { return .permanent }
        // NSFileProviderError and anything unknown: prefer not losing events.
        return .transient
    }
}
