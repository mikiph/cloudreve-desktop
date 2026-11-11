import FileProvider
import Foundation

@main enum PendingPolicyUpdateTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        let drive = DriveConfig(id: "pending-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let domain = NSFileProviderDomain(identifier: .init("pending-test"), displayName: "Test")
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root)

        // Case 1: concurrent records must all survive.
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            store.recordPendingItemUpdates(uris: ["cloudreve://my/r\(i)"])
        }
        let taken = Set(store.takePendingItemUpdates())
        precondition(taken.count == 200, "lost \(200 - taken.count) concurrent pending updates")

        // Case 2: records racing with takes must never be lost.
        let lock = NSLock()
        var collected: [String] = []
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            if i % 5 == 0 {
                let got = store.takePendingItemUpdates()
                lock.lock(); collected.append(contentsOf: got); lock.unlock()
            } else {
                store.recordPendingItemUpdates(uris: ["cloudreve://my/t\(i)"])
            }
        }
        collected.append(contentsOf: store.takePendingItemUpdates())
        let expected = Set((0..<400).filter { $0 % 5 != 0 }.map { "cloudreve://my/t\($0)" })
        let missing = expected.subtracting(collected)
        precondition(missing.isEmpty, "lost \(missing.count) pending updates during take")
        print("PendingPolicyUpdateTests: all tests passed")
    }
}
