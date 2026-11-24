import CommonCrypto
import Foundation

/// On-disk partial downloads, so a large download continues from the last byte
/// written. File names are the SHA-256 of the item identifier (no names on disk).
enum PartialDownloadStore {
    struct State: Equatable {
        var written: Int64
        var contentVersion: Data
        var size: Int64
        var encoded: Bool
    }

    private struct Sidecar: Codable {
        var contentVersion: String
        var size: Int64
        var written: Int64
        var encoded: Bool
    }

    static let defaultMaxAge: TimeInterval = 7 * 24 * 3600
    static let defaultMaxTotalBytes: Int64 = 4 << 30

    /// `$CLOUDREVE_FP_STATE_ROOT/partial-downloads` in tests, else the extension's own caches directory.
    static var partialRoot: URL {
        if let value = ProcessInfo.processInfo.environment["CLOUDREVE_FP_STATE_ROOT"] {
            return URL(fileURLWithPath: value, isDirectory: true)
                .appendingPathComponent("partial-downloads", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("partial-downloads", isDirectory: true)
    }

    static func paths(driveID: String, itemIdentifier: String) -> (part: URL, meta: URL) {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Data(itemIdentifier.utf8)
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let directory = partialRoot.appendingPathComponent(driveID, isDirectory: true)
        return (directory.appendingPathComponent(name + ".part"),
                directory.appendingPathComponent(name + ".json"))
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// The recorded state, or nil when there is no sidecar or the part file is shorter than recorded.
    static func load(driveID: String, itemIdentifier: String) -> State? {
        let paths = paths(driveID: driveID, itemIdentifier: itemIdentifier)
        guard let data = try? Data(contentsOf: paths.meta),
            let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
            let version = Data(base64Encoded: sidecar.contentVersion),
            let onDisk = fileSize(paths.part), onDisk >= sidecar.written
        else { return nil }
        return State(written: sidecar.written, contentVersion: version, size: sidecar.size,
            encoded: sidecar.encoded)
    }

    static func save(driveID: String, itemIdentifier: String, _ state: State) {
        let paths = paths(driveID: driveID, itemIdentifier: itemIdentifier)
        let sidecar = Sidecar(contentVersion: state.contentVersion.base64EncodedString(),
            size: state.size, written: state.written, encoded: state.encoded)
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? FileManager.default.createDirectory(
            at: paths.meta.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? data.write(to: paths.meta, options: .atomic)
    }

    static func remove(driveID: String, itemIdentifier: String) {
        let paths = paths(driveID: driveID, itemIdentifier: itemIdentifier)
        try? FileManager.default.removeItem(at: paths.part)
        try? FileManager.default.removeItem(at: paths.meta)
    }

    /// Removes partials older than `maxAge`, then the oldest ones until the total fits `maxTotalBytes`.
    static func evict(
        now: Date = Date(), maxAge: TimeInterval = defaultMaxAge,
        maxTotalBytes: Int64 = defaultMaxTotalBytes
    ) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: partialRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return }
        var parts: [(url: URL, modified: Date, size: Int64)] = []
        for case let url as URL in enumerator where url.pathExtension == "part" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            parts.append((url, values?.contentModificationDate ?? .distantPast,
                Int64(values?.fileSize ?? 0)))
        }
        func drop(_ url: URL) {
            try? manager.removeItem(at: url)
            try? manager.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
        }
        var kept: [(url: URL, modified: Date, size: Int64)] = []
        for part in parts {
            if now.timeIntervalSince(part.modified) > maxAge { drop(part.url) } else { kept.append(part) }
        }
        var total = kept.reduce(Int64(0)) { $0 + $1.size }
        for part in kept.sorted(by: { $0.modified < $1.modified }) where total > maxTotalBytes {
            drop(part.url)
            total -= part.size
        }
    }
}
