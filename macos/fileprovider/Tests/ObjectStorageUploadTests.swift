import Foundation
import FileProvider

private struct Call {
    let method: String
    let host: String
    let path: String
    let query: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

private final class StorageProtocol: URLProtocol {
    static var calls: [Call] = []
    static var sessionPayload: [String: Any] = [:]
    /// The Nth (1-based) provider PUT answers 500.
    static var failProviderPut: Int?
    /// Number of /file/info answers that still carry the upload session marker.
    static var pendingInfoPolls = 0
    static var providerPuts = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let host = url.host ?? ""
        Self.calls.append(Call(
            method: method, host: host, path: url.path,
            query: url.query ?? "", headers: request.allHTTPHeaderFields ?? [:],
            body: Self.bodyData(request)))

        var status = 200
        var headers: [String: String] = [:]
        var data = Data()
        if host == "test.invalid" {
            var payload: [String: Any] = ["code": 0]
            if method == "PUT", url.path == "/api/v4/file/upload" {
                payload["data"] = Self.sessionPayload
            } else if url.path == "/api/v4/file/info" || url.path == "/api/v4/file/create" {
                let uri = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?
                    .first(where: { $0.name == "uri" })?.value ?? "cloudreve://my/f.txt"
                var metadata: [String: String] = [:]
                if url.path == "/api/v4/file/info", Self.pendingInfoPolls > 0 {
                    Self.pendingInfoPolls -= 1
                    metadata["sys:upload_session_id"] = "our-session"
                }
                payload["data"] = ["type": 0, "id": "file", "name": "f", "path": uri, "size": 3,
                    "metadata": metadata]
            }
            data = try! JSONSerialization.data(withJSONObject: payload)
        } else if method == "PUT" {
            Self.providerPuts += 1
            if Self.failProviderPut == Self.providerPuts {
                status = 500
            } else if host == "qiniu.invalid" {
                data = Data("{\"etag\":\"q\(Self.providerPuts)\",\"md5\":\"m\"}".utf8)
            } else {
                headers["ETag"] = "\"e\(Self.providerPuts)\""
                if host == "onedrive.invalid" { status = 202 }
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
            httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum ObjectStorageUploadTests {
    static func main() async throws {
        pureHelperCases()
        try await endToEndCases()
        print("ObjectStorageUploadTests: all tests passed")
    }

    // MARK: Pure helpers

    static func pureHelperCases() {
        // 1. target truth table.
        func target(_ type: String?, urls: Int = 1, same: Bool? = false, cred: Bool = false) -> UploadTargetKind {
            ObjectStorageUpload.target(policyType: type, uploadURLCount: urls,
                firstURLIsSameOrigin: urls == 0 ? nil : same, hasSlaveCredential: cred)
        }
        precondition(target(nil, urls: 0) == .cloudreve)
        precondition(target("s3", same: true) == .cloudreve)
        precondition(target("remote", cred: true) == .slave)
        for type in ["s3", "ks3", "cos", "oss", "obs"] {
            precondition(target(type) == .s3Like(type))
        }
        precondition(target("onedrive") == .oneDrive)
        precondition(target("qiniu") == .qiniu)
        precondition(target("upyun") == .upyun)
        precondition(target("mystery") == .unsupported("mystery"))
        precondition(target("remote", cred: false) == .unsupported("remote"))
        precondition(target(nil) == .unsupported("unknown"))

        // 2. chunkCount and trimmedETag.
        precondition(ObjectStorageUpload.chunkCount(size: 0, chunkSize: 3) == 1)
        precondition(ObjectStorageUpload.chunkCount(size: 3, chunkSize: 3) == 1)
        precondition(ObjectStorageUpload.chunkCount(size: 7, chunkSize: 3) == 3)
        precondition(ObjectStorageUpload.trimmedETag("\"abc\"") == "abc")
        precondition(ObjectStorageUpload.trimmedETag("") == nil)
        precondition(ObjectStorageUpload.trimmedETag(nil) == nil)

        // 3. Multipart XML.
        let xml = String(decoding: ObjectStorageUpload.completeMultipartXML(etags: ["a", "b"]), as: UTF8.self)
        precondition(xml == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>a</ETag></Part><Part><PartNumber>2</PartNumber><ETag>b</ETag></Part></CompleteMultipartUpload>")

        // 4. OneDrive range.
        precondition(ObjectStorageUpload.oneDriveContentRange(offset: 3, length: 3, total: 7) == "bytes 3-5/7")

        // 5. Qiniu complete body.
        let withMime = try! JSONSerialization.jsonObject(
            with: ObjectStorageUpload.qiniuCompleteBody(etags: ["x", "y"], mimeType: "text/plain")) as! [String: Any]
        let parts = withMime["parts"] as! [[String: Any]]
        precondition(parts.count == 2 && parts[0]["partNumber"] as? Int == 1
            && parts[1]["partNumber"] as? Int == 2 && parts[1]["etag"] as? String == "y")
        precondition(withMime["mimeType"] as? String == "text/plain")
        let noMime = try! JSONSerialization.jsonObject(
            with: ObjectStorageUpload.qiniuCompleteBody(etags: ["x"], mimeType: nil)) as! [String: Any]
        precondition(noMime["mimeType"] == nil)
    }

    // MARK: End to end

    static func endToEndCases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        CloudreveClient.completionPollAttempts = 3
        CloudreveClient.completionPollIntervalNanoseconds = 10_000_000

        let drive = DriveConfig(id: "storage-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StorageProtocol.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))

        let source7 = root.appendingPathComponent("source7")
        try Data("abcdefg".utf8).write(to: source7)
        let source3 = root.appendingPathComponent("source3")
        try Data("abc".utf8).write(to: source3)
        let source0 = root.appendingPathComponent("source0")
        try Data().write(to: source0)

        var everyCall: [Call] = []
        func run(_ extra: [String: Any], file: URL, overwrite: Bool = false) async -> Error? {
            StorageProtocol.calls = []
            StorageProtocol.providerPuts = 0
            StorageProtocol.failProviderPut = nil
            StorageProtocol.pendingInfoPolls = 0
            var payload: [String: Any] = ["session_id": "our-session", "chunk_size": 3]
            payload.merge(extra) { $1 }
            StorageProtocol.sessionPayload = payload
            defer { everyCall += StorageProtocol.calls }
            do {
                try await client.uploadFile(at: "cloudreve://my/f.txt", from: file,
                    overwrite: overwrite, progress: Progress())
                return nil
            } catch { return error }
        }
        func calls(_ method: String, host: String? = nil, path: String? = nil) -> [Call] {
            StorageProtocol.calls.filter {
                $0.method == method && (host == nil || $0.host == host)
                    && (path == nil || $0.path == path)
            }
        }
        func hasCancel() -> Bool { !calls("DELETE", host: "test.invalid", path: "/api/v4/file/upload").isEmpty }
        func body(_ call: Call) -> String { String(decoding: call.body, as: UTF8.self) }
        func s3URLs(_ host: String) -> [String] { (0..<3).map { "https://\(host)/obj\($0)?sig=x" } }

        // 6. s3.
        var err = await run([
            "upload_urls": s3URLs("bucket.s3.invalid"), "storage_policy": ["type": "s3"],
            "completeURL": "https://bucket.s3.invalid/complete?sig=y", "callback_secret": "sec",
        ], file: source7)
        precondition(err == nil, "s3: \(String(describing: err))")
        var puts = calls("PUT", host: "bucket.s3.invalid")
        precondition(puts.map(\.path) == ["/obj0", "/obj1", "/obj2"])
        precondition(puts.allSatisfy { $0.header("Authorization") == nil })
        precondition(puts.allSatisfy { $0.header("Content-Type") == "application/octet-stream" })
        precondition(puts.map(\.body) == [Data("abc".utf8), Data("def".utf8), Data("g".utf8)])
        var complete = calls("POST", host: "bucket.s3.invalid")
        precondition(complete.count == 1 && complete[0].path == "/complete")
        precondition(body(complete[0]).contains("<PartNumber>3</PartNumber><ETag>e3</ETag>"))
        precondition(body(complete[0]).contains("<PartNumber>1</PartNumber><ETag>e1</ETag>"))
        precondition(complete[0].header("x-cos-forbid-overwrite") == nil)
        precondition(calls("GET", host: "test.invalid", path: "/api/v4/callback/s3/our-session/sec").count == 1)
        precondition(!hasCancel())

        // 7. cos.
        err = await run([
            "upload_urls": s3URLs("bucket.cos.invalid"), "storage_policy": ["type": "cos"],
            "completeURL": "https://bucket.cos.invalid/complete", "callback_secret": "sec",
        ], file: source7)
        precondition(err == nil, "cos: \(String(describing: err))")
        complete = calls("POST", host: "bucket.cos.invalid")
        precondition(complete.count == 1 && complete[0].header("x-cos-forbid-overwrite") == "true")
        precondition(body(complete[0]).contains("<CompleteMultipartUpload>"))
        precondition(calls("GET", host: "test.invalid", path: "/api/v4/callback/cos/our-session/sec").count == 1)

        // 8. oss: empty complete body, no callback, polls file info.
        err = await run([
            "upload_urls": s3URLs("bucket.oss.invalid"), "storage_policy": ["type": "oss"],
            "completeURL": "https://bucket.oss.invalid/complete",
        ], file: source7)
        precondition(err == nil, "oss: \(String(describing: err))")
        complete = calls("POST", host: "bucket.oss.invalid")
        precondition(complete.count == 1 && complete[0].body.isEmpty)
        precondition(complete[0].header("x-oss-complete-all") == "yes")
        precondition(complete[0].header("x-oss-forbid-overwrite") == "true")
        precondition(calls("GET", host: "test.invalid").filter { $0.path.hasPrefix("/api/v4/callback") }.isEmpty)
        precondition(!calls("GET", host: "test.invalid", path: "/api/v4/file/info").isEmpty)

        // 8b. oss: the session marker never clears; polling is bounded and the upload still succeeds.
        StorageProtocol.calls = []
        StorageProtocol.providerPuts = 0
        StorageProtocol.pendingInfoPolls = 100
        StorageProtocol.sessionPayload = [
            "session_id": "our-session", "chunk_size": 3,
            "upload_urls": s3URLs("bucket.oss.invalid"), "storage_policy": ["type": "oss"],
            "completeURL": "https://bucket.oss.invalid/complete",
        ]
        do {
            try await client.uploadFile(at: "cloudreve://my/f.txt", from: source7, overwrite: false,
                progress: Progress())
        } catch { preconditionFailure("oss unconfirmed completion must not throw: \(error)") }
        precondition(!hasCancel(), "unconfirmed completion must not cancel the session")
        precondition(calls("GET", host: "test.invalid", path: "/api/v4/file/info").count >= 3)
        everyCall += StorageProtocol.calls
        StorageProtocol.pendingInfoPolls = 0

        // 9. obs.
        err = await run([
            "upload_urls": s3URLs("bucket.obs.invalid"), "storage_policy": ["type": "obs"],
            "completeURL": "https://bucket.obs.invalid/complete",
        ], file: source7)
        precondition(err == nil, "obs: \(String(describing: err))")
        complete = calls("POST", host: "bucket.obs.invalid")
        precondition(complete.count == 1 && body(complete[0]).contains("<CompleteMultipartUpload>"))
        precondition(calls("GET", host: "test.invalid").filter { $0.path.hasPrefix("/api/v4/callback") }.isEmpty)

        // 10. onedrive.
        err = await run([
            "upload_urls": ["https://onedrive.invalid/session"], "storage_policy": ["type": "onedrive"],
            "callback_secret": "sec",
        ], file: source7)
        precondition(err == nil, "onedrive: \(String(describing: err))")
        puts = calls("PUT", host: "onedrive.invalid")
        precondition(puts.map { $0.header("Content-Range") ?? "" } == ["bytes 0-2/7", "bytes 3-5/7", "bytes 6-6/7"])
        precondition(puts.allSatisfy { $0.header("Authorization") == nil })
        precondition(calls("POST", host: "test.invalid", path: "/api/v4/callback/onedrive/our-session/sec").count == 1)

        // 11. onedrive empty file, new item.
        err = await run([
            "upload_urls": ["https://onedrive.invalid/session"], "storage_policy": ["type": "onedrive"],
            "callback_secret": "sec",
        ], file: source0)
        precondition(err == nil, "onedrive empty: \(String(describing: err))")
        precondition(hasCancel())
        precondition(calls("POST", host: "test.invalid", path: "/api/v4/file/create").count == 1)
        precondition(calls("PUT", host: "onedrive.invalid").isEmpty)

        // 12. qiniu.
        err = await run([
            "upload_urls": ["https://qiniu.invalid/buckets/b/objects/o/uploads/u"],
            "credential": "qcred", "storage_policy": ["type": "qiniu"], "mime_type": "text/plain",
        ], file: source7)
        precondition(err == nil, "qiniu: \(String(describing: err))")
        puts = calls("PUT", host: "qiniu.invalid")
        precondition(puts.map(\.path) == [
            "/buckets/b/objects/o/uploads/u/1", "/buckets/b/objects/o/uploads/u/2",
            "/buckets/b/objects/o/uploads/u/3"])
        precondition(puts.allSatisfy { $0.header("Authorization") == "UpToken qcred" })
        complete = calls("POST", host: "qiniu.invalid")
        precondition(complete.count == 1 && complete[0].header("Authorization") == "UpToken qcred")
        let qiniuBody = try JSONSerialization.jsonObject(with: complete[0].body) as! [String: Any]
        precondition((qiniuBody["parts"] as! [[String: Any]]).count == 3)
        precondition(qiniuBody["mimeType"] as? String == "text/plain")

        // 13. upyun.
        err = await run([
            "upload_urls": ["https://upyun.invalid/bucket"], "credential": "ucred",
            "upload_policy": "upolicy", "storage_policy": ["type": "upyun"],
        ], file: source3)
        precondition(err == nil, "upyun: \(String(describing: err))")
        let posts = calls("POST", host: "upyun.invalid")
        precondition(posts.count == 1)
        precondition(posts[0].header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        precondition(body(posts[0]).contains("name=\"policy\"") && body(posts[0]).contains("name=\"authorization\""))
        precondition(body(posts[0]).contains("upolicy") && body(posts[0]).contains("ucred"))
        err = await run([
            "upload_urls": ["https://upyun.invalid/bucket"], "credential": "ucred",
            "upload_policy": "upolicy", "storage_policy": ["type": "upyun"],
        ], file: source7)
        guard case CloudreveError.unsupportedStoragePolicy? = err else {
            preconditionFailure("upyun large: expected unsupportedStoragePolicy, got \(String(describing: err))")
        }
        precondition(hasCancel() && calls("POST", host: "upyun.invalid").isEmpty)

        // 14. failure on chunk 2.
        StorageProtocol.calls = []
        StorageProtocol.providerPuts = 0
        StorageProtocol.pendingInfoPolls = 0
        StorageProtocol.failProviderPut = 2
        StorageProtocol.sessionPayload = [
            "session_id": "our-session", "chunk_size": 3,
            "upload_urls": s3URLs("bucket.s3.invalid"), "storage_policy": ["type": "s3"],
            "completeURL": "https://bucket.s3.invalid/complete", "callback_secret": "sec",
        ]
        do {
            try await client.uploadFile(at: "cloudreve://my/f.txt", from: source7, overwrite: false,
                progress: Progress())
            preconditionFailure("expected failure")
        } catch CloudreveError.http(let status) {
            precondition(status == 500)
        } catch { preconditionFailure("expected http 500, got \(error)") }
        precondition(!hasCancel())  // 5xx is transient: the session is kept for resume
        precondition(calls("POST", host: "bucket.s3.invalid").isEmpty)
        everyCall += StorageProtocol.calls

        // 15. too few URLs.
        err = await run([
            "upload_urls": Array(s3URLs("bucket.s3.invalid").prefix(2)), "storage_policy": ["type": "s3"],
            "completeURL": "https://bucket.s3.invalid/complete", "callback_secret": "sec",
        ], file: source7)
        guard case CloudreveError.badResponse? = err else {
            preconditionFailure("too few URLs: expected badResponse, got \(String(describing: err))")
        }
        precondition(StorageProtocol.calls.allSatisfy { $0.host == "test.invalid" })
        precondition(hasCancel())

        // 16. The account token never reaches a provider host.
        precondition(everyCall.contains { $0.host != "test.invalid" })
        for call in everyCall where call.host != "test.invalid" {
            precondition(call.header("Authorization")?.contains("Bearer") != true,
                "Bearer token sent to \(call.host)")
        }
    }
}
