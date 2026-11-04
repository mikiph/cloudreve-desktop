import Foundation
import FileProvider

private func check(_ value: Bool, _ message: String = "Assertion failed") { precondition(value, message) }

private actor VisitLog {
    private(set) var paths: Set<String> = []
    func record(_ uri: String) { paths.insert(uri) }
}

private final class StoreHolder { weak var store: RemoteStore? }

/// Exercises the production recovery worker against isolated SQLite databases.
/// The generated metadata never reaches the user's File Provider domain/server.
/// Timings measure local database, hashing and replay costs after fixture setup.
/// Simulated API pages have no network latency, so these are not estimates of
/// completion time against a real server. --edges-only skips the scale cases.
private actor StressListing {
    enum Mode { case routine, wide, subtree }
    let mode: Mode
    let folders: Int
    let filesPerFolder: Int
    private(set) var calls = 0
    private(set) var paths: Set<String> = []
    private(set) var largestPage = 0

    init(_ mode: Mode, folders: Int = 3_000, filesPerFolder: Int = 20) {
        self.mode = mode
        self.folders = folders
        self.filesPerFolder = filesPerFolder
    }

    func load(_ uri: String, _ page: String?) async throws -> CloudreveClient.ListResult {
        calls += 1
        paths.insert(uri)
        let offset = Int(page ?? "0")!
        var files: [RemoteFile]
        let count: Int
        switch mode {
        case .routine, .subtree:
            let base = mode == .routine ? "cloudreve://my" : "cloudreve://my/new-tree"
            if uri == base {
                count = folders
                files = (offset..<min(offset + 200, count)).map {
                    RecoveryStressTests.file("folder-\($0)", path: "\(base)/folder-\($0)", folder: true)
                }
            } else {
                check(uri.hasPrefix(base + "/folder-"), "Recovery must stay inside the selected tree")
                let folder = Int(uri.split(separator: "-").last!)!
                count = filesPerFolder
                files = (offset..<min(offset + 200, count)).map {
                    RecoveryStressTests.file("file-\(folder)-\($0)", path: "\(uri)/file-\($0).pdf")
                }
            }
        case .wide:
            check(uri == "cloudreve://my/wide" || uri == "cloudreve://my/tiny")
            count = uri.hasSuffix("/tiny") ? 1 : filesPerFolder
            let prefix = uri.hasSuffix("/tiny") ? "tiny" : "wide"
            files = (offset..<min(offset + 200, count)).map {
                RecoveryStressTests.file("\(prefix)-\($0)", path: "\(uri)/file-\($0).pdf")
            }
        }
        largestPage = max(largestPage, files.count)
        return .init(files: files, nextPage: offset + files.count < count ? String(offset + files.count) : nil)
    }
}

private actor RelevantInsertionListing {
    let database: FileProviderStateDatabase
    private(set) var calls = 0
    private(set) var starts = 0
    private var inserted = false
    init(_ database: FileProviderStateDatabase) { self.database = database }
    func load(_ uri: String, _ page: String?) async throws -> CloudreveClient.ListResult {
        calls += 1
        check(uri == "cloudreve://my/insertion")
        let old = RecoveryStressTests.file("existing", path: uri + "/existing.pdf")
        let arriving = RecoveryStressTests.file("inserted", path: uri + "/a-new.pdf")
        if page == nil {
            starts += 1
            return .init(files: inserted ? [arriving, old] : [old], nextPage: "page-2")
        }
        check(page == "page-2")
        if !inserted {
            inserted = true
            try database.transaction {
                let head = Int64(try database.rows("SELECT latest FROM fp_event_heads WHERE drive='stress'")[0][0])! + 1
                let event = RemoteStore.FpEvent(ts: head, type: "create", from: arriving.path, to: nil, localEcho: false)
                try database.execute("INSERT INTO fp_events VALUES('stress',?,?)", [String(head), String(decoding: try JSONEncoder().encode(event), as: UTF8.self)])
                try database.execute("UPDATE fp_event_heads SET latest=? WHERE drive='stress'", [String(head)])
            }
        }
        // Offset paging would skip the new a-new.pdf inserted before this page.
        return .init(files: [RecoveryStressTests.file("tail", path: uri + "/tail.pdf")], nextPage: nil)
    }
}

