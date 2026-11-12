import Foundation
import FileProvider

private struct Call {
    let method: String
    let host: String
    let path: String
    let query: String
    let body: Data
}

private struct Reply {
    let status: Int
    let body: Data?
}

private final class ResumeProtocol: URLProtocol {
    static var calls: [Call] = []
    static var sessionPayload: [String: Any] = [:]
    /// Session id reported by /file/info for URIs without an override; nil = the last created session.
    static var currentSession = "none"
    static var infoSession: String?
    static var infoSessionsByURI: [String: String] = [:]
    /// Lets a case answer a request itself (failures, cancellation).
    static var behave: (Call) -> Reply? = { _ in nil }

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
        let call = Call(method: method, host: host, path: url.path, query: url.query ?? "",
            body: Self.bodyData(request))
        Self.calls.append(call)

        var status = 200
        var headers: [String: String] = [:]
        var data = Data()
        if let reply = Self.behave(call) {
            status = reply.status
            data = reply.body ?? Data()
        } else if host == "test.invalid" {
            var payload: [String: Any] = ["code": 0]
            if method == "PUT", url.path == "/api/v4/file/upload" {
                payload["data"] = Self.sessionPayload
                Self.currentSession = Self.sessionPayload["session_id"] as? String ?? "none"
            } else if url.path == "/api/v4/file/info" {
                let uri = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?
                    .first(where: { $0.name == "uri" })?.value ?? "cloudreve://my/f.txt"
                let session = Self.infoSessionsByURI[uri] ?? Self.infoSession ?? Self.currentSession
                payload["data"] = ["type": 0, "id": "file", "name": "f", "path": uri, "size": 3,
                    "metadata": ["sys:upload_session_id": session]]
            }
            data = try! JSONSerialization.data(withJSONObject: payload)
        } else if method == "PUT" {
            headers["ETag"] = "\"e\(url.path.last.map(String.init) ?? "x")\""
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
            httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func expect(_ ok: Bool, _ message: String = "") { precondition(ok, message) }

@main enum UploadResumeTests {
    static let namespace = UploadSessionRecord.namespace
    static let driveID = "up-resume"
    static let uri = "cloudreve://my/f.txt"
    static let original = Data("abcdefghijkl".utf8)  // 12 bytes, chunk size 3 => 4 chunks

    static func main() async throws {
        pureRecordCases()
        try await endToEndCases()
        print("UploadResumeTests: all tests passed")
    }

    // MARK: Pure record helpers

    static func pureRecordCases() {
        for value in [UploadTargetKind.cloudreve, .slave, .s3Like("oss"), .oneDrive, .qiniu, .upyun, .unsupported("x:y")] {
            precondition(UploadTargetKind(recordValue: value.recordValue) == value)
        }
        precondition(UploadTargetKind(recordValue: "bogus") == nil)

        let legacy = UploadSessionRecord.decode(Data("{\"id\":\"a\",\"uri\":\"cloudreve://my/x\"}".utf8))
        precondition(legacy?.v == 0 && legacy?.id == "a" && legacy?.uri == "cloudreve://my/x")
        precondition(legacy!.isAbandoned(now: 1) && !legacy!.isResumable(now: 1))
        precondition(UploadSessionRecord.decode(Data("[1]".utf8)) == nil)

        let now: Int64 = 1_000_000
        var record = UploadSessionRecord(
            v: 1, id: "s", uri: uri, overwrite: false, previous: nil, size: 12, mtime: 5,
            headHash: "h", tailHash: "t", chunkSize: 3, nextChunk: 2, etags: ["a", "b"],
            kind: "s3:s3", uploadURLs: ["u"], credential: nil, completeURL: nil, callbackSecret: nil,
            mimeType: nil, uploadPolicy: nil, encrypt: nil, expiresAt: nil, createdAt: now, updatedAt: now)
        let round = UploadSessionRecord.decode(try! JSONEncoder().encode(record))
        precondition(round?.etags == ["a", "b"] && round?.nextChunk == 2)
        precondition(record.isResumable(now: now) && !record.isAbandoned(now: now))
        precondition(record.matches(uri: uri, overwrite: false, previous: nil, size: 12, mtime: 5, head: "h", tail: "t", chunkSize: 3))
        precondition(!record.matches(uri: uri, overwrite: false, previous: nil, size: 12, mtime: 6, head: "h", tail: "t", chunkSize: 3))
        record.expiresAt = now + 30
        precondition(!record.isResumable(now: now) && !record.isAbandoned(now: now))
        record.expiresAt = now + 120
        precondition(record.isResumable(now: now))
        record.expiresAt = nil
        record.updatedAt = now - 25 * 3600
        precondition(record.isAbandoned(now: now))
        record.updatedAt = now
        record.etags = ["a"]  // etag count must equal nextChunk for s3
        precondition(!record.isResumable(now: now))
        record.etags = ["a", "b"]
        record.kind = "upyun"
        precondition(!record.isResumable(now: now))
        record.kind = "unsupported:foo"
        precondition(!record.isResumable(now: now))
    }

    // MARK: End to end

    static func endToEndCases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        CloudreveClient.completionPollAttempts = 2
        CloudreveClient.completionPollIntervalNanoseconds = 5_000_000

        let drive = DriveConfig(id: driveID, name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResumeProtocol.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))
        let source = root.appendingPathComponent("source")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        func writeSource(_ data: Data, date: Date = fixedDate) throws {
            try data.write(to: source)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        }
        func reset(_ payload: [String: Any]) throws {
            ResumeProtocol.calls = []
            ResumeProtocol.behave = { _ in nil }
            ResumeProtocol.infoSession = nil
            ResumeProtocol.infoSessionsByURI = [:]
            var full: [String: Any] = ["session_id": "s1", "chunk_size": 3]
            full.merge(payload) { $1 }
            ResumeProtocol.sessionPayload = full
            let db = try FileProviderStateDatabase()
            try db.execute("DELETE FROM fp_records WHERE namespace=?", [namespace])
            try writeSource(original)
        }
        func run(_ payload: [String: Any]? = nil, to target: String = uri, progress: Progress = Progress())
            async -> Error?
        {
            if let payload {
                var full: [String: Any] = ["session_id": "s1", "chunk_size": 3]
                full.merge(payload) { $1 }
                ResumeProtocol.sessionPayload = full
            }
            ResumeProtocol.calls = []
            do {
                try await client.uploadFile(at: target, from: source, overwrite: false, progress: progress)
                return nil
            } catch { return error }
        }
        func calls(_ method: String, host: String? = nil, path: String? = nil, prefix: String? = nil) -> [Call] {
            ResumeProtocol.calls.filter {
                $0.method == method && (host == nil || $0.host == host)
                    && (path == nil || $0.path == path) && (prefix == nil || $0.path.hasPrefix(prefix!))
            }
        }
        func deletes() -> [Call] { calls("DELETE", host: "test.invalid", path: "/api/v4/file/upload") }
        func puts() -> [Call] { calls("PUT", host: "test.invalid", path: "/api/v4/file/upload") }
        func record(_ session: String) throws -> UploadSessionRecord? {
            try FileProviderStateDatabase().get(namespace, UploadSessionRecord.key(driveID: driveID, sessionID: session))
                .flatMap(UploadSessionRecord.decode)
        }
        func recordCount() throws -> Int {
            try FileProviderStateDatabase().rows("SELECT key FROM fp_records WHERE namespace=?", [namespace]).count
        }
        func chunkIndexes() -> [String] {
            calls("POST", host: "test.invalid", prefix: "/api/v4/file/upload/").map { String($0.path.split(separator: "/").last!) }
        }
        func failLocalChunk(_ index: Int, status: Int = 503, body: Data? = nil) {
            ResumeProtocol.behave = { call in
                call.method == "POST" && call.path.hasSuffix("/\(index)") ? Reply(status: status, body: body) : nil
            }
        }
        func isTransient(_ error: Error?) -> Bool {
            guard let error else { return false }
            return ReplayFailure.classify(error) == .transient
        }
        func s3Payload(session: String = "s1") -> [String: Any] {
            ["session_id": session, "storage_policy": ["type": "s3"],
             "upload_urls": (0..<4).map { "https://bucket.s3.invalid/obj\($0)?sig=x" },
             "completeURL": "https://bucket.s3.invalid/complete?sig=y", "callback_secret": "sec"]
        }

        // 1 + 2. Local policy: a 503 keeps the session; the next attempt resumes at the failed chunk.
        try reset([:])
        failLocalChunk(2)
        var err = await run()
        precondition(isTransient(err), "1: \(String(describing: err))")
        precondition(deletes().isEmpty, "1: no DELETE after 503")
        var saved = try record("s1")
        precondition(saved?.nextChunk == 2 && saved?.v == 1, "1: nextChunk \(String(describing: saved?.nextChunk))")
        ResumeProtocol.behave = { _ in nil }
        err = await run()
        precondition(err == nil, "2: \(String(describing: err))")
        precondition(puts().isEmpty, "2: no new session")
        precondition(chunkIndexes() == ["2", "3"], "2: chunks \(chunkIndexes())")
        precondition(deletes().isEmpty)
        expect(try record("s1") == nil && recordCount() == 0, "2: record removed")

        // 3. S3: resumed completion carries all four ETags.
        try reset(s3Payload())
        ResumeProtocol.behave = { call in
            call.method == "PUT" && call.host == "bucket.s3.invalid" && call.path == "/obj2" ? Reply(status: 503, body: nil) : nil
        }
        err = await run()
        precondition(isTransient(err), "3: \(String(describing: err))")
        saved = try record("s1")
        precondition(saved?.etags == ["e0", "e1"] && saved?.nextChunk == 2 && deletes().isEmpty)
        ResumeProtocol.behave = { _ in nil }
        err = await run()
        precondition(err == nil, "3 resume: \(String(describing: err))")
        precondition(puts().isEmpty)
        let provider = calls("PUT", host: "bucket.s3.invalid").map(\.path)
        precondition(provider == ["/obj2", "/obj3"], "3: \(provider)")
        let complete = calls("POST", host: "bucket.s3.invalid")
        precondition(complete.count == 1)
        let xml = String(decoding: complete[0].body, as: UTF8.self)
        precondition(xml == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>e0</ETag></Part><Part><PartNumber>2</PartNumber><ETag>e1</ETag></Part><Part><PartNumber>3</PartNumber><ETag>e2</ETag></Part><Part><PartNumber>4</PartNumber><ETag>e3</ETag></Part></CompleteMultipartUpload>", xml)
        expect(try recordCount() == 0)

        // 4. Encryption: resumed chunk bytes equal those of an uninterrupted upload.
        let encrypt: [String: Any] = ["encrypt_metadata": [
            "algorithm": "aes-256-ctr",
            "key_plain_text": Data((0..<32).map { UInt8($0) }).base64EncodedString(),
            "iv": Data((0..<16).map { UInt8(100 + $0) }).base64EncodedString()]]
        try reset(encrypt)
        err = await run()
        precondition(err == nil, "4 baseline: \(String(describing: err))")
        var baseline: [String: Data] = [:]
        for call in calls("POST", host: "test.invalid", prefix: "/api/v4/file/upload/") {
            baseline[String(call.path.split(separator: "/").last!)] = call.body
        }
        precondition(baseline.count == 4 && baseline["0"] != Data("abc".utf8))
        try reset(encrypt)
        failLocalChunk(2)
        err = await run()
        precondition(isTransient(err))
        var resumedBodies: [String: Data] = [:]
        for call in calls("POST", host: "test.invalid", prefix: "/api/v4/file/upload/") {
            if call.path.hasSuffix("/0") || call.path.hasSuffix("/1") {
                resumedBodies[String(call.path.split(separator: "/").last!)] = call.body
            }
        }
        ResumeProtocol.behave = { _ in nil }
        err = await run()
        precondition(err == nil && puts().isEmpty, "4 resume: \(String(describing: err))")
        for call in calls("POST", host: "test.invalid", prefix: "/api/v4/file/upload/") {
            resumedBodies[String(call.path.split(separator: "/").last!)] = call.body
        }
        precondition(resumedBodies == baseline, "4: resumed bytes differ")

        // 5. Expired record: fresh session; the old one is cancelled only when owned.
        for owned in [true, false] {
            try reset([:])
            failLocalChunk(2)
            err = await run()
            precondition(isTransient(err))
            var expired = try record("s1")!
            expired.expiresAt = Int64(Date().timeIntervalSince1970) - 10
            try FileProviderStateDatabase().put(namespace, UploadSessionRecord.key(driveID: driveID, sessionID: "s1"),
                try JSONEncoder().encode(expired))
            ResumeProtocol.behave = { _ in nil }
            ResumeProtocol.infoSession = owned ? nil : "someone-else"
            err = await run(["session_id": "s2"])
            precondition(err == nil, "5: \(String(describing: err))")
            precondition(puts().count == 1, "5: fresh PUT")
            precondition(chunkIndexes() == ["0", "1", "2", "3"], "5: \(chunkIndexes())")
            let cancelled = deletes().compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
                .compactMap { $0["id"] as? String }
            precondition(owned ? cancelled == ["s1"] : cancelled.isEmpty, "5 owned=\(owned): \(cancelled)")
            expect(try recordCount() == 0)
        }

        // 6. A changed file starts a fresh session each time and cancels the owned old one.
        let variants: [(String, Data, Date)] = [
            ("size", Data("abcdefghijklm".utf8), fixedDate),
            ("mtime", original, fixedDate.addingTimeInterval(60)),
            ("last chunk", Data("abcdefghijkX".utf8), fixedDate),
        ]
        for (name, data, date) in variants {
            try reset([:])
            failLocalChunk(2)
            err = await run()
            precondition(isTransient(err), "6 \(name)")
            try writeSource(data, date: date)
            ResumeProtocol.behave = { _ in nil }
            err = await run(["session_id": "s2"])
            precondition(err == nil, "6 \(name): \(String(describing: err))")
            precondition(puts().count == 1, "6 \(name): fresh PUT")
            let first = chunkIndexes().first
            precondition(first == "0", "6 \(name): restarted at \(String(describing: first))")
            let cancelled = deletes().compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
                .compactMap { $0["id"] as? String }
            precondition(cancelled == ["s1"], "6 \(name): \(cancelled)")
            expect(try recordCount() == 0)
        }

        // 7. Ownership mismatch: never DELETE, drop the record, start fresh.
        try reset([:])
        failLocalChunk(2)
        err = await run()
        precondition(isTransient(err))
        ResumeProtocol.behave = { _ in nil }
        ResumeProtocol.infoSession = "someone-else"
        err = await run(["session_id": "s2"])
        precondition(err == nil, "7: \(String(describing: err))")
        precondition(deletes().isEmpty, "7: no DELETE without ownership")
        precondition(puts().count == 1 && chunkIndexes() == ["0", "1", "2", "3"])
        expect(try record("s1") == nil && recordCount() == 0)

        // 8. 40073 on the first resumed chunk: lockConflict, no DELETE, record kept.
        try reset([:])
        failLocalChunk(2)
        err = await run()
        precondition(isTransient(err))
        failLocalChunk(2, status: 200, body: Data("{\"code\":40073,\"msg\":\"locked\"}".utf8))
        err = await run()
        guard case CloudreveError.lockConflict? = err else {
            preconditionFailure("8: expected lockConflict, got \(String(describing: err))")
        }
        precondition(deletes().isEmpty && puts().isEmpty, "8: no cancel, no new session")
        precondition(calls("POST", host: "test.invalid").allSatisfy { $0.path.hasPrefix("/api/v4/file/upload/") })
        expect(try record("s1")?.nextChunk == 2, "8: record kept")

        // 9. User cancel: the owned session is cancelled and the record removed.
        try reset([:])
        let cancelling = Progress()
        ResumeProtocol.behave = { call in
            if call.method == "POST", call.path.hasSuffix("/1") { cancelling.cancel() }
            return nil
        }
        err = await run(progress: cancelling)
        precondition(err != nil && cancelling.isCancelled, "9: \(String(describing: err))")
        precondition(deletes().count == 1, "9: DELETE sent")
        expect(try record("s1") == nil && recordCount() == 0)

        // 10. Flush volume: 100 chunks without failure.
        try reset([:])
        try writeSource(Data(repeating: 0x61, count: 300))
        let writesBefore = CloudreveClient.recordWritesForTests
        err = await run()
        precondition(err == nil, "10: \(String(describing: err))")
        precondition(chunkIndexes().count == 100)
        let writes = CloudreveClient.recordWritesForTests - writesBefore
        precondition(writes >= 2 && writes <= 15, "10: \(writes) record writes")
        expect(try recordCount() == 0)

        // 11. A legacy v0 record for another URI is cleaned up with ownership proof.
        try reset([:])
        let legacyKey = UploadSessionRecord.key(driveID: driveID, sessionID: "legacy")
        try FileProviderStateDatabase().put(namespace, legacyKey,
            Data("{\"id\":\"legacy\",\"uri\":\"cloudreve://my/other.txt\"}".utf8))
        ResumeProtocol.infoSessionsByURI = ["cloudreve://my/other.txt": "legacy"]
        err = await run()
        precondition(err == nil, "11: \(String(describing: err))")
        let legacyDeletes = deletes().compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
            .compactMap { $0["id"] as? String }
        precondition(legacyDeletes == ["legacy"], "11: \(legacyDeletes)")
        expect(try FileProviderStateDatabase().get(namespace, legacyKey) == nil)
        // Without proof (item reports another session) only the record goes.
        try FileProviderStateDatabase().put(namespace, legacyKey,
            Data("{\"id\":\"legacy\",\"uri\":\"cloudreve://my/other.txt\"}".utf8))
        ResumeProtocol.infoSessionsByURI = ["cloudreve://my/other.txt": "unrelated"]
        err = await run()
        precondition(err == nil && deletes().isEmpty, "11b: \(String(describing: err))")
        expect(try FileProviderStateDatabase().get(namespace, legacyKey) == nil)

        // 12. Upyun never resumes: each attempt sends a fresh request.
        try reset([:])
        try writeSource(Data("abc".utf8))
        let upyun: [String: Any] = ["storage_policy": ["type": "upyun"],
            "upload_urls": ["https://upyun.invalid/bucket"], "upload_policy": "pol", "credential": "auth"]
        ResumeProtocol.behave = { call in
            call.host == "upyun.invalid" ? Reply(status: 503, body: nil) : nil
        }
        err = await run(upyun)
        precondition(isTransient(err), "12: \(String(describing: err))")
        expect(try record("s1") != nil)
        ResumeProtocol.behave = { _ in nil }
        var second = upyun
        second["session_id"] = "s2"
        err = await run(second)
        precondition(err == nil, "12 retry: \(String(describing: err))")
        precondition(puts().count == 1, "12: fresh session")
        precondition(calls("POST", host: "upyun.invalid").count == 1, "12: fresh upload request")
        let upyunCancelled = deletes().compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
            .compactMap { $0["id"] as? String }
        precondition(upyunCancelled == ["s1"], "12: \(upyunCancelled)")
    }
}
