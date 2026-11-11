import Foundation

enum ItemIdentity {
    static let remotePrefix = "cloudreve-item:/"

    static func remoteID(_ fileID: String, fallbackURI: String) -> String {
        fileID.isEmpty ? fallbackURI : "\(remotePrefix)\(fileID)"
    }

    /// The Cloudreve file ID encoded in a stable identifier, or nil for
    /// legacy URI identifiers and random identities.
    static func fileID(fromIdentifier raw: String) -> String? {
        let canonical = raw.hasPrefix("cloudreve-item://")
            ? remotePrefix + raw.dropFirst("cloudreve-item://".count) : raw
        guard canonical.hasPrefix(remotePrefix) else { return nil }
        let id = String(canonical.dropFirst(remotePrefix.count))
        return id.isEmpty ? nil : id
    }
}
