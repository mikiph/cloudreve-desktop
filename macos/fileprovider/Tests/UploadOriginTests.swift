import Foundation
import FileProvider

private final class OriginProtocol: URLProtocol {
    static var calls: [(method: String, host: String, path: String, auth: String?)] = []
    static var sessionPayload: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        Self.calls.append((method, url.host ?? "", url.path, request.value(forHTTPHeaderField: "Authorization")))
        var payload: [String: Any] = ["code": 0]
        if method == "PUT", url.path == "/api/v4/file/upload" {
            payload["data"] = Self.sessionPayload
        } else if url.path == "/api/v4/file/info" {
            let uri = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .first(where: { $0.name == "uri" })!.value!
            payload["data"] = ["type": 0, "id": "file", "name": "f", "path": uri, "size": 3, "metadata": [String: String]()]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum UploadOriginTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        let drive = DriveConfig(id: "origin-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OriginProtocol.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))
        let source = root.appendingPathComponent("source")
        try Data("abc".utf8).write(to: source)

        func run(_ extra: [String: Any]) async -> Error? {
            OriginProtocol.calls = []
            var payload: [String: Any] = ["session_id": "our-session", "chunk_size": 3]
            payload.merge(extra) { $1 }
            OriginProtocol.sessionPayload = payload
            do {
                try await client.uploadFile(at: "cloudreve://my/f.txt", from: source, overwrite: false, progress: Progress())
                return nil
            } catch { return error }
        }
        func chunkCalls(host: String) -> [(method: String, host: String, path: String, auth: String?)] {
            OriginProtocol.calls.filter { $0.method == "POST" && $0.host == host }
        }

        // 1. Local policy.
        var err = await run([:])
        precondition(err == nil, "local: \(String(describing: err))")
        var chunks = chunkCalls(host: "test.invalid")
        precondition(chunks.count == 1 && chunks[0].auth?.hasPrefix("Bearer ") == true)

        // 2. Relay, relative.
        err = await run(["upload_urls": ["/api/v4/file/upload/our-session/0"]])
        precondition(err == nil, "relay: \(String(describing: err))")
        chunks = chunkCalls(host: "test.invalid")
        precondition(chunks.count == 1 && chunks[0].auth?.hasPrefix("Bearer ") == true)

        // 3. Remote slave.
        err = await run(["upload_urls": ["https://slave.invalid/api/v4/slave/upload/our-session"],
            "credential": "slave-cred", "storage_policy": ["type": "remote"]])
        precondition(err == nil, "remote: \(String(describing: err))")
        chunks = chunkCalls(host: "slave.invalid")
        precondition(chunks.count == 1 && chunks[0].auth == "slave-cred")
        precondition(!OriginProtocol.calls.contains { $0.host == "slave.invalid" && $0.auth?.contains("Bearer") == true })

        // 4. Object storage.
        err = await run(["upload_urls": ["https://bucket.s3.invalid/obj?X-Amz-Signature=x"],
            "storage_policy": ["type": "mystery"]])
        guard case CloudreveError.unsupportedStoragePolicy(let type)? = err else {
            preconditionFailure("expected unsupportedStoragePolicy, got \(String(describing: err))")
        }
        precondition(type == "mystery")
        precondition(!OriginProtocol.calls.contains { $0.host == "bucket.s3.invalid" })
        precondition(OriginProtocol.calls.contains { $0.method == "DELETE" && $0.host == "test.invalid" && $0.path == "/api/v4/file/upload" })
        let mapped = FileProviderEnumerator.mapError(CloudreveError.unsupportedStoragePolicy("s3")) as NSError
        precondition(mapped.code == NSFileProviderError.Code.cannotSynchronize.rawValue)

        // 5. Absolute URL on our own origin.
        err = await run(["upload_urls": ["https://test.invalid/custom/upload"]])
        precondition(err == nil, "own origin: \(String(describing: err))")
        chunks = chunkCalls(host: "test.invalid").filter { $0.path == "/custom/upload" }
        precondition(chunks.count == 1 && chunks[0].auth?.hasPrefix("Bearer ") == true)

        print("UploadOriginTests: all tests passed")
    }
}