private actor BaselineListing {
    private var second = false
    private(set) var paths: Set<String> = []
    func nextCheck() { second = true; paths = [] }
    func load(_ uri: String, _ page: String?) -> CloudreveClient.ListResult {
        paths.insert(uri)
        check(page == nil)
        if uri == "cloudreve://my/baseline" {
            let initial = RecoveryStressTests.file("initial-folder", path: uri + "/initial", folder: true)
            let added = RecoveryStressTests.file("added-folder", path: uri + "/added", folder: true)
            return .init(files: second ? [initial, added] : [initial], nextPage: nil)
        }
        check(second && uri == "cloudreve://my/baseline/added", "The initial shallow baseline must not recursively scan existing folders")
        return .init(files: [RecoveryStressTests.file("added-child", path: uri + "/old-time.pdf")], nextPage: nil)
    }
}

private actor MetadataChangeListing {
    let database: FileProviderStateDatabase
    private(set) var calls = 0
    init(_ database: FileProviderStateDatabase) { self.database = database }
    func load(_ uri: String, _ page: String?) throws -> CloudreveClient.ListResult {
        calls += 1
        check(uri == "cloudreve://my/metadata-race" && page == nil)
        let path = uri + "/edit.pdf"
        if calls == 1 {
            try database.transaction {
                let head = Int64(try database.rows("SELECT latest FROM fp_event_heads WHERE drive='stress'")[0][0])! + 1
                let event = RemoteStore.FpEvent(ts: head, type: "modify", from: path, to: nil, localEcho: false)
                try database.execute("INSERT INTO fp_events VALUES('stress',?,?)", [String(head), String(decoding: try JSONEncoder().encode(event), as: UTF8.self)])
                try database.execute("UPDATE fp_event_heads SET latest=? WHERE drive='stress'", [String(head)])
            }
            return .init(files: [RecoveryStressTests.file("edited", path: path, entity: "old-content")], nextPage: nil)
        }
        return .init(files: [RecoveryStressTests.file("edited", path: path, entity: "new-content")], nextPage: nil)
    }
}

private actor LiveTrafficListing {
    let database: FileProviderStateDatabase
    private(set) var calls = 0
    init(_ database: FileProviderStateDatabase) { self.database = database }
    func load(_ uri: String, _ page: String?) async throws -> CloudreveClient.ListResult {
        calls += 1
        // A different device continuously edits a completely different folder.
        // This must not prevent a stable listing from finishing indefinitely.
        try database.transaction {
            let head = Int64(try database.rows("SELECT latest FROM fp_event_heads WHERE drive='stress'")[0][0])! + 1
            let event = RemoteStore.FpEvent(ts: head, type: "metadata", from: "cloudreve://my/unrelated/live.txt", to: nil, localEcho: false)
            try database.execute("INSERT INTO fp_events VALUES('stress',?,?)", [String(head), String(decoding: try JSONEncoder().encode(event), as: UTF8.self)])
            try database.execute("UPDATE fp_event_heads SET latest=? WHERE drive='stress'", [String(head)])
        }
        try await Task.sleep(nanoseconds: 2_000_000)
        return .init(files: [RecoveryStressTests.file("stable", path: uri + "/stable.pdf")], nextPage: nil)
    }
}

private actor MutationListing {
    private(set) var calls = 0
    private(set) var missingLookups = 0
    let kept = RecoveryStressTests.file("kept", path: "cloudreve://my/changing/kept.pdf")
    let arriving = RecoveryStressTests.file("arriving", path: "cloudreve://my/changing/new.pdf")
    let shifted = RecoveryStressTests.file("shifted", path: "cloudreve://my/changing/shifted.pdf")
    func load(_ uri: String, _ page: String?) async throws -> CloudreveClient.ListResult {
        calls += 1
        check(uri == "cloudreve://my/changing")
        // An insertion between offset pages shifts a known item out of the
        // listing. The final per-item lookup must preserve it instead of
        // interpreting paginated absence as a deletion.
        if page == nil { return .init(files: [kept], nextPage: "page-2") }
        check(page == "page-2")
        return .init(files: [kept, arriving], nextPage: nil)
    }
    func lookup(_ uri: String) throws -> RemoteFile {
        missingLookups += 1
        if uri == shifted.path { return shifted }
        check(uri == "cloudreve://my/changing/deleted.pdf")
        throw CloudreveError.noSuchItem
    }
}

