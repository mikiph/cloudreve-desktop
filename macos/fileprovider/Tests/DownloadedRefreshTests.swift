import Foundation
import FileProvider

private final class MetadataProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path == "/api/v4/file/info",
            let uri = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "uri" })?.value
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let name = uri == "cloudreve://my" ? "root" : String(uri.split(separator: "/").last!)
        let file = RemoteFile(type: name == "folder" || name == "root" ? 1 : 0,
            id: name, name: name, path: uri, size: 1,
            created_at: "2026-10-19T12:00:00Z", updated_at: "2026-10-19T12:00:00Z",
            metadata: nil, shared: false, owned: true, primary_entity: "entity-\(name)")
        struct Envelope: Encodable { let code = 0; let data: RemoteFile }
        do {
            let data = try JSONEncoder().encode(Envelope(data: file))
            let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class RefreshObserver: NSObject, NSFileProviderChangeObserver {
    private let lock = NSLock()
    private var done = false
    private var failed: Error?
    private var updates: [String] = []
    private var deletions: [String] = []
    var suggestedBatchSize: Int { 100 }
    func didUpdate(_ updatedItems: [NSFileProviderItem]) {
        lock.lock(); updates += updatedItems.map(\.filename); lock.unlock()
    }
    func didDeleteItems(withIdentifiers identifiers: [NSFileProviderItemIdentifier]) {
        lock.lock(); deletions += identifiers.map(\.rawValue); lock.unlock()
    }
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        lock.lock(); done = true; lock.unlock()
    }
    func finishEnumeratingWithError(_ error: Error) {
        lock.lock(); failed = error; done = true; lock.unlock()
    }
    func snapshot() -> (done: Bool, failed: Error?, updates: [String], deletions: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (done, failed, updates, deletions)
    }
}

private actor BlockingContentRefresh {
    private var continuation: CheckedContinuation<Void, Never>?
    private var identifiers: [String] = []
    func run(_ identifier: NSFileProviderItemIdentifier) async {
        identifiers.append(identifier.rawValue)
        if identifiers.count == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
    }
    func called() -> [String] { identifiers }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@main
enum DownloadedRefreshTests {
    static func waitFor(_ message: String, _ predicate: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        fatalError(message)
    }

    static func append(_ database: FileProviderStateDatabase, sequence: Int64,
        type: String, name: String, localEcho: Bool = false) throws {
        let event = RemoteStore.FpEvent(ts: sequence, type: type,
            from: "/\(name)", to: nil, localEcho: localEcho)
        try database.execute("INSERT INTO fp_events VALUES('content-test',?,?)",
            [String(sequence), String(decoding: try JSONEncoder().encode(event), as: UTF8.self)])
        try database.execute("UPDATE fp_event_heads SET latest=? WHERE drive='content-test'", [String(sequence)])
    }

    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudreve-content-refresh-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        setenv("CLOUDREVE_FP_STATE_ROOT", temporary.path, 1)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("finder-metadata-v8-sharing-sentence-case".utf8).write(
            to: temporary.appendingPathComponent("policy-metadata-version-content-test.txt"))

        let drive = DriveConfig(id: "content-test", name: "Test", instance_url: "https://example.invalid",
            remote_path: "cloudreve://my", user_id: "test", enabled: true,
            credentials: Credentials(access_token: "fixture", refresh_token: "fixture",
                access_expires: "2999-01-01T00:00:00Z"))
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("content-test"), displayName: "Test")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let blocked = BlockingContentRefresh()
        let firstObserver = RefreshObserver()
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: temporary,
            workingSetSignaller: {}, client: CloudreveClient(drive: drive, session: session),
            downloadedContentRefresher: { identifier in
                precondition(firstObserver.snapshot().done,
                    "Native content work must start only after metadata enumeration finishes")
                await blocked.run(identifier)
            })
        let database = try FileProviderStateDatabase(root: temporary)
        try database.execute("INSERT INTO fp_event_heads VALUES('content-test',0,0,1)")
        try append(database, sequence: 1, type: "modify", name: "remote.txt")
        try append(database, sequence: 2, type: "modify", name: "own-upload.txt", localEcho: true)
        try append(database, sequence: 3, type: "metadata", name: "metadata.txt")
        try append(database, sequence: 4, type: "create", name: "new.txt")
        try append(database, sequence: 5, type: "modify", name: "folder")
        try append(database, sequence: 6, type: "delete", name: "deleted.txt")

        let enumerator = FileProviderEnumerator(containerIdentifier: .workingSet, store: store)
        enumerator.enumerateChanges(for: firstObserver, from: NSFileProviderSyncAnchor(Data("evt-0".utf8)))
        try await waitFor("The first metadata batch never completed") { firstObserver.snapshot().done }
        try await waitFor("The post-enumeration content refresh never started") { await blocked.called().count == 1 }
        let first = firstObserver.snapshot()
        precondition(first.failed == nil)
        precondition(Set(first.updates) == ["remote.txt", "own-upload.txt", "metadata.txt", "new.txt", "folder"])
        precondition(first.deletions == ["cloudreve://my/deleted.txt"])

        // Finder must receive later batches while one native refresh stays
        // blocked. The first refresh is released only after this assertion.
        try append(database, sequence: 7, type: "modify", name: "second.txt")
        try append(database, sequence: 8, type: "delete", name: "later-delete.txt")
        let secondObserver = RefreshObserver()
        enumerator.enumerateChanges(for: secondObserver, from: NSFileProviderSyncAnchor(Data("evt-6".utf8)))
        try await waitFor("A blocked native refresh held up a later metadata batch") { secondObserver.snapshot().done }
        let second = secondObserver.snapshot()
        precondition(second.failed == nil && second.updates == ["second.txt"])
        precondition(second.deletions == ["cloudreve://my/later-delete.txt"])
        let stillBlocked = await blocked.called()
        precondition(stillBlocked == [ItemIdentity.remoteID("remote.txt", fallbackURI: "cloudreve://my/remote.txt")])

        await blocked.release()
        try await waitFor("Queued content work did not resume after native work completed") { await blocked.called().count == 2 }
        let calls = await blocked.called()
        precondition(Set(calls) == Set(["remote.txt", "second.txt"].map {
            ItemIdentity.remoteID($0, fallbackURI: "cloudreve://my/\($0)")
        }), "Local echoes, metadata-only events, creates and folders must not trigger content refresh")
        print("DownloadedRefreshTests: metadata delivery, blocked native work and local echo tests passed")
    }
}
