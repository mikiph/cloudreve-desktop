import FileProvider
import Darwin
import OSLog
import UniformTypeIdentifiers
import CryptoKit

extension RemoteStore {
    /// A working-set listing with the verification data used to build it.
    struct WorkingSetSnapshot {
        let items: [FileProviderItem]
        /// Containers re-listed in this snapshot.
        let freshListings: [String: Set<String>]
        /// Containers proven absent on the server.
        let extinctURIs: [String]
        /// Identities confirmed gone by lookup after a fresh listing omitted them.
        let verifiedGone: Set<String>
    }

    /// Confirms which missing candidates are really gone. Pagination is not a
    /// server snapshot, so absence from a listing alone never proves deletion.
    /// Candidates whose lookup fails for any other reason stay unverified.
    private func verifyMissingCandidates(_ candidates: [String: String]) async
        -> (gone: Set<String>, stillPresent: [RemoteFile])
    {
        guard !candidates.isEmpty else { return ([], []) }
        var checked = candidates
        if candidates.count > 500 {
            let keep = Set(candidates.keys.sorted().prefix(500))
            checked = candidates.filter { keep.contains($0.key) }
            logger.notice(
                "verifying 500 of \(candidates.count, privacy: .public) missing candidates; rest stay unverified"
            )
        }
        let results = await FileInfoPrefetch.fetch(Array(Set(checked.values)), using: client)
        var gone: Set<String> = []
        var stillPresent: [RemoteFile] = []
        for (raw, uri) in checked {
            guard let result = results[uri] else { continue }
            switch result {
            case .failure(let error):
                if case CloudreveError.noSuchItem = error {
                    gone.insert(raw)
                } else {
                    logger.error(
                        "missing candidate \(raw, privacy: .private(mask: .hash)) unverified: \(error.localizedDescription, privacy: .public)"
                    )
                }
            case .success(let file):
                let remoteIdentifier =
                    file.presentationIdentity ?? ItemIdentity.remoteID(file.id, fallbackURI: file.path)
                if raw.hasPrefix(ItemIdentity.remotePrefix),
                    Self.canonicalIdentifier(remoteIdentifier) != Self.canonicalIdentifier(raw)
                {
                    gone.insert(raw)
                } else {
                    stillPresent.append(file)
                }
            }
        }
        return (gone, stillPresent)
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
                    "presented folder \(container.rawValue, privacy: .private(mask: .hash)) no longer exists"
                )
                extinctContainers.insert(container.rawValue)
            } catch {
                logger.error(
                    "presented folder \(container.rawValue, privacy: .private(mask: .hash)) failed: \(error.localizedDescription, privacy: .public)"
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
                        "pinned item \(rawIdentifier, privacy: .private(mask: .hash)) no longer exists"
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
                        "pending policy update \(uri, privacy: .private(mask: .hash)) skipped: \(error.localizedDescription, privacy: .public)"
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
                        "working-set folder \(folder.rawValue, privacy: .private(mask: .hash)) no longer exists"
                    )
                    extinctContainers.insert(folder.rawValue)
                } catch {
                    logger.error(
                        "working-set folder \(folder.rawValue, privacy: .private(mask: .hash)) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

        }

        // Remove cached items proven absent by fresh listings.
        let extinctURIs = extinctContainers.map {
            self.uri(for: NSFileProviderItemIdentifier($0))
        }
        var pruned: [NSFileProviderItemIdentifier] = []
        var missing: [String: String] = [:]
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
                missing[rawIdentifier] = self.uri(for: item.itemIdentifier)
            }
        }
        // Absence from a paged listing is not proof of deletion.
        let verification = await verifyMissingCandidates(missing)
        for raw in verification.gone {
            if let item = itemsByIdentifier.removeValue(forKey: raw) {
                pruned.append(item.itemIdentifier)
            }
        }
        for file in verification.stillPresent {
            add(makeItem(file))
        }
        if !pruned.isEmpty {
            evictCachedItems(withIdentifiers: pruned)
        }
        return WorkingSetSnapshot(
            items: Array(itemsByIdentifier.values),
            freshListings: freshListings,
            extinctURIs: extinctURIs,
            verifiedGone: verification.gone)
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
        var toVerify: [String: String] = [:]
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
            if snapshot.verifiedGone.contains(raw) {
                deleted.append(NSFileProviderItemIdentifier(raw))
            } else {
                toVerify[raw] = uri
            }
        }
        let (gone, _) = await verifyMissingCandidates(toVerify)
        if !gone.isEmpty {
            let ids = gone.sorted().map { NSFileProviderItemIdentifier($0) }
            deleted.append(contentsOf: ids)
            evictCachedItems(withIdentifiers: ids)
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

}