@main
enum RecoveryStressTests {
    static let driveID = "stress"
    static func file(_ id: String, path: String, folder: Bool = false, entity: String? = nil) -> RemoteFile {
        RemoteFile(type: folder ? 1 : 0, id: id, name: String(path.split(separator: "/").last!), path: path,
            size: 1, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
            metadata: nil, shared: false, owned: true, primary_entity: entity ?? "entity-\(id)")
    }
    static func fixture(_ base: URL, _ name: String) throws -> (URL, FileProviderStateDatabase, DriveConfig, NSFileProviderDomain) {
        let root = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        try Data("finder-metadata-v8-sharing-sentence-case".utf8).write(to: root.appendingPathComponent("policy-metadata-version-stress.txt"))
        let database = try FileProviderStateDatabase(root: root)
        try database.execute("INSERT INTO fp_event_heads VALUES('stress',1,0,1)")
        try database.put("fp-move-repair-v190", driveID, Data(#"{"cursor":0,"target":0,"done":true}"#.utf8))
        let drive = DriveConfig(id: driveID, name: "Stress fixture", instance_url: "https://example.invalid",
            remote_path: "cloudreve://my", user_id: "test", enabled: true, credentials: Credentials(refresh_token: ""))
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("isolated-stress-\(name)"), displayName: "Stress fixture")
        return (root, database, drive, domain)
    }
    static func state(_ database: FileProviderStateDatabase) throws -> RemoteStore.PresentedRefreshState {
        try JSONDecoder().decode(RemoteStore.PresentedRefreshState.self, from: database.get("fp-folder-refresh", driveID)!)
    }
    static func writeState(_ state: RemoteStore.PresentedRefreshState, _ database: FileProviderStateDatabase) throws {
        try database.put("fp-folder-refresh", driveID, JSONEncoder().encode(state))
    }
    static func waitForCompletion(_ database: FileProviderStateDatabase, timeout: TimeInterval = 90) async throws -> RemoteStore.PresentedRefreshState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try database.get("fp-folder-refresh", driveID) {
                let value = try JSONDecoder().decode(RemoteStore.PresentedRefreshState.self, from: data)
                if !value.pending { return value }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "RecoveryStressTimeout", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Recovery did not finish before \(timeout) seconds"])
    }
    static func events(_ database: FileProviderStateDatabase) throws -> [RemoteStore.FpEvent] {
        try database.eventSnapshot(drive: driveID, since: 0).events.map { try JSONDecoder().decode(RemoteStore.FpEvent.self, from: $0) }
    }
    static func measured(_ label: String, start: Date, calls: Int, items: Int) {
        print(String(format: "%@: %.3f seconds, %d simulated API pages, %d metadata items", label, Date().timeIntervalSince(start), calls, items))
    }

    static func unrelatedTraffic(_ base: URL) async throws {
        let (root, database, drive, domain) = try fixture(base, "live-traffic")
        let transport = LiveTrafficListing(database)
        let folder = RemoteStore.PresentedFolder(id: "live", identifier: "cloudreve://my/watched", uri: "cloudreve://my/watched", seeded: true)
        try writeState(.init(requested: 1, active: 1, pending: true, folders: [folder]), database)
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, page in try await transport.load(uri, page) }, workingSetSignaller: {})
        let start = Date()
        store.resumePresentedRefresh()
        do {
            let result = try await waitForCompletion(database, timeout: 3)
            check(result.items_checked == 1)
            check(try events(database).flatMap { $0.presentation?.items ?? [] }.contains { $0.id == "stable" })
            measured("Concurrent unrelated device edits", start: start, calls: await transport.calls, items: 1)
        } catch {
            let attempts = await transport.calls
            let progress = try state(database)
            throw NSError(domain: "RecoveryStressLiveTraffic", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Unrelated live traffic starved recovery: \(attempts) listings, \(progress.pages_checked ?? 0) committed pages, \(progress.folders.count) folders pending. \(error.localizedDescription)"])
        }
    }

