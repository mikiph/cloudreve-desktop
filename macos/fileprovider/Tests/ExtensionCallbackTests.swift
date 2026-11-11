import Foundation
import FileProvider
import UniformTypeIdentifiers

/// A tiny in-memory Cloudreve server behind a URLProtocol.
private final class ServerProtocol: URLProtocol {
    typealias Entry = (method: String, endpoint: String, uri: String?, body: [String: Any])
    private static let lock = NSLock()
    private static var _files: [String: [String: Any]] = [:]
    private static var _log: [Entry] = []
    private static var _failNext: [String: Int] = [:]
    private static var counter = 0
    private static var uploadURI = ""

    static var files: [String: [String: Any]] {
        get { lock.lock(); defer { lock.unlock() }; return _files }
        set { lock.lock(); defer { lock.unlock() }; _files = newValue }
    }
    static var log: [Entry] {
        get { lock.lock(); defer { lock.unlock() }; return _log }
        set { lock.lock(); defer { lock.unlock() }; _log = newValue }
    }
    static var failNext: [String: Int] {
        get { lock.lock(); defer { lock.unlock() }; return _failNext }
        set { lock.lock(); defer { lock.unlock() }; _failNext = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private static func parent(_ uri: String) -> String {
        guard let slash = uri.lastIndex(of: "/") else { return uri }
        return String(uri[..<slash])
    }
    private static func last(_ uri: String) -> String {
        uri.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }
    private static func decoded(_ s: String?) -> String? { s?.removingPercentEncoding ?? s }

    private func reply(_ status: Int = 200, _ data: Data, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    private func ok(_ data: Any) {
        let body = try! JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
        reply(200, body)
    }
    private func fail(_ code: Int) {
        let body = try! JSONSerialization.data(withJSONObject: ["code": code, "msg": "x"])
        reply(200, body)
    }

    override func startLoading() {
        let url = request.url!
        // Blob download (not part of the API).
        if url.host == "test.invalid" && url.path == "/blob" {
            reply(200, Data("hello".utf8), headers: ["Content-Length": "5"])
            return
        }
        let endpoint = url.path.replacingOccurrences(of: "/api/v4", with: "")
        let method = request.httpMethod ?? "GET"
        var bodyData = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bodyData.append(contentsOf: buffer.prefix(count))
            }
        }
        let isChunk = endpoint.hasPrefix("/file/upload/")
        var body = (isChunk ? nil : try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        // Decode every URI in the body, so the mock works with or without percent-encoding.
        if let u = body["uri"] as? String { body["uri"] = Self.decoded(u) }
        if let d = body["dst"] as? String { body["dst"] = Self.decoded(d) }
        if let us = body["uris"] as? [String] { body["uris"] = us.map { Self.decoded($0)! } }
        let queryURI = Self.decoded(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "uri" }?.value)
        let uri = queryURI ?? body["uri"] as? String

        Self.lock.lock()
        defer { Self.lock.unlock() }
        Self._log.append((method, endpoint, uri, body))

        let key = "\(method) \(endpoint)"
        if let code = Self._failNext.removeValue(forKey: key) { fail(code); return }

        switch (method, endpoint) {
        case ("GET", "/file/info"):
            if let uri, let f = Self._files[uri] { ok(f) } else { fail(40016) }
        case ("GET", "/file"):
            let p = uri ?? ""
            let children = Self._files.filter { Self.parent($0.key) == p }.map { $0.value }
            ok(["files": children, "pagination": [String: Any]()])
        case ("POST", "/file/create"):
            Self.counter += 1
            let target = body["uri"] as! String
            let isFolder = (body["type"] as? String) == "folder"
            let f = Self.fileJSON(uri: target, type: isFolder ? 1 : 0, id: "new-\(Self.counter)",
                                  size: 0, entity: nil)
            Self._files[target] = f
            ok(f)
        case ("POST", "/file/rename"):
            let from = body["uri"] as! String
            let newName = body["new_name"] as! String
            guard var f = Self._files.removeValue(forKey: from) else { fail(40016); return }
            let to = Self.parent(from) + "/" + newName
            f["name"] = newName
            f["path"] = to
            Self._files[to] = f
            ok(f)
        case ("POST", "/file/move"):
            let dst = body["dst"] as! String
            for from in body["uris"] as? [String] ?? [] {
                guard var f = Self._files.removeValue(forKey: from) else { fail(40016); return }
                let to = dst + "/" + Self.last(from)
                f["path"] = to
                Self._files[to] = f
            }
            ok([String: Any]())
        case ("DELETE", "/file"):
            for u in body["uris"] as? [String] ?? [] { Self._files.removeValue(forKey: u) }
            ok([String: Any]())
        case ("PUT", "/file/upload"):
            Self.uploadURI = body["uri"] as? String ?? ""
            ok(["session_id": "s1", "chunk_size": 1_048_576])
        case ("POST", _) where isChunk:
            let target = Self.uploadURI
            let existing = Self._files[target]
            Self.counter += 1
            var f = Self.fileJSON(uri: target, type: 0,
                                  id: existing?["id"] as? String ?? "new-\(Self.counter)",
                                  size: bodyData.count, entity: "e-upload")
            if let existing { f["created_at"] = existing["created_at"] }
            Self._files[target] = f
            ok([String: Any]())
        case ("DELETE", "/file/upload"):
            ok([String: Any]())
        case ("POST", "/file/url"):
            ok(["urls": [["url": "https://test.invalid/blob"]]])
        default:
            fail(40000)
        }
    }

    static func fileJSON(uri: String, type: Int, id: String, size: Int, entity: String?) -> [String: Any] {
        var f: [String: Any] = [
            "type": type, "id": id, "name": last(uri), "path": uri, "size": size,
            "created_at": "2026-10-19T12:00:00Z", "updated_at": "2026-10-19T12:00:00Z",
        ]
        if let entity { f["primary_entity"] = entity }
        return f
    }
}

@main enum ExtensionCallbackTests {
    fileprivate typealias Log = ServerProtocol.Entry

