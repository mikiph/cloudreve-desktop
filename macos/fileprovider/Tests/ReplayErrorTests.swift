import Foundation
import FileProvider

private final class ReplayProtocol: URLProtocol {
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
        let name = String(uri.split(separator: "/").last!)
        func send(_ status: Int, _ body: Data) {
            let response = HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        switch name {
        case "forbidden.txt":
            send(200, Data(#"{"code":40088,"msg":"denied"}"#.utf8))
        case "html.txt":
            send(200, Data("<html>login</html>".utf8))
        case "shape.txt":
            send(200, Data(#"{"code":0,"data":{"unexpected":true}}"#.utf8))
        case "outage.txt":
            send(503, Data())
        default:
            let file = RemoteFile(type: 0, id: name, name: name, path: uri, size: 1,
                created_at: "2026-10-19T12:00:00Z", updated_at: "2026-10-19T12:00:00Z",
                metadata: nil, shared: false, owned: true, primary_entity: "entity-\(name)")
            struct Envelope: Encodable { let code = 0; let data: RemoteFile }
            do { send(200, try JSONEncoder().encode(Envelope(data: file))) }
            catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}

private final class ReplayObserver: NSObject, NSFileProviderChangeObserver {
    private let lock = NSLock()
    private var done = false
    private var failed: Error?
    private var finished = false
    private var updates: [String] = []
    var suggestedBatchSize: Int { 100 }
    func didUpdate(_ items: [NSFileProviderItem]) {
        lock.lock(); updates += items.map(\.filename); lock.unlock()
    }
    func didDeleteItems(withIdentifiers identifiers: [NSFileProviderItemIdentifier]) {}
    func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        lock.lock(); done = true; finished = true; lock.unlock()
    }
    func finishEnumeratingWithError(_ error: Error) {
        lock.lock(); failed = error; done = true; lock.unlock()
    }
    func snapshot() -> (done: Bool, finished: Bool, failed: Error?, updates: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (done, finished, failed, updates)
    }
}

@main
enum ReplayErrorTests {
    static func append(_ database: FileProviderStateDatabase, sequence: Int64, name: String, type: String = "modify") throws {
        let event = RemoteStore.FpEvent(ts: sequence, type: type,
            from: "/\(name)", to: nil, localEcho: false)
        try database.execute("INSERT INTO fp_events VALUES('replay-test',?,?)",
            [String(sequence), String(decoding: try JSONEncoder().encode(event), as: UTF8.self)])
        try database.execute("UPDATE fp_event_heads SET latest=? WHERE drive='replay-test'", [String(sequence)])
    }

    fileprivate static func run(_ enumerator: FileProviderEnumerator, from anchor: String) async throws -> ReplayObserver {
        let observer = ReplayObserver()
        enumerator.enumerateChanges(for: observer, from: NSFileProviderSyncAnchor(Data(anchor.utf8)))
        for _ in 0..<600 {
            if observer.snapshot().done { return observer }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        fatalError("enumerateChanges from \(anchor) never finished")
    }

    fileprivate static func runShape(_ enumerator: FileProviderEnumerator,
        _ database: FileProviderStateDatabase) async throws -> Bool {
        // Drop the failing transient rows so only the wrong-shape event remains.
        try database.execute("DELETE FROM fp_events WHERE drive='replay-test' AND sequence IN (4,5)")
        try append(database, sequence: 6, name: "shape.txt")
        let o = try await run(enumerator, from: "evt-3").snapshot()
        return o.finished && o.failed == nil
    }

    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudreve-replay-error-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        setenv("CLOUDREVE_FP_STATE_ROOT", temporary.path, 1)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("finder-metadata-v8-sharing-sentence-case".utf8).write(
            to: temporary.appendingPathComponent("policy-metadata-version-replay-test.txt"))

        let drive = DriveConfig(id: "replay-test", name: "Test", instance_url: "https://example.invalid",
            remote_path: "cloudreve://my", user_id: "test", enabled: true,
            credentials: Credentials(access_token: "fixture", refresh_token: "fixture",
                access_expires: "2999-01-01T00:00:00Z"))
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("replay-test"), displayName: "Test")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplayProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: temporary,
            workingSetSignaller: {}, client: CloudreveClient(drive: drive, session: session))
        let database = try FileProviderStateDatabase(root: temporary)
        try database.execute("INSERT INTO fp_event_heads VALUES('replay-test',0,0,1)")
        let enumerator = FileProviderEnumerator(containerIdentifier: .workingSet, store: store)

        // Case A: a permanent failure is skipped and a refresh is requested.
        try append(database, sequence: 1, name: "ok-1.txt")
        try append(database, sequence: 2, name: "forbidden.txt")
        try append(database, sequence: 3, name: "ok-2.txt")
        let a = try await run(enumerator, from: "evt-0").snapshot()
        precondition(a.finished && a.failed == nil, "Permanent failure must not fail the page: \(String(describing: a.failed))")
        precondition(Set(a.updates) == ["ok-1.txt", "ok-2.txt"], "Healthy events must still be delivered: \(a.updates)")
        let state = try JSONDecoder().decode(RemoteStore.PresentedRefreshState.self,
            from: database.get("fp-folder-refresh", "replay-test")!)
        precondition(state.requested >= 2, "Skipped event must request a refresh")

        // Case B: a transient failure fails the page with serverUnreachable.
        try append(database, sequence: 4, name: "outage.txt")
        let b = try await run(enumerator, from: "evt-3").snapshot()
        precondition(!b.finished, "Transient failure must not advance the anchor")
        let bError = b.failed! as NSError
        precondition(bError.domain == NSFileProviderErrorDomain
            && bError.code == NSFileProviderError.Code.serverUnreachable.rawValue,
            "Transient failure must map to serverUnreachable: \(bError)")

        // Case B2: an HTML page with HTTP 200 is transient too.
        try append(database, sequence: 5, name: "html.txt", type: "create")
        let b2 = try await run(enumerator, from: "evt-3").snapshot()
        precondition(!b2.finished, "A non-envelope 200 response must not advance the anchor")
        let b2Error = b2.failed! as NSError
        precondition(b2Error.domain == NSFileProviderErrorDomain
            && b2Error.code == NSFileProviderError.Code.serverUnreachable.rawValue)

        // Case B3: a valid envelope with a wrong payload shape is permanent.
        let b3Store = try await runShape(enumerator, database)
        precondition(b3Store, "A valid envelope with a wrong payload must be skipped")

        // Case C: mapError.
        let cancelled = FileProviderEnumerator.mapError(URLError(.cancelled)) as NSError
        precondition(cancelled.domain == NSCocoaErrorDomain && cancelled.code == NSUserCancelledError)
        let denied = FileProviderEnumerator.mapError(CloudreveError.api(code: 40088, message: "x")) as NSError
        precondition(denied.domain == NSFileProviderErrorDomain
            && denied.code == NSFileProviderError.Code.cannotSynchronize.rawValue)
        let other = FileProviderEnumerator.mapError(NSError(domain: "x", code: 1)) as NSError
        precondition(other.domain == NSFileProviderErrorDomain
            && other.code == NSFileProviderError.Code.serverUnreachable.rawValue)

        // Case D: classify.
        precondition(ReplayFailure.classify(CancellationError()) == .cancelled)
        precondition(ReplayFailure.classify(URLError(.cancelled)) == .cancelled)
        precondition(ReplayFailure.classify(CocoaError(.userCancelled)) == .cancelled)
        precondition(ReplayFailure.classify(CloudreveError.notAuthenticated) == .authentication)
        precondition(ReplayFailure.classify(URLError(.notConnectedToInternet)) == .transient)
        precondition(ReplayFailure.classify(CloudreveError.http(status: 429)) == .transient)
        precondition(ReplayFailure.classify(CloudreveError.http(status: 503)) == .transient)
        precondition(ReplayFailure.classify(CloudreveError.http(status: 404)) == .transient)
        precondition(ReplayFailure.classify(CloudreveError.http(status: 403)) == .permanent)
        precondition(ReplayFailure.classify(CloudreveError.api(code: 50001, message: "")) == .transient)
        precondition(ReplayFailure.classify(CloudreveError.api(code: 40088, message: "")) == .permanent)
        precondition(ReplayFailure.classify(CloudreveError.invalidEnvelope(status: 503)) == .transient)
        precondition(ReplayFailure.classify(CloudreveError.badResponse("x")) == .permanent)
        precondition(ReplayFailure.classify(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))) == .permanent)
        precondition(ReplayFailure.classify(CloudreveError.nameCollision) == .permanent)
        precondition(ReplayFailure.classify(CloudreveError.staleVersion) == .permanent)
        precondition(ReplayFailure.classify(CloudreveError.lockConflict(path: nil, application: nil, ownerID: nil)) == .permanent)
        precondition(ReplayFailure.classify(CloudreveError.unsupportedPackage) == .permanent)
        precondition(ReplayFailure.classify(CloudreveError.noSuchItem) == .permanent)
        precondition(ReplayFailure.classify(NSFileProviderError(.serverUnreachable)) == .transient)
        precondition(ReplayFailure.classify(NSError(domain: "x", code: 1)) == .transient)

        print("ReplayErrorTests: all tests passed")
    }
}
