import Foundation

enum DeletePreflight: Equatable {
    case proceed, directoryNotEmpty, deletionRejected

    /// `baseContentVersion` is the system's baseVersion.contentVersion.
    static func decide(remote: RemoteFile, recursive: Bool,
                       remoteChildNames: [String]?, baseContentVersion: Data) -> DeletePreflight {
        if remote.isFolder {
            let visible = (remoteChildNames ?? []).filter { !RemoteStore.isIgnored(filename: $0) }
            return !recursive && !visible.isEmpty ? .directoryNotEmpty : .proceed
        }
        guard let base = entityToken(baseContentVersion),
              let current = remote.primary_entity, !current.isEmpty else { return .proceed }
        return base == current ? .proceed : .deletionRejected
    }

    /// Same parsing as FileProviderExtension.versionToken: "entity:<token>[#thumbnail-v1]".
    static func entityToken(_ version: Data) -> String? {
        guard var value = String(data: version, encoding: .utf8) else { return nil }
        if value.hasSuffix("#thumbnail-v1") { value.removeLast("#thumbnail-v1".count) }
        guard value.hasPrefix("entity:") else { return nil }
        let token = String(value.dropFirst("entity:".count))
        return token.isEmpty ? nil : token
    }
}

enum MutationReplay {
    /// A rename or move answered "not found" may already have been applied by
    /// an earlier attempt whose response was lost. It counts as applied only
    /// when the item at the destination is provably the same file.
    static func alreadyApplied(identifier: String, destination: RemoteFile?) -> Bool {
        guard let destination, let id = ItemIdentity.fileID(fromIdentifier: identifier) else { return false }
        return destination.id == id
    }
}
