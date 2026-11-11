import Foundation
import FileProvider

private func remoteFile(_ id: String, _ name: String, type: Int = 0) -> RemoteFile {
    RemoteFile(type: type, id: id, name: name, path: "cloudreve://my/\(name)", size: 1,
        created_at: "2026-10-19T12:00:00Z", updated_at: "2026-10-19T12:00:00Z",
        metadata: nil, shared: false, owned: true, primary_entity: "entity-\(id)")
}

private final class ReconcileProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private func send(_ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        guard let url = request.url,
            let uri = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "uri" })?.value
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        struct Envelope<T: Encodable>: Encodable { let code = 0; let data: T }
        struct Listing: Encodable {
            struct Pagination: Encodable { let page = 0; let page_size = 200 }
            let files: [RemoteFile]
            let pagination = Pagination()
        }
        let notFound = Data(#"{"code":40016,"msg":"not found"}"#.utf8)
        do {
            switch url.path {
            case "/api/v4/file":
                send(try JSONEncoder().encode(Envelope(data: Listing(files: [remoteFile("keep", "keep.txt")]))))
            case "/api/v4/file/info":
                let name = String(uri.split(separator: "/").last!)
                switch name {
                case "my": send(try JSONEncoder().encode(Envelope(data: remoteFile("root", "my", type: 1))))
                case "keep.txt": send(try JSONEncoder().encode(Envelope(data: remoteFile("keep", name))))
                case "shifted.txt": send(try JSONEncoder().encode(Envelope(data: remoteFile("shifted", name))))
                case "replaced.txt": send(try JSONEncoder().encode(Envelope(data: remoteFile("new-id", name))))
                case "flaky.txt": client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                default: send(notFound)
                }
            default:
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
enum ReconcileVerificationTests {
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudreve-reconcile-verification-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        setenv("CLOUDREVE_FP_STATE_ROOT", temporary.path, 1)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let drive = DriveConfig(id: "reconcile-test", name: "Test", instance_url: "https://example.invalid",
            remote_path: "cloudreve://my", user_id: "test", enabled: true,
            credentials: Credentials(access_token: "fixture", refresh_token: "fixture",
                access_expires: "2999-01-01T00:00:00Z"))
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("reconcile-test"), displayName: "Test")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReconcileProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: temporary,
            workingSetSignaller: {}, client: CloudreveClient(drive: drive, session: session))

        // Seed the cache. The listing returns only keep.txt.
        var ids: [String: NSFileProviderItemIdentifier] = [:]
        for (id, name) in [("keep", "keep.txt"), ("shifted", "shifted.txt"), ("gone", "gone.txt"),
            ("flaky", "flaky.txt"), ("old-id", "replaced.txt")]
        {
            ids[id] = store.makeItem(remoteFile(id, name)).itemIdentifier
        }
        _ = store.setPinned(true, for: ids["shifted"]!)
        _ = store.setPinned(true, for: ids["flaky"]!)

        let (_, deleted) = try await store.reconcileWorkingSet(includePinnedDescendants: false)
        let deletedSet = Set(deleted.map(\.rawValue))
        precondition(deletedSet.contains(ids["gone"]!.rawValue), "confirmed-gone item must be deleted: \(deletedSet)")
        precondition(deletedSet.contains(ids["old-id"]!.rawValue), "replaced identity must be deleted: \(deletedSet)")
        precondition(!deletedSet.contains(ids["shifted"]!.rawValue), "item found by lookup must not be deleted")
        precondition(!deletedSet.contains(ids["flaky"]!.rawValue), "unverified item must not be deleted")
        precondition(!deletedSet.contains(ids["keep"]!.rawValue), "listed item must not be deleted")
        precondition(store.isPinned(ids["shifted"]!), "shifted item lost its pin")
        precondition(store.isPinned(ids["flaky"]!), "unverified item lost its pin")
        precondition(store.identifier(forURI: "cloudreve://my/shifted.txt").rawValue == "cloudreve-item:/shifted",
            "shifted identity changed")
        print("ReconcileVerificationTests: all tests passed")
    }
}