    static func fpCode(_ e: Error?) -> Int? {
        guard let ns = e as NSError?, ns.domain == NSFileProviderErrorDomain else { return nil }
        return ns.code
    }

    fileprivate static func hits(_ method: String, _ endpoint: String) -> [Log] {
        ServerProtocol.log.filter { $0.method == method && $0.endpoint == endpoint }
    }

    /// Calls like "GET /file/info" and the create-stabilization relists are
    /// excluded from "no request" checks: a successful createItem starts a
    /// background task that lists the parent after 2, 6 and 22 seconds.
    fileprivate static func nonListing() -> [Log] {
        ServerProtocol.log.filter { !($0.method == "GET" && $0.endpoint == "/file") }
    }

    static func tempFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-cb-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: callback wrappers

    static func itemFor(_ ext: FileProviderExtension, _ id: NSFileProviderItemIdentifier)
        async -> (NSFileProviderItem?, Error?)
    {
        await withCheckedContinuation { c in
            _ = ext.item(for: id, request: NSFileProviderRequest()) { c.resume(returning: ($0, $1)) }
        }
    }

    static func fetch(_ ext: FileProviderExtension, _ id: NSFileProviderItemIdentifier)
        async -> (URL?, NSFileProviderItem?, Error?)
    {
        await withCheckedContinuation { c in
            _ = ext.fetchContents(for: id, version: nil, request: NSFileProviderRequest()) {
                c.resume(returning: ($0, $1, $2))
            }
        }
    }

    static func create(_ ext: FileProviderExtension, _ template: NSFileProviderItem, contents: URL?)
        async -> (NSFileProviderItem?, Error?)
    {
        await withCheckedContinuation { c in
            _ = ext.createItem(basedOn: template, fields: [], contents: contents, options: [],
                               request: NSFileProviderRequest()) { item, _, _, error in
                c.resume(returning: (item, error))
            }
        }
    }

    static func modify(_ ext: FileProviderExtension, _ item: NSFileProviderItem,
                       base: NSFileProviderItemVersion, fields: NSFileProviderItemFields,
                       contents: URL?) async -> (NSFileProviderItem?, Error?)
    {
        await withCheckedContinuation { c in
            _ = ext.modifyItem(item, baseVersion: base, changedFields: fields, contents: contents,
                               options: [], request: NSFileProviderRequest()) { item, _, _, error in
                c.resume(returning: (item, error))
            }
        }
    }

