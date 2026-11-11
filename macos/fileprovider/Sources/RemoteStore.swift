import FileProvider
import Darwin
import OSLog
import UniformTypeIdentifiers
import CryptoKit

actor OperationGate {
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

actor MetadataRefreshCoordinator {
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
    let logger = Logger(
        subsystem: "cloudreve.desktop.fileprovider", category: "store")

    let drive: DriveConfig
    let client: CloudreveClient
    let domain: NSFileProviderDomain

    /// itemIdentifier.rawValue -> item.
    var cache: [String: FileProviderItem] = [:]
    /// Stable Finder identity -> current Cloudreve URI.
    var uriByIdentifier: [String: String] = [:]
    var identifierByURI: [String: String] = [:]
    var identityChildrenByParent: [String: Set<String>] = [:]
    var identityRevision: UInt64 = 0
    // While a batch is open, identity changes are persisted once when the last
    // batch closes instead of rewriting the whole snapshot for every item.
    // Guarded by cacheLock.
    var identityBatchDepth = 0
    var identityBatchDirty = false
    var identityBatchDeletedDirty = false
    var identityBatchPinsDirty = false
    private let identityPersistenceLock = NSLock()
    /// Explicitly pinned identifiers, persisted per drive.
    var pinnedIdentifiers: Set<String> = []
    var pinRevision: UInt64 = 0
    var pinRevisionByIdentifier: [String: UInt64] = [:]

    struct PinChange {
        let wasPinned: Bool
        let revision: UInt64
    }
    /// Stable identities confirmed absent remotely. Finder may replay these
    /// as create callbacks after a domain is re-registered.
    var deletedIdentityURIs: [String: String] = [:]
    /// Deletion time (ms since epoch) per tombstone; guarded by cacheLock.
    var deletedIdentityTimes: [String: Int64] = [:]
    static let tombstoneRetention: TimeInterval = 30 * 24 * 3600
    static var tombstoneLimit = 50_000
    var tombstoneClock: () -> Date = Date.init
    /// Version marker used to force a working-set refresh after policy changes.
    private static let policyMetadataVersion = "finder-metadata-v8-sharing-sentence-case"
    static let metadataRefreshTTL: TimeInterval = 5
    static let lockStateTTL: TimeInterval = 30
    var policyRescanPending = false
    var metadataRefreshAt: [String: Date] = [:]
    var lockExpiryByURI: [String: Date] = [:]
    var presentedContainers: [String: UInt64] = [:]
    var presentedContainerSequence: UInt64 = 0
    var remoteDeleteGenerationByURI: [String: UInt64] = [:]
    private var pendingStabilizationDeletes: Set<String> = []
    // Reconnect reconciliation only walks containers Finder has presented.
    // Eight entries is too small for normal use and lets quiet folders fall
    // out of recovery coverage, so missed SSE creates can remain invisible.
    // Keep this bounded to avoid turning a reconnect into a full-drive crawl.
    static let presentedContainerLimit = 128
    let cacheLock = NSLock()
    /// Serializes the read-modify-write of pending-pinned-<drive>.json.
    /// Never take cacheLock while holding this lock, or the reverse.
    let pendingPolicyUpdatesLock = NSLock()
    let pinRequestLock = NSLock()
    let stateDirectoryOverride: URL?
    let pinRequestDirectoryOverride: URL?
    private let actionGate = OperationGate()
    private let managerCallGate = OperationGate()
    let metadataRefreshCoordinator = MetadataRefreshCoordinator()
    let migrationRecoveryGate = OperationGate()
    var migrationRecoveryCompleted = false
    let presentedRefreshLock = NSLock()
    var presentedRefreshRunning = false
    let downloadedRefreshLock = NSLock()
    var downloadedRefreshRunning = false
    var downloadedRefreshPending: Set<String> = []
    let presentedPageLoader: ((String, String?) async throws -> CloudreveClient.ListResult)?
    private let workingSetSignaller: (() async throws -> Void)?
    let presentedMissingLookup: ((String) async throws -> RemoteFile)?
    let downloadedContentRefresher: ((NSFileProviderItemIdentifier) async -> Void)?

    // MARK: - Change feed (shared event log)

    /// Remote event recorded by the main app in the shared SQLite journal.
    struct FpEvent: Codable {
        let ts: Int64  // journal sequence (>= ms timestamp, strictly increasing)
        let type: String  // create | modify | metadata | rename | delete | rescan | refresh_presented | presented_page | metadata_rescan | metadata_name
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
    static let changePageSize = 100

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
                        "duplicate item identity for \(uri, privacy: .private(mask: .hash)): keeping \(existing, privacy: .private(mask: .hash)), ignoring \(identifier, privacy: .private(mask: .hash))"
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
            let savedTimes: [String: Int64] =
                (try? Data(contentsOf: deletedIdentityTimesFileURL))
                .flatMap { try? JSONDecoder().decode([String: Int64].self, from: $0) } ?? [:]
            let now = tombstoneNowMillis()
            for raw in deletedIdentityURIs.keys {
                deletedIdentityTimes[raw] = savedTimes[raw] ?? now
            }
            pruneTombstonesLocked(now: now)
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

    var stateDirectoryURL: URL {
        if let stateDirectoryOverride { return stateDirectoryOverride }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("CloudreveFileProvider", isDirectory: true)
    }

    var pinnedFileURL: URL {
        stateDirectoryURL.appendingPathComponent("pinned-\(drive.id).json")
    }

    var identityFileURL: URL {
        stateDirectoryURL
            .appendingPathComponent("identities-\(drive.id).json")
    }

    private var deletedIdentitiesFileURL: URL {
        stateDirectoryURL
            .appendingPathComponent("deleted-identities-\(drive.id).json")
    }

    private var deletedIdentityTimesFileURL: URL {
        stateDirectoryURL
            .appendingPathComponent("deleted-identities-\(drive.id).times.json")
    }

    func tombstoneNowMillis() -> Int64 {
        Int64(tombstoneClock().timeIntervalSince1970 * 1000)
    }

    /// Drops tombstones older than the retention window, then the oldest
    /// beyond the count cap. Call with cacheLock held.
    private func pruneTombstonesLocked(now: Int64) {
        let cutoff = now - Int64(Self.tombstoneRetention * 1000)
        var doomed = Set(deletedIdentityURIs.keys.filter {
            (deletedIdentityTimes[$0] ?? now) < cutoff
        })
        let remaining = deletedIdentityURIs.count - doomed.count
        if remaining > Self.tombstoneLimit {
            let survivors = deletedIdentityURIs.keys.filter { !doomed.contains($0) }
                .sorted { (deletedIdentityTimes[$0] ?? now) < (deletedIdentityTimes[$1] ?? now) }
            doomed.formUnion(survivors.prefix(remaining - Self.tombstoneLimit))
        }
        for raw in doomed {
            deletedIdentityURIs.removeValue(forKey: raw)
            deletedIdentityTimes.removeValue(forKey: raw)
        }
        for raw in Array(deletedIdentityTimes.keys) where deletedIdentityURIs[raw] == nil {
            deletedIdentityTimes.removeValue(forKey: raw)
        }
    }

    var presentedFileURL: URL {
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

    var resetAcknowledgementURL: URL {
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
            identityFileURL, deletedIdentitiesFileURL, deletedIdentityTimesFileURL, pinnedFileURL,
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

    func persistIdentitySnapshot(_ snapshot: [String: String]) {
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

    func persistDeletedIdentitySnapshot(_ snapshot: [String: String]) {
        identityPersistenceLock.lock()
        defer { identityPersistenceLock.unlock() }
        cacheLock.lock()
        pruneTombstonesLocked(now: tombstoneNowMillis())
        let snapshot = deletedIdentityURIs
        let timesSnapshot = deletedIdentityTimes
        cacheLock.unlock()
        do {
            try FileManager.default.createDirectory(
                at: deletedIdentitiesFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(
                to: deletedIdentitiesFileURL, options: .atomic)
            try JSONEncoder().encode(timesSnapshot).write(
                to: deletedIdentityTimesFileURL, options: .atomic)
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

    func withManagerCall<T>(_ operation: () async throws -> T) async rethrows -> T {
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

    func persistPolicyRescanMarker() {
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

}
