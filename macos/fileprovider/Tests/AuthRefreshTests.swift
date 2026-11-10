import Foundation
import FileProvider

private final class AuthProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _refreshCount = 0
    private static var _refreshFails = false
    static var refreshCount: Int { lock.lock(); defer { lock.unlock() }; return _refreshCount }
    static func reset(fails: Bool = false) {
        lock.lock(); _refreshCount = 0; _refreshFails = fails; lock.unlock()
    }
    private static func bumpRefresh() -> Bool {
        lock.lock(); defer { lock.unlock() }
        _refreshCount += 1
        return _refreshFails
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var payload: [String: Any] = ["code": 0]
        if path == "/api/v4/session/token/refresh" {
            if Self.bumpRefresh() {
                payload = ["code": 40020, "msg": "invalid"]
            } else {
                payload["data"] = ["access_token": "new", "refresh_token": "r2",
                    "access_expires": "2099-01-01T00:00:00Z", "refresh_expires": "2099-01-01T00:00:00Z"]
            }
        } else if path == "/api/v4/file/info" {
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer new" {
                let uri = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                    .first(where: { $0.name == "uri" })!.value!
                payload["data"] = ["type": 0, "id": "file", "name": "a.txt", "path": uri, "size": 1]
            } else {
                payload = ["code": 401, "msg": "Login required"]
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum AuthRefreshTests {
    static func makeClient(_ creds: Credentials, reloader: (@Sendable () -> Credentials?)?) -> CloudreveClient {
        let drive = DriveConfig(id: "auth-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true, credentials: creds)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthProtocol.self]
        return CloudreveClient(drive: drive, session: URLSession(configuration: config),
            credentialReloader: reloader)
    }
    static let oldCreds = Credentials(access_token: "old", refresh_token: "r1",
        access_expires: "2099-01-01T00:00:00Z", refresh_expires: nil)

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        let uri = "cloudreve://my/a.txt"

        // 1. Single refresh after envelope 401.
        AuthProtocol.reset()
        var client = makeClient(oldCreds, reloader: { nil })
        _ = try await client.fileInfo(uri: uri)
        precondition(AuthProtocol.refreshCount == 1)

        // 2. Concurrent callers share one refresh.
        AuthProtocol.reset()
        client = makeClient(oldCreds, reloader: { nil })
        let c = client
        var tasks: [Task<Bool, Never>] = []
        for _ in 0..<16 {
            tasks.append(Task { (try? await c.fileInfo(uri: uri)) != nil })
        }
        var okCount = 0
        for t in tasks { if await t.value { okCount += 1 } }
        precondition(okCount == 16)
        precondition(AuthProtocol.refreshCount == 1)

        // 3. Host already refreshed.
        AuthProtocol.reset()
        client = makeClient(oldCreds, reloader: {
            Credentials(access_token: "new", refresh_token: "r9",
                access_expires: "2099-01-01T00:00:00Z", refresh_expires: nil)
        })
        _ = try await client.fileInfo(uri: uri)
        precondition(AuthProtocol.refreshCount == 0)

        // 4. Refresh fails.
        AuthProtocol.reset(fails: true)
        client = makeClient(oldCreds, reloader: { nil })
        do {
            _ = try await client.fileInfo(uri: uri)
            preconditionFailure("Expected notAuthenticated")
        } catch CloudreveError.notAuthenticated {
            let mapped = FileProviderEnumerator.mapError(CloudreveError.notAuthenticated) as NSError
            precondition(mapped.domain == NSFileProviderErrorDomain)
            precondition(mapped.code == NSFileProviderError.Code.notAuthenticated.rawValue)
        }

        // 5. Envelope 401 maps to notAuthenticated.
        if case .notAuthenticated = mapApiError(code: 401, message: nil) {} else {
            preconditionFailure("401 must map to notAuthenticated")
        }
        // 6. A reloaded token the server already rejected is not re-adopted.
        AuthProtocol.reset()
        client = makeClient(oldCreds, reloader: { oldCreds })
        _ = try await client.fileInfo(uri: uri)
        precondition(AuthProtocol.refreshCount == 1)

        print("AuthRefreshTests: all tests passed")
    }
}
