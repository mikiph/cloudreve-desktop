import Foundation

@main enum FinderActivityHeartbeatTests {
    static func storedAt(_ driveID: String) -> Int64? {
        guard let data = try? FileProviderStateDatabase().get(FinderActivityHeartbeat.namespace, driveID),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = object["at"] as? NSNumber else { return nil }
        return at.int64Value
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        FinderActivityHeartbeat.resetForTests()

        let t0: Int64 = 1_000_000
        precondition(FinderActivityHeartbeat.touch(driveID: "d1", nowMillis: t0), "first touch must write")
        precondition(storedAt("d1") == t0, "first touch stored wrong value")

        precondition(!FinderActivityHeartbeat.touch(driveID: "d1", nowMillis: t0 + 10_000),
            "touch 10 s later must be throttled")
        precondition(storedAt("d1") == t0, "throttled touch changed the row")

        precondition(FinderActivityHeartbeat.touch(driveID: "d1", nowMillis: t0 + 61_000),
            "touch 61 s later must write")
        precondition(storedAt("d1") == t0 + 61_000, "later touch stored wrong value")

        precondition(storedAt("d2") == nil, "d2 must have no row yet")
        precondition(FinderActivityHeartbeat.touch(driveID: "d2", nowMillis: t0 + 62_000),
            "second drive must be independent of the first drive's throttle")
        precondition(storedAt("d2") == t0 + 62_000, "d2 stored wrong value")
        precondition(storedAt("d1") == t0 + 61_000, "d1 row disturbed by d2")

        print("FinderActivityHeartbeatTests: all tests passed")
    }
}
