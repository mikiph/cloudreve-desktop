import FileProvider
import Darwin
import OSLog
import UniformTypeIdentifiers
import CryptoKit

private actor OperationGate {
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available {
            available = false
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available = true
        }
    }
}

private actor MetadataRefreshCoordinator {
    private var inFlight: [String: Task<RemoteFile, Error>] = [:]

    func run(
        for key: String,
        operation: @escaping () async throws -> RemoteFile
    ) async throws -> RemoteFile {
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task { try await operation() }
        inFlight[key] = task
        do {
            let result = try await task.value
            inFlight[key] = nil
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
}

/// Maps a File Provider domain to a Cloudreve drive.
final class RemoteStore {
    private let logger = Logger(
        subsystem: "cloudreve.desktop.fileprovider", category: "store")

    let drive: DriveConfig
    let client: CloudreveClient
    private let domain: NSFileProviderDomain

    /// itemIdentifier.rawValue -> item.
    private var cache: [String: FileProviderItem] = [:]
    /// Stable Finder identity -> current Cloudreve URI.
    private var uriByIdentifier: [String: String] = [:]
    private var identifierByURI: [String: String] = [:]
    private var identityChildrenByParent: [String: Set<String>] = [:]
    private var identityRevision: UInt64 = 0
    // While a batch is open, identity changes are persisted once when the last
    // batch closes instead of rewriting the whole snapshot for every item.
    // Guarded by cacheLock.
    private var identityBatchDepth = 0
    private var identityBatchDirty = false
    private var identityBatchDeletedDirty = false
    private let identityPersistenceLock = NSLock()
    /// Explicitly pinned identifiers, persisted per drive.
    private var pinnedIdentifiers: Set<String> = []
    private var pinRevision: UInt64 = 0
    private var pinRevisionByIdentifier: [String: UInt64] = [:]

    struct PinChange {
        let wasPinned: Bool
        let revision: UInt64
    }
    /// Stable identities confirmed absent remotely. Finder may replay these
    /// as create callbacks after a domain is re-registered.
    private var deletedIdentityURIs: [String: String] = [:]
    /// Version marker used to force a working-set refresh after policy changes.
    private static let policyMetadataVersion = "finder-metadata-v8-sharing-sentence-case"
    private static let metadataRefreshTTL: TimeInterval = 5
    private static let lockStateTTL: TimeInterval = 30
    private var policyRescanPending = false
    private var metadataRefreshAt: [String: Date] = [:]
    private var lockExpiryByURI: [String: Date] = [:]
    private var presentedContainers: [String: UInt64] = [:]
    private var presentedContainerSequence: UInt64 = 0
    private var remoteDeleteGenerationByURI: [String: UInt64] = [:]
    private var pendingStabilizationDeletes: Set<String> = []
    // Reconnect reconciliation only walks containers Finder has presented.
    // Eight entries is too small for normal use and lets quiet folders fall
    // out of recovery coverage, so missed SSE creates can remain invisible.
    // Keep this bounded to avoid turning a reconnect into a full-drive crawl.
    private static let presentedContainerLimit = 128
    private let cacheLock = NSLock()
    private let pinRequestLock = NSLock()
    private let stateDirectoryOverride: URL?
    private let pinRequestDirectoryOverride: URL?
    private let actionGate = OperationGate()
    private let managerCallGate = OperationGate()
    private let metadataRefreshCoordinator = MetadataRefreshCoordinator()
    private let migrationRecoveryGate = OperationGate()
    private var migrationRecoveryCompleted = false
    private let presentedRefreshLock = NSLock()
    private var presentedRefreshRunning = false
    private let downloadedRefreshLock = NSLock()
    private var downloadedRefreshRunning = false
    private var downloadedRefreshPending: Set<String> = []
    private let presentedPageLoader: ((String, String?) async throws -> CloudreveClient.ListResult)?
    private let workingSetSignaller: (() async throws -> Void)?
    private let presentedMissingLookup: ((String) async throws -> RemoteFile)?
    private let downloadedContentRefresher: ((NSFileProviderItemIdentifier) async -> Void)?

    // MARK: - Change feed (shared event log)

    /// Remote event recorded by the main app in the shared SQLite journal.
    struct FpEvent: Codable {
        let ts: Int64  // unix epoch milliseconds
        let type: String  // create | modify | metadata | rename | delete
        let from: String  // path relative to drive root, or an absolute URI
        let to: String?
        let localEcho: Bool?
        var presentation: PresentedPage? = nil
        /// Stable Cloudreve file ID from the server event, when it supplied one.
        var fileID: String? = nil

        enum CodingKeys: String, CodingKey {
            case ts, type, from, to
            case localEcho = "local_echo"
            case presentation
            case fileID = "file_id"
        }
    }

    /// Keep each File Provider callback short.  macOS immediately requests
    /// the next page when `moreComing` is true, so a large recovery delta
    /// cannot monopolize the extension or delay newer changes.
    private static let changePageSize = 100

    init(drive: DriveConfig, domain: NSFileProviderDomain,
         stateDirectory: URL? = nil, pinRequestDirectory: URL? = nil,
         presentedPageLoader: ((String, String?) async throws -> CloudreveClient.ListResult)? = nil,
         workingSetSignaller: (() async throws -> Void)? = nil,
         presentedMissingLookup: ((String) async throws -> RemoteFile)? = nil,
         client: CloudreveClient? = nil,
         downloadedContentRefresher: ((NSFileProviderItemIdentifier) async -> Void)? = nil) {
        self.presentedPageLoader = presentedPageLoader
        self.workingSetSignaller = workingSetSignaller
        self.presentedMissingLookup = presentedMissingLookup
        self.downloadedContentRefresher = downloadedContentRefresher
        self.stateDirectoryOverride = stateDirectory
        self.pinRequestDirectoryOverride = pinRequestDirectory
        self.drive = drive
        self.domain = domain
        self.client = client ?? CloudreveClient(drive: drive)
        resetLocalStateIfRequested()
        if let data = try? Data(contentsOf: identityFileURL),
            let saved = try? JSONDecoder().decode([String: String].self, from: data)
        {
            var normalized: [String: String] = [:]
            var reverse: [String: String] = [:]
            var needsRepair = false

            // Keep one stable identity per canonical URI.
            for savedIdentifier in saved.keys.sorted() {
                guard let rawURI = saved[savedIdentifier] else { continue }
                let identifier = Self.canonicalIdentifier(savedIdentifier)
                let uri = Self.canonicalURI(rawURI)
                if let existing = reverse[uri] {
                    needsRepair = true
                    logger.error(
                        "duplicate item identity for \(uri, privacy: .public): keeping \(existing, privacy: .public), ignoring \(identifier, privacy: .public)"
                    )
                    continue
                }
                normalized[identifier] = uri
                reverse[uri] = identifier
                needsRepair = needsRepair || rawURI != uri || savedIdentifier != identifier
            }
            uriByIdentifier = normalized
            identifierByURI = reverse
            for (identifier, uri) in normalized {
                identityChildrenByParent[parentPath(of: uri), default: []].insert(identifier)
            }
            if needsRepair { persistIdentitySnapshot(normalized) }
        }
        if let data = try? Data(contentsOf: pinnedFileURL),
            let saved = try? JSONDecoder().decode([String].self, from: data)
        {
            pinnedIdentifiers = Set(saved.map(Self.canonicalIdentifier))
        }
        if let data = try? Data(contentsOf: deletedIdentitiesFileURL),
            let saved = try? JSONDecoder().decode([String: String].self, from: data)
        {
            deletedIdentityURIs = Dictionary(
                uniqueKeysWithValues: saved.map {
                    (Self.canonicalIdentifier($0.key), Self.canonicalURI($0.value))
                })
        }
        // Persist presented folders for later reconciliation.
        if let data = try? Data(contentsOf: presentedFileURL),
            let saved = try? JSONDecoder().decode([String: UInt64].self, from: data)
        {
            presentedContainers = Dictionary(
                uniqueKeysWithValues: saved.map {
                    (Self.canonicalIdentifier($0.key), $0.value)
                })
            presentedContainerSequence = presentedContainers.values.max() ?? 0
        }
        let currentPolicyVersion = Data(Self.policyMetadataVersion.utf8)
        let hasCurrentPolicyVersion =
            (try? Data(contentsOf: policyMetadataVersionURL)) == currentPolicyVersion
        let hasRescanMarker = FileManager.default.fileExists(atPath: policyRescanMarkerURL.path)
        policyRescanPending = hasRescanMarker || !hasCurrentPolicyVersion
        if policyRescanPending {
            persistPolicyRescanMarker()
            logger.notice(
                "Keep Downloaded metadata refresh scheduled for drive \(drive.id, privacy: .public)"
            )
        }
    }

    private var stateDirectoryURL: URL {
        if let stateDirectoryOverride { return stateDirectoryOverride }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("CloudreveFileProvider", isDirectory: true)
    }

    private var pinnedFileURL: URL {
        stateDirectoryURL.appendingPathComponent("pinned-\(drive.id).json")
    }

    private var identityFileURL: URL {
        stateDirectoryURL
            .appendingPathComponent("identities-\(drive.id).json")
    }

    private var deletedIdentitiesFileURL: URL {
        stateDirectoryURL
            .appendingPathComponent("deleted-identities-\(drive.id).json")
    }

    private var presentedFileURL: URL {
        stateDirectoryURL
            .appendingPathComponent("presented-\(drive.id).json")
    }

    private var policyMetadataVersionURL: URL {
        stateDirectoryURL
            .appendingPathComponent("policy-metadata-version-\(drive.id).txt")
    }

    private var policyRescanMarkerURL: URL {
        stateDirectoryURL
            .appendingPathComponent("policy-rescan-\(drive.id).marker")
    }

    private var resetAcknowledgementURL: URL {
        stateDirectoryURL
            .appendingPathComponent("reset-applied-\(drive.id).marker")
    }

    private func resetLocalStateIfRequested() {
        let request = try? FileProviderStateDatabase(root: stateDirectoryOverride ?? FileProviderStateDatabase.defaultRoot)
            .get("fp-reset-requests-v2", "\(drive.id).marker")
        let acknowledged = try? Data(contentsOf: resetAcknowledgementURL)
        guard ResetRequest.shouldApply(request: request, acknowledged: acknowledged),
            let request
        else { return }
        for url in [
            identityFileURL, deletedIdentitiesFileURL, pinnedFileURL,
            presentedFileURL, pendingPolicyUpdatesFileURL,
            policyMetadataVersionURL, policyRescanMarkerURL,
        ] {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try FileManager.default.createDirectory(
                at: resetAcknowledgementURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try request.write(to: resetAcknowledgementURL, options: .atomic)
        } catch {
            logger.error(
                "failed to acknowledge File Provider reset: \(error.localizedDescription, privacy: .public)"
            )
        }
        logger.notice("cleared local File Provider state for drive reset")
    }

    private func persistIdentitySnapshot(_ snapshot: [String: String]) {
        // Snapshot only after taking the writer lock. Concurrent callbacks must
        // never overwrite a newer move with an older snapshot captured earlier.
        identityPersistenceLock.lock()
        defer { identityPersistenceLock.unlock() }
        let snapshot = identityMapsSnapshot().byIdentifier
        do {
            try FileManager.default.createDirectory(
                at: identityFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: identityFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist item identities: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistDeletedIdentitySnapshot(_ snapshot: [String: String]) {
        identityPersistenceLock.lock()
        defer { identityPersistenceLock.unlock() }
        cacheLock.lock()
        let snapshot = deletedIdentityURIs
        cacheLock.unlock()
        do {
            try FileManager.default.createDirectory(
                at: deletedIdentitiesFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(
                to: deletedIdentitiesFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist deleted identities: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func withActionLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await actionGate.acquire()
        do {
            let result = try await operation()
            await actionGate.release()
            return result
        } catch {
            await actionGate.release()
            throw error
        }
    }

    private func withManagerCall<T>(_ operation: () async throws -> T) async rethrows -> T {
        await managerCallGate.acquire()
        do {
            let result = try await operation()
            await managerCallGate.release()
            return result
        } catch {
            await managerCallGate.release()
            throw error
        }
    }

    func queueStabilizationDelete(_ identifier: NSFileProviderItemIdentifier) {
        cacheLock.lock()
        pendingStabilizationDeletes.insert(identifier.rawValue)
        cacheLock.unlock()
        evictCachedItems(withIdentifiers: [identifier])
    }

    func takeStabilizationDeletes() -> [NSFileProviderItemIdentifier] {
        cacheLock.lock()
        let identifiers = pendingStabilizationDeletes
        pendingStabilizationDeletes.removeAll()
        cacheLock.unlock()
        return identifiers.map { NSFileProviderItemIdentifier($0) }
    }

    func signalWorkingSet() async {
        if let workingSetSignaller {
            do { try await workingSetSignaller() } catch {}
            return
        }
        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            // Signalling must not queue behind a download waiting for Finder
            // to ingest the very metadata this signal announces.
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            logger.error(
                "failed to signal working set: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistPolicyRescanMarker() {
        do {
            try FileManager.default.createDirectory(
                at: policyRescanMarkerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(Self.policyMetadataVersion.utf8).write(
                to: policyRescanMarkerURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist policy rescan marker: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Consume the one-shot working-set refresh request.
    func consumePolicyRescanIfNeeded() -> Bool {
        cacheLock.lock()
        guard policyRescanPending else {
            cacheLock.unlock()
            return false
        }
        policyRescanPending = false
        cacheLock.unlock()

        try? FileManager.default.removeItem(at: policyRescanMarkerURL)
        do {
            try FileManager.default.createDirectory(
                at: policyMetadataVersionURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(Self.policyMetadataVersion.utf8).write(
                to: policyMetadataVersionURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist policy metadata version: \(error.localizedDescription, privacy: .public)"
            )
        }
        logger.notice("expiring working-set anchor for Keep Downloaded metadata refresh")
        return true
    }

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
                "allocating a new identity for reused path \(uri, privacy: .public); old identity belongs to \(mappedURI, privacy: .public)"
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
                "identity collision for \(uri, privacy: .public): keeping \(existing, privacy: .public), ignoring \(identifier.rawValue, privacy: .public)"
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
                let prefix = previousURI + "/"
                for (raw, oldURI) in Array(uriByIdentifier) where oldURI.hasPrefix(prefix) {
                    let newURI = uri + String(oldURI.dropFirst(previousURI.count))
                    if identifierByURI[oldURI] == raw { identifierByURI.removeValue(forKey: oldURI) }
                    uriByIdentifier[raw] = newURI
                    identityChildrenByParent[parentPath(of: oldURI)]?.remove(raw)
                    identityChildrenByParent[parentPath(of: newURI), default: []].insert(raw)
                    identifierByURI[newURI] = raw
                    cache.removeValue(forKey: raw)
                    metadataRefreshAt.removeValue(forKey: raw)
                }
                logger.notice("remapped descendants of moved folder \(previousURI, privacy: .public) to \(uri, privacy: .public)")
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
        let flush = identityBatchDepth == 0 && identityBatchDirty
        let flushDeleted = flush && identityBatchDeletedDirty
        if flush {
            identityBatchDirty = false
            identityBatchDeletedDirty = false
        }
        cacheLock.unlock()
        if flush { persistIdentitySnapshot([:]) }
        if flushDeleted { persistDeletedIdentitySnapshot([:]) }
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

    // MARK: - "Keep Downloaded" pin state

    func isPinned(_ identifier: NSFileProviderItemIdentifier) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return pinnedIdentifiers.contains(identifier.rawValue)
    }

    private func pinnedIdentifiersSnapshot() -> Set<String> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return pinnedIdentifiers
    }

    private func cachedItem(
        for identifier: NSFileProviderItemIdentifier
    ) -> FileProviderItem? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[identifier.rawValue]
    }

    private func metadataIsFresh(
        for identifier: NSFileProviderItemIdentifier
    ) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let refreshedAt = metadataRefreshAt[identifier.rawValue] else {
            return false
        }
        return Date().timeIntervalSince(refreshedAt) < Self.metadataRefreshTTL
    }

    private func isEffectivelyPinnedLocked(
        _ identifier: NSFileProviderItemIdentifier, uri: String
    ) -> Bool {
        let uri = Self.canonicalURI(uri)
        if pinnedIdentifiers.contains(identifier.rawValue) {
            return true
        }

        // A pinned root covers the whole drive.
        let rootIdentifier = NSFileProviderItemIdentifier.rootContainer.rawValue
        if pinnedIdentifiers.contains(rootIdentifier) {
            let root = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return uri == rootPath || uri.hasPrefix(root)
        }

        for pinned in pinnedIdentifiers {
            let pinnedURI: String
            if pinned == rootIdentifier {
                pinnedURI = rootPath
            } else {
                pinnedURI = uriByIdentifier[pinned].map(Self.canonicalURI)
                    ?? Self.canonicalURI(pinned)
            }
            let prefix = pinnedURI.hasSuffix("/") ? pinnedURI : pinnedURI + "/"
            if uri.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// Whether an item is explicitly or implicitly pinned.
    func isEffectivelyPinned(
        _ identifier: NSFileProviderItemIdentifier, uri: String
    ) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return isEffectivelyPinnedLocked(identifier, uri: uri)
    }

    /// Pending policy updates for working-set enumeration.
    private var pendingPolicyUpdatesFileURL: URL {
        stateDirectoryURL.appendingPathComponent("pending-pinned-\(drive.id).json")
    }

    /// Queue items whose content policy changed.
    func recordPendingItemUpdates(uris: [String]) {
        cacheLock.lock()
        var pending = readPendingPolicyUpdates()
        pending.formUnion(uris)
        policyRescanPending = true
        cacheLock.unlock()
        do {
            try FileManager.default.createDirectory(
                at: pendingPolicyUpdatesFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(pending.sorted()).write(
                to: pendingPolicyUpdatesFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist pending item updates: \(error.localizedDescription, privacy: .public)")
        }
        persistPolicyRescanMarker()
    }

    private func readPendingPolicyUpdates() -> Set<String> {
        guard let data = try? Data(contentsOf: pendingPolicyUpdatesFileURL),
            let saved = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(saved)
    }

    private func pendingItemUpdatesSnapshot() -> Set<String> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return readPendingPolicyUpdates()
    }

    /// Take queued policy updates, clearing the persisted list.
    func takePendingItemUpdates() -> [String] {
        cacheLock.lock()
        let pending = readPendingPolicyUpdates()
        cacheLock.unlock()
        try? FileManager.default.removeItem(at: pendingPolicyUpdatesFileURL)
        return pending.sorted()
    }

    /// Retry until the requested content is available locally.
    func requestDownloadWhenKnown(
        _ identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager? = nil
    ) async -> Bool {
        guard let manager = manager ?? NSFileProviderManager(for: domain) else {
            logger.error(
                "cannot request download for \(identifier.rawValue, privacy: .public): no File Provider manager"
            )
            return false
        }
        var lastError: Error?
        for attempt in 0..<5 {
            if Task.isCancelled { return false }
            if !isEffectivelyPinned(identifier, uri: uri(for: identifier)) {
                return true
            }
            do {
                try await withManagerCall {
                    try await manager.requestDownloadForItem(withIdentifier: identifier)
                }
                if Task.isCancelled { return false }
                if attempt == 1 {
                    try await materializePinnedContent(identifier, manager: manager)
                }
                logger.notice(
                    "download request accepted for \(identifier.rawValue, privacy: .public) on attempt \(attempt + 1)"
                )
                let deadline = Date().addingTimeInterval(Double(attempt + 1))
                repeat {
                    if Task.isCancelled { return false }
                    if !isEffectivelyPinned(identifier, uri: uri(for: identifier)) {
                        return true
                    }
                    if await localContentState(identifier, manager: manager) == .downloaded {
                        return true
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                } while Date() < deadline
            } catch {
                lastError = error
                logger.error(
                    "download request attempt \(attempt + 1) failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
            }
        }
        logger.error(
            "download incomplete for \(identifier.rawValue, privacy: .public) after 5 attempts: \(lastError?.localizedDescription ?? "content is still unavailable", privacy: .public)"
        )
        return false
    }

    /// Coordinated reads also download files previously evicted by the user.
    private func materializePinnedContent(
        _ identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager
    ) async throws {
        let url = try await withManagerCall {
            try await manager.getUserVisibleURL(for: identifier)
        }
        guard isEffectivelyPinned(identifier, uri: uri(for: identifier)) else { return }
        try Task.checkCancellation()
        let coordinator = NSFileCoordinator()
        let readTask = Task.detached(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var error: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in }
            if let error { throw error }
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            try await readTask.value
        } onCancel: {
            coordinator.cancel()
            readTask.cancel()
        }
    }

    private enum LocalContentState {
        case downloaded
        case dataless
        case unavailable
    }

    private func localContentState(
        _ identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager
    ) async -> LocalContentState {
        do {
            let url = try await withManagerCall {
                try await manager.getUserVisibleURL(for: identifier)
            }
            var info = stat()
            let result = url.path.withCString { lstat($0, &info) }
            guard result == 0 else {
                logger.error(
                    "could not inspect local content for \(identifier.rawValue, privacy: .public): errno \(errno)"
                )
                return .unavailable
            }
            return (info.st_flags & UInt32(SF_DATALESS)) == 0 ? .downloaded : .dataless
        } catch {
            logger.error(
                "could not inspect local content for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .unavailable
        }
    }

    func hasDownloadedContent(_ identifier: NSFileProviderItemIdentifier) async -> Bool {
        guard let manager = NSFileProviderManager(for: domain) else { return false }
        let state = await localContentState(identifier, manager: manager)
        logger.notice(
            "local content state for \(identifier.rawValue, privacy: .public): \(state == .downloaded ? "downloaded" : "dataless", privacy: .public)"
        )
        return state == .downloaded
    }

    /// Evict materialized content before publishing a newer remote generation.
    func prepareDownloadedContentForRemoteUpdate(
        _ identifier: NSFileProviderItemIdentifier
    ) async -> Bool {
        guard let manager = NSFileProviderManager(for: domain) else { return false }
        guard await localContentState(identifier, manager: manager) == .downloaded else {
            return false
        }

        do {
            try await withManagerCall {
                try await manager.evictItem(identifier: identifier)
            }
            logger.notice(
                "evicted previous content generation for \(identifier.rawValue, privacy: .public)"
            )
        } catch {
            // The post-update refresh retries after open descriptors are released.
            logger.error(
                "could not evict previous content generation for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        return true
    }

    func refreshDownloadedContent(_ identifiers: [NSFileProviderItemIdentifier]) async {
        guard let manager = NSFileProviderManager(for: domain) else { return }

        var seen = Set<String>()
        for identifier in identifiers where seen.insert(identifier.rawValue).inserted {
            if Task.isCancelled { return }
            let uri = uri(for: identifier)
            if FileProviderDownloadSuppressionStore.contains(driveID: drive.id, uri: uri) {
                continue
            }

            // Materialize only after File Provider commits the remote version.
            let settleDeadline = Date().addingTimeInterval(2)
            var state = await localContentState(identifier, manager: manager)
            while state == .downloaded && Date() < settleDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                state = await localContentState(identifier, manager: manager)
            }
            if state == .downloaded {
                do {
                    try await withManagerCall {
                        try await manager.evictItem(identifier: identifier)
                    }
                    logger.notice(
                        "evicted previous content generation for \(identifier.rawValue, privacy: .public) after publishing the remote update"
                    )
                    state = await localContentState(identifier, manager: manager)
                } catch {
                    logger.error(
                        "remote content refresh could not evict \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            if state == .dataless {
                try? await Task.sleep(nanoseconds: 200_000_000)
                state = await localContentState(identifier, manager: manager)
            }
            if state == .downloaded {
                logger.notice(
                    "materialized current remote content for \(identifier.rawValue, privacy: .public) from content policy"
                )
                continue
            }

            let verificationDelays: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000]
            var refreshed = false
            for (index, delay) in verificationDelays.enumerated() {
                if Task.isCancelled { return }
                do {
                    try await withManagerCall {
                        try await manager.requestDownloadForItem(withIdentifier: identifier)
                    }
                    logger.notice(
                        "requested current remote content for \(identifier.rawValue, privacy: .public) on attempt \(index + 1)"
                    )
                } catch {
                    logger.error(
                        "remote content refresh attempt \(index + 1) failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }

                let deadline = Date().addingTimeInterval(Double(delay) / 1_000_000_000)
                repeat {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if Task.isCancelled { return }
                    if await localContentState(identifier, manager: manager) == .downloaded {
                        refreshed = true
                        break
                    }
                } while Date() < deadline
                if refreshed { break }
            }

            if refreshed {
                logger.notice(
                    "materialized current remote content for \(identifier.rawValue, privacy: .public)"
                )
            } else {
                logger.error(
                    "current remote content remained dataless for \(identifier.rawValue, privacy: .public)"
                )
            }
        }
    }

    /// Evict local content, retrying while the new policy is ingested.
    func evictWhenAllowed(
        _ identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager? = nil
    ) async -> Bool {
        guard let manager = manager ?? NSFileProviderManager(for: domain) else {
            logger.error(
                "cannot evict \(identifier.rawValue, privacy: .public): no File Provider manager"
            )
            return false
        }
        var lastError: Error?
        for attempt in 1...6 {
            if Task.isCancelled { return false }
            if isEffectivelyPinned(identifier, uri: uri(for: identifier)) {
                return true
            }
            do {
                try await withManagerCall {
                    try await manager.evictItem(identifier: identifier)
                }
                logger.notice(
                    "eviction accepted for \(identifier.rawValue, privacy: .public) on attempt \(attempt)"
                )
                return true
            } catch {
                lastError = error
                logger.error(
                    "eviction attempt \(attempt) failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                if attempt < 6 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                }
            }
        }
        logger.error(
            "eviction failed for \(identifier.rawValue, privacy: .public) after 6 attempts: \(lastError?.localizedDescription ?? "unknown error", privacy: .public)"
        )
        return false
    }

    /// Resume downloads for persisted pins.
    func requestDownloadsForPinnedItems() async {
        let pinned = pinnedIdentifiersSnapshot()
        guard !pinned.isEmpty else { return }
        var pending = pinned.map { NSFileProviderItemIdentifier($0) }
        var visited: Set<String> = []
        while let identifier = pending.popLast() {
            if Task.isCancelled { return }
            guard visited.insert(identifier.rawValue).inserted,
                isEffectivelyPinned(identifier, uri: uri(for: identifier)) else { continue }
            do {
                let selected = try await item(for: identifier, displayName: domain.displayName)
                let items = selected.contentType.conforms(to: .folder)
                    ? try await allChildren(of: identifier) : [selected]
                pending.append(contentsOf: items.filter {
                    $0.contentType.conforms(to: .folder)
                }.map { $0.itemIdentifier })
                let files = items.filter {
                    !$0.contentType.conforms(to: .folder)
                        && isEffectivelyPinned($0.itemIdentifier, uri: uri(for: $0.itemIdentifier))
                }
                for start in stride(from: 0, to: files.count, by: 8) {
                    if Task.isCancelled { return }
                    let end = min(start + 8, files.count)
                    await withTaskGroup(of: Void.self) { group in
                        for file in files[start..<end] {
                            group.addTask {
                                guard self.isEffectivelyPinned(
                                    file.itemIdentifier,
                                    uri: self.uri(for: file.itemIdentifier)
                                ) else { return }
                                _ = await self.requestDownloadWhenKnown(file.itemIdentifier)
                            }
                        }
                    }
                }
            } catch {
                logger.error(
                    "failed to resume pinned downloads for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Retry evictions that were blocked by an in-progress system download.
    func retryEvictionsWhenUnpinned(
        _ identifiers: [NSFileProviderItemIdentifier],
        manager: NSFileProviderManager,
        completion: @escaping () -> Void = {}
    ) {
        let uniqueIdentifiers = identifiers.reduce(into: [String: NSFileProviderItemIdentifier]()) {
            $0[$1.rawValue] = $1
        }.values

        Task { [weak self] in
            defer { completion() }
            guard let self else { return }
            var remaining = Array(uniqueIdentifiers)
            for attempt in 0..<12 {
                if Task.isCancelled { return }
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }

                let candidates = remaining
                remaining = await withActionLock {
                    var failed: [NSFileProviderItemIdentifier] = []
                    for identifier in candidates {
                        if self.isEffectivelyPinned(
                            identifier, uri: self.uri(for: identifier))
                        {
                            continue
                        }
                        if !(await self.evictWhenAllowed(identifier, manager: manager)) {
                            failed.append(identifier)
                        }
                    }
                    return failed
                }
                if remaining.isEmpty { return }
            }
            let unresolved = remaining.prefix(3).map(\.rawValue).joined(separator: ", ")
            self.logger.error(
                "deferred eviction still pending after retries: \(unresolved, privacy: .public)"
            )
        }
    }

    /// A working-set listing with the verification data used to build it.
    struct WorkingSetSnapshot {
        let items: [FileProviderItem]
        /// Containers re-listed in this snapshot.
        let freshListings: [String: Set<String>]
        /// Containers proven absent on the server.
        let extinctURIs: [String]
    }

    /// Return the current working set, including pinned subtrees.
    func workingSetItems() async throws -> [FileProviderItem] {
        try await workingSetSnapshot().items
    }

    /// Build the current working set and track fresh listings.
    func workingSetSnapshot(includePinnedDescendants: Bool = true) async throws -> WorkingSetSnapshot {
        var itemsByIdentifier: [String: FileProviderItem] = [:]
        var foldersToWalk: [NSFileProviderItemIdentifier] = []
        var queuedFolders: Set<String> = []
        /// Containers re-listed during this run and their current children.
        var freshListings: [String: Set<String>] = [:]
        /// Containers proven absent during this run.
        var extinctContainers: Set<String> = []

        func add(_ item: FileProviderItem) {
            itemsByIdentifier[item.itemIdentifier.rawValue] = item
        }

        func queueFolder(_ identifier: NSFileProviderItemIdentifier) {
            if queuedFolders.insert(identifier.rawValue).inserted {
                foldersToWalk.append(identifier)
            }
        }

        for item in cachedItems() {
            add(item)
        }

        // Keep top-level items current.
        let rootItems = try await allChildren(of: .rootContainer)
        freshListings[NSFileProviderItemIdentifier.rootContainer.rawValue] = Set(
            rootItems.map { $0.itemIdentifier.rawValue })
        for item in rootItems {
            add(item)
        }

        // Re-list folders Finder has presented during this extension session.
        for container in presentedContainersSnapshot() where container != .rootContainer {
            do {
                let children = try await allChildren(of: container)
                freshListings[container.rawValue] = Set(
                    children.map { $0.itemIdentifier.rawValue })
                for item in children {
                    add(item)
                }
            } catch CloudreveError.noSuchItem {
                logger.notice(
                    "presented folder \(container.rawValue, privacy: .public) no longer exists"
                )
                extinctContainers.insert(container.rawValue)
            } catch {
                logger.error(
                    "presented folder \(container.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                // Keep the lightweight refresh event pending after a transient
                // error instead of acknowledging an incomplete reconciliation.
                if !includePinnedDescendants { throw error }
            }
        }

        // Routine refreshes re-list root and presented folders only. A full
        // anchor repair and Keep Downloaded enumeration retain subtree walks.
        if includePinnedDescendants {
            let pinned = pinnedIdentifiersSnapshot()
            for rawIdentifier in pinned {
                let identifier = NSFileProviderItemIdentifier(rawIdentifier)
                if identifier == .rootContainer {
                    queueFolder(identifier)
                    continue
                }
                do {
                    let pinnedItem = try await item(
                        for: identifier, displayName: domain.displayName,
                        refreshIfStale: true)
                    add(pinnedItem)
                    if pinnedItem.contentType.conforms(to: .folder) {
                        queueFolder(identifier)
                    }
                } catch CloudreveError.noSuchItem {
                    logger.notice(
                        "pinned item \(rawIdentifier, privacy: .public) no longer exists"
                    )
                    extinctContainers.insert(rawIdentifier)
                }
            }

            // Include queued transitions even after an item is unpinned.
            for uri in pendingItemUpdatesSnapshot() {
                do {
                    let file = try await client.fileInfoWithShareState(uri: uri)
                    for parent in try await parentItemsForUpdate(file) { add(parent) }
                    let pendingItem = makeItem(file)
                    add(pendingItem)
                    if pendingItem.contentType.conforms(to: .folder) {
                        queueFolder(pendingItem.itemIdentifier)
                    }
                } catch CloudreveError.noSuchItem {
                    // The remote delete superseded the update.
                } catch where ReplayFailure.classify(error) == .permanent {
                    logger.error(
                        "pending policy update \(uri, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            while !foldersToWalk.isEmpty {
                if Task.isCancelled { break }
                let folder = foldersToWalk.removeFirst()
                do {
                    let children = try await allChildren(of: folder)
                    freshListings[folder.rawValue] = Set(
                        children.map { $0.itemIdentifier.rawValue })
                    for child in children {
                        add(child)
                        if child.contentType.conforms(to: .folder) {
                            queueFolder(child.itemIdentifier)
                        }
                    }
                } catch CloudreveError.noSuchItem {
                    logger.notice(
                        "working-set folder \(folder.rawValue, privacy: .public) no longer exists"
                    )
                    extinctContainers.insert(folder.rawValue)
                } catch {
                    logger.error(
                        "working-set folder \(folder.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

        }

        // Remove cached items proven absent by fresh listings.
        let extinctURIs = extinctContainers.map {
            self.uri(for: NSFileProviderItemIdentifier($0))
        }
        var pruned: [NSFileProviderItemIdentifier] = []
        for (rawIdentifier, item) in itemsByIdentifier {
            if extinctContainers.contains(rawIdentifier)
                || extinctURIs.contains(where: { extinct in
                    self.uri(for: item.itemIdentifier).hasPrefix(extinct + "/")
                })
            {
                itemsByIdentifier.removeValue(forKey: rawIdentifier)
                pruned.append(item.itemIdentifier)
                continue
            }
            let parent = item.parentItemIdentifier.rawValue
            if let present = freshListings[parent], !present.contains(rawIdentifier) {
                itemsByIdentifier.removeValue(forKey: rawIdentifier)
                pruned.append(item.itemIdentifier)
            }
        }
        if !pruned.isEmpty {
            evictCachedItems(withIdentifiers: pruned)
        }
        return WorkingSetSnapshot(
            items: Array(itemsByIdentifier.values),
            freshListings: freshListings,
            extinctURIs: extinctURIs)
    }

    /// Item versions currently in the session cache, for change detection.
    private func cacheVersionsSnapshot() -> [String: NSFileProviderItemVersion] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.mapValues { $0.itemVersion }
    }

    private func identityMapsSnapshot() -> (
        byIdentifier: [String: String], byURI: [String: String]
    ) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (uriByIdentifier, identifierByURI)
    }

    /// The parent index is maintained with the identity maps. Candidate seeding
    /// visits this folder's children instead of scanning every known drive item.
    private func immediateIdentityChildren(of uri: String) -> [(String, String)] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (identityChildrenByParent[uri] ?? []).compactMap { identifier in
            uriByIdentifier[identifier].map { (identifier, $0) }
        }
    }

    /// Reconcile cached working-set items with the server.
    func reconcileWorkingSet(includePinnedDescendants: Bool = true) async throws -> (
        updated: [FileProviderItem], deleted: [NSFileProviderItemIdentifier]
    ) {
        let before = cacheVersionsSnapshot()
        // Snapshot identities before workingSetSnapshot evicts missing entries.
        // Reading them afterwards loses the very IDs Finder must be told to delete.
        let identityMaps = identityMapsSnapshot()
        let snapshot = try await workingSetSnapshot(includePinnedDescendants: includePinnedDescendants)
        let currentIDs = Set(snapshot.items.map { $0.itemIdentifier.rawValue })

        var updated: [FileProviderItem] = []
        for item in snapshot.items {
            guard let old = before[item.itemIdentifier.rawValue] else {
                updated.append(item)
                continue
            }
            if old.contentVersion != item.itemVersion.contentVersion
                || old.metadataVersion != item.itemVersion.metadataVersion
            {
                updated.append(item)
            }
        }

        let identities = identityMaps.byIdentifier
        let identifierByURI = identityMaps.byURI

        let rootRaw = NSFileProviderItemIdentifier.rootContainer.rawValue
        var deleted: [NSFileProviderItemIdentifier] = []
        for (raw, uri) in identities where !currentIDs.contains(raw) {
            if snapshot.extinctURIs.contains(where: { uri == $0 || uri.hasPrefix($0 + "/") }) {
                deleted.append(NSFileProviderItemIdentifier(raw))
                continue
            }
            let parentURI = parentPath(of: uri)
            let parentRaw = parentURI == rootPath ? rootRaw : identifierByURI[parentURI]
            guard let parentRaw, let present = snapshot.freshListings[parentRaw],
                !present.contains(raw)
            else { continue }
            deleted.append(NSFileProviderItemIdentifier(raw))
        }
        return (updated, deleted)
    }

    private func allChildren(
        of identifier: NSFileProviderItemIdentifier
    ) async throws -> [FileProviderItem] {
        var result: [FileProviderItem] = []
        var page: String? = nil
        repeat {
            let (items, nextPage) = try await children(of: identifier, page: page)
            result.append(contentsOf: items)
            page = nextPage
        } while page != nil
        return result
    }

    /// Fetch the immediate contents of a folder Finder has opened.
    func currentChildren(
        of identifier: NSFileProviderItemIdentifier
    ) async throws -> [FileProviderItem] {
        try await allChildren(of: identifier)
    }

    /// Apply menu-app requests without evicting downloaded contents.
    func applyPinRequests() {
        // Enumeration must not wait on actions that await Finder enumeration.
        pinRequestLock.lock()
        defer { pinRequestLock.unlock() }
        struct Request: Decodable { let drive_id: String; let uri: String }
        let database: FileProviderStateDatabase
        let requests: [[String]]
        do {
            database = try FileProviderStateDatabase(root: pinRequestDirectoryOverride?.deletingLastPathComponent()
                ?? FileProviderStateDatabase.defaultRoot)
            try database.importRecords("pin-requests")
            requests = try database.rows("SELECT key,payload FROM fp_records WHERE namespace='pin-requests' ORDER BY key")
        } catch {
            logger.error("could not read pin requests: \(error.localizedDescription, privacy: .public)")
            return
        }
        for row in requests where row[0].hasSuffix(".json") {
            guard let request = try? JSONDecoder().decode(Request.self, from: Data(row[1].utf8)),
                request.drive_id == self.drive.id else { continue }
            let uri = Self.canonicalURI(request.uri)
            let root = Self.canonicalURI(self.rootPath).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard uri == root || uri.hasPrefix(root + "/") else { continue }
            let matches = self.pinnedIdentifiersSnapshot().filter {
                Self.canonicalURI(self.uri(for: NSFileProviderItemIdentifier($0))) == uri
            }
            for raw in matches { self.setPinned(false, for: NSFileProviderItemIdentifier(raw)) }
            self.recordPendingItemUpdates(uris: [uri])
            // Acknowledge only after the persisted selection is updated.
            if let saved = try? Data(contentsOf: self.pinnedFileURL),
                let pins = try? JSONDecoder().decode([String].self, from: saved),
                Set(pins).isDisjoint(with: matches) {
                do {
                    try database.execute("DELETE FROM fp_records WHERE namespace='pin-requests' AND key=? AND payload=?", row)
                    logger.notice("applied pin removal for \(uri, privacy: .public)")
                } catch {
                    logger.error("could not acknowledge pin removal: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    @discardableResult
    func setPinned(_ pinned: Bool, for identifier: NSFileProviderItemIdentifier) -> PinChange {
        cacheLock.lock()
        let previous = pinnedIdentifiers.contains(identifier.rawValue)
        pinRevision &+= 1
        pinRevisionByIdentifier[identifier.rawValue] = pinRevision
        let change = PinChange(wasPinned: previous, revision: pinRevision)
        if pinned {
            pinnedIdentifiers.insert(identifier.rawValue)
        } else {
            pinnedIdentifiers.remove(identifier.rawValue)
        }
        refreshCachedPinStatesLocked()
        persistPins(pinnedIdentifiers.sorted())
        cacheLock.unlock()
        return change
    }

    /// Undo a cancelled or failed action only if a newer action has not
    /// superseded its requested state.
    func restorePin(_ change: PinChange, for identifier: NSFileProviderItemIdentifier) -> Bool {
        cacheLock.lock()
        guard pinRevisionByIdentifier[identifier.rawValue] == change.revision else {
            cacheLock.unlock()
            return false
        }
        pinRevision &+= 1
        pinRevisionByIdentifier[identifier.rawValue] = pinRevision
        if change.wasPinned {
            pinnedIdentifiers.insert(identifier.rawValue)
        } else {
            pinnedIdentifiers.remove(identifier.rawValue)
        }
        refreshCachedPinStatesLocked()
        persistPins(pinnedIdentifiers.sorted())
        cacheLock.unlock()
        return true
    }

    private func refreshCachedPinStatesLocked() {
        // Refresh descendants already cached by File Provider.
        for (rawIdentifier, cached) in cache {
            let cachedIdentifier = NSFileProviderItemIdentifier(rawIdentifier)
            let cachedURI = cachedIdentifier == .rootContainer
                ? rootPath
                : (uriByIdentifier[rawIdentifier] ?? Self.uri(fromPath: rawIdentifier))
            let explicitlyPinned = pinnedIdentifiers.contains(rawIdentifier)
            let effectivelyPinned = isEffectivelyPinnedLocked(
                cachedIdentifier, uri: cachedURI)
            if cached.pinned != explicitlyPinned
                || cached.effectivelyPinned != effectivelyPinned
            {
                cache[rawIdentifier] = cached.withPinned(
                    explicitlyPinned, effectivelyPinned: effectivelyPinned)
            }
        }
    }

    private func persistPins(_ snapshot: [String]) {
        do {
            try FileManager.default.createDirectory(
                at: pinnedFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: pinnedFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist pinned items: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Anchors and change replay

    /// Anchor for the last delivered event: "evt-<millis>".
    func currentSyncAnchor() throws -> NSFileProviderSyncAnchor {
        let lastTs = try FileProviderStateDatabase().eventSnapshot(drive: drive.id, since: nil).latest
        return NSFileProviderSyncAnchor(Data("evt-\(lastTs)".utf8))
    }

    /// Return events after an anchor, or expire an unknown anchor.
    func changes(since anchorData: Data, for container: NSFileProviderItemIdentifier)
        throws -> ([FpEvent], NSFileProviderSyncAnchor, Bool)
    {
        guard let text = String(data: anchorData, encoding: .utf8),
            text.hasPrefix("evt-"), let since = Int64(text.dropFirst(4))
        else {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let snapshot = try FileProviderStateDatabase().eventSnapshot(drive: drive.id, since: since, limit: 32)
        guard since >= snapshot.floor, since <= snapshot.latest else {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let events = try snapshot.events.map { try JSONDecoder().decode(FpEvent.self, from: $0) }
        // A rescan marker invalidates all later anchors.
        if snapshot.hasRescan || events.contains(where: { $0.type == "rescan" && $0.ts > since }) {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let relevant = events.filter { $0.ts > since }
        // One refresh request covers all older requests in this snapshot.
        // Never repeat a folder traversal once for every reconnect marker.
        let latestRefresh = relevant.last(where: { $0.type == "refresh_presented" })?.ts
        let filtered = relevant.filter {
            ($0.type != "refresh_presented" || $0.ts == latestRefresh)
                && changeTouchesContainer($0, container: container)
        }
        var page: [FpEvent] = []
        var cost = 0
        for event in filtered {
            let weight = max(1, (event.presentation?.items.count ?? 0)
                + (event.presentation?.deleted.count ?? 0))
            if !page.isEmpty && cost + weight > Self.changePageSize { break }
            page.append(event)
            cost += weight
            if cost >= Self.changePageSize { break }
        }
        let hasBufferedChanges = filtered.count > page.count
        let moreComing = hasBufferedChanges || snapshot.hasMore
        // Advance only over records actually read. A bounded database read may
        // still have later relevant events even when this batch is unrelated.
        let nextTimestamp = hasBufferedChanges ? (page.last?.ts ?? since) : snapshot.readThrough
        let newAnchor = NSFileProviderSyncAnchor(Data("evt-\(nextTimestamp)".utf8))
        logger.notice(
            "changes for \(container.rawValue, privacy: .public): anchor \(since), relevant \(relevant.count), delivered \(page.count), next \(nextTimestamp), moreComing \(moreComing)"
        )
        return (page, newAnchor, moreComing)
    }

    /// Convert an event path to a canonical URI.
    func uri(forEventPath path: String) -> String {
        if path.hasPrefix("cloudreve://") {
            return Self.canonicalURI(path)
        }
        return Self.canonicalURI(drive.remote_path + (path.hasPrefix("/") ? path : "/" + path))
    }

    private func changeTouchesContainer(
        _ change: FpEvent, container: NSFileProviderItemIdentifier
    ) -> Bool {
        if change.type == "refresh_presented" || change.type == "presented_page" {
            return container == .workingSet
        }
        let fromURI = uri(forEventPath: change.from)
        let toURI = change.to.map { uri(forEventPath: $0) }
        let parentOf = { (uri: String) -> String in
            var u = uri
            if u.hasSuffix("/") { u.removeLast() }
            guard let idx = u.lastIndex(of: "/") else { return self.rootPath }
            let parent = String(u[..<idx])
            if parent == self.drive.remote_path || parent == "cloudreve://my" || parent.isEmpty {
                return self.rootPath
            }
            return Self.canonicalURI(parent)
        }

        // The working set is the domain-wide incremental feed. Every change
        // must pass through it, including a new hierarchy below a folder that
        // has never been opened. Items remain placeholders; this updates
        // metadata only and does not download file contents. The persistent
        // audit establishes its first snapshot without emitting events, and
        // paging above bounds later recovery bursts.
        if container == .workingSet { return true }

        let containerURI = container == .rootContainer
            ? rootPath : Self.canonicalURI(uri(for: container))
        if fromURI == containerURI || toURI == containerURI { return true }
        return parentOf(fromURI) == containerURI || (toURI.map { parentOf($0) } == containerURI)
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
        logger.notice("marked item locked: \(itemURI, privacy: .public)")
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

    // MARK: - Paged presented-folder recovery

    struct PresentedDeletion: Codable {
        let identifier: String
        let uri: String
    }

    struct PresentedPage: Codable {
        let items: [RemoteFile]
        let deleted: [PresentedDeletion]
    }

    struct PresentedFolder: Codable {
        let id: String
        let identifier: String
        let uri: String
        var page: String? = nil
        var seeded = false
        var tokens: [String] = []
        var retryAfter: Double = 0
        var failures: Int = 0
        var verifyingMissing = false
        // Optional for compatibility with queues saved by older versions.
        var recursive: Bool? = nil
        var validated_sequence: Int64? = nil
    }

    struct PresentedRefreshState: Codable {
        var requested: Int64 = 0
        var completed: Int64 = 0
        var active: Int64 = 0
        var pending = false
        var latest_sequence: Int64 = 0
        var folders: [PresentedFolder] = []
        var pages_checked: Int? = nil
        var items_checked: Int? = nil
        var folders_checked: Int? = nil
    }

    private func refreshDatabase() throws -> FileProviderStateDatabase {
        try FileProviderStateDatabase(root: stateDirectoryOverride ?? FileProviderStateDatabase.defaultRoot)
    }

    private func readPresentedRefresh(_ database: FileProviderStateDatabase) throws -> PresentedRefreshState {
        let rows = try database.rows(
            "SELECT payload FROM fp_records WHERE namespace='fp-folder-refresh' AND key=?", [drive.id])
        guard let payload = rows.first?.first else { return PresentedRefreshState() }
        return try JSONDecoder().decode(PresentedRefreshState.self, from: Data(payload.utf8))
    }

    private func savePresentedRefresh(_ state: PresentedRefreshState, to database: FileProviderStateDatabase) throws {
        var state = state
        state.pending = state.requested > state.completed || !state.folders.isEmpty
        let payload = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try database.execute(
            "INSERT INTO fp_records(namespace,key,payload) VALUES('fp-folder-refresh',?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload",
            [drive.id, payload])
    }

    /// Persist before the working-set anchor acknowledges the marker. Network
    /// work belongs to the independent worker, never to change replay.
    func requestPresentedRefresh(sequence: Int64) throws {
        let database = try refreshDatabase()
        try database.transaction {
            var state = try readPresentedRefresh(database)
            state.requested = max(state.requested, sequence)
            try savePresentedRefresh(state, to: database)
        }
        resumePresentedRefresh()
    }

    func needsSubtreeRefresh(_ file: RemoteFile) -> Bool {
        let expected = Self.canonicalIdentifier(file.presentationIdentity ?? ItemIdentity.remoteID(file.id, fallbackURI: file.path))
        let identities = identityMapsSnapshot()
        return identities.byIdentifier[expected] != Self.canonicalURI(file.path)
            && identities.byURI[Self.canonicalURI(file.path)] == nil
    }

    /// A new or moved directory can contain descendants with old timestamps.
    /// Discover that affected subtree, without scanning unrelated drive folders.
    func requestSubtreeRefresh(_ file: RemoteFile) throws {
        guard file.isFolder, file.metadata?["sys:shared_redirect"] == nil else { return }
        let path = Self.canonicalURI(file.path)
        guard path != rootPath else { return }
        let identifier = presentedIdentifier(for: file)
        let database = try refreshDatabase()
        try database.transaction {
            var state = try readPresentedRefresh(database)
            if !state.pending {
                state.pages_checked = 0
                state.items_checked = 0
                state.folders_checked = 0
            }
            if let index = state.folders.firstIndex(where: { $0.identifier == identifier && $0.uri == path }) {
                // Restart a shallow listing when promoting it to a subtree check.
                if state.folders[index].recursive != true {
                    try database.execute("DELETE FROM fp_records WHERE namespace=?", [candidateNamespace(state.folders[index])])
                    state.folders[index] = PresentedFolder(id: UUID().uuidString, identifier: identifier, uri: path, recursive: true)
                }
            } else {
                state.folders.insert(PresentedFolder(id: UUID().uuidString, identifier: identifier, uri: path, recursive: true), at: 0)
            }
            try savePresentedRefresh(state, to: database)
        }
        resumePresentedRefresh()
    }

    /// Every callback resumes durable unfinished work after extension suspension.
    func resumePresentedRefresh() {
        presentedRefreshLock.lock()
        guard !presentedRefreshRunning else { presentedRefreshLock.unlock(); return }
        presentedRefreshRunning = true
        presentedRefreshLock.unlock()
        Task { [self] in
            defer { finishPresentedRefreshWorker() }
            do {
                try await repairPreviouslyMovedFolders()
                while !Task.isCancelled {
                    guard let folder = try nextPresentedFolder() else { return }
                    if folder.retryAfter > Date().timeIntervalSince1970 {
                        try await Task.sleep(nanoseconds: UInt64(max(0.05, min(2, folder.retryAfter - Date().timeIntervalSince1970)) * 1_000_000_000))
                        continue
                    }
                    let database = try refreshDatabase()
                    if try hasUnappliedFolderMove(database) {
                        // A path-based 404 is unsafe until queued moves have
                        // updated the stable identity map.
                        try await Task.sleep(nanoseconds: 200_000_000)
                        continue
                    }
                    let head = try database.eventSnapshot(drive: drive.id, since: nil).latest
                    do {
                        if folder.verifyingMissing {
                            try await verifyMissingPresentedItems(folder, expectedHead: head)
                            if try refreshDatabase().eventSnapshot(drive: drive.id, since: nil).latest > head { await signalWorkingSet() }
                            continue
                        }
                        let result: CloudreveClient.ListResult
                        if let presentedPageLoader { result = try await presentedPageLoader(folder.uri, folder.page) }
                        else { result = try await client.listDirectory(uri: folder.uri, page: folder.page) }
                        try commitPresentedPage(folder, files: result.files.filter { !Self.isIgnored(filename: $0.name) }, nextPage: result.nextPage, expectedHead: head)
                        if try refreshDatabase().eventSnapshot(drive: drive.id, since: nil).latest > head { await signalWorkingSet() }
                    } catch CloudreveError.noSuchItem {
                        // A disappeared container is definitive. Preserve its
                        // stable identity in the deletion result.
                        if folder.identifier == NSFileProviderItemIdentifier.rootContainer.rawValue {
                            try deferPresentedFolder(folder)
                        } else {
                            try commitMissingPresentedFolder(folder, expectedHead: head)
                            await signalWorkingSet()
                        }
                    } catch {
                        logger.error("presented refresh deferred for \(folder.uri, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        try deferPresentedFolder(folder)
                    }
                    await Task.yield()
                }
            } catch {
                logger.error("presented refresh queue paused: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Earlier builds could acknowledge a folder move and then delete its
    /// children at their old paths. Replay only retained, already-applied move
    /// destinations once. The cursor survives suspension, and no drive-wide
    /// scan or domain reset is needed to repair those affected subtrees.
    private func repairPreviouslyMovedFolders() async throws {
        struct Repair: Codable { var cursor: Int64; let target: Int64; var done: Bool }
        let database = try refreshDatabase()
        var repair: Repair
        if let data = try database.get("fp-move-repair-v190", drive.id) {
            repair = try JSONDecoder().decode(Repair.self, from: data)
        } else {
            let payload = try database.get("fp-applied", drive.id)
            let applied = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int64] }?["sequence"] ?? 0
            repair = Repair(cursor: 0, target: applied, done: false)
            try database.put("fp-move-repair-v190", drive.id, JSONEncoder().encode(repair))
        }
        guard !repair.done else { return }
        while !Task.isCancelled {
            let rows = try database.rows("SELECT sequence,payload FROM fp_events WHERE drive=? AND sequence>? AND sequence<=? AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.type') END='rename' ORDER BY sequence LIMIT 16", [drive.id, String(repair.cursor), String(repair.target)])
            if rows.isEmpty {
                repair.done = true
                try database.put("fp-move-repair-v190", drive.id, JSONEncoder().encode(repair))
                return
            }
            for row in rows {
                let event = try JSONDecoder().decode(FpEvent.self, from: Data(row[1].utf8))
                if let to = event.to {
                    do {
                        let file = try await client.fileInfoWithShareState(uri: uri(forEventPath: to))
                        if file.isFolder {
                            _ = try await parentItemsForUpdate(file)
                            _ = makeItem(file)
                            try requestSubtreeRefresh(file)
                            logger.notice("queued repair of previously moved folder \(file.path, privacy: .public)")
                        }
                    } catch CloudreveError.noSuchItem {
                        // It moved again or was deleted. Later destinations are
                        // checked independently, never turned into deletions here.
                    }
                }
                repair.cursor = Int64(row[0])!
                try database.put("fp-move-repair-v190", drive.id, JSONEncoder().encode(repair))
            }
        }
    }

    private func finishPresentedRefreshWorker() {
        presentedRefreshLock.lock()
        presentedRefreshRunning = false
        presentedRefreshLock.unlock()
        // A marker can arrive between the worker's empty read and this release.
        // The persisted request makes that race recoverable without another event.
        if let state = try? readPresentedRefresh(refreshDatabase()), state.pending {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.resumePresentedRefresh()
            }
        }
    }

    private func nextPresentedFolder() throws -> PresentedFolder? {
        let database = try refreshDatabase()
        return try database.transaction {
            var state = try readPresentedRefresh(database)
            if state.folders.isEmpty {
                state.completed = max(state.completed, state.active)
                guard state.requested > state.completed else {
                    try savePresentedRefresh(state, to: database)
                    return nil
                }
                state.active = state.requested
                state.pages_checked = 0
                state.items_checked = 0
                state.folders_checked = 0
                let identifiers = [.rootContainer] + presentedContainersSnapshot().filter { $0 != .rootContainer }
                state.folders = identifiers.map {
                    PresentedFolder(id: UUID().uuidString, identifier: $0.rawValue, uri: Self.canonicalURI(uri(for: $0)))
                }
            }
            // Queued pages may have been captured before a folder move.
            // Restart them at the current path, with a fresh request identity so
            // an in-flight response for the old path cannot commit afterwards.
            let identities = identityMapsSnapshot().byIdentifier
            for index in state.folders.indices {
                let old = state.folders[index]
                if let current = identities[old.identifier], current != old.uri {
                    try database.execute("DELETE FROM fp_records WHERE namespace=?", [candidateNamespace(old)])
                    state.folders[index] = PresentedFolder(id: UUID().uuidString,
                        identifier: old.identifier, uri: current, recursive: old.recursive)
                }
            }
            // Round-robin pages prevent a large folder starving smaller ones.
            let now = Date().timeIntervalSince1970
            let index = state.folders.firstIndex(where: { $0.retryAfter <= now }) ?? 0
            var folder = state.folders.remove(at: index)
            if !folder.seeded {
                let namespace = candidateNamespace(folder)
                for (identifier, uri) in immediateIdentityChildren(of: folder.uri) {
                    try database.execute("INSERT OR IGNORE INTO fp_records(namespace,key,payload) VALUES(?,?,?)", [namespace, identifier, uri])
                }
                folder.seeded = true
            }
            state.folders.append(folder)
            try savePresentedRefresh(state, to: database)
            return folder
        }
    }

    /// Cursor and result commit together. An interrupted/failed page cannot
    /// infer deletions or lose updates. A concurrent live journal commit causes
    /// a retry instead of publishing an older listing after newer live metadata.
    func commitPresentedPage(_ folder: PresentedFolder, files: [RemoteFile], nextPage: String?, expectedHead: Int64) throws {
        let database = try refreshDatabase()
        try database.transaction {
            var state = try readPresentedRefresh(database)
            guard let index = state.folders.firstIndex(where: { $0.id == folder.id && $0.page == folder.page }) else { return }
            guard try !hasUnappliedFolderMove(database) else { return }
            if let current = identityMapsSnapshot().byIdentifier[folder.identifier], current != folder.uri { return }
            guard try canCommitPresentedResult(folder, paths: files.map(\.path), expectedHead: expectedHead, database: database) else {
                try restartPresentedFolder(at: index, state: &state, database: database)
                return
            }
            var updated = state.folders[index]
            updated.validated_sequence = try database.rows("SELECT latest FROM fp_event_heads WHERE drive=?", [drive.id]).first?.first.flatMap(Int64.init)
            state.pages_checked = (state.pages_checked ?? 0) + 1
            state.items_checked = (state.items_checked ?? 0) + files.count
            if let nextPage, updated.tokens.contains(nextPage) {
                throw CloudreveError.badResponse("The server repeated a folder page")
            }
            for file in files {
                try database.execute("DELETE FROM fp_records WHERE namespace=? AND key=?", [candidateNamespace(folder), presentedIdentifier(for: file)])
            }
            // Only a completed earlier listing establishes which newly seen
            // folders are additions. First visits stay shallow, even with
            // thousands of pre-existing directories in the account root.
            let hasBaseline = try !database.rows("SELECT key FROM fp_records WHERE namespace=? AND key=?", ["fp-folder-baselines-\(drive.id)", folder.identifier]).isEmpty
            let identities = identityMapsSnapshot().byIdentifier
            var discover: [RemoteFile] = []
            for file in files where file.isFolder && file.metadata?["sys:shared_redirect"] == nil {
                let path = Self.canonicalURI(file.path)
                guard path != folder.uri, parentPath(of: path) == folder.uri else { continue }
                let identifier = presentedIdentifier(for: file)
                let knownPath = try identities[identifier] ?? database.rows("SELECT payload FROM fp_records WHERE namespace=? AND key=?", ["fp-folder-locations-\(drive.id)", identifier]).first?.first
                let memberNamespace = "fp-folder-members-\(drive.id)-\(folder.identifier)"
                let wasMember = try !database.rows("SELECT key FROM fp_records WHERE namespace=? AND key=?", [memberNamespace, identifier]).isEmpty
                if folder.recursive == true || (knownPath != nil && knownPath != path)
                    || (hasBaseline && !wasMember) {
                    discover.append(file)
                }
                try database.execute("INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload", [memberNamespace, identifier, folder.id])
                try database.execute("INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload", ["fp-folder-locations-\(drive.id)", identifier, path])
            }
            // Pagination is not a server snapshot. Verify each missing item
            // authoritatively after the listing before reporting any deletion.
            try appendPresentedResults(items: files, deleted: [], state: &state, database: database)
            state.folders.remove(at: index)
            for file in discover {
                let path = Self.canonicalURI(file.path)
                let identifier = presentedIdentifier(for: file)
                if let existing = state.folders.firstIndex(where: { $0.identifier == identifier && $0.uri == path }) {
                    if state.folders[existing].recursive != true {
                        let shallow = state.folders[existing]
                        try database.execute("DELETE FROM fp_records WHERE namespace=?", [candidateNamespace(shallow)])
                        state.folders[existing] = PresentedFolder(id: UUID().uuidString, identifier: identifier, uri: path, recursive: true)
                    }
                } else {
                    state.folders.append(PresentedFolder(id: UUID().uuidString, identifier: identifier, uri: path, recursive: true))
                }
            }
            if nextPage == nil {
                try database.execute("DELETE FROM fp_records WHERE namespace=? AND payload<>?", ["fp-folder-members-\(drive.id)-\(folder.identifier)", folder.id])
                try database.execute("INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,'complete') ON CONFLICT(namespace,key) DO NOTHING", ["fp-folder-baselines-\(drive.id)", folder.identifier])
            }
            if let nextPage {
                updated.page = nextPage
                updated.tokens.append(nextPage)
                updated.retryAfter = 0
                updated.failures = 0
                state.folders.append(updated)
            } else if try hasPresentedCandidates(updated, database: database) {
                updated.verifyingMissing = true
                updated.page = nil
                updated.retryAfter = 0
                updated.failures = 0
                state.folders.append(updated)
            } else {
                state.folders_checked = (state.folders_checked ?? 0) + 1
            }
            if state.folders.isEmpty { state.completed = max(state.completed, state.active) }
            try savePresentedRefresh(state, to: database)
        }
    }

    private func verifyMissingPresentedItems(_ folder: PresentedFolder, expectedHead: Int64) async throws {
        let candidates = try refreshDatabase().rows("SELECT key,payload FROM fp_records WHERE namespace=? ORDER BY key LIMIT 20", [candidateNamespace(folder)]).map { ($0[0], $0[1]) }
        var current: [RemoteFile] = []
        var deleted: [PresentedDeletion] = []
        for (identifier, uri) in candidates {
            do {
                let file: RemoteFile
                if let presentedMissingLookup { file = try await presentedMissingLookup(uri) }
                else { file = try await client.fileInfoWithShareState(uri: uri) }
                let remoteIdentifier = file.presentationIdentity ?? ItemIdentity.remoteID(file.id, fallbackURI: file.path)
                if identifier.hasPrefix("cloudreve-item:/"), Self.canonicalIdentifier(remoteIdentifier) != Self.canonicalIdentifier(identifier) {
                    deleted.append(PresentedDeletion(identifier: identifier, uri: uri))
                }
                current.append(file)
            } catch CloudreveError.noSuchItem {
                deleted.append(PresentedDeletion(identifier: identifier, uri: uri))
            }
        }
        let database = try refreshDatabase()
        try database.transaction {
            var state = try readPresentedRefresh(database)
            guard let index = state.folders.firstIndex(where: { $0.id == folder.id && $0.verifyingMissing }) else { return }
            guard try !hasUnappliedFolderMove(database) else { return }
            if let current = identityMapsSnapshot().byIdentifier[folder.identifier], current != folder.uri { return }
            guard try canCommitPresentedResult(folder, paths: candidates.map { $0.1 }, expectedHead: expectedHead, database: database) else {
                try restartPresentedFolder(at: index, state: &state, database: database)
                return
            }
            state.folders[index].validated_sequence = try database.rows("SELECT latest FROM fp_event_heads WHERE drive=?", [drive.id]).first?.first.flatMap(Int64.init)
            for file in current where file.isFolder && file.metadata?["sys:shared_redirect"] == nil {
                let identifier = presentedIdentifier(for: file)
                try database.execute("INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload", ["fp-folder-members-\(drive.id)-\(folder.identifier)", identifier, folder.id])
                try database.execute("INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload", ["fp-folder-locations-\(drive.id)", identifier, Self.canonicalURI(file.path)])
            }
            try appendPresentedResults(items: current, deleted: deleted, state: &state, database: database)
            for (identifier, _) in candidates {
                try database.execute("DELETE FROM fp_records WHERE namespace=? AND key=?", [candidateNamespace(folder), identifier])
            }
            if try !hasPresentedCandidates(folder, database: database) {
                state.folders.remove(at: index)
                state.folders_checked = (state.folders_checked ?? 0) + 1
            }
            if state.folders.isEmpty { state.completed = max(state.completed, state.active) }
            try savePresentedRefresh(state, to: database)
        }
    }

    private func commitMissingPresentedFolder(_ folder: PresentedFolder, expectedHead: Int64) throws {
        let database = try refreshDatabase()
        try database.transaction {
            var state = try readPresentedRefresh(database)
            guard let index = state.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            guard try !hasUnappliedFolderMove(database) else { return }
            if let current = identityMapsSnapshot().byIdentifier[folder.identifier], current != folder.uri { return }
            guard try canCommitPresentedResult(folder, paths: [folder.uri], expectedHead: expectedHead, database: database) else {
                try restartPresentedFolder(at: index, state: &state, database: database)
                return
            }
            // The drive root itself cannot be deleted through a recovery result.
            guard folder.identifier != NSFileProviderItemIdentifier.rootContainer.rawValue else {
                throw CloudreveError.noSuchItem
            }
            try appendPresentedResults(items: [], deleted: [PresentedDeletion(identifier: folder.identifier, uri: folder.uri)], state: &state, database: database)
            state.folders.remove(at: index)
            state.folders_checked = (state.folders_checked ?? 0) + 1
            try database.execute("DELETE FROM fp_records WHERE namespace=? AND key=?", ["fp-folder-baselines-\(drive.id)", folder.identifier])
            try database.execute("DELETE FROM fp_records WHERE namespace=?", [candidateNamespace(folder)])
            if state.folders.isEmpty { state.completed = max(state.completed, state.active) }
            try savePresentedRefresh(state, to: database)
        }
    }

    /// A listing only conflicts with newer changes to its returned items or
    /// membership. Traffic in another directory must not starve this check.
    /// Structural changes since the preceding validated page restart the
    /// directory: offset/cursor pages do not form a stable server snapshot.
    /// Advancing that watermark after every commit bounds journal replay.
    private func canCommitPresentedResult(_ folder: PresentedFolder, paths: [String], expectedHead: Int64,
        database: FileProviderStateDatabase) throws -> Bool {
        guard let head = try database.rows("SELECT latest,floor FROM fp_event_heads WHERE drive=? AND imported=1", [drive.id]).first,
            let latest = Int64(head[0]), let floor = Int64(head[1]),
            expectedHead <= latest, min(expectedHead, folder.validated_sequence ?? expectedHead) >= floor else { return false }
        let protected = Set(paths.map(Self.canonicalURI) + [folder.uri])
        func changesMembership(_ uri: String) -> Bool {
            uri == folder.uri || folder.uri.hasPrefix(uri + "/") || parentPath(of: uri) == folder.uri
        }
        var cursor = min(expectedHead, folder.validated_sequence ?? expectedHead)
        while cursor < latest {
            let rows = try database.rows("SELECT sequence,payload FROM fp_events WHERE drive=? AND sequence>? AND sequence<=? ORDER BY sequence LIMIT 64", [drive.id, String(cursor), String(latest)])
            guard !rows.isEmpty else { return false }
            for row in rows {
                let sequence = Int64(row[0])!
                let event = try JSONDecoder().decode(FpEvent.self, from: Data(row[1].utf8))
                if event.type == "rescan" { return false }
                if event.type == "presented_page", sequence > expectedHead, let page = event.presentation {
                    if page.items.contains(where: { protected.contains(Self.canonicalURI($0.path)) })
                        || page.deleted.contains(where: { changesMembership(Self.canonicalURI($0.uri)) }) { return false }
                } else if ["create", "delete", "rename"].contains(event.type) {
                    if changesMembership(uri(forEventPath: event.from))
                        || event.to.map({ changesMembership(uri(forEventPath: $0)) }) == true { return false }
                } else if sequence > expectedHead {
                    if ["modify", "metadata"].contains(event.type), protected.contains(uri(forEventPath: event.from)) { return false }
                    if event.type == "metadata_rescan" { return false }
                    if event.type == "metadata_name", paths.contains(where: { $0.split(separator: "/").last.map(String.init) == event.from }) { return false }
                }
                cursor = sequence
            }
        }
        return true
    }

    private func restartPresentedFolder(at index: Int, state: inout PresentedRefreshState, database: FileProviderStateDatabase) throws {
        let old = state.folders[index]
        try database.execute("DELETE FROM fp_records WHERE namespace=?", [candidateNamespace(old)])
        state.folders[index] = PresentedFolder(id: UUID().uuidString, identifier: old.identifier,
            uri: old.uri, recursive: old.recursive)
        try savePresentedRefresh(state, to: database)
    }

    private func hasUnappliedFolderMove(_ database: FileProviderStateDatabase) throws -> Bool {
        let payload = try database.rows("SELECT payload FROM fp_records WHERE namespace='fp-applied' AND key=?", [drive.id]).first?.first
        let applied = payload.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Int64] }?["sequence"] ?? 0
        return try !database.rows("SELECT sequence FROM fp_events WHERE drive=? AND sequence>? AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.type') END='rename' LIMIT 1", [drive.id, String(applied)]).isEmpty
    }

    private func candidateNamespace(_ folder: PresentedFolder) -> String {
        "fp-folder-candidates-\(drive.id)-\(folder.id)"
    }

    private func hasPresentedCandidates(_ folder: PresentedFolder, database: FileProviderStateDatabase) throws -> Bool {
        try !database.rows("SELECT key FROM fp_records WHERE namespace=? LIMIT 1", [candidateNamespace(folder)]).isEmpty
    }

    private func deferPresentedFolder(_ folder: PresentedFolder) throws {
        let database = try refreshDatabase()
        try database.transaction {
            var state = try readPresentedRefresh(database)
            guard let index = state.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            state.folders[index].failures += 1
            state.folders[index].retryAfter = Date().timeIntervalSince1970
                + min(60, pow(2, Double(min(6, state.folders[index].failures))))
            try savePresentedRefresh(state, to: database)
        }
    }

    private func presentedIdentifier(for file: RemoteFile) -> String {
        let uri = Self.canonicalURI(file.path)
        let expected = Self.canonicalIdentifier(file.presentationIdentity ?? ItemIdentity.remoteID(file.id, fallbackURI: uri))
        guard let existing = identityMapsSnapshot().byURI[uri] else { return expected }
        // Retain compatible legacy URI identities, but never assign an old
        // stable remote identity to a different object at a reused path.
        return existing.hasPrefix("cloudreve-item:/") && expected.hasPrefix("cloudreve-item:/") && existing != expected
            ? expected : existing
    }

    private func appendPresentedResults(items: [RemoteFile], deleted: [PresentedDeletion], state: inout PresentedRefreshState, database: FileProviderStateDatabase) throws {
        let namespace = "fp-presented-versions-\(drive.id)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var changed: [RemoteFile] = []
        for item in items {
            let identifier = presentedIdentifier(for: item)
            let fingerprint = SHA256.hash(data: try encoder.encode(item)).map { String(format: "%02x", $0) }.joined()
            let previous = try database.rows("SELECT payload FROM fp_records WHERE namespace=? AND key=?", [namespace, identifier]).first?.first
            guard previous != fingerprint else { continue }
            changed.append(item)
            // This method always runs in the same transaction as page progress
            // and journal insertion. A failed insert cannot suppress the retry.
            try database.execute("INSERT INTO fp_records(namespace,key,payload) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload", [namespace, identifier, fingerprint])
        }
        for item in deleted {
            try database.execute("DELETE FROM fp_records WHERE namespace=? AND key=?", [namespace, item.identifier])
        }
        let items = changed
        guard let value = try database.rows("SELECT latest FROM fp_event_heads WHERE drive=? AND imported=1", [drive.id]).first?.first,
            var latest = Int64(value) else { throw CloudreveError.badResponse("The event journal is not ready") }
        let count = max(items.count, deleted.count)
        for start in stride(from: 0, to: count, by: Self.changePageSize) {
            latest = max(latest + 1, Int64(Date().timeIntervalSince1970 * 1000))
            let itemSlice = start < items.count ? Array(items[start..<min(start + Self.changePageSize, items.count)]) : []
            let deletedSlice = start < deleted.count ? Array(deleted[start..<min(start + Self.changePageSize, deleted.count)]) : []
            var event = FpEvent(ts: latest, type: "presented_page", from: "", to: nil, localEcho: false)
            event.presentation = PresentedPage(items: itemSlice, deleted: deletedSlice)
            let payload = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            try database.execute("INSERT INTO fp_events(drive,sequence,payload) VALUES(?,?,?)", [drive.id, String(latest), payload])
        }
        let cutoff = try database.rows("SELECT sequence FROM fp_events WHERE drive=? ORDER BY sequence DESC LIMIT 1 OFFSET 100000", [drive.id]).first?.first ?? "0"
        try database.execute("UPDATE fp_event_heads SET latest=?,floor=MAX(floor,?) WHERE drive=?", [String(latest), cutoff, drive.id])
        try database.execute("DELETE FROM fp_events WHERE drive=? AND sequence<=?", [drive.id, cutoff])
        state.latest_sequence = max(state.latest_sequence, latest)
    }

    func applyPresentedPage(_ page: PresentedPage) -> (items: [FileProviderItem], deleted: [NSFileProviderItemIdentifier]) {
        let revision = currentIdentityRevision()
        defer { persistIdentityBatch(since: revision) }
        var replaced: [NSFileProviderItemIdentifier] = []
        let items = page.items.map { file in
            let uri = Self.canonicalURI(file.path)
            let expected = Self.canonicalIdentifier(file.presentationIdentity ?? ItemIdentity.remoteID(file.id, fallbackURI: uri))
            if let existing = identityMapsSnapshot().byURI[uri],
                existing.hasPrefix("cloudreve-item:/"), expected.hasPrefix("cloudreve-item:/"), existing != expected {
                // An old path can now belong to a different remote object.
                // Never reuse its stable identity for the replacement.
                let old = NSFileProviderItemIdentifier(existing)
                evictCachedItems(withIdentifiers: [old])
                replaced.append(old)
            }
            return makeItem(file, persistIdentity: false)
        }
        let identities = identityMapsSnapshot()
        let deleted = page.deleted.compactMap { candidate -> NSFileProviderItemIdentifier? in
            // A newer move to another URI supersedes this listing's deletion.
            if let current = identities.byIdentifier[candidate.identifier], current != candidate.uri { return nil }
            // A delayed tombstone for the old identity must not cancel an
            // upload to a new object that has since reused the same name.
            if identities.byURI[candidate.uri] == nil || identities.byURI[candidate.uri] == candidate.identifier {
                recordRemoteDelete(for: candidate.uri)
            }
            return NSFileProviderItemIdentifier(candidate.identifier)
        }
        if !deleted.isEmpty { evictCachedItems(withIdentifiers: deleted) }
        var seen: Set<String> = []
        return (items, (replaced + deleted).filter { seen.insert($0.rawValue).inserted })
    }

    func recordAppliedAnchor(_ anchor: NSFileProviderSyncAnchor) {
        guard let text = String(data: anchor.rawValue, encoding: .utf8), text.hasPrefix("evt-"),
            let sequence = Int64(text.dropFirst(4)) else { return }
        do {
            let database = try refreshDatabase()
            try database.transaction {
                let old = try database.rows("SELECT payload FROM fp_records WHERE namespace='fp-applied' AND key=?", [drive.id]).first?.first
                let oldValue = old.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Int64] }?["sequence"] ?? 0
                let data = try JSONSerialization.data(withJSONObject: ["sequence": max(oldValue, sequence), "updated_at": Int64(Date().timeIntervalSince1970 * 1000)])
                try database.execute("INSERT INTO fp_records(namespace,key,payload) VALUES('fp-applied',?,?) ON CONFLICT(namespace,key) DO UPDATE SET payload=excluded.payload", [drive.id, String(decoding: data, as: UTF8.self)])
            }
        } catch { logger.error("could not record applied Finder anchor: \(error.localizedDescription, privacy: .public)") }
    }

    /// Native materialization may wait for Finder. Run it only after metadata
    /// delivery completes, and never download an online-only item merely because
    /// an incremental search discovered it.
    func scheduleDownloadedContentRefresh(_ identifiers: [NSFileProviderItemIdentifier]) {
        downloadedRefreshLock.lock()
        downloadedRefreshPending.formUnion(identifiers.map(\.rawValue))
        guard !downloadedRefreshRunning, !downloadedRefreshPending.isEmpty else { downloadedRefreshLock.unlock(); return }
        downloadedRefreshRunning = true
        downloadedRefreshLock.unlock()
        Task { [self] in
            while let identifier = nextDownloadedRefresh() {
                if let downloadedContentRefresher {
                    await downloadedContentRefresher(identifier)
                } else if await prepareDownloadedContentForRemoteUpdate(identifier) {
                    await refreshDownloadedContent([identifier])
                }
            }
        }
    }

    private func nextDownloadedRefresh() -> NSFileProviderItemIdentifier? {
        downloadedRefreshLock.lock()
        defer { downloadedRefreshLock.unlock() }
        guard let raw = downloadedRefreshPending.popFirst() else {
            downloadedRefreshRunning = false
            return nil
        }
        return NSFileProviderItemIdentifier(raw)
    }

    // MARK: - Item construction

    /// An event can arrive before its parent was ever enumerated, or after a
    /// local identity cache was lost. Never publish a child under a guessed URI
    /// identifier when Finder already knows its parent by a stable remote ID.
    func parentItemsForUpdate(_ file: RemoteFile) async throws -> [FileProviderItem] {
        var path = parentPath(of: Self.canonicalURI(file.path))
        var ancestors: [RemoteFile] = []
        var visited = Set<String>()
        while path != rootPath && path != "cloudreve:" && visited.insert(path).inserted {
            if identityMapsSnapshot().byURI[path] != nil { break }
            let parent = try await client.fileInfoWithShareState(uri: path)
            ancestors.append(parent)
            path = parentPath(of: path)
        }
        return ancestors.reversed().map { makeItem($0) }
    }

    /// Build 181 accidentally imported historical reset commands as new work.
    /// Recover only that migration from macOS's retained metadata, once. Normal
    /// resets use a separate namespace and cannot trigger this recovery.
    func recoverMigrationStateIfNeeded() async throws {
        await migrationRecoveryGate.acquire()
        do {
            try await recoverMigrationState()
            await migrationRecoveryGate.release()
        } catch {
            await migrationRecoveryGate.release()
            throw error
        }
    }

    private func recoverMigrationState() async throws {
        if migrationRecoveryCompleted { return }
        let database = try FileProviderStateDatabase(root: stateDirectoryOverride ?? FileProviderStateDatabase.defaultRoot)
        let key = "\(drive.id).marker"
        let recovered = try database.get("fp-migration-repair-v183", key)
        let legacy = try database.get("fp-reset", key)
        let acknowledged = try? Data(contentsOf: resetAcknowledgementURL)
        guard recovered == nil, let legacy, legacy == acknowledged else {
            migrationRecoveryCompleted = true
            return
        }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSFileProviderError(.providerNotFound)
        }
        let items = try await MaterializedStateRecovery.read(manager: manager)
        let recoveredState = MaterializedStateRecovery.reconstruct(items, root: rootPath,
            existing: identityMapsSnapshot().byIdentifier)
        mergeRecoveredIdentities(recoveredState.identities)
        for identifier in recoveredState.pins {
            setPinned(true, for: NSFileProviderItemIdentifier(identifier))
        }
        // Persist errors must not mark a partial repair as finished.
        try JSONEncoder().encode(identityMapsSnapshot().byIdentifier).write(to: identityFileURL, options: .atomic)
        try JSONEncoder().encode(Array(pinnedIdentifiersSnapshot())).write(to: pinnedFileURL, options: .atomic)
        // Replay metadata delivered with missing parent mappings after the reset.
        let date = try resetAcknowledgementURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let snapshot = try database.eventSnapshot(drive: drive.id, since: Int64(date.timeIntervalSince1970 * 1000))
        let events = try snapshot.events.map { try JSONDecoder().decode(FpEvent.self, from: $0) }
        let paths = events.compactMap { event -> String? in
            switch event.type {
            case "create", "modify", "metadata": return uri(forEventPath: event.from)
            case "rename": return event.to.map { uri(forEventPath: $0) }
            default: return nil
            }
        }
        recordPendingItemUpdates(uris: paths)
        let queued = try JSONDecoder().decode([String].self, from: Data(contentsOf: pendingPolicyUpdatesFileURL))
        guard Set(paths).isSubset(of: Set(queued)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try database.put("fp-migration-repair-v183", key, Data("recovered".utf8))
        migrationRecoveryCompleted = true
        logger.notice("recovered \(recoveredState.identities.count) identities and \(recoveredState.pins.count) pin selections from Finder")
    }

    private func mergeRecoveredIdentities(_ identities: [String: String]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        for (identifier, uri) in identities {
            // Do not replace an identity learned by a concurrent live callback.
            if let existing = identifierByURI[uri], existing != identifier { continue }
            if let previous = uriByIdentifier[identifier], previous != uri {
                identifierByURI.removeValue(forKey: previous)
            }
            if let previous = uriByIdentifier[identifier] {
                identityChildrenByParent[parentPath(of: previous)]?.remove(identifier)
            }
            uriByIdentifier[identifier] = uri
            identityChildrenByParent[parentPath(of: uri), default: []].insert(identifier)
            identifierByURI[uri] = identifier
            identityRevision &+= 1
        }
    }

    /// Writable capabilities; trash is handled by the server.
    private static let writableCapabilities: NSFileProviderItemCapabilities = [
        .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting,
        .allowsDeleting,
    ]

    func makeItem(
        _ file: RemoteFile,
        preservingIdentifier preserved: NSFileProviderItemIdentifier? = nil,
        metadataRevision: Data? = nil,
        persistIdentity: Bool = true
    ) -> FileProviderItem {
        let filePath = Self.canonicalURI(file.path)
        let identifier = identifier(for: file, preserving: preserved)
        let parentPath = parentPath(of: filePath)
        let parent: NSFileProviderItemIdentifier =
            (parentPath == rootPath || filePath == rootPath)
            ? .rootContainer
            : self.identifier(forURI: parentPath)

        // Cloudreve uses primary_entity as the optimistic upload version.
        let remoteVersion = file.primary_entity
        let versionBasis =
            remoteVersion.map { "entity:\($0)" }
            ?? file.metadata?["etag"] ?? file.metadata?["hash"]
            ?? "\(file.updated_at ?? "")#\(file.size)"
        var version = versionBasis.data(using: .utf8) ?? Data()
        if let metadataRevision { version += metadataRevision }
        let locked = isLockActive(for: filePath)
            || UploadConflictStore.load(driveID: drive.id, uri: filePath) != nil
        // Invalidate Finder's old thumbnail cache once.
        let thumbnailVersion = "\(versionBasis)#thumbnail-v1".data(using: .utf8) ?? version

        let item = FileProviderItem(
            identifier: identifier,
            parentIdentifier: parent,
            filename: file.name,
            contentType: file.isFolder
                ? .folder
                : (UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data),
            documentSize: file.isFolder ? nil : Int(file.size),
            childItemCount: nil,
            capabilities: file.isFolder
                ? Self.writableCapabilities.union(.allowsContentEnumerating)
                : Self.writableCapabilities,
            contentVersion: file.isFolder ? version : thumbnailVersion,
            metadataVersion: version,
            creationDate: CloudreveClient.parseDate(file.created_at),
            contentModificationDate: CloudreveClient.parseDate(file.updated_at),
            pinned: isPinned(identifier),
            effectivelyPinned: isEffectivelyPinned(identifier, uri: filePath),
            sharedState: file.shared ?? false,
            sharedByCurrentUserState: file.hasOwnShare(currentUserID: drive.user_id),
            sharedWithMeState: file.isSharedWithMe(currentUserID: drive.user_id)
                && (file.metadata?["sys:shared_redirect"] != nil
                    || !file.hasOwnShare(currentUserID: drive.user_id)),
            locked: locked,
            remoteID: file.id,
            remoteURI: filePath,
            remoteVersion: remoteVersion
        )
        cacheLock.lock()
        cache[identifier.rawValue] = item
        metadataRefreshAt[identifier.rawValue] = Date()
        cacheLock.unlock()
        recordIdentity(identifier, uri: filePath, isFolder: file.isFolder, persist: persistIdentity)
        return item
    }

    /// Items served during this session.
    func cachedItems() -> [FileProviderItem] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return Array(cache.values)
    }

    /// Refresh share flags for the root and presented Finder folders.
    func refreshPresentedShareMetadata() async -> [FileProviderItem] {
        var candidates: [String: FileProviderItem] = [:]
        func add(_ items: [FileProviderItem]) {
            for item in items { candidates[item.itemIdentifier.rawValue] = item }
        }
        do {
            add(try await allChildren(of: .rootContainer))
        } catch {
            logger.error(
                "root share metadata listing failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        for container in presentedContainersSnapshot() where container != .rootContainer {
            if Task.isCancelled { break }
            do {
                add(try await allChildren(of: container))
            } catch CloudreveError.noSuchItem {
                continue
            } catch {
                logger.error(
                    "presented share metadata listing failed for \(container.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return Array(candidates.values)
    }

    /// Verify every persisted identity with the changed filename. Names are
    /// not unique, so all matches are checked against authoritative metadata.
    func refreshShareMetadata(named name: String) async -> [FileProviderItem] {
        let matches = identityMatches(named: name)
        let revision = Data("#share-refresh-\(Date().timeIntervalSince1970)".utf8)
        var refreshed: [FileProviderItem] = []
        for (raw, uri) in matches {
            do {
                let file = try await client.fileInfoWithShareState(uri: uri)
                refreshed.append(makeItem(
                    file,
                    preservingIdentifier: NSFileProviderItemIdentifier(raw),
                    metadataRevision: revision))
            } catch { continue }
        }
        logger.notice("named share refresh \(name, privacy: .public): \(refreshed.count) item(s)")
        return refreshed
    }

    private func identityMatches(named name: String) -> [(String, String)] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let matches = uriByIdentifier.compactMap { raw, uri -> (String, String)? in
            let decodedName = URL(fileURLWithPath: uri).lastPathComponent
            return decodedName == name ? (raw, uri) : nil
        }
        return matches
    }

    /// Forget cached items after a confirmed remote delete, so later
    /// working-set enumerations cannot resurrect them. A deleted folder
    /// takes its cached descendants with it.
    func evictCachedItems(withIdentifiers identifiers: [NSFileProviderItemIdentifier]) {
        cacheLock.lock()
        var doomed = Set(identifiers.map { Self.canonicalIdentifier($0.rawValue) })
        for identifier in identifiers {
            let raw = Self.canonicalIdentifier(identifier.rawValue)
            guard let uri = uriByIdentifier[raw] else { continue }
            let prefix = uri + "/"
            for (raw, mappedURI) in uriByIdentifier where mappedURI.hasPrefix(prefix) {
                doomed.insert(raw)
            }
        }
        for raw in doomed {
            cache.removeValue(forKey: raw)
            metadataRefreshAt.removeValue(forKey: raw)
            presentedContainers.removeValue(forKey: raw)
            pinnedIdentifiers.remove(raw)
            if let uri = uriByIdentifier.removeValue(forKey: raw) {
                identityRevision &+= 1
                identityChildrenByParent[parentPath(of: uri)]?.remove(raw)
                lockExpiryByURI.removeValue(forKey: uri)
                deletedIdentityURIs[raw] = uri
                if identifierByURI[uri] == raw {
                    identifierByURI.removeValue(forKey: uri)
                }
            }
        }
        let identitySnapshot = uriByIdentifier
        let deletedSnapshot = deletedIdentityURIs
        let pinnedSnapshot = pinnedIdentifiers.sorted()
        cacheLock.unlock()

        persistIdentitySnapshot(identitySnapshot)
        persistDeletedIdentitySnapshot(deletedSnapshot)
        do {
            try FileManager.default.createDirectory(
                at: pinnedFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(pinnedSnapshot).write(to: pinnedFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist pins after remote delete: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func recordPresentedContainer(_ identifier: NSFileProviderItemIdentifier) {
        cacheLock.lock()
        presentedContainerSequence &+= 1
        presentedContainers[Self.canonicalIdentifier(identifier.rawValue)] =
            presentedContainerSequence
        if presentedContainers.count > Self.presentedContainerLimit {
            let overflow = presentedContainers.count - Self.presentedContainerLimit
            for key in presentedContainers.sorted(by: { $0.value < $1.value }).prefix(overflow) {
                presentedContainers.removeValue(forKey: key.key)
            }
        }
        let snapshot = presentedContainers
        cacheLock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: presentedFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(
                to: presentedFileURL, options: .atomic)
        } catch {
            logger.error(
                "failed to persist presented containers: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func presentedContainersSnapshot() -> [NSFileProviderItemIdentifier] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return presentedContainers
            .sorted(by: { $0.value > $1.value })
            .map { NSFileProviderItemIdentifier($0.key) }
    }

    func rootItem(displayName: String) -> FileProviderItem {
        FileProviderItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: displayName,
            contentType: .folder,
            documentSize: nil,
            childItemCount: nil,
            capabilities: [.allowsReading, .allowsContentEnumerating, .allowsWriting],
            contentVersion: Data("root".utf8),
            metadataVersion: Data("root".utf8),
            creationDate: nil,
            contentModificationDate: nil,
            pinned: isPinned(.rootContainer),
            remoteURI: drive.remote_path
        )
    }

    // MARK: - Queries

    /// Refresh one item from Cloudreve.
    func refreshItem(
        for identifier: NSFileProviderItemIdentifier, displayName: String
    ) async throws -> FileProviderItem {
        if identifier == .rootContainer {
            return rootItem(displayName: displayName)
        }
        if identifier == .trashContainer {
            throw NSFileProviderError(.noSuchItem)
        }
        let itemURI = uri(for: identifier)
        let client = self.client
        do {
            let file = try await metadataRefreshCoordinator.run(for: itemURI) {
                try await client.fileInfoWithShareState(uri: itemURI)
            }
            guard uri(for: identifier) == itemURI else {
                throw NSFileProviderError(.serverUnreachable)
            }
            return makeItem(file, preservingIdentifier: identifier)
        } catch CloudreveError.noSuchItem {
            // A response for the pre-move path is not evidence of deletion.
            guard uri(for: identifier) == itemURI,
                try !hasUnappliedFolderMove(refreshDatabase()) else {
                throw NSFileProviderError(.serverUnreachable)
            }
            // Confirmed gone on the server: drop the stale cache entry.
            evictCachedItems(withIdentifiers: [identifier])
            throw CloudreveError.noSuchItem
        }
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        displayName: String,
        refreshIfStale: Bool = true
    ) async throws -> FileProviderItem {
        if identifier == .rootContainer {
            return rootItem(displayName: displayName)
        }
        if identifier == .trashContainer {
            throw NSFileProviderError(.noSuchItem)
        }
        let cached = cachedItem(for: identifier)
        if let cached {
            if !refreshIfStale || metadataIsFresh(for: identifier) {
                logger.debug(
                    "metadata cache hit for \(identifier.rawValue, privacy: .public)")
                return cached
            }

            logger.debug(
                "refreshing stale metadata for \(identifier.rawValue, privacy: .public)")
            do {
                return try await refreshItem(for: identifier, displayName: displayName)
            } catch CloudreveError.noSuchItem {
                throw CloudreveError.noSuchItem
            } catch {
                logger.notice(
                    "metadata refresh failed for \(identifier.rawValue, privacy: .public); using cached item: \(error.localizedDescription, privacy: .public)"
                )
                return cached
            }
        }

        // Resolve items not present in the session cache.
        logger.debug(
            "metadata cache miss for \(identifier.rawValue, privacy: .public)")
        return try await refreshItem(for: identifier, displayName: displayName)
    }

    func browserURL(
        for identifier: NSFileProviderItemIdentifier, item: FileProviderItem
    ) -> URL? {
        let itemURI = item.remoteURI ?? uri(for: identifier)
        let isFolder = item.contentType.conforms(to: .folder)
        let folderURI = isFolder ? itemURI : parentPath(of: itemURI)
        guard var components = URLComponents(string: drive.instance_url) else { return nil }
        components.path = "/home"
        var queryItems = [URLQueryItem(name: "path", value: folderURI)]
        if !isFolder {
            queryItems.append(
                URLQueryItem(name: "open", value: item.remoteID ?? itemURI))
        }
        if let userID = drive.user_id, !userID.isEmpty {
            queryItems.append(URLQueryItem(name: "user_hint", value: userID))
        }
        components.percentEncodedQueryItems = strictlyEncodedQueryItems(queryItems)
        return components.url
    }

    func children(
        of identifier: NSFileProviderItemIdentifier, page: String?
    ) async throws -> (items: [FileProviderItem], nextPage: String?) {
        let folderURI = uri(for: identifier)
        let result: CloudreveClient.ListResult
        do {
            result = try await client.listDirectory(uri: folderURI, page: page)
        } catch CloudreveError.noSuchItem {
            guard uri(for: identifier) == folderURI,
                try !hasUnappliedFolderMove(refreshDatabase()) else {
                throw NSFileProviderError(.serverUnreachable)
            }
            throw CloudreveError.noSuchItem
        }
        let visible = result.files.filter { !Self.isIgnored(filename: $0.name) }
        let revision = Data("#listed-share-\(Date().timeIntervalSince1970)".utf8)
        var verified = visible

        // Directory listings can retain a removed share flag. Verify only the
        // small set reported as shared when Finder presents this folder.
        for index in verified.indices where verified[index].shared == true {
            let itemURI = Self.canonicalURI(verified[index].path)
            do {
                verified[index] = try await client.fileInfoWithShareState(
                    uri: itemURI)
            } catch {
                logger.notice(
                    "share verification failed for \(itemURI, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard uri(for: identifier) == folderURI else {
            throw NSFileProviderError(.serverUnreachable)
        }
        let sharedCount = verified.reduce(into: 0) { count, file in
            if file.shared == true { count += 1 }
        }
        logger.info(
            "listed \(identifier.rawValue, privacy: .public): \(visible.count) items, shared: \(sharedCount), next: \(result.nextPage ?? "nil", privacy: .public)")
        let identityRevision = currentIdentityRevision()
        let items = verified.map { makeItem($0, metadataRevision: revision, persistIdentity: false) }
        persistIdentityBatch(since: identityRevision)
        return (items, result.nextPage)
    }
}
