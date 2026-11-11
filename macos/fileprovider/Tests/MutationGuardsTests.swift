import Foundation

@main enum MutationGuardsTests {
    static func file(id: String = "A", type: Int = 0, entity: String? = nil) -> RemoteFile {
        RemoteFile(type: type, id: id, name: "a", path: "cloudreve://my/a",
            size: 1, created_at: "2026-10-19T12:00:00Z", updated_at: "2026-10-19T12:00:00Z",
            metadata: nil, shared: false, owned: true, primary_entity: entity)
    }

    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        if !ok { failures += 1; print("FAIL: \(name)") }
    }

    static func main() {
        let folder = file(type: 1)
        check(DeletePreflight.decide(remote: folder, recursive: false, remoteChildNames: ["a.txt"], baseContentVersion: Data()) == .directoryNotEmpty, "1")
        check(DeletePreflight.decide(remote: folder, recursive: false, remoteChildNames: [".DS_Store", "._x"], baseContentVersion: Data()) == .proceed, "2")
        check(DeletePreflight.decide(remote: folder, recursive: true, remoteChildNames: ["a.txt"], baseContentVersion: Data()) == .proceed, "3")
        let base = Data("entity:E1#thumbnail-v1".utf8)
        check(DeletePreflight.decide(remote: file(entity: "E1"), recursive: false, remoteChildNames: nil, baseContentVersion: base) == .proceed, "4")
        check(DeletePreflight.decide(remote: file(entity: "E2"), recursive: false, remoteChildNames: nil, baseContentVersion: base) == .deletionRejected, "5")
        check(DeletePreflight.decide(remote: file(entity: "E2"), recursive: false, remoteChildNames: nil, baseContentVersion: Data("2026-01-01#10".utf8)) == .proceed, "6")
        check(DeletePreflight.decide(remote: file(entity: "E2"), recursive: false, remoteChildNames: nil, baseContentVersion: Data()) == .proceed, "7")
        check(ItemIdentity.fileID(fromIdentifier: "cloudreve-item:/abc") == "abc", "8a")
        check(ItemIdentity.fileID(fromIdentifier: "cloudreve-item://abc") == "abc", "8b")
        check(ItemIdentity.fileID(fromIdentifier: "cloudreve://my/a.txt") == nil, "8c")
        check(ItemIdentity.fileID(fromIdentifier: "cloudreve-item:/") == nil, "8d")
        check(MutationReplay.alreadyApplied(identifier: "cloudreve-item:/abc", destination: file(id: "abc")), "9a")
        check(!MutationReplay.alreadyApplied(identifier: "cloudreve-item:/abc", destination: file(id: "xyz")), "9b")
        check(!MutationReplay.alreadyApplied(identifier: "cloudreve-item:/abc", destination: nil), "9c")
        check(!MutationReplay.alreadyApplied(identifier: "cloudreve-item:/\(UUID().uuidString)", destination: file(id: "abc")), "9d")
        if failures > 0 { exit(1) }
        print("MutationGuardsTests: all tests passed")
    }
}
