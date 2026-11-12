import Foundation

struct RefusedNameRecord: Codable, Equatable {
    let driveID: String
    let itemIdentifier: String
    let parentIdentifier: String
    let filename: String
    let operation: String
    let message: String
    let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case filename, operation, message
        case driveID = "drive_id"
        case itemIdentifier = "item_identifier"
        case parentIdentifier = "parent_identifier"
        case updatedAt = "updated_at"
    }
}

/// Names Cloudreve forbids are refused by the extension, and macOS drops the
/// failed item from its pending list shortly afterwards. This store keeps our
/// own record so the host app can keep listing the item until it is fixed.
/// The host prunes rows whose file is gone or whose name became valid.
enum RefusedNameStore {
    static let namespace = "fileprovider-refused-names"
    static let maxRowsPerDrive = 500

    static func key(driveID: String, itemIdentifier: String) -> String {
        driveID + ":" + itemIdentifier
    }

    static func record(driveID: String, itemIdentifier: String, parentIdentifier: String,
                       filename: String, operation: String,
                       now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        let row = RefusedNameRecord(
            driveID: driveID, itemIdentifier: itemIdentifier, parentIdentifier: parentIdentifier,
            filename: filename, operation: operation,
            message: CloudreveError.invalidName(filename).localizedDescription, updatedAt: now)
        let payload = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        let database = try FileProviderStateDatabase()
        try database.importRecords(namespace)
        try database.transaction {
            try database.execute(
                "INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload",
                [namespace, key(driveID: driveID, itemIdentifier: itemIdentifier), payload])
            let rows = try decodeRows(database, driveID: driveID)
            if rows.count > maxRowsPerDrive {
                let oldest = rows.sorted { $0.record.updatedAt < $1.record.updatedAt }
                    .prefix(rows.count - maxRowsPerDrive)
                for entry in oldest {
                    try database.execute("DELETE FROM fp_records WHERE namespace=? AND key=?",
                        [namespace, entry.key])
                }
            }
        }
    }

    static func remove(driveID: String, itemIdentifier: String) throws {
        try FileProviderStateDatabase().remove(namespace, key(driveID: driveID, itemIdentifier: itemIdentifier))
    }

    static func records(driveID: String) throws -> [RefusedNameRecord] {
        let database = try FileProviderStateDatabase()
        try database.importRecords(namespace)
        return try decodeRows(database, driveID: driveID).map(\.record)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func decodeRows(_ database: FileProviderStateDatabase, driveID: String) throws ->
        [(key: String, record: RefusedNameRecord)] {
        try database.rows("SELECT key,payload FROM fp_records WHERE namespace=?", [namespace]).compactMap { row in
            guard let record = try? JSONDecoder().decode(RefusedNameRecord.self, from: Data(row[1].utf8)),
                  record.driveID == driveID else { return nil }
            return (row[0], record)
        }
    }
}
