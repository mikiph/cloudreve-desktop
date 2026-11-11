import FileProvider
import Darwin
import OSLog
import UniformTypeIdentifiers
import CryptoKit

extension RemoteStore {
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
                        logger.error("presented refresh deferred for \(folder.uri, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)")
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
                            logger.notice("queued repair of previously moved folder \(file.path, privacy: .private(mask: .hash))")
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
                if event.type == JournalEventType.rescan { return false }
                if event.type == JournalEventType.presentedPage, sequence > expectedHead, let page = event.presentation {
                    if page.items.contains(where: { protected.contains(Self.canonicalURI($0.path)) })
                        || page.deleted.contains(where: { changesMembership(Self.canonicalURI($0.uri)) }) { return false }
                } else if [JournalEventType.create, JournalEventType.delete, JournalEventType.rename].contains(event.type) {
                    if changesMembership(uri(forEventPath: event.from))
                        || event.to.map({ changesMembership(uri(forEventPath: $0)) }) == true { return false }
                } else if sequence > expectedHead {
                    if [JournalEventType.modify, JournalEventType.metadata].contains(event.type), protected.contains(uri(forEventPath: event.from)) { return false }
                    if event.type == JournalEventType.metadataRescan { return false }
                    if event.type == JournalEventType.metadataName, paths.contains(where: { $0.split(separator: "/").last.map(String.init) == event.from }) { return false }
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
            var event = FpEvent(ts: latest, type: JournalEventType.presentedPage, from: "", to: nil, localEcho: false)
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

}
