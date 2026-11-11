import FileProvider
import Darwin
import OSLog
import UniformTypeIdentifiers
import CryptoKit

extension RemoteStore {
    func identifier(forURI uri: String) -> NSFileProviderItemIdentifier {
        let uri = Self.canonicalURI(uri)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = identifierByURI[uri] {
            return NSFileProviderItemIdentifier(existing)
        }

        // Do not reuse an identifier for a renamed item.
        if let mappedURI = uriByIdentifier[uri], mappedURI != uri {
            var identifier: String
            repeat {
                identifier = "cloudreve-item:/\(UUID().uuidString.lowercased())"
            } while uriByIdentifier[identifier] != nil
            logger.notice(
                "allocating a new identity for reused path \(uri, privacy: .private(mask: .hash)); old identity belongs to \(mappedURI, privacy: .private(mask: .hash))"
            )
            return NSFileProviderItemIdentifier(identifier)
        }

        return NSFileProviderItemIdentifier(uri)
    }

    /// Identity a remote delete applies to. The event names the deleted file's
    /// stable ID, but its path may already belong to a newer file (delete `a`,
    /// then create a different `a`). Resolving by path alone would evict the
    /// new file until the next refresh. When the path is held by a different
    /// ID-based identity, only the deleted file's own identity is removed.
    func identifierForRemoteDelete(uri: String, fileID: String?) -> NSFileProviderItemIdentifier {
        let atPath = identifier(forURI: uri)
        guard let fileID, !fileID.isEmpty else { return atPath }
        let own = ItemIdentity.remoteID(fileID, fallbackURI: uri)
        guard atPath.rawValue.hasPrefix(ItemIdentity.remotePrefix), atPath.rawValue != own else {
            return atPath
        }
        return NSFileProviderItemIdentifier(own)
    }

    private func identifier(
        for file: RemoteFile,
        preserving preserved: NSFileProviderItemIdentifier? = nil
    ) -> NSFileProviderItemIdentifier {
        let uri = Self.canonicalURI(file.path)
        cacheLock.lock()
        defer { cacheLock.unlock() }

        // Prefer the current URI mapping over a stale rename event.
        if let existing = identifierByURI[uri] {
            return NSFileProviderItemIdentifier(existing)
        }

        if let preserved {
            return NSFileProviderItemIdentifier(
                Self.canonicalIdentifier(preserved.rawValue))
        }
        return NSFileProviderItemIdentifier(
            file.presentationIdentity ?? ItemIdentity.remoteID(file.id, fallbackURI: uri))
    }

    private func recordIdentity(_ identifier: NSFileProviderItemIdentifier, uri: String, isFolder: Bool, persist: Bool) {
        let uri = Self.canonicalURI(uri)
        cacheLock.lock()
        if let existing = identifierByURI[uri], existing != identifier.rawValue {
            cacheLock.unlock()
            logger.error(
                "identity collision for \(uri, privacy: .private(mask: .hash)): keeping \(existing, privacy: .private(mask: .hash)), ignoring \(identifier.rawValue, privacy: .private(mask: .hash))"
            )
            return
        }
        if uriByIdentifier[identifier.rawValue] == uri,
            identifierByURI[uri] == identifier.rawValue,
            deletedIdentityURIs[identifier.rawValue] == nil
        {
            cacheLock.unlock()
            return
        }
        identityRevision &+= 1
        if let previousURI = uriByIdentifier[identifier.rawValue] {
            identityChildrenByParent[parentPath(of: previousURI)]?.remove(identifier.rawValue)
            if isFolder && previousURI != uri {
                // A folder move changes every descendant's API path, while
                // Finder identities and pin selections must remain stable.
                // Collect descendants before mutating the parent index.
                let descendants: [(raw: String, oldURI: String)] =
                    descendantIdentifiers(of: previousURI).compactMap { raw in
                        uriByIdentifier[raw].map { (raw, $0) }
                    }
                for (raw, oldURI) in descendants {
                    let newURI = uri + String(oldURI.dropFirst(previousURI.count))
                    if identifierByURI[oldURI] == raw { identifierByURI.removeValue(forKey: oldURI) }
                    uriByIdentifier[raw] = newURI
                    identityChildrenByParent[parentPath(of: oldURI)]?.remove(raw)
                    identityChildrenByParent[parentPath(of: newURI), default: []].insert(raw)
                    identifierByURI[newURI] = raw
                    cache.removeValue(forKey: raw)
                    metadataRefreshAt.removeValue(forKey: raw)
                }
                logger.notice("remapped descendants of moved folder \(previousURI, privacy: .private(mask: .hash)) to \(uri, privacy: .private(mask: .hash))")
            }
            if identifierByURI[previousURI] == identifier.rawValue {
                identifierByURI.removeValue(forKey: previousURI)
            }
        }
        uriByIdentifier[identifier.rawValue] = uri
        identityChildrenByParent[parentPath(of: uri), default: []].insert(identifier.rawValue)
        identifierByURI[uri] = identifier.rawValue
        let deletedIdentityChanged =
            deletedIdentityURIs.removeValue(forKey: identifier.rawValue) != nil
        deletedIdentityTimes.removeValue(forKey: identifier.rawValue)
        let snapshot = uriByIdentifier
        let deletedSnapshot = deletedIdentityURIs
        let batching = identityBatchDepth > 0
        if persist && batching {
            identityBatchDirty = true
            identityBatchDeletedDirty = identityBatchDeletedDirty || deletedIdentityChanged
        }
        cacheLock.unlock()
        if persist && !batching {
            persistIdentitySnapshot(snapshot)
            if deletedIdentityChanged { persistDeletedIdentitySnapshot(deletedSnapshot) }
        }
    }

