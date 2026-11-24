import CommonCrypto
import Foundation

/// Persisted state of a live Cloudreve upload session, so an interrupted upload
/// can continue from the last acknowledged chunk. Lives in the shared 0600 state
/// database only while the session is live. The secret-bearing fields
/// (`credential`, `uploadURLs`, `callbackSecret`, `encrypt`) must never be logged.
struct UploadSessionRecord: Codable {
    static let namespace = "fileprovider-upload-sessions"
    static let abandonedAfter: Int64 = 24 * 3600
    static let expirySafetyMargin: Int64 = 60

    /// 0 = legacy `{"id","uri"}` row (cleanup only), 1 = resumable record.
    var v: Int
    var id: String
    var uri: String
    var overwrite: Bool
    var previous: String?
    var size: Int64
    var mtime: Int64?
    var headHash: String
    var tailHash: String
    var chunkSize: Int64
    var nextChunk: Int
    var etags: [String]
    var kind: String
    var uploadURLs: [String]
    var credential: String?
    var completeURL: String?
    var callbackSecret: String?
    var mimeType: String?
    var uploadPolicy: String?
    var encrypt: UploadEncryptMetadata?
    var expiresAt: Int64?
    var createdAt: Int64
    var updatedAt: Int64

    static func key(driveID: String, sessionID: String) -> String { driveID + ":" + sessionID }

    /// Decodes a v1 record, or a legacy v0 row as a record with `v == 0`.
    static func decode(_ data: Data) -> UploadSessionRecord? {
        if let record = try? JSONDecoder().decode(UploadSessionRecord.self, from: data), record.v == 1 {
            return record
        }
        guard let legacy = try? JSONDecoder().decode([String: String].self, from: data),
            let id = legacy["id"], let uri = legacy["uri"] else { return nil }
        return UploadSessionRecord(
            v: 0, id: id, uri: uri, overwrite: false, previous: nil, size: 0, mtime: nil,
            headHash: "", tailHash: "", chunkSize: 1, nextChunk: 0, etags: [], kind: "unsupported:legacy",
            uploadURLs: [], credential: nil, completeURL: nil, callbackSecret: nil, mimeType: nil,
            uploadPolicy: nil, encrypt: nil, expiresAt: nil, createdAt: 0, updatedAt: 0)
    }

    static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 (hex) of the plaintext of the first and last chunk. A zero-byte
    /// file hashes empty data; for a single-chunk file head == tail.
    static func fingerprint(of fileURL: URL, size: Int64, chunkSize: Int64) throws -> (head: String, tail: String) {
        let chunk = max(chunkSize, 1)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        func read(at offset: Int64, length: Int64) throws -> String {
            try handle.seek(toOffset: UInt64(offset))
            return sha256Hex(try handle.read(upToCount: Int(length)) ?? Data())
        }
        guard size > 0 else { let empty = sha256Hex(Data()); return (empty, empty) }
        let head = try read(at: 0, length: min(chunk, size))
        let chunks = (size + chunk - 1) / chunk
        if chunks == 1 { return (head, head) }
        let lastStart = (chunks - 1) * chunk
        return (head, try read(at: lastStart, length: size - lastStart))
    }

    func matches(
        uri: String, overwrite: Bool, previous: String?, size: Int64, mtime: Int64?,
        head: String, tail: String, chunkSize: Int64
    ) -> Bool {
        self.uri == uri && self.overwrite == overwrite && self.previous == previous
            && self.size == size && self.mtime == mtime && headHash == head && tailHash == tail
            && self.chunkSize == chunkSize
    }

    func isResumable(now: Int64) -> Bool {
        guard v == 1, let target = UploadTargetKind(recordValue: kind) else { return false }
        switch target {
        case .upyun, .unsupported: return false
        case .s3Like, .qiniu:
            if etags.count != nextChunk { return false }
        default: break
        }
        guard nextChunk >= 0, nextChunk <= ObjectStorageUpload.chunkCount(size: size, chunkSize: chunkSize)
        else { return false }
        if let expiresAt, expiresAt <= now + Self.expirySafetyMargin { return false }
        return true
    }

    func isAbandoned(now: Int64) -> Bool {
        if v != 1 { return true }
        if let expiresAt { return expiresAt <= now }
        return updatedAt < now - Self.abandonedAfter
    }
}
