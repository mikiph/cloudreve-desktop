import Foundation
import OSLog

/// Lets the host know Finder is actively browsing a drive. Throttled; best effort.
enum FinderActivityHeartbeat {
    static let namespace = "fp-finder-activity"
    static let minimumIntervalMillis: Int64 = 60_000
    private static let logger = Logger(
        subsystem: "cloudreve.desktop.fileprovider", category: "activity")
    private static let lock = NSLock()
    private static var lastWrite: [String: Int64] = [:]

    /// Returns true when a row was written.
    @discardableResult
    static func touch(
        driveID: String, nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        lock.lock()
        if let last = lastWrite[driveID], nowMillis - last < minimumIntervalMillis {
            lock.unlock()
            return false
        }
        lastWrite[driveID] = nowMillis
        lock.unlock()

        do {
            let data = try JSONSerialization.data(withJSONObject: ["at": nowMillis])
            try FileProviderStateDatabase().put(namespace, driveID, data)
            return true
        } catch {
            logger.error(
                "failed to write Finder activity heartbeat: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    static func resetForTests() {
        lock.lock()
        lastWrite.removeAll()
        lock.unlock()
    }
}