    /// Runs `body` with identity persistence deferred. Replaying a page of
    /// remote changes records one identity per item; rewriting the whole
    /// identity file each time cost about 19 ms per item on a 5,000-item drive.
    /// The page's anchor only advances after this returns, so a process that
    /// dies mid-page replays it and records the identities again.
    func batchingIdentityPersistence<T>(_ body: () async throws -> T) async rethrows -> T {
        beginIdentityBatch()
        defer { endIdentityBatch() }
        return try await body()
    }

    // Lock use stays in synchronous helpers; NSLock is unavailable from async code.
    private func beginIdentityBatch() {
        cacheLock.lock()
        identityBatchDepth += 1
        cacheLock.unlock()
    }

    private func endIdentityBatch() {
        cacheLock.lock()
        identityBatchDepth -= 1
        let closing = identityBatchDepth == 0
        let flushIdentities = closing && identityBatchDirty
        let flushDeleted = closing && identityBatchDeletedDirty
        let flushPins = closing && identityBatchPinsDirty
        var pinnedSnapshot: [String] = []
        if closing {
            identityBatchDirty = false
            identityBatchDeletedDirty = false
            identityBatchPinsDirty = false
            if flushPins { pinnedSnapshot = pinnedIdentifiers.sorted() }
        }
        cacheLock.unlock()
        if flushIdentities { persistIdentitySnapshot([:]) }
        if flushDeleted { persistDeletedIdentitySnapshot([:]) }
        if flushPins { persistPins(pinnedSnapshot) }
    }

    /// All identities under `uri`, found via the parent index keys (one per
    /// distinct parent folder) so unindexed intermediate folders are covered.
    /// Call with `cacheLock` held.
    private func descendantIdentifiers(of uri: String) -> Set<String> {
        let prefix = uri + "/"
        var result = Set<String>()
        for (parent, children) in identityChildrenByParent where parent == uri || parent.hasPrefix(prefix) {
            result.formUnion(children)
        }
        return result
    }

    private func currentIdentityRevision() -> UInt64 {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return identityRevision
    }

    private func persistIdentityBatch(since revision: UInt64) {
        guard currentIdentityRevision() != revision else { return }
        persistIdentitySnapshot([:])
        persistDeletedIdentitySnapshot([:])
    }

    /// Return the API URI for an item identifier.
    func uri(for identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer {
            return drive.remote_path
        }
        let canonicalIdentifier = Self.canonicalIdentifier(identifier.rawValue)
        cacheLock.lock()
        let mapped = uriByIdentifier[canonicalIdentifier]
        let cached = cache[canonicalIdentifier]?.remoteURI
        cacheLock.unlock()
        return mapped ?? cached ?? Self.uri(fromPath: canonicalIdentifier)
    }

