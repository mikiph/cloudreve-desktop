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
