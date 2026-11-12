import Foundation

@main enum RefusedNameStoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)

        // Round trip and remove.
        try RefusedNameStore.record(driveID: "d1", itemIdentifier: "i1", parentIdentifier: "p1",
            filename: "a?b.zip", operation: "upload", now: 1)
        var rows = try RefusedNameStore.records(driveID: "d1")
        precondition(rows.count == 1, "expected one row")
        precondition(rows[0].filename == "a?b.zip" && rows[0].parentIdentifier == "p1"
            && rows[0].operation == "upload" && rows[0].updatedAt == 1, "round trip mismatch")
        precondition(rows[0].message.hasPrefix("Cloudreve does not allow these characters in names"), "message")
        try RefusedNameStore.remove(driveID: "d1", itemIdentifier: "i1")
        let r0 = try RefusedNameStore.records(driveID: "d1").isEmpty
        precondition(r0, "remove failed")

        // Upsert on the same key replaces.
        try RefusedNameStore.record(driveID: "d1", itemIdentifier: "i1", parentIdentifier: "p1",
            filename: "a?b.zip", operation: "upload", now: 1)
        try RefusedNameStore.record(driveID: "d1", itemIdentifier: "i1", parentIdentifier: "p2",
            filename: "c?d.zip", operation: "upload", now: 2)
        rows = try RefusedNameStore.records(driveID: "d1")
        precondition(rows.count == 1 && rows[0].filename == "c?d.zip" && rows[0].parentIdentifier == "p2",
            "upsert did not replace")

        // Other drives are isolated.
        try RefusedNameStore.record(driveID: "d2", itemIdentifier: "x", parentIdentifier: "p",
            filename: "z?", operation: "upload", now: 3)
        let d1 = try RefusedNameStore.records(driveID: "d1")
        let d2 = try RefusedNameStore.records(driveID: "d2")
        precondition(d1.count == 1, "drive d1 leaked rows")
        precondition(d2.count == 1, "drive d2 rows missing")
        try RefusedNameStore.remove(driveID: "d2", itemIdentifier: "x")

        // Cap of 500 drops the oldest.
        try RefusedNameStore.remove(driveID: "d1", itemIdentifier: "i1")
        for n in 0..<502 {
            try RefusedNameStore.record(driveID: "d1", itemIdentifier: "n\(n)", parentIdentifier: "p",
                filename: "f\(n)?", operation: "upload", now: Int64(100 + n))
        }
        rows = try RefusedNameStore.records(driveID: "d1")
        precondition(rows.count == 500, "cap not applied: \(rows.count)")
        let ids = Set(rows.map(\.itemIdentifier))
        precondition(!ids.contains("n0") && !ids.contains("n1") && ids.contains("n2") && ids.contains("n501"),
            "wrong rows dropped")
        print("RefusedNameStoreTests: all tests passed")
    }
}