    /// Whether Finder is referring to an item identity we have already seen
    /// at this URI. This distinguishes a stale mirrored create callback after
    /// domain re-registration from a genuinely new Finder item.
    func isKnownIdentity(
        _ identifier: NSFileProviderItemIdentifier, forURI uri: String
    ) -> Bool {
        let raw = Self.canonicalIdentifier(identifier.rawValue)
        let canonicalURI = Self.canonicalURI(uri)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return uriByIdentifier[raw] == canonicalURI
            || deletedIdentityURIs[raw] == canonicalURI
    }

    /// Tracks remote deletes that race with an in-flight Finder upload.
    func remoteDeleteGeneration(for uri: String) -> UInt64 {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var path = Self.canonicalURI(uri)
        var generation: UInt64 = 0
        while path.hasPrefix("cloudreve://") {
            generation &+= remoteDeleteGenerationByURI[path] ?? 0
            guard let slash = path.lastIndex(of: "/"),
                path.distance(from: path.startIndex, to: slash) > "cloudreve://".count else { break }
            path = String(path[..<slash])
        }
        return generation
    }

    func recordRemoteDelete(for uri: String) {
        let uri = Self.canonicalURI(uri)
        cacheLock.lock()
        remoteDeleteGenerationByURI[uri, default: 0] &+= 1
        cacheLock.unlock()
    }

    func remoteDeleteOccurred(for uri: String, after generation: UInt64) -> Bool {
        remoteDeleteGeneration(for: uri) != generation
    }

    func markLocked(
        _ identifier: NSFileProviderItemIdentifier, uri: String? = nil
    ) {
        let itemURI = Self.canonicalURI(uri ?? self.uri(for: identifier))
        let rawIdentifier = Self.canonicalIdentifier(identifier.rawValue)
        cacheLock.lock()
        lockExpiryByURI[itemURI] = Date().addingTimeInterval(Self.lockStateTTL)
        if let cached = cache[rawIdentifier], !cached.isLocked {
            cache[rawIdentifier] = cached.withLocked(true)
            metadataRefreshAt[rawIdentifier] = Date()
        }
        cacheLock.unlock()
        logger.notice("marked item locked: \(itemURI, privacy: .private(mask: .hash))")
    }

    func clearLockState(for uri: String) {
        let itemURI = Self.canonicalURI(uri)
        cacheLock.lock()
        lockExpiryByURI.removeValue(forKey: itemURI)
        cacheLock.unlock()
    }

    private func isLockActive(for uri: String) -> Bool {
        let itemURI = Self.canonicalURI(uri)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let expiresAt = lockExpiryByURI[itemURI] else { return false }
        if expiresAt > Date() { return true }
        lockExpiryByURI.removeValue(forKey: itemURI)
        return false
    }

    /// Finder metadata files that stay local-only.
    static func isIgnored(filename: String) -> Bool {
        filename == ".DS_Store" || filename == "Icon\r" || filename.hasPrefix("._")
    }

    /// Convert a logical path to a Cloudreve URI.
    static func uri(fromPath path: String) -> String {
        let uri =
            path.hasPrefix("cloudreve://")
            ? path
            : "cloudreve://my" + (path.hasPrefix("/") ? path : "/" + path)
        return canonicalURI(uri)
    }

    /// Normalize percent-encoded Cloudreve paths.
    static func canonicalURI(_ uri: String) -> String {
        uri.removingPercentEncoding ?? uri
    }

    /// File Provider canonicalizes opaque identifiers containing `://` to
    /// `:/` when returning them. Store one form so callbacks hit the same map.
    static func canonicalIdentifier(_ raw: String) -> String {
        guard raw.hasPrefix("cloudreve-item://") else { return raw }
        return "cloudreve-item:/" + raw.dropFirst("cloudreve-item://".count)
    }

    /// Canonical URI of the drive root.
    private var rootPath: String {
        Self.canonicalURI(drive.remote_path)
    }

    private func parentPath(of path: String) -> String {
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        guard let idx = p.lastIndex(of: "/") else { return rootPath }
        let parent = String(p[..<idx])
        // Never return a path above the drive root.
        return parent.isEmpty || parent == "cloudreve:" || parent == "cloudreve://my"
            ? rootPath : parent
    }

}
