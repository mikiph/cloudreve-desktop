import Foundation
import FileProvider
import UniformTypeIdentifiers

private final class MutationProtocol: URLProtocol {
    static var calls: [(String, String, [String: Any])] = []
    static var failChunk = false
    static var failCancel = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        let method = request.httpMethod ?? "GET"
        Self.calls.append((method, path, body))
        var payload: [String: Any] = ["code": 0]
        if method == "PUT", path == "/api/v4/file/upload" {
            payload["data"] = ["session_id": "our-session", "chunk_size": 3]
        } else if path.contains("/file/upload/"), Self.failChunk {
            payload = ["code": 50000, "msg": "Injected upload failure"]
        } else if method == "DELETE", Self.failCancel {
            payload = ["code": 50000, "msg": "Injected offline cancellation"]
        } else if path == "/api/v4/file/info" {
            let uri = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first(where: { $0.name == "uri" })!.value!
            payload["data"] = ["type": 0, "id": "file", "name": "tool", "path": uri, "size": 7, "metadata": ["sys:upload_session_id": "our-session"]]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum MutationRecoveryTests {
    static func sessionCount(_ db: FileProviderStateDatabase) -> Int {
        try! db.rows("SELECT key FROM fp_records WHERE namespace='fileprovider-upload-sessions'").count
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        let db = try FileProviderStateDatabase()
        let drive = DriveConfig(id: "mutation-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MutationProtocol.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))
        let uri = "cloudreve://my/App.app/Contents/MacOS/tool"
        let domain = NSFileProviderDomain(identifier: .init("mutation-test"), displayName: "Test")
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root)
        try FileProviderDeleteIntentStore.begin(driveID: drive.id, identifier: "app", uri: "cloudreve://my/App.app")
        let pendingDelete = try FileProviderDeleteIntentStore.contains(driveID: drive.id, identifier: "app")
        precondition(pendingDelete)
        let descendant = try FileProviderDeleteIntentStore.containsURI(driveID: drive.id, uri: uri)
        let sibling = try FileProviderDeleteIntentStore.containsURI(driveID: drive.id, uri: "cloudreve://my/App.app.zip")
        let otherDrive = try FileProviderDeleteIntentStore.containsURI(driveID: "other", uri: uri)
        precondition(descendant && !sibling && !otherDrive)
        let before = store.remoteDeleteGeneration(for: uri)
        store.recordRemoteDelete(for: "cloudreve://my/App.app")
        precondition(store.remoteDeleteOccurred(for: uri, after: before))
        try FileProviderDeleteIntentStore.finish(driveID: drive.id, identifier: "app")
        let cleared = try FileProviderDeleteIntentStore.contains(driveID: drive.id, identifier: "app")
        precondition(!cleared)

        let package = root.appendingPathComponent("Test.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("local package data".utf8).write(to: package.appendingPathComponent("payload"))
        let callsBefore = MutationProtocol.calls.count
        do {
            try await client.uploadFile(at: "cloudreve://my/Test.appex", from: package,
                overwrite: false, progress: Progress())
            preconditionFailure("Package directory must not be uploaded as bytes")
        } catch CloudreveError.unsupportedPackage {
            let error = FileProviderEnumerator.mapError(CloudreveError.unsupportedPackage) as NSError
            precondition(error.domain == NSFileProviderErrorDomain)
            precondition(error.code == NSFileProviderError.Code.cannotSynchronize.rawValue)
            precondition(error.localizedDescription.contains("ZIP"))
        }
        // URI resolution can read metadata, but no upload session or chunk may be created.
        precondition(!MutationProtocol.calls.dropFirst(callsBefore).contains { $0.0 == "PUT" || $0.0 == "POST" })
        precondition(FileManager.default.fileExists(atPath: package.appendingPathComponent("payload").path))
        precondition(sessionCount(db) == 0)

        let source = root.appendingPathComponent("source")
        try Data("1234567".utf8).write(to: source)
        try await client.uploadFile(at: uri, from: source, overwrite: false, progress: Progress())
        precondition(sessionCount(db) == 0)
        MutationProtocol.failChunk = true
        MutationProtocol.failCancel = true
        do {
            try await client.uploadFile(at: uri, from: source, overwrite: false, progress: Progress())
            preconditionFailure("Expected upload failure")
        } catch { }
        precondition(sessionCount(db) == 1)
        MutationProtocol.failCancel = false
        // A different drive must never cancel this drive's session.
        let other = DriveConfig(id: "other", name: "Other", instance_url: drive.instance_url,
            remote_path: drive.remote_path, enabled: true, credentials: drive.credentials)
        let otherClient = CloudreveClient(drive: other, session: URLSession(configuration: config))
        try await otherClient.cancelOwnedUploads(under: "cloudreve://my/App.app")
        precondition(sessionCount(db) == 1)
        try await client.cancelOwnedUploads(under: "cloudreve://my/App.app.zip")
        precondition(sessionCount(db) == 1)
        try await client.cancelOwnedUploads(under: "cloudreve://my/App.app")
        precondition(sessionCount(db) == 0)
        let cancel = MutationProtocol.calls.last!
        precondition(cancel.0 == "DELETE" && cancel.2["id"] as? String == "our-session")
        let mapped = FileProviderEnumerator.mapError(CloudreveError.lockConflict(path: uri, application: "upload", ownerID: nil))
        precondition(mapped.localizedDescription.contains("unfinished upload"))
        print("MutationRecoveryTests: delete races and abandoned upload recovery passed")
    }
}