    static func routineScale(_ base: URL) async throws {
        let (root, database, drive, domain) = try fixture(base, "routine-3000")
        var identities: [String: String] = [:]
        for folder in 0..<3_000 {
            let path = "cloudreve://my/folder-\(folder)"
            identities[ItemIdentity.remoteID("folder-\(folder)", fallbackURI: path)] = path
            for index in 0..<20 {
                let filePath = "\(path)/file-\(index).pdf"
                identities[ItemIdentity.remoteID("file-\(folder)-\(index)", fallbackURI: filePath)] = filePath
            }
        }
        try JSONEncoder().encode(identities).write(to: root.appendingPathComponent("identities-stress.json"))
        let transport = StressListing(.routine)
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, page in try await transport.load(uri, page) }, workingSetSignaller: {},
            presentedMissingLookup: { _ in preconditionFailure("A complete unchanged listing must leave no missing candidates") })
        // Populate the production bounded recent-folder cache.
        for index in 0..<3_000 {
            let path = "cloudreve://my/folder-\(index)"
            store.recordPresentedContainer(NSFileProviderItemIdentifier(ItemIdentity.remoteID("folder-\(index)", fallbackURI: path)))
        }
        let start = Date()
        try store.requestPresentedRefresh(sequence: 1)
        let result = try await waitForCompletion(database)
        let paths = await transport.paths
        check(paths.count == 129, "Routine refresh must remain bounded for 3,000 folders")
        check(paths.contains("cloudreve://my"))
        check(paths.contains("cloudreve://my/folder-2999") && !paths.contains("cloudreve://my/folder-0"))
        check(await transport.calls == 143)
        check(result.pages_checked == 143 && result.items_checked == 5_560 && result.folders_checked == 129)
        check(try database.rows("SELECT key FROM fp_records WHERE namespace LIKE 'fp-folder-candidates-%'").isEmpty)
        measured("3,000 folders / 60,000 cached files, normal check", start: start, calls: await transport.calls, items: result.items_checked ?? 0)
        // Reading the resulting journal must respect Finder's 100-item budget.
        var anchor = Data("evt-0".utf8)
        var received = 0
        var callbacks = 0
        while true {
            let (batch, next, more) = try store.changes(since: anchor, for: .workingSet)
            let count = batch.reduce(0) { $0 + ($1.presentation?.items.count ?? 0) }
            check(count <= 100, "Large recovery must preserve short Finder callbacks")
            received += count
            callbacks += 1
            anchor = next.rawValue
            if !more { break }
        }
        check(received == 5_560 && callbacks >= 56)
        print("Large journal replay: \(received) metadata items in \(callbacks) callbacks, maximum 100 per callback")
        let incoming = (0..<100).map { file("new-\($0)", path: "cloudreve://my/new-\($0).pdf") }
        let deliveryStart = Date()
        let delivered = store.applyPresentedPage(.init(items: incoming, deleted: []))
        check(delivered.items.count == 100)
        print(String(format: "Actual metadata apply: 100 new identities into existing 63,000-identity cache in %.3f seconds", Date().timeIntervalSince(deliveryStart)))
        let persisted = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("identities-stress.json")))
        check(persisted.count == 63_100, "Replay must persist the complete batch before returning")
    }

    static func wideFolder(_ base: URL) async throws {
        let (root, database, drive, domain) = try fixture(base, "wide-20000")
        let transport = StressListing(.wide, filesPerFolder: 20_000)
        let folder = RemoteStore.PresentedFolder(id: "wide", identifier: "cloudreve://my/wide", uri: "cloudreve://my/wide", seeded: true)
        let tiny = RemoteStore.PresentedFolder(id: "tiny", identifier: "cloudreve://my/tiny", uri: "cloudreve://my/tiny", seeded: true)
        try writeState(.init(requested: 1, active: 1, pending: true, folders: [folder, tiny]), database)
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, page in try await transport.load(uri, page) }, workingSetSignaller: {})
        let start = Date()
        store.resumePresentedRefresh()
        let result = try await waitForCompletion(database)
        check(result.pages_checked == 101 && result.items_checked == 20_001 && result.folders_checked == 2)
        check(await transport.largestPage == 200)
        let found = try events(database).flatMap { $0.presentation?.items.map(\.id) ?? [] }
        check(found.count == 20_001 && Set(found).count == 20_001)
        let early = try events(database).prefix(3).flatMap { $0.presentation?.items.map(\.path) ?? [] }
        check(early.contains("cloudreve://my/tiny/file-0.pdf"), "One large directory must not starve smaller queued directories")
        measured("20,000-file directory plus one small sibling", start: start, calls: await transport.calls, items: result.items_checked ?? 0)
    }

    static func mutationAndRetry(_ base: URL) async throws {
        let (root, database, drive, domain) = try fixture(base, "pagination-mutation")
        let transport = MutationListing()
        let folder = RemoteStore.PresentedFolder(id: "mutating", identifier: "cloudreve://my/changing", uri: "cloudreve://my/changing", seeded: true)
        let shifted = transport.shifted
        let deleted = file("deleted", path: "cloudreve://my/changing/deleted.pdf")
        for item in [shifted, deleted] {
            try database.put("fp-folder-candidates-stress-mutating", ItemIdentity.remoteID(item.id, fallbackURI: item.path), Data(item.path.utf8))
        }
        try writeState(.init(requested: 1, active: 1, pending: true, folders: [folder]), database)
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, page in try await transport.load(uri, page) }, workingSetSignaller: {},
            presentedMissingLookup: { uri in try await transport.lookup(uri) })
        store.resumePresentedRefresh()
        let result = try await waitForCompletion(database)
        let journal = try events(database)
        let items = journal.flatMap { $0.presentation?.items.map(\.id) ?? [] }
        check(Set(items) == ["kept", "arriving", "shifted"] && items.count == 3,
            "Overlapping pages must be deduplicated, new files delivered, and shifted existing files preserved")
        let tombstones = journal.flatMap { $0.presentation?.deleted.map(\.identifier) ?? [] }
        check(tombstones == [ItemIdentity.remoteID(deleted.id, fallbackURI: deleted.path)])
        check(await transport.missingLookups == 2 && result.pages_checked == 2)
        print("Mid-refresh insertion / overlapping pages / shifted item / confirmed deletion: passed")

        // A saved cursor must resume after a failed page transaction, while a
        // repeated continuation token must fail without marking work complete.
        let retryFolder = RemoteStore.PresentedFolder(id: "retry", identifier: "cloudreve://my/retry", uri: "cloudreve://my/retry", seeded: true)
        let head = try database.eventSnapshot(drive: driveID, since: nil).latest
        try writeState(.init(requested: 2, completed: 1, active: 2, pending: true, folders: [retryFolder]), database)
        try database.execute("CREATE TRIGGER fail_stress_page BEFORE INSERT ON fp_events BEGIN SELECT RAISE(ABORT, 'disk full fixture'); END")
        do {
            try store.commitPresentedPage(retryFolder, files: [file("retry-file", path: retryFolder.uri + "/file.pdf")], nextPage: "page-2", expectedHead: head)
            preconditionFailure("A simulated disk failure must fail the transaction")
        } catch {}
        check(try state(database).folders[0].page == nil)
        check(try database.eventSnapshot(drive: driveID, since: nil).latest == head)
        try database.execute("DROP TRIGGER fail_stress_page")
        try store.commitPresentedPage(retryFolder, files: [file("retry-file", path: retryFolder.uri + "/file.pdf")], nextPage: "page-2", expectedHead: head)
        let persisted = try state(database).folders[0]
        let nextHead = try database.eventSnapshot(drive: driveID, since: nil).latest
        do {
            try store.commitPresentedPage(persisted, files: [], nextPage: "page-2", expectedHead: nextHead)
            preconditionFailure("A repeated token must not silently finish")
        } catch {}
        check(try state(database).folders[0].page == "page-2")
        let restarted = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, page in
                check(uri == retryFolder.uri && page == "page-2", "Restart must resume its committed continuation")
                return .init(files: [file("after-restart", path: uri + "/after.pdf")], nextPage: nil)
            }, workingSetSignaller: {})
        restarted.resumePresentedRefresh()
        _ = try await waitForCompletion(database)
        let recovered = try events(database).flatMap { $0.presentation?.items.map(\.id) ?? [] }
        check(recovered.filter { $0 == "retry-file" }.count == 1 && recovered.contains("after-restart"))
        print("Disk failure rollback / repeated token / extension restart: passed")
    }

    static func newSubtreeScale(_ base: URL) async throws {
        let (root, database, drive, domain) = try fixture(base, "subtree-3000")
        let transport = StressListing(.subtree, filesPerFolder: 2)
        let folder = RemoteStore.PresentedFolder(id: "subtree", identifier: "cloudreve://my/new-tree", uri: "cloudreve://my/new-tree", seeded: true, recursive: true)
        try writeState(.init(requested: 1, active: 1, pending: true, folders: [folder]), database)
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, page in try await transport.load(uri, page) }, workingSetSignaller: {})
        let start = Date()
        store.resumePresentedRefresh()
        let result = try await waitForCompletion(database, timeout: 180)
        let visited = await transport.paths.count
        let calls = await transport.calls
        check(visited == 3_001 && calls == 3_015)
        check(result.items_checked == 9_000 && result.pages_checked == 3_015 && result.folders_checked == 3_001)
        check(try events(database).flatMap { $0.presentation?.items ?? [] }.count == 9_000)
        measured("New subtree containing 3,000 directories / 6,000 files", start: start, calls: await transport.calls, items: result.items_checked ?? 0)
    }

    static func offlineMove(_ base: URL) async throws {
        let (root, database, drive, domain) = try fixture(base, "offline-folder-move")
        let old = "cloudreve://my/old-parent/moved"
        let destination = "cloudreve://my/Windows/moved"
        let moved = file("moved-folder", path: destination, folder: true)
        let nested = file("moved-nested", path: destination + "/nested", folder: true)
        let leaf = file("moved-leaf", path: nested.path + "/old-timestamp.pdf")
        let movedID = ItemIdentity.remoteID(moved.id, fallbackURI: old)
        try JSONEncoder().encode([movedID: old]).write(to: root.appendingPathComponent("identities-stress.json"))
        let watched = RemoteStore.PresentedFolder(id: "windows", identifier: "cloudreve://my/Windows", uri: "cloudreve://my/Windows", seeded: true)
        try writeState(.init(requested: 1, active: 1, pending: true, folders: [watched]), database)
        let visited = VisitLog()
        // Apply returned metadata the same way a real working-set enumerator
        // does, so descendants follow the stable identity's new location.
        let holder = StoreHolder()
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, _ in
                await visited.record(uri)
                switch uri {
                case watched.uri: return .init(files: [moved], nextPage: nil)
                case destination: return .init(files: [nested], nextPage: nil)
                case nested.path: return .init(files: [leaf], nextPage: nil)
                default: preconditionFailure("An offline move must not recheck the obsolete path or unrelated directories: \(uri)")
                }
            }, workingSetSignaller: {
                let value = try database.eventSnapshot(drive: driveID, since: 0)
                if let target = holder.store {
                    for data in value.events {
                        let event = try JSONDecoder().decode(RemoteStore.FpEvent.self, from: data)
                        if let presentation = event.presentation { _ = target.applyPresentedPage(presentation) }
                    }
                    target.recordAppliedAnchor(.init(Data("evt-\(value.latest)".utf8)))
                }
            })
        holder.store = store
        store.resumePresentedRefresh()
        _ = try await waitForCompletion(database, timeout: 5)
        let found = try events(database).flatMap { $0.presentation?.items.map(\.id) ?? [] }
        check(Set(found) == [moved.id, nested.id, leaf.id], "A shallow listing that finds a stable-ID move must discover its old-timestamp descendants")
        let paths = await visited.paths
        check(paths == [watched.uri, destination, nested.path])
        print("Offline stable-ID move found by shallow listing: old-timestamp descendants recovered")
    }

    static func membershipChange(_ base: URL) async throws {
        let (root, database, drive, domain) = try fixture(base, "membership-insertion")
        let transport = RelevantInsertionListing(database)
        let folder = RemoteStore.PresentedFolder(id: "membership", identifier: "cloudreve://my/insertion", uri: "cloudreve://my/insertion", seeded: true)
        try writeState(.init(requested: 1, active: 1, pending: true, folders: [folder]), database)
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, page in try await transport.load(uri, page) }, workingSetSignaller: {})
        store.resumePresentedRefresh()
        _ = try await waitForCompletion(database, timeout: 5)
        let found = Set(try events(database).flatMap { $0.presentation?.items.map(\.id) ?? [] })
        check(found == ["existing", "inserted", "tail"])
        check(await transport.starts == 2, "A membership change during offset paging must restart from page one")
        print("New file inserted before the current page during refresh: restarted safely and recovered all entries")
    }

    static func shallowBaseline(_ base: URL) async throws {
        let (root, database, drive, domain) = try fixture(base, "shallow-baseline")
        let transport = BaselineListing()
        let folder = RemoteStore.PresentedFolder(id: "baseline", identifier: "cloudreve://my/baseline", uri: "cloudreve://my/baseline", seeded: true)
        try writeState(.init(requested: 1, active: 1, pending: true, folders: [folder]), database)
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, page in await transport.load(uri, page) }, workingSetSignaller: {})
        store.resumePresentedRefresh()
        _ = try await waitForCompletion(database)
        check(await transport.paths == [folder.uri], "The initial baseline must stay shallow")
        await transport.nextCheck()
        let next = RemoteStore.PresentedFolder(id: "baseline-second", identifier: folder.identifier, uri: folder.uri, seeded: true)
        try writeState(.init(requested: 2, completed: 1, active: 2, pending: true, folders: [next]), database)
        store.resumePresentedRefresh()
        _ = try await waitForCompletion(database)
        check(await transport.paths == [folder.uri, folder.uri + "/added"], "Only a new child after an established baseline should be recursively discovered")
        check(try events(database).flatMap { $0.presentation?.items.map(\.id) ?? [] }.contains("added-child"))
        print("Initial baseline stayed shallow, later new folder discovered its old-timestamp child")
    }

    static func promotedShallowPage(_ base: URL) async throws {
        let (root, database, drive, domain) = try fixture(base, "promoted-shallow-page")
        let parentURI = "cloudreve://my/promotion"
        let child = file("promotion-child", path: parentURI + "/child", folder: true)
        let nested = file("promotion-nested", path: child.path + "/nested-on-first-page", folder: true)
        let leaf = file("promotion-leaf", path: nested.path + "/old-time.pdf")
        let parent = RemoteStore.PresentedFolder(id: "promotion-parent", identifier: parentURI,
            uri: parentURI, seeded: true, recursive: true)
        let childID = ItemIdentity.remoteID(child.id, fallbackURI: child.path)
        let shallow = RemoteStore.PresentedFolder(id: "shallow-old", identifier: childID,
            uri: child.path, page: "page-2", seeded: true, tokens: ["page-2"])
        try database.put("fp-folder-candidates-stress-shallow-old", "obsolete", Data("obsolete-path".utf8))
        try writeState(.init(requested: 1, active: 1, pending: true, folders: [parent, shallow]), database)
        let visited = VisitLog()
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, page in
                await visited.record(uri)
                if uri == child.path {
                    if page == nil { return .init(files: [nested], nextPage: "page-2") }
                    check(page == "page-2")
                    return .init(files: [], nextPage: nil)
                }
                check(uri == nested.path && page == nil)
                return .init(files: [leaf], nextPage: nil)
            }, workingSetSignaller: {})
        try store.commitPresentedPage(parent, files: [child], nextPage: nil, expectedHead: 1)
        let promoted = try state(database).folders
        check(promoted.count == 1 && promoted[0].recursive == true && promoted[0].page == nil,
            "Promoting a shallow job already on page two must restart page one")
        check(promoted[0].id != shallow.id && promoted[0].tokens.isEmpty && !promoted[0].seeded)
        check(try database.rows("SELECT key FROM fp_records WHERE namespace='fp-folder-candidates-stress-shallow-old'").isEmpty)
        store.resumePresentedRefresh()
        _ = try await waitForCompletion(database)
        let found = Set(try events(database).flatMap { $0.presentation?.items.map(\.id) ?? [] })
        check(found == [child.id, nested.id, leaf.id], "Promotion must recover nested directories from pages already traversed shallowly")
        check(await visited.paths == [child.path, nested.path])
        print("Shallow page-two job promoted to recursive: restarted page one and discovered earlier nested directory")
    }

    static func sameItemMetadataRace(_ base: URL) async throws {
        let (root, database, drive, domain) = try fixture(base, "same-item-metadata-race")
        let transport = MetadataChangeListing(database)
        let folder = RemoteStore.PresentedFolder(id: "metadata-race", identifier: "cloudreve://my/metadata-race",
            uri: "cloudreve://my/metadata-race", seeded: true)
        try writeState(.init(requested: 1, active: 1, pending: true, folders: [folder]), database)
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
            presentedPageLoader: { uri, page in try await transport.load(uri, page) }, workingSetSignaller: {})
        store.resumePresentedRefresh()
        let result = try await waitForCompletion(database)
        let published = try events(database).flatMap { $0.presentation?.items ?? [] }
        check(published.count == 1 && published[0].primary_entity == "new-content",
            "A same-item edit during a request must reject the old response and publish only the newer entity")
        check(await transport.calls == 2 && result.pages_checked == 1 && result.folders_checked == 1)
        print("Same returned item edited during request: stale entity rejected, newer entity delivered")
    }

    static func finalPageRollback(_ base: URL) throws {
        let (root, database, drive, domain) = try fixture(base, "final-page-rollback")
        let folderURI = "cloudreve://my/rollback"
        let folder = RemoteStore.PresentedFolder(id: "final-page", identifier: folderURI, uri: folderURI, seeded: true)
        let child = file("rollback-child", path: folderURI + "/child", folder: true)
        let childID = ItemIdentity.remoteID(child.id, fallbackURI: child.path)
        let memberNamespace = "fp-folder-members-stress-\(folder.identifier)"
        try database.put(memberNamespace, "previous-member", Data("older-request".utf8))
        try writeState(.init(requested: 1, active: 1, pending: true, folders: [folder]), database)
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root, workingSetSignaller: {})
        // The failure occurs at the final queue save, after membership,
        // fingerprints, journal results and the baseline were all modified.
        try database.execute("CREATE TRIGGER fail_final_queue BEFORE UPDATE ON fp_records WHEN NEW.namespace='fp-folder-refresh' BEGIN SELECT RAISE(ABORT, 'late commit failure fixture'); END")
        do {
            try store.commitPresentedPage(folder, files: [child], nextPage: nil, expectedHead: 1)
            preconditionFailure("The final queue write must fail the entire page transaction")
        } catch {}
        check(try database.get("fp-folder-baselines-stress", folder.identifier) == nil)
        check(try database.get("fp-folder-locations-stress", childID) == nil)
        check(try database.get("fp-presented-versions-stress", childID) == nil)
        let members = try database.rows("SELECT key,payload FROM fp_records WHERE namespace=?", [memberNamespace])
        check(members == [["previous-member", "older-request"]], "Rollback must undo new membership and restore deleted old membership")
        check(try database.eventSnapshot(drive: driveID, since: nil).latest == 1 && events(database).isEmpty)
        let pending = try state(database)
        check(pending.pending && pending.folders.count == 1 && pending.folders[0].id == folder.id && pending.pages_checked == nil)
        try database.execute("DROP TRIGGER fail_final_queue")
        try store.commitPresentedPage(folder, files: [child], nextPage: nil, expectedHead: 1)
        check(try database.get("fp-folder-baselines-stress", folder.identifier) != nil)
        check(try database.get("fp-folder-locations-stress", childID) == Data(child.path.utf8))
        check(try database.rows("SELECT key FROM fp_records WHERE namespace=?", [memberNamespace]) == [[childID]])
        check(try !state(database).pending && state(database).folders_checked == 1)
        print("Final-page failure after baseline and membership writes: entire transaction rolled back, retry succeeded")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-recovery-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        setenv("CLOUDREVE_FP_STATE_ROOT", base.path, 1)
        defer { try? FileManager.default.removeItem(at: base) }
        print("Recovery stress fixtures use temporary SQLite and simulated API metadata, with no network calls")
        if CommandLine.arguments.contains("--edges-only") {
            try await promotedShallowPage(base)
            try await sameItemMetadataRace(base)
            try finalPageRollback(base)
            print("RecoveryStressTests: additional edge cases passed")
            return
        }
        if !CommandLine.arguments.contains("--scale-only") { try await unrelatedTraffic(base) }
        if CommandLine.arguments.contains("--churn-only") { return }
        try await routineScale(base)
        try await wideFolder(base)
        try await mutationAndRetry(base)
        try await membershipChange(base)
        try await shallowBaseline(base)
        try await offlineMove(base)
        try await promotedShallowPage(base)
        try await sameItemMetadataRace(base)
        try finalPageRollback(base)
        try await newSubtreeScale(base)
        print("RecoveryStressTests: all tests passed")
    }
}
