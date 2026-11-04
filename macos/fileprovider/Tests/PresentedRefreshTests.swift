import Foundation
import FileProvider

private final class MoveMetadataProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        guard url.path == "/api/v4/file/info",
            let uri = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uri" })?.value
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let file = PresentedRefreshTests.file(uri.hasSuffix("/repaired") ? "repair-folder" : "repair-parent", path: uri, folder: true)
        struct Envelope: Encodable { let code = 0; let data: RemoteFile }
        let data = try! JSONEncoder().encode(Envelope(data: file))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor BlockedListing {
    private var continuation: CheckedContinuation<CloudreveClient.ListResult, Error>?
    private(set) var started = false
    func load() async throws -> CloudreveClient.ListResult {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume(returning: .init(files: [], nextPage: nil))
        continuation = nil
    }
}

private final class ChangeObserver: NSObject, NSFileProviderChangeObserver {
    private let lock = NSLock()
    private var done = false
    private(set) var deleted: [String] = []
    private(set) var failure: Error?
    var completed: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func didDeleteItems(withIdentifiers identifiers: [NSFileProviderItemIdentifier]) {
        lock.lock(); deleted += identifiers.map(\.rawValue); lock.unlock()
    }
    func didUpdate(_ updatedItems: [NSFileProviderItem]) {}
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        lock.lock(); done = true; lock.unlock()
    }
    func finishEnumeratingWithError(_ error: Error) {
        lock.lock(); failure = error; done = true; lock.unlock()
    }
    var suggestedBatchSize: Int { 100 }
}

