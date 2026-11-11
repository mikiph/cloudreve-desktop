import FileProvider
import Darwin
import OSLog
import UniformTypeIdentifiers
import CryptoKit

extension RemoteStore {
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
        pendingPolicyUpdatesLock.lock()
        var pending = readPendingPolicyUpdates()
        pending.formUnion(uris)
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
        pendingPolicyUpdatesLock.unlock()
        cacheLock.lock()
        policyRescanPending = true
        cacheLock.unlock()
        persistPolicyRescanMarker()
    }

    private func readPendingPolicyUpdates() -> Set<String> {
        guard let data = try? Data(contentsOf: pendingPolicyUpdatesFileURL),
            let saved = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(saved)
    }

    private func pendingItemUpdatesSnapshot() -> Set<String> {
        pendingPolicyUpdatesLock.lock()
        defer { pendingPolicyUpdatesLock.unlock() }
        return readPendingPolicyUpdates()
    }

    /// Take queued policy updates, clearing the persisted list.
    func takePendingItemUpdates() -> [String] {
        pendingPolicyUpdatesLock.lock()
        defer { pendingPolicyUpdatesLock.unlock() }
        let pending = readPendingPolicyUpdates()
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
                "cannot request download for \(identifier.rawValue, privacy: .private(mask: .hash)): no File Provider manager"
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
                    "download request accepted for \(identifier.rawValue, privacy: .private(mask: .hash)) on attempt \(attempt + 1)"
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
                    "download request attempt \(attempt + 1) failed for \(identifier.rawValue, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
                )
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
            }
        }
        logger.error(
            "download incomplete for \(identifier.rawValue, privacy: .private(mask: .hash)) after 5 attempts: \(lastError?.localizedDescription ?? "content is still unavailable", privacy: .public)"
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
                    "could not inspect local content for \(identifier.rawValue, privacy: .private(mask: .hash)): errno \(errno)"
                )
                return .unavailable
            }
            return (info.st_flags & UInt32(SF_DATALESS)) == 0 ? .downloaded : .dataless
        } catch {
            logger.error(
                "could not inspect local content for \(identifier.rawValue, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
            )
            return .unavailable
        }
    }

    func hasDownloadedContent(_ identifier: NSFileProviderItemIdentifier) async -> Bool {
        guard let manager = NSFileProviderManager(for: domain) else { return false }
        let state = await localContentState(identifier, manager: manager)
        logger.notice(
            "local content state for \(identifier.rawValue, privacy: .private(mask: .hash)): \(state == .downloaded ? "downloaded" : "dataless", privacy: .public)"
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
                "evicted previous content generation for \(identifier.rawValue, privacy: .private(mask: .hash))"
            )
        } catch {
            // The post-update refresh retries after open descriptors are released.
            logger.error(
                "could not evict previous content generation for \(identifier.rawValue, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
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
                        "evicted previous content generation for \(identifier.rawValue, privacy: .private(mask: .hash)) after publishing the remote update"
                    )
                    state = await localContentState(identifier, manager: manager)
                } catch {
                    logger.error(
                        "remote content refresh could not evict \(identifier.rawValue, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            if state == .dataless {
                try? await Task.sleep(nanoseconds: 200_000_000)
                state = await localContentState(identifier, manager: manager)
            }
            if state == .downloaded {
                logger.notice(
                    "materialized current remote content for \(identifier.rawValue, privacy: .private(mask: .hash)) from content policy"
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
                        "requested current remote content for \(identifier.rawValue, privacy: .private(mask: .hash)) on attempt \(index + 1)"
                    )
                } catch {
                    logger.error(
                        "remote content refresh attempt \(index + 1) failed for \(identifier.rawValue, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
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
                    "materialized current remote content for \(identifier.rawValue, privacy: .private(mask: .hash))"
                )
            } else {
                logger.error(
                    "current remote content remained dataless for \(identifier.rawValue, privacy: .private(mask: .hash))"
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
                "cannot evict \(identifier.rawValue, privacy: .private(mask: .hash)): no File Provider manager"
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
                    "eviction accepted for \(identifier.rawValue, privacy: .private(mask: .hash)) on attempt \(attempt)"
                )
                return true
            } catch {
                lastError = error
                logger.error(
                    "eviction attempt \(attempt) failed for \(identifier.rawValue, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
                )
                if attempt < 6 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                }
            }
        }
        logger.error(
            "eviction failed for \(identifier.rawValue, privacy: .private(mask: .hash)) after 6 attempts: \(lastError?.localizedDescription ?? "unknown error", privacy: .public)"
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
                    "failed to resume pinned downloads for \(identifier.rawValue, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
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
                "deferred eviction still pending after retries: \(unresolved, privacy: .private(mask: .hash))"
            )
        }
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
                    logger.notice("applied pin removal for \(uri, privacy: .private(mask: .hash))")
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

}