    static func delete(_ ext: FileProviderExtension, _ id: NSFileProviderItemIdentifier,
                       base: NSFileProviderItemVersion) async -> Error?
    {
        await withCheckedContinuation { c in
            _ = ext.deleteItem(identifier: id, baseVersion: base, options: [],
                               request: NSFileProviderRequest()) { c.resume(returning: $0) }
        }
    }

    static func template(_ name: String, parent: NSFileProviderItemIdentifier = .rootContainer,
                         type: UTType, id: String = UUID().uuidString) -> FileProviderItem
    {
        FileProviderItem(
            identifier: NSFileProviderItemIdentifier(id), parentIdentifier: parent,
            filename: name, contentType: type, documentSize: nil, childItemCount: nil,
            capabilities: [.allowsReading, .allowsWriting, .allowsDeleting],
            contentVersion: Data("local".utf8), metadataVersion: Data("local".utf8),
            creationDate: nil, contentModificationDate: nil, pinned: false)
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        let drive = DriveConfig(id: "ext-callbacks-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let domain = NSFileProviderDomain(identifier: .init("ext-callbacks-test"), displayName: "Test")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServerProtocol.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root,
                                workingSetSignaller: {}, client: client)
        let ext = FileProviderExtension(domain: domain, store: store)

        func seed(_ uri: String, type: Int, id: String, size: Int, entity: String?) -> FileProviderItem {
            ServerProtocol.files[uri] = ServerProtocol.fileJSON(
                uri: uri, type: type, id: id, size: size, entity: entity)
            return store.makeItem(RemoteFile(
                type: type, id: id, name: uri.components(separatedBy: "/").last!, path: uri, size: Int64(size),
                created_at: "2026-10-19T12:00:00Z", updated_at: "2026-10-19T12:00:00Z",
                metadata: nil, shared: false, owned: true, primary_entity: entity))
        }
        let idA = NSFileProviderItemIdentifier("cloudreve-item:/A")
        let idF = NSFileProviderItemIdentifier("cloudreve-item:/F")
        let seededA = seed("cloudreve://my/a.txt", type: 0, id: "A", size: 5, entity: "e1")
        _ = seed("cloudreve://my/F", type: 1, id: "F", size: 0, entity: nil)
        precondition(seededA.itemIdentifier == idA, "seeded identity: \(seededA.itemIdentifier.rawValue)")
        precondition(store.uri(for: idF) == "cloudreve://my/F")
        ServerProtocol.log = []

        // 1. No store: every callback reports notAuthenticated, with no HTTP.
        do {
            let bare = FileProviderExtension(domain: domain, store: nil)
            let (item, error) = await itemFor(bare, idA)
            precondition(item == nil)
            precondition(fpCode(error) == NSFileProviderError.Code.notAuthenticated.rawValue, "case 1: \(String(describing: error))")
            precondition(ServerProtocol.log.isEmpty, "case 1: no HTTP expected")
        }

        // 2. Ignored Finder names are handled locally.
        do {
            ServerProtocol.log = []
            let (item, error) = await create(ext, template(".DS_Store", type: .data), contents: nil)
            precondition(item != nil && error == nil, "case 2 create: \(String(describing: error))")
            let deleteError = await delete(ext, NSFileProviderItemIdentifier("cloudreve-item:/x/.DS_Store"),
                                           base: seededA.itemVersion)
            precondition(deleteError == nil, "case 2 delete: \(String(describing: deleteError))")
            precondition(ServerProtocol.log.isEmpty, "case 2: no HTTP expected")
        }

        // 3. item(for:)
        do {
            ServerProtocol.log = []
            var (item, error) = await itemFor(ext, .rootContainer)
            precondition(item?.itemIdentifier == .rootContainer && error == nil, "case 3 root")
            (item, error) = await itemFor(ext, idA)
            precondition(item?.filename == "a.txt" && error == nil, "case 3 a.txt: \(String(describing: error))")
            (item, error) = await itemFor(ext, .trashContainer)
            // Characterized: mapError maps NSFileProviderError to serverUnreachable; see plans/README.md
            precondition(item == nil && fpCode(error) == NSFileProviderError.Code.serverUnreachable.rawValue,
                         "case 3 trash: \(String(describing: error))")
            (item, error) = await itemFor(ext, NSFileProviderItemIdentifier("cloudreve-item:/Z"))
            precondition(item == nil && fpCode(error) == NSFileProviderError.Code.noSuchItem.rawValue,
                         "case 3 unknown: \(String(describing: error))")
        }

        // 4. fetchContents
        do {
            ServerProtocol.log = []
            let (url, item, error) = await fetch(ext, idA)
            precondition(error == nil, "case 4 error: \(String(describing: error))")
            precondition(item?.filename == "a.txt", "case 4 filename")
            let data = try Data(contentsOf: url!)
            precondition(String(data: data, encoding: .utf8) == "hello", "case 4 contents")
            let urlCalls = hits("POST", "/file/url")
            precondition(urlCalls.count == 1 && (urlCalls[0].body["uris"] as? [String]) == ["cloudreve://my/a.txt"],
                         "case 4 /file/url body")
            try? FileManager.default.removeItem(at: url!)
        }

        // 5. fetchContents failure (remote item is gone)
        do {
            ServerProtocol.failNext["GET /file/info"] = 40016
            let (url, item, error) = await fetch(ext, idA)
            precondition(url == nil && item == nil)
            precondition(fpCode(error) == NSFileProviderError.Code.noSuchItem.rawValue, "case 5: \(String(describing: error))")
            // The store evicts the item on noSuchItem; re-seed it.
            _ = seed("cloudreve://my/a.txt", type: 0, id: "A", size: 5, entity: "e1")
        }

        // 6. createItem folder
        do {
            ServerProtocol.log = []
            let (item, error) = await create(ext, template("New Folder", type: .folder), contents: nil)
            precondition(error == nil, "case 6: \(String(describing: error))")
            precondition(item?.filename == "New Folder", "case 6 filename")
            let calls = hits("POST", "/file/create")
            precondition(calls.count == 1 && calls[0].body["uri"] as? String == "cloudreve://my/New Folder"
                         && calls[0].body["type"] as? String == "folder", "case 6 body")
        }

        // 7. createItem file with contents
        do {
            ServerProtocol.log = []
            let content = try tempFile("12345")
            let (item, error) = await create(ext, template("n.txt", type: .plainText), contents: content)
            precondition(error == nil && item?.filename == "n.txt", "case 7: \(String(describing: error))")
            let order = nonListing().map { "\($0.method) \($0.endpoint)" }
            precondition(order == ["PUT /file/upload", "POST /file/upload/s1/0", "GET /file/info"],
                         "case 7 order: \(order)")
            precondition(hits("PUT", "/file/upload")[0].body["size"] as? Int == 5, "case 7 size")
        }

        // 8. createItem collision
        do {
            ServerProtocol.failNext["POST /file/create"] = 40004
            let (item, error) = await create(ext, template("Dup", type: .folder), contents: nil)
            precondition(item == nil)
            precondition(fpCode(error) == NSFileProviderError.Code.filenameCollision.rawValue, "case 8: \(String(describing: error))")
        }

        // 9. modifyItem rename
        let renamed = template("b.txt", type: .plainText, id: idA.rawValue)
        do {
            ServerProtocol.log = []
            let (item, error) = await modify(ext, renamed, base: seededA.itemVersion, fields: [.filename], contents: nil)
            precondition(error == nil, "case 9: \(String(describing: error))")
            precondition(item?.filename == "b.txt", "case 9 filename")
            let calls = hits("POST", "/file/rename")
            precondition(calls.count == 1 && calls[0].body["uri"] as? String == "cloudreve://my/a.txt"
                         && calls[0].body["new_name"] as? String == "b.txt", "case 9 body")
            precondition(store.uri(for: idA) == "cloudreve://my/b.txt", "case 9 uri: \(store.uri(for: idA))")
        }

        // 10. modifyItem move
        var afterMove: NSFileProviderItem?
        do {
            ServerProtocol.log = []
            let moving = template("b.txt", parent: idF, type: .plainText, id: idA.rawValue)
            let (item, error) = await modify(ext, moving, base: seededA.itemVersion, fields: [.parentItemIdentifier], contents: nil)
            precondition(error == nil, "case 10: \(String(describing: error))")
            let calls = hits("POST", "/file/move")
            precondition(calls.count == 1 && calls[0].body["uris"] as? [String] == ["cloudreve://my/b.txt"]
                         && calls[0].body["dst"] as? String == "cloudreve://my/F", "case 10 body")
            precondition(store.uri(for: idA) == "cloudreve://my/F/b.txt", "case 10 uri: \(store.uri(for: idA))")
            afterMove = item
        }

        // 11. modifyItem contents: previous comes from the returned item's remoteVersion (e1).
        var afterContents: NSFileProviderItem?
        do {
            ServerProtocol.log = []
            let content = try tempFile("123456")
            let (item, error) = await modify(ext, afterMove!, base: afterMove!.itemVersion!, fields: [.contents], contents: content)
            precondition(error == nil, "case 11: \(String(describing: error))")
            let puts = hits("PUT", "/file/upload")
            precondition(puts.count == 1 && puts[0].body["entity_type"] as? String == "version"
                         && puts[0].body["previous"] as? String == "e1", "case 11 body: \(puts.map { $0.body })")
            afterContents = item
        }

        // 12. modifyItem on an ignored name returns the item unchanged with no remote call.
        do {
            // Let any create-stabilization relist settle out of the check; they are GET /file only.
            ServerProtocol.log = []
            let ignored = template("._b.txt", type: .data, id: idA.rawValue)
            let (item, error) = await modify(ext, ignored, base: seededA.itemVersion, fields: [.filename], contents: nil)
            precondition(error == nil && item?.itemIdentifier == ignored.itemIdentifier && item?.filename == "._b.txt",
                         "case 12: \(String(describing: error))")
            precondition(nonListing().isEmpty, "case 12: no non-listing HTTP expected, got \(nonListing().map { $0.endpoint })")
        }

        // 13. deleteItem. Adaptation to plan 021: deleteItem first reads GET /file/info and rejects a stale baseVersion.
        do {
            ServerProtocol.log = []
            // 13a. A stale base version (e1; the server now has e-upload) is rejected without DELETE.
            let stale = await delete(ext, idA, base: afterMove!.itemVersion!)
            precondition(fpCode(stale) == NSFileProviderError.Code.deletionRejected.rawValue, "case 13a: \(String(describing: stale))")
            precondition(hits("DELETE", "/file").isEmpty, "case 13a: no DELETE expected")
            // 13b. The version returned by case 11 deletes.
            ServerProtocol.log = []
            let error = await delete(ext, idA, base: afterContents!.itemVersion!)
            precondition(error == nil, "case 13: \(String(describing: error))")
            let calls = hits("DELETE", "/file")
            precondition(calls.count == 1 && calls[0].body["uris"] as? [String] == ["cloudreve://my/F/b.txt"], "case 13 body")
            precondition(!hits("GET", "/file/info").isEmpty, "case 13: preflight GET /file/info expected (plan 021)")
            let intentLeft = try FileProviderDeleteIntentStore.contains(driveID: drive.id, identifier: idA.rawValue)
            precondition(!intentLeft, "case 13: delete intent must be finished")
        }

        // 14. deleteItem of an already-gone item is acknowledged.
        do {
            let g = seed("cloudreve://my/g.txt", type: 0, id: "G", size: 1, entity: "eg")
            ServerProtocol.failNext["DELETE /file"] = 40016
            let error = await delete(ext, NSFileProviderItemIdentifier("cloudreve-item:/G"), base: g.itemVersion)
            precondition(error == nil, "case 14: \(String(describing: error))")
        }

        // 15. deleteItem blocked by a lock.
        do {
            let h = seed("cloudreve://my/h.txt", type: 0, id: "H", size: 1, entity: "eh")
            ServerProtocol.failNext["DELETE /file"] = 40073
            let error = await delete(ext, NSFileProviderItemIdentifier("cloudreve-item:/H"), base: h.itemVersion)
            precondition(fpCode(error) == NSFileProviderError.Code.cannotSynchronize.rawValue, "case 15: \(String(describing: error))")
        }

        print("ExtensionCallbackTests: all tests passed")
    }
}