@main
enum PresentedRefreshTests {
    static func preconditionValue(_ value: Bool, _ message: String = "Assertion failed") { precondition(value, message) }
    static func file(_ id: String, path: String, entity: String? = nil, folder: Bool = false) -> RemoteFile {
        RemoteFile(type: folder ? 1 : 0, id: id, name: String(path.split(separator: "/").last!), path: path,
            size: 1, created_at: "2026-10-19T12:00:00Z", updated_at: "2026-10-19T12:00:00Z",
            metadata: nil, shared: false, owned: true, primary_entity: entity ?? "entity-\(id)")
    }
    static func writeState(_ state: RemoteStore.PresentedRefreshState, _ database: FileProviderStateDatabase) throws {
        try database.put("fp-folder-refresh", "test", JSONEncoder().encode(state))
    }
    static func state(_ database: FileProviderStateDatabase) throws -> RemoteStore.PresentedRefreshState {
        try JSONDecoder().decode(RemoteStore.PresentedRefreshState.self,
            from: database.get("fp-folder-refresh", "test")!)
    }
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-refresh-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        setenv("CLOUDREVE_FP_STATE_ROOT", temporary.path, 1)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("finder-metadata-v8-sharing-sentence-case".utf8)
            .write(to: temporary.appendingPathComponent("policy-metadata-version-test.txt"))
        let drive = DriveConfig(id: "test", name: "Test", instance_url: "https://example.invalid",
            remote_path: "cloudreve://my", user_id: "test", enabled: true,
            credentials: Credentials(refresh_token: ""))
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test"), displayName: "Test")
        let blocked = BlockedListing()
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: temporary,
            presentedPageLoader: { _, _ in try await blocked.load() }, workingSetSignaller: {})
        let database = try FileProviderStateDatabase(root: temporary)
        try database.execute("INSERT INTO fp_event_heads VALUES('test',28,0,1)")
        for index in 1...28 {
            let event = RemoteStore.FpEvent(ts: Int64(index), type: index == 28 ? "delete" : "refresh_presented",
                from: index == 28 ? "/deleted.txt" : "", to: nil, localEcho: false)
            try database.execute("INSERT INTO fp_events VALUES('test',?,?)", [String(index), String(decoding: try JSONEncoder().encode(event), as: UTF8.self)])
        }
        let (events, _, more) = try store.changes(since: Data("evt-0".utf8), for: .workingSet)
        precondition(events.map(\.ts) == [27, 28] && !more, "Reconnect backlog must coalesce into one refresh without dropping live events")
        let observer = ChangeObserver()
        let enumerator = FileProviderEnumerator(containerIdentifier: .workingSet, store: store)
        enumerator.enumerateChanges(for: observer, from: NSFileProviderSyncAnchor(Data("evt-0".utf8)))
        for _ in 0..<200 {
            let started = await blocked.started
            if observer.completed && started { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(observer.completed && observer.failure == nil, "A blocked folder listing must not block the working-set journal")
        precondition(observer.deleted.contains("cloudreve://my/deleted.txt"))
        try preconditionValue(state(database).pending, "The marker must persist its work before being acknowledged")
        let applied = try JSONSerialization.jsonObject(with: database.get("fp-applied", "test")!) as! [String: Int64]
        precondition(applied["sequence"] == 28)
        await blocked.release()
        // Let the now-finished worker retire before testing transactional pages.
        for _ in 0..<200 {
            if try !state(database).pending { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try preconditionValue(!state(database).pending)

        // Persist a two-page folder. A failed transaction must retain its cursor
        // and candidates without publishing incomplete deletions.
        let kept = file("kept", path: "cloudreve://my/kept.txt")
        let missing = file("missing", path: "cloudreve://my/missing.txt")
        let keptID = store.makeItem(kept).itemIdentifier.rawValue
        let missingID = store.makeItem(missing).itemIdentifier.rawValue
        var folder = RemoteStore.PresentedFolder(id: "page-test", identifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            uri: "cloudreve://my", seeded: true)
        try database.put("fp-folder-candidates-test-page-test", keptID, Data(kept.path.utf8))
        try database.put("fp-folder-candidates-test-page-test", missingID, Data(missing.path.utf8))
        var queued = RemoteStore.PresentedRefreshState(requested: 40, completed: 27, active: 40,
            pending: true, latest_sequence: 0, folders: [folder])
        try writeState(queued, database)
        try database.execute("CREATE TRIGGER fail_page BEFORE INSERT ON fp_events BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END")
        do {
            try store.commitPresentedPage(folder, files: [kept], nextPage: "p:1", expectedHead: 28)
            preconditionFailure("A failed journal insert must fail the page")
        } catch {}
        try preconditionValue(state(database).folders[0].page == nil)
        try database.execute("DROP TRIGGER fail_page")
        try store.commitPresentedPage(folder, files: [kept], nextPage: "p:1", expectedHead: 28)
        queued = try state(database)
        precondition(queued.folders[0].page == "p:1")
        let candidates = try database.rows("SELECT key FROM fp_records WHERE namespace='fp-folder-candidates-test-page-test'")
        precondition(candidates.count == 1 && candidates[0][0] == missingID)
        let firstPage = try database.eventSnapshot(drive: "test", since: 28)
        let firstEvent = try JSONDecoder().decode(RemoteStore.FpEvent.self, from: firstPage.events.last!)
        precondition(firstEvent.presentation?.deleted.isEmpty == true)
        folder = queued.folders[0]
        // An unrelated metadata event must not force another directory walk.
        let unrelated = RemoteStore.FpEvent(ts: firstPage.latest + 1, type: "metadata", from: "/other-folder/elsewhere", to: nil, localEcho: false)
        try database.execute("INSERT INTO fp_events VALUES('test',?,?)", [String(unrelated.ts), String(decoding: try JSONEncoder().encode(unrelated), as: UTF8.self)])
        try database.execute("UPDATE fp_event_heads SET latest=? WHERE drive='test'", [String(unrelated.ts)])
        try store.commitPresentedPage(folder, files: [], nextPage: nil, expectedHead: firstPage.latest)
        let head = try database.eventSnapshot(drive: "test", since: nil).latest
        queued = try state(database)
        precondition(queued.pending && queued.folders[0].verifyingMissing,
            "A complete listing must still verify unseen entries before deleting them")
        let afterListing = try database.eventSnapshot(drive: "test", since: firstPage.latest)
        let afterListingTypes = try afterListing.events.map { try JSONDecoder().decode(RemoteStore.FpEvent.self, from: $0).type }
        precondition(afterListingTypes == ["metadata"], "No tombstone may be inferred merely from paginated absence")

        // A new extension instance resumes the persisted verification phase.
        // It must not restart the listing or infer a delete without a lookup.
        let resumed = RemoteStore(drive: drive, domain: domain, stateDirectory: temporary,
            presentedPageLoader: { _, _ in preconditionFailure("Completed pages must not be listed again") },
            workingSetSignaller: {}, presentedMissingLookup: { uri in
                precondition(uri == missing.path)
                throw CloudreveError.noSuchItem
            })
        resumed.resumePresentedRefresh()
        for _ in 0..<200 {
            if try !state(database).pending { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try preconditionValue(!state(database).pending)
        let verifiedEvents = try database.eventSnapshot(drive: "test", since: head)
        let tombstone = try JSONDecoder().decode(RemoteStore.FpEvent.self, from: verifiedEvents.events.last!)
        precondition(tombstone.presentation?.deleted.map(\.identifier) == [missingID])
        try preconditionValue(database.rows("SELECT key FROM fp_records WHERE namespace='fp-folder-candidates-test-page-test'").isEmpty)
        try await Task.sleep(nanoseconds: 20_000_000)

        // Direct listing results retain the normal 100-item replay budget.
        let bulkFolder = RemoteStore.PresentedFolder(id: "bulk", identifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            uri: "cloudreve://my", seeded: true)
        try writeState(.init(requested: 60, completed: 40, active: 60, pending: true,
            latest_sequence: verifiedEvents.latest, folders: [bulkFolder]), database)
        let bulk = (0..<200).map { file("bulk-\($0)", path: "cloudreve://my/bulk-\($0)") }
        try store.commitPresentedPage(bulkFolder, files: bulk, nextPage: nil, expectedHead: verifiedEvents.latest)
        let (first, firstAnchor, firstMore) = try store.changes(since: Data("evt-\(verifiedEvents.latest)".utf8), for: .workingSet)
        let (second, _, secondMore) = try store.changes(since: firstAnchor.rawValue, for: .workingSet)
        precondition(first.count == 1 && first.first?.presentation?.items.count == 100 && firstMore)
        precondition(second.count == 1 && second.first?.presentation?.items.count == 100 && !secondMore)

        // Persisted fingerprints suppress unchanged repeated listings, while
        // a new content entity with identical size/time still reaches Finder.
        let bulkHead = try database.eventSnapshot(drive: "test", since: nil).latest
        let repeatFolder = RemoteStore.PresentedFolder(id: "unchanged", identifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            uri: "cloudreve://my", seeded: true)
        try writeState(.init(requested: 80, completed: 60, active: 80, pending: true,
            latest_sequence: bulkHead, folders: [repeatFolder]), database)
        try store.commitPresentedPage(repeatFolder, files: bulk, nextPage: nil, expectedHead: bulkHead)
        let unchanged = try database.eventSnapshot(drive: "test", since: bulkHead)
        precondition(unchanged.events.isEmpty && unchanged.latest == bulkHead,
            "Unchanged listings must not generate another metadata journal burst")
        let changedFolder = RemoteStore.PresentedFolder(id: "changed", identifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            uri: "cloudreve://my", seeded: true)
        try writeState(.init(requested: 90, completed: 80, active: 90, pending: true,
            latest_sequence: bulkHead, folders: [changedFolder]), database)
        let changedFile = file("bulk-0", path: "cloudreve://my/bulk-0", entity: "new-content")
        try store.commitPresentedPage(changedFolder, files: [changedFile], nextPage: nil, expectedHead: bulkHead)
        let changedEvents = try database.eventSnapshot(drive: "test", since: bulkHead)
        precondition(changedEvents.events.count == 1)
        let changedResult = try JSONDecoder().decode(RemoteStore.FpEvent.self, from: changedEvents.events[0])
        precondition(changedResult.presentation?.items.count == 1
            && changedResult.presentation?.items[0].primary_entity == "new-content")

        // Replacement at a reused name gets its own stable remote identity.
        let replacement = file("replacement", path: missing.path)
        let result = store.applyPresentedPage(.init(items: [replacement], deleted: []))
        let replacementID = ItemIdentity.remoteID("replacement", fallbackURI: missing.path)
        precondition(result.items.first?.itemIdentifier.rawValue == replacementID)
        precondition(result.deleted.contains(NSFileProviderItemIdentifier(missingID)))
        let generation = store.remoteDeleteGeneration(for: missing.path)
        _ = store.applyPresentedPage(.init(items: [], deleted: [.init(identifier: missingID, uri: missing.path)]))
        precondition(store.remoteDeleteGeneration(for: missing.path) == generation,
            "A tombstone for an old object must not cancel an upload to its replacement")
        precondition(store.identifier(forURI: missing.path).rawValue == replacementID)
        store.recordAppliedAnchor(NSFileProviderSyncAnchor(Data("evt-50".utf8)))
        store.recordAppliedAnchor(NSFileProviderSyncAnchor(Data("evt-30".utf8)))
        let finalApplied = try JSONSerialization.jsonObject(with: database.get("fp-applied", "test")!) as! [String: Int64]
        precondition(finalApplied["sequence"] == 50, "Concurrent callbacks must never move the applied anchor backwards")
        // A parent move must remap all known descendants before stale queued
        // tombstones can delete them. Prefix siblings must remain untouched.
        let before = "cloudreve://my/old/test"
        let after = "cloudreve://my/Windows/test"
        let parent = file("move-parent", path: before, folder: true)
        let child = file("move-child", path: before + "/battery", folder: true)
        let leaf = file("move-leaf", path: child.path + "/charge.pdf")
        let sibling = file("move-sibling", path: before + "-other/file.pdf")
        let parentID = store.makeItem(parent).itemIdentifier
        let childID = store.makeItem(child).itemIdentifier
        let leafID = store.makeItem(leaf).itemIdentifier
        let siblingID = store.makeItem(sibling).itemIdentifier
        _ = store.setPinned(true, for: childID)
        let moved = file("move-parent", path: after, folder: true)
        _ = store.makeItem(moved, preservingIdentifier: parentID)
        precondition(store.uri(for: childID) == after + "/battery")
        precondition(store.uri(for: leafID) == after + "/battery/charge.pdf")
        precondition(store.uri(for: siblingID) == sibling.path)
        precondition(store.isPinned(childID), "Folder moves must preserve Keep Downloaded selections")
        let staleDelete = store.applyPresentedPage(.init(items: [], deleted: [.init(identifier: childID.rawValue, uri: child.path)]))
        precondition(staleDelete.deleted.isEmpty, "An old-path tombstone must not delete a moved subtree")
        let restarted = RemoteStore(drive: drive, domain: domain, stateDirectory: temporary, workingSetSignaller: {})
        precondition(restarted.uri(for: leafID) == after + "/battery/charge.pdf", "Moved paths must survive extension restart")

        // In-flight old-path listings cannot publish after remapping.
        let staleFolder = RemoteStore.PresentedFolder(id: "stale-move", identifier: childID.rawValue, uri: child.path, seeded: true)
        let beforeStale = try database.eventSnapshot(drive: "test", since: nil).latest
        try writeState(.init(requested: beforeStale, completed: 0, active: beforeStale, pending: true, folders: [staleFolder]), database)
        try store.commitPresentedPage(staleFolder, files: [leaf], nextPage: nil, expectedHead: beforeStale)
        try preconditionValue(database.eventSnapshot(drive: "test", since: nil).latest == beforeStale,
            "A response from the old location must not be published")

        // Discover an affected subtree in pages, even when every child's
        // timestamp predates the recovery checkpoint. Never visit other trees.
        let subtreeRoot = file("tree", path: "cloudreve://my/new-tree", folder: true)
        let nested = file("nested", path: subtreeRoot.path + "/nested", folder: true)
        let nestedLeaf = file("nested-leaf", path: nested.path + "/old-timestamp.pdf")
        let treeStore = RemoteStore(drive: drive, domain: domain, stateDirectory: temporary,
            presentedPageLoader: { uri, page in
                if uri == subtreeRoot.path {
                    if page == nil { return .init(files: [nested], nextPage: "second") }
                    precondition(page == "second")
                    return .init(files: [file("tree-leaf", path: uri + "/leaf.pdf")], nextPage: nil)
                }
                precondition(uri == nested.path, "Targeted recovery must not scan unrelated folders")
                return .init(files: [nestedLeaf], nextPage: nil)
            }, workingSetSignaller: {})
        try writeState(.init(), database)
        _ = treeStore.makeItem(subtreeRoot)
        let treeHead = try database.eventSnapshot(drive: "test", since: nil).latest
        try treeStore.requestSubtreeRefresh(subtreeRoot)
        for _ in 0..<400 {
            if try !state(database).pending { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try preconditionValue(!state(database).pending, "Targeted subtree recovery must finish")
        let treeEvents = try database.eventSnapshot(drive: "test", since: treeHead).events.map {
            try JSONDecoder().decode(RemoteStore.FpEvent.self, from: $0)
        }
        let found = Set(treeEvents.flatMap { $0.presentation?.items.map(\.id) ?? [] })
        precondition(found == ["nested", "nested-leaf", "tree-leaf"])
        try preconditionValue(state(database).pages_checked == 3 && state(database).items_checked == 3)
        // An upgrade repairs a move already acknowledged by the old build.
        // A queued deletion/listing must wait while a move is still unapplied.
        let repairSequence = try database.eventSnapshot(drive: "test", since: nil).latest + 1
        let moveEvent = RemoteStore.FpEvent(ts: repairSequence, type: "rename", from: "cloudreve://my/old-repair", to: "cloudreve://my/repaired", localEcho: false)
        try database.execute("INSERT INTO fp_events VALUES('test',?,?)", [String(repairSequence), String(decoding: try JSONEncoder().encode(moveEvent), as: UTF8.self)])
        try database.execute("UPDATE fp_event_heads SET latest=? WHERE drive='test'", [String(repairSequence)])
        let waitingFolder = RemoteStore.PresentedFolder(id: "wait-for-move", identifier: NSFileProviderItemIdentifier.rootContainer.rawValue, uri: "cloudreve://my", seeded: true)
        try writeState(.init(requested: repairSequence, completed: 0, active: repairSequence, pending: true, folders: [waitingFolder]), database)
        try store.commitPresentedPage(waitingFolder, files: [file("unsafe", path: "cloudreve://my/unsafe")], nextPage: nil, expectedHead: repairSequence)
        try preconditionValue(database.eventSnapshot(drive: "test", since: nil).latest == repairSequence,
            "Folder checks must not overtake unapplied move events")
        store.recordAppliedAnchor(.init(Data("evt-\(repairSequence)".utf8)))
        try database.execute("DELETE FROM fp_records WHERE namespace='fp-move-repair-v190'")
        try writeState(.init(), database)
        var repairDrive = drive
        repairDrive.credentials = Credentials(access_token: "fixture", refresh_token: "fixture", access_expires: "2999-01-01T00:00:00Z")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoveMetadataProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let repairStore = RemoteStore(drive: repairDrive, domain: domain, stateDirectory: temporary,
            presentedPageLoader: { uri, _ in
                precondition(uri == "cloudreve://my/repaired", "Upgrade repair must target only the historical move destination")
                return .init(files: [file("repaired-leaf", path: uri + "/old-file.pdf")], nextPage: nil)
            }, workingSetSignaller: {}, client: CloudreveClient(drive: repairDrive, session: session))
        repairStore.resumePresentedRefresh()
        for _ in 0..<400 {
            if let data = try database.get("fp-move-repair-v190", "test"),
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                json["done"] as? Bool == true, try !state(database).pending { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let repairedEvents = try database.eventSnapshot(drive: "test", since: repairSequence).events.map {
            try JSONDecoder().decode(RemoteStore.FpEvent.self, from: $0)
        }
        precondition(repairedEvents.flatMap { $0.presentation?.items.map(\.id) ?? [] } == ["repaired-leaf"],
            "Upgrade must recover old-timestamp descendants of a previously acknowledged move")
        print("PresentedRefreshTests: all tests passed, including move races, descendant discovery and upgrade repair")
    }
}
