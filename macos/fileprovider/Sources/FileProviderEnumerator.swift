import FileProvider
import OSLog

/// Enumerates Cloudreve containers and replays remote changes.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let logger = Logger(
        subsystem: "cloudreve.desktop.fileprovider", category: "enumerator")

    private let containerIdentifier: NSFileProviderItemIdentifier
    private let store: RemoteStore
    private let refreshLock = NSLock()
    private var needsPresentedContainerRefresh = true

    init(containerIdentifier: NSFileProviderItemIdentifier, store: RemoteStore) {
        self.containerIdentifier = containerIdentifier
        self.store = store
        super.init()
        logger.debug("enumerator init for \(containerIdentifier.rawValue, privacy: .public)")
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        store.resumePresentedRefresh()
        // Working-set enumeration includes cached items and pinned subtrees.
        if containerIdentifier == .workingSet {
            Task {
                do {
                    try await store.recoverMigrationStateIfNeeded()
                    store.applyPinRequests()
                    let items = try await store.workingSetItems()
                    observer.didEnumerate(items)
                    observer.finishEnumerating(upTo: nil)
                } catch {
                    logger.error(
                        "working set enumeration failed: \(error.localizedDescription, privacy: .public)"
                    )
                    observer.finishEnumeratingWithError(Self.mapError(error))
                }
            }
            return
        }

        // Trash is handled by the remote provider.
        guard containerIdentifier != .trashContainer else {
            observer.didEnumerate([])
            observer.finishEnumerating(upTo: nil)
            return
        }

        store.recordPresentedContainer(containerIdentifier)

        let pageToken: String?
        if page.rawValue == NSFileProviderPage.initialPageSortedByName as Data
            || page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data
        {
            pageToken = nil
        } else {
            pageToken = String(data: page.rawValue, encoding: .utf8)
        }

        Task {
            do {
                try await store.recoverMigrationStateIfNeeded()
                store.applyPinRequests()
                _ = consumePresentedContainerRefresh()
                let (items, nextPage) = try await store.children(
                    of: containerIdentifier, page: pageToken)
                observer.didEnumerate(items)
                if let nextPage,
                    let data = nextPage.data(using: .utf8)
                {
                    observer.finishEnumerating(upTo: NSFileProviderPage(rawValue: data))
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
            } catch {
                logger.error(
                    "enumerateItems failed for \(self.containerIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                observer.finishEnumeratingWithError(Self.mapError(error))
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        logger.info(
            "enumerateChanges for \(self.containerIdentifier.rawValue, privacy: .public) from \(String(data: anchor.rawValue, encoding: .utf8) ?? "?", privacy: .public)"
        )
        Task {
            do {
                try await store.recoverMigrationStateIfNeeded()
                store.applyPinRequests()
                store.resumePresentedRefresh()
                if containerIdentifier != .workingSet,
                    containerIdentifier != .trashContainer,
                    consumePresentedContainerRefresh()
                {
                    let items = try await store.currentChildren(of: containerIdentifier)
                    if !items.isEmpty {
                        logger.notice(
                            "refreshing \(items.count) presented item(s) in \(self.containerIdentifier.rawValue, privacy: .public)"
                        )
                        observer.didUpdate(items)
                    }
                }
                // Force a full working-set refresh after a policy change.
                if containerIdentifier == .workingSet,
                    store.consumePolicyRescanIfNeeded()
                {
                    throw NSFileProviderError(.syncAnchorExpired)
                }
                let changes: [RemoteStore.FpEvent]
                let newAnchor: NSFileProviderSyncAnchor
                let moreComing: Bool
                do {
                    (changes, newAnchor, moreComing) = try store.changes(
                        since: anchor.rawValue, for: containerIdentifier)
                } catch let error as NSFileProviderError
                    where error.code == .syncAnchorExpired
                        && containerIdentifier == .workingSet
                {
                    // Reconcile after an expired anchor.
                    logger.notice("anchor expired; reconciling working set with the server")
                    // Keep events received during reconciliation for the next pass.
                    let reconciliationAnchor = try store.currentSyncAnchor()
                    logger.notice(
                        "reconciliation captured anchor \(String(data: reconciliationAnchor.rawValue, encoding: .utf8) ?? "?", privacy: .public)"
                    )
                    let (updated, deleted) = try await store.reconcileWorkingSet()
                    if !updated.isEmpty {
                        logger.notice(
                            "reconciliation updating \(updated.count) item(s)")
                        observer.didUpdate(updated)
                    }
                    if !deleted.isEmpty {
                        logger.notice(
                            "reconciliation deleting \(deleted.count) item(s)")
                        observer.didDeleteItems(withIdentifiers: deleted)
                    }
                    observer.finishEnumeratingChanges(
                        upTo: reconciliationAnchor, moreComing: false)
                    store.recordAppliedAnchor(reconciliationAnchor)
                    return
                }
                var downloadedContentUpdates: [NSFileProviderItemIdentifier] = []
                // A large remote batch names many items. Read their metadata with
                // bounded concurrency instead of one round trip at a time.
                let prefetched = await prefetchFileInfo(for: changes)
                for change in changes {
                    if let identifier = try await apply(change: change, to: observer, prefetched: prefetched) {
                        if change.localEcho != true {
                            downloadedContentUpdates.append(identifier)
                        }
                    }
                }
                // Deliver queued Keep Downloaded policy changes.
                if containerIdentifier == .workingSet {
                    let stabilizationDeletes = store.takeStabilizationDeletes()
                    if !stabilizationDeletes.isEmpty {
                        logger.notice(
                            "delivering \(stabilizationDeletes.count) stabilization delete(s)"
                        )
                        observer.didDeleteItems(withIdentifiers: stabilizationDeletes)
                    }
                    let pending = store.takePendingItemUpdates()
                    if !pending.isEmpty {
                        var items: [NSFileProviderItem] = []
                        var retry: [String] = []
                        for (index, uri) in pending.enumerated() {
                            if Task.isCancelled {
                                retry.append(contentsOf: pending[index...])
                                break
                            }
                            do {
                                let file = try await store.client.fileInfoWithShareState(uri: uri)
                                items.append(contentsOf: try await store.parentItemsForUpdate(file))
                                items.append(store.makeItem(file))
                            } catch CloudreveError.noSuchItem {
                                // The remote delete superseded this update.
                            } catch {
                                retry.append(uri)
                                logger.error(
                                    "policy update item \(uri, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)"
                                )
                            }
                        }
                        if Task.isCancelled {
                            // Retain every dequeued item on cancellation.
                            retry = pending
                        } else if !items.isEmpty {
                            logger.notice(
                                "delivering \(items.count) policy update item(s) to the working set")
                            observer.didUpdate(items)
                        }
                        if !retry.isEmpty {
                            store.recordPendingItemUpdates(uris: retry)
                        }
                    }
                }
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: moreComing)
                if containerIdentifier == .workingSet { store.recordAppliedAnchor(newAnchor) }
                store.scheduleDownloadedContentRefresh(downloadedContentUpdates)
            } catch let error as NSFileProviderError where error.code == .syncAnchorExpired {
                logger.info(
                    "anchor expired for \(self.containerIdentifier.rawValue, privacy: .public); system will re-enumerate"
                )
                observer.finishEnumeratingWithError(error)
            } catch {
                logger.error(
                    "enumerateChanges failed: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    private func consumePresentedContainerRefresh() -> Bool {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        guard needsPresentedContainerRefresh else { return false }
        needsPresentedContainerRefresh = false
        return true
    }

    private static let prefetchConcurrency = 8

    typealias PrefetchedInfo = [String: Result<RemoteFile, Error>]

    private func prefetchFileInfo(for changes: [RemoteStore.FpEvent]) async -> PrefetchedInfo {
        var uris: [String] = []
        var seen = Set<String>()
        for change in changes {
            let path: String?
            switch change.type {
            case "create", "modify", "metadata": path = change.from
            case "rename": path = change.to
            default: path = nil
            }
            guard let path else { continue }
            let uri = store.uri(forEventPath: path)
            if seen.insert(uri).inserted { uris.append(uri) }
        }
        guard uris.count > 1 else { return [:] }
        let store = self.store
        var results: PrefetchedInfo = [:]
        await withTaskGroup(of: (String, Result<RemoteFile, Error>).self) { group in
            var next = uris.makeIterator()
            func start(_ uri: String) {
                group.addTask {
                    do { return (uri, .success(try await store.client.fileInfoWithShareState(uri: uri))) }
                    catch { return (uri, .failure(error)) }
                }
            }
            for _ in 0..<min(Self.prefetchConcurrency, uris.count) {
                if let uri = next.next() { start(uri) }
            }
            while let (uri, result) = await group.next() {
                results[uri] = result
                if let uri = next.next() { start(uri) }
            }
        }
        return results
    }

    private func fileInfo(_ uri: String, _ prefetched: PrefetchedInfo) async throws -> RemoteFile {
        if let result = prefetched[uri] { return try result.get() }
        return try await store.client.fileInfoWithShareState(uri: uri)
    }

    private func apply(
        change: RemoteStore.FpEvent, to observer: NSFileProviderChangeObserver,
        prefetched: PrefetchedInfo = [:]
    ) async throws -> NSFileProviderItemIdentifier? {
        if change.type == "refresh_presented" {
            try store.requestPresentedRefresh(sequence: change.ts)
            return nil
        }
        if change.type == "presented_page", let page = change.presentation {
            let result = store.applyPresentedPage(page)
            if !result.items.isEmpty { observer.didUpdate(result.items) }
            if !result.deleted.isEmpty { observer.didDeleteItems(withIdentifiers: result.deleted) }
            return nil
        }
        if change.type == "metadata_rescan" {
            let items = await store.refreshPresentedShareMetadata()
            if !items.isEmpty {
                logger.notice("refreshing share metadata for \(items.count) presented item(s)")
                observer.didUpdate(items)
            }
            return nil
        }
        if change.type == "metadata_name" {
            let items = await store.refreshShareMetadata(named: change.from)
            if !items.isEmpty { observer.didUpdate(items) }
            return nil
        }
        let fromURI = store.uri(forEventPath: change.from)
        logger.notice(
            "applying \(change.type, privacy: .public) for \(fromURI, privacy: .public)"
        )
        switch change.type {
        case "create", "modify", "metadata":
            // Refresh metadata; a disappeared item becomes a delete.
            do {
                let file = try await fileInfo(fromURI, prefetched)
                let parents = try await store.parentItemsForUpdate(file)
                if !parents.isEmpty { observer.didUpdate(parents) }
                let discoverSubtree = file.isFolder && change.type != "metadata"
                    && (change.type == "create" || store.needsSubtreeRefresh(file))
                let item = store.makeItem(file)
                if discoverSubtree { try store.requestSubtreeRefresh(file) }
                let refreshContent = containerIdentifier == .workingSet
                    && change.type == "modify" && !file.isFolder && change.localEcho != true
                logger.notice(
                    "refreshed \(fromURI, privacy: .public), shared: \(file.shared == true, privacy: .public)"
                )
                observer.didUpdate([item])
                return refreshContent ? item.itemIdentifier : nil
            } catch CloudreveError.noSuchItem {
                let identifier = store.identifier(forURI: fromURI)
                store.evictCachedItems(withIdentifiers: [identifier])
                observer.didDeleteItems(withIdentifiers: [identifier])
            }
        case "delete":
            let identifier = store.identifierForRemoteDelete(uri: fromURI, fileID: change.fileID)
            logger.notice(
                "delivering remote delete for \(fromURI, privacy: .public) as \(identifier.rawValue, privacy: .public)"
            )
            store.recordRemoteDelete(for: fromURI)
            store.evictCachedItems(withIdentifiers: [identifier])
            observer.didDeleteItems(withIdentifiers: [identifier])
        case "rename":
            let identifier = store.identifier(forURI: fromURI)
            if let to = change.to {
                let toURI = store.uri(forEventPath: to)
                do {
                    let file = try await fileInfo(toURI, prefetched)
                    let parents = try await store.parentItemsForUpdate(file)
                    if !parents.isEmpty { observer.didUpdate(parents) }
                    observer.didUpdate([
                        store.makeItem(file, preservingIdentifier: identifier)
                    ])
                    try store.requestSubtreeRefresh(file)
                } catch CloudreveError.noSuchItem {
                    store.evictCachedItems(withIdentifiers: [identifier])
                    observer.didDeleteItems(withIdentifiers: [identifier])
                }
            }
        default:
            break
        }
        return nil
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        completionHandler(try? store.currentSyncAnchor())
    }

    static func mapError(_ error: Error) -> Error {
        switch error {
        case CloudreveError.noSuchItem:
            return NSFileProviderError(.noSuchItem)
        case CloudreveError.notAuthenticated:
            return NSFileProviderError(.notAuthenticated)
        case CloudreveError.nameCollision:
            return NSFileProviderError(.filenameCollision)
        case CloudreveError.lockConflict(_, let application, _):
            return NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.Code.cannotSynchronize.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        application == "upload" ? "An unfinished upload is holding this item." : "Someone has this file open online."
                ])
        case CloudreveError.unsupportedPackage:
            return NSError(domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.Code.cannotSynchronize.rawValue,
                userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
        case CloudreveError.staleVersion:
            return NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.Code.cannotSynchronize.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The file changed on the server before this update was saved."
                ])
        default:
            // File Provider only accepts Cocoa and File Provider error
            // domains. Keep implementation errors inside the extension.
            return NSFileProviderError(.serverUnreachable)
        }
    }
}
