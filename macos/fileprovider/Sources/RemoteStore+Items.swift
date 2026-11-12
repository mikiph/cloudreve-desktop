import FileProvider
import Darwin
import OSLog
import UniformTypeIdentifiers
import CryptoKit

extension RemoteStore {
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
            case JournalEventType.create, JournalEventType.modify, JournalEventType.metadata: return uri(forEventPath: event.from)
            case JournalEventType.rename: return event.to.map { uri(forEventPath: $0) }
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
                    "presented share metadata listing failed for \(container.rawValue, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
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
        logger.notice("named share refresh \(name, privacy: .private(mask: .hash)): \(refreshed.count) item(s)")
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
        for raw in Array(doomed) {
            if let uri = uriByIdentifier[raw] { doomed.formUnion(descendantIdentifiers(of: uri)) }
        }
        var identitiesChanged = false
        var pinsChanged = false
        for raw in doomed {
            cache.removeValue(forKey: raw)
            metadataRefreshAt.removeValue(forKey: raw)
            presentedContainers.removeValue(forKey: raw)
            if pinnedIdentifiers.remove(raw) != nil { pinsChanged = true }
            if let uri = uriByIdentifier.removeValue(forKey: raw) {
                identitiesChanged = true
                identityRevision &+= 1
                identityChildrenByParent[parentPath(of: uri)]?.remove(raw)
                lockExpiryByURI.removeValue(forKey: uri)
                deletedIdentityURIs[raw] = uri
                deletedIdentityTimes[raw] = tombstoneNowMillis()
                if identifierByURI[uri] == raw {
                    identifierByURI.removeValue(forKey: uri)
                }
            }
        }
        if identityBatchDepth > 0 {
            // Flushed once when the outermost batch closes.
            if identitiesChanged {
                identityBatchDirty = true
                identityBatchDeletedDirty = true
            }
            if pinsChanged { identityBatchPinsDirty = true }
            cacheLock.unlock()
            return
        }
        let pinnedSnapshot = pinnedIdentifiers.sorted()
        cacheLock.unlock()

        if identitiesChanged {
            persistIdentitySnapshot([:])
            persistDeletedIdentitySnapshot([:])
        }
        if pinsChanged { persistPins(pinnedSnapshot) }
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
        FinderActivityHeartbeat.touch(driveID: drive.id)
    }

    func presentedContainersSnapshot() -> [NSFileProviderItemIdentifier] {
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
                    "metadata cache hit for \(identifier.rawValue, privacy: .private(mask: .hash))")
                return cached
            }

            logger.debug(
                "refreshing stale metadata for \(identifier.rawValue, privacy: .private(mask: .hash))")
            do {
                return try await refreshItem(for: identifier, displayName: displayName)
            } catch CloudreveError.noSuchItem {
                throw CloudreveError.noSuchItem
            } catch {
                logger.notice(
                    "metadata refresh failed for \(identifier.rawValue, privacy: .private(mask: .hash)); using cached item: \(error.localizedDescription, privacy: .public)"
                )
                return cached
            }
        }

        // Resolve items not present in the session cache.
        logger.debug(
            "metadata cache miss for \(identifier.rawValue, privacy: .private(mask: .hash))")
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
        var queryItems = [URLQueryItem(name: "path", value: wireCloudreveURI(folderURI))]
        if !isFolder {
            queryItems.append(
                URLQueryItem(name: "open", value: item.remoteID ?? wireCloudreveURI(itemURI)))
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
                    "share verification failed for \(itemURI, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
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
            "listed \(identifier.rawValue, privacy: .private(mask: .hash)): \(visible.count) items, shared: \(sharedCount), next: \(result.nextPage ?? "nil", privacy: .public)")
        let identityRevision = currentIdentityRevision()
        let items = verified.map { makeItem($0, metadataRevision: revision, persistIdentity: false) }
        persistIdentityBatch(since: identityRevision)
        return (items, result.nextPage)
    }
}
