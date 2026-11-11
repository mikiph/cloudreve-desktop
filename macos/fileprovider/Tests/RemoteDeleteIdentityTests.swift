import Foundation
import FileProvider

@main enum RemoteDeleteIdentityTests {
    static func file(_ id: String, path: String) -> RemoteFile {
        RemoteFile(type: 0, id: id, name: String(path.split(separator: "/").last!), path: path,
            size: 1, created_at: "2026-10-19T12:00:00Z", updated_at: "2026-10-19T12:00:00Z",
            metadata: nil, shared: false, owned: true, primary_entity: "entity-\(id)")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        let drive = DriveConfig(id: "delete-identity-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let domain = NSFileProviderDomain(identifier: .init("delete-identity-test"), displayName: "Test")
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root)

        // File A was deleted and a different file B now uses the same path.
        let path = "cloudreve://my/report.txt"
        _ = store.makeItem(file("B", path: path))
        precondition(store.identifier(forURI: path).rawValue == "cloudreve-item:/B")

        // Without the ID, a path lookup resolves to the NEW file: the old
        // behaviour that evicted B when A's delete was replayed.
        precondition(store.identifierForRemoteDelete(uri: path, fileID: nil).rawValue == "cloudreve-item:/B")
        precondition(store.identifierForRemoteDelete(uri: path, fileID: "").rawValue == "cloudreve-item:/B")
        // With the deleted file's ID, B is left alone.
        precondition(store.identifierForRemoteDelete(uri: path, fileID: "A").rawValue == "cloudreve-item:/A")
        // A delete that really is for B still resolves to B.
        precondition(store.identifierForRemoteDelete(uri: path, fileID: "B").rawValue == "cloudreve-item:/B")
        // Items known only by a legacy path identity cannot be compared by ID.
        let legacy = "cloudreve://my/legacy.txt"
        precondition(store.identifierForRemoteDelete(uri: legacy, fileID: "X") == store.identifier(forURI: legacy))

        // Replay persists identities once per batch, not once per item.
        let identityFile = root.appendingPathComponent("identities-\(drive.id).json")
        func persisted() -> [String: String] {
            guard let data = try? Data(contentsOf: identityFile) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        let before = persisted().count
        _ = store.makeItem(file("S0", path: "cloudreve://my/single.txt"))
        precondition(persisted().count == before + 1, "outside a batch every item is written immediately")
        await store.batchingIdentityPersistence {
            for i in 1...50 { _ = store.makeItem(file("B\(i)", path: "cloudreve://my/batch/\(i).txt")) }
            precondition(persisted().count == before + 1, "nothing is written while the batch is open")
            await store.batchingIdentityPersistence {  // nested batches flush only at the outermost close
                _ = store.makeItem(file("N1", path: "cloudreve://my/batch/nested.txt"))
            }
            precondition(persisted().count == before + 1, "an inner batch must not flush")
        }
        precondition(persisted().count == before + 1 + 51, "the batch flushes once, with every identity")
        precondition(persisted()["cloudreve-item:/B50"] == "cloudreve://my/batch/50.txt")

        // Batched evictions write nothing until the batch closes.
        let deletedFile = root.appendingPathComponent("deleted-identities-\(drive.id).json")
        func tombstones() -> [String: String] {
            guard let data = try? Data(contentsOf: deletedFile) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        var evictItems: [NSFileProviderItemIdentifier] = []
        for i in 0..<20 {
            let item = store.makeItem(file("E\(i)", path: "cloudreve://my/evict/\(i).txt"))
            evictItems.append(item.itemIdentifier)
        }
        store.setPinned(true, for: evictItems[0])
        let pinsFile = root.appendingPathComponent("pinned-\(drive.id).json")
        func pinsOnDisk() -> [String] {
            guard let data = try? Data(contentsOf: pinsFile) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        precondition(pinsOnDisk().contains(evictItems[0].rawValue), "pin is persisted before eviction")
        let evictBase = persisted().count
        await store.batchingIdentityPersistence {
            for i in 0..<10 { store.evictCachedItems(withIdentifiers: [evictItems[i]]) }
            precondition(persisted().count == evictBase, "evictions write nothing while the batch is open")
            precondition(pinsOnDisk().contains(evictItems[0].rawValue), "pins are not rewritten mid-batch")
        }
        precondition(persisted().count == evictBase - 10, "the batch flushes evictions once")
        precondition(persisted()[evictItems[0].rawValue] == nil && persisted()[evictItems[10].rawValue] != nil)
        precondition(tombstones()[evictItems[3].rawValue] == "cloudreve://my/evict/3.txt", "tombstones flushed")
        precondition(!pinsOnDisk().contains(evictItems[0].rawValue), "pin removal flushed at batch close")

        // Evicting a folder evicts its descendants, persisted immediately outside a batch.
        let folder = RemoteFile(type: 1, id: "TREE", name: "tree", path: "cloudreve://my/tree",
            size: 0, created_at: "2026-10-19T12:00:00Z", updated_at: "2026-10-19T12:00:00Z",
            metadata: nil, shared: false, owned: true, primary_entity: nil)
        let treeItem = store.makeItem(folder)
        let a = store.makeItem(file("TA", path: "cloudreve://my/tree/a.txt"))
        let b = store.makeItem(file("TB", path: "cloudreve://my/tree/sub/b.txt"))
        precondition(persisted()[a.itemIdentifier.rawValue] != nil && persisted()[b.itemIdentifier.rawValue] != nil)
        store.evictCachedItems(withIdentifiers: [treeItem.itemIdentifier])
        let afterTree = persisted()
        precondition(afterTree[treeItem.itemIdentifier.rawValue] == nil, "folder evicted immediately")
        precondition(afterTree[a.itemIdentifier.rawValue] == nil, "child evicted immediately")
        precondition(afterTree[b.itemIdentifier.rawValue] == nil, "grandchild evicted immediately")

        // The journal carries the ID; older records without it still decode.
        let withID = try JSONDecoder().decode(RemoteStore.FpEvent.self,
            from: Data(#"{"ts":1,"type":"delete","from":"/a","to":"","file_id":"A"}"#.utf8))
        precondition(withID.fileID == "A")
        let legacyRecord = try JSONDecoder().decode(RemoteStore.FpEvent.self,
            from: Data(#"{"ts":1,"type":"delete","from":"/a"}"#.utf8))
        precondition(legacyRecord.fileID == nil)
        print("RemoteDeleteIdentityTests: all tests passed")
    }
}
