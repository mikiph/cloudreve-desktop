import Foundation

private final class ResumeDownloadMock: URLProtocol {
    static var payload = Data()
    static var requests: [[String: String]] = []
    /// How the next requests behave; consumed per request via `mode`.
    enum Mode { case full, dropAfter(Int), ignoreRange, status(Int) }
    static var mode: Mode = .full

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let headers = request.allHTTPHeaderFields ?? [:]
        Self.requests.append(headers)
        let total = Self.payload.count

        var start = 0
        if let range = headers["Range"], range.hasPrefix("bytes="),
            let value = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            start = value
        }
        func respond(_ status: Int, _ fields: [String: String]) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: fields)!, cacheStoragePolicy: .notAllowed)
        }
        func send(_ data: Data) {
            let step = 256 * 1024
            var offset = 0
            while offset < data.count {
                client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + step, data.count)))
                offset += step
            }
        }
        switch Self.mode {
        case .status(let code):
            respond(code, [:])
            client?.urlProtocol(self, didLoad: Data("error".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .ignoreRange:
            respond(200, ["Content-Length": String(total)])
            send(Self.payload)
            client?.urlProtocolDidFinishLoading(self)
        case .dropAfter(let limit):
            let tail = Self.payload.subdata(in: start..<total)
            respond(start > 0 ? 206 : 200, start > 0
                ? ["Content-Range": "bytes \(start)-\(total - 1)/\(total)", "Content-Length": String(tail.count)]
                : ["Content-Length": String(total)])
            send(tail.prefix(limit))
            // Let the loader deliver the bytes before the connection drops.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        case .full:
            if start > 0 {
                let tail = Self.payload.subdata(in: start..<total)
                respond(206, ["Content-Range": "bytes \(start)-\(total - 1)/\(total)",
                    "Content-Length": String(tail.count)])
                send(tail)
            } else {
                respond(200, ["Content-Length": String(total)])
                send(Self.payload)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

func expect(_ ok: Bool, _ message: String = "") { precondition(ok, message) }

@main enum DownloadResumeTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        let mib = 1 << 20
        let drive = DriveConfig(id: "dl-resume", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResumeDownloadMock.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))

        let big = Data((0..<(9 * mib)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        let item = "item-1"
        let version = Data("v1".utf8)
        let source = URL(string: "https://storage.invalid/file")!

        func fetch(_ data: Data = big, version: Data = version, item: String = item,
            mode: ResumeDownloadMock.Mode) async -> (Error?, URL) {
            ResumeDownloadMock.payload = data
            ResumeDownloadMock.mode = mode
            ResumeDownloadMock.requests = []
            let dest = root.appendingPathComponent("dest-" + UUID().uuidString)
            do {
                try await client.download(source, to: dest, itemSize: Int64(data.count),
                    progress: Progress(), resume: (driveID: "dl-resume", itemIdentifier: item, contentVersion: version))
                return (nil, dest)
            } catch { return (error, dest) }
        }
        func partialFiles() -> [URL] {
            let enumerator = FileManager.default.enumerator(at: PartialDownloadStore.partialRoot,
                includingPropertiesForKeys: nil)
            return (enumerator?.allObjects as? [URL] ?? []).filter { ["part", "json"].contains($0.pathExtension) }
        }
        func state(_ item: String = item) -> PartialDownloadStore.State? {
            PartialDownloadStore.load(driveID: "dl-resume", itemIdentifier: item)
        }
        func reset() { try? FileManager.default.removeItem(at: PartialDownloadStore.partialRoot) }

        // 1. A dropped connection after 5 MiB keeps the partial.
        reset()
        var result = await fetch(mode: .dropAfter(5 * mib))
        precondition(result.0 != nil, "1: expected failure")
        precondition(ReplayFailure.classify(result.0!) == .transient)
        let partial = state()
        precondition((partial?.written ?? 0) >= Int64(4 * mib) && partial?.written == Int64(5 * mib),
            "1: written \(String(describing: partial?.written))")
        precondition(!FileManager.default.fileExists(atPath: result.1.path))

        // 2. Same content version: Range resumes; the result matches byte for byte.
        result = await fetch(mode: .full)
        precondition(result.0 == nil, "2: \(String(describing: result.0))")
        precondition(ResumeDownloadMock.requests.first?["Range"] == "bytes=\(5 * mib)-",
            "2: range \(String(describing: ResumeDownloadMock.requests.first?["Range"]))")
        expect(try Data(contentsOf: result.1) == big, "2: content differs")
        precondition(partialFiles().isEmpty, "2: partial not removed")

        // 3. A server that ignores Range answers 200 with the full body.
        reset()
        result = await fetch(mode: .dropAfter(5 * mib))
        precondition(result.0 != nil)
        result = await fetch(mode: .ignoreRange)
        precondition(result.0 == nil, "3: \(String(describing: result.0))")
        precondition(ResumeDownloadMock.requests.first?["Range"] != nil)
        expect(try Data(contentsOf: result.1) == big, "3: content differs")
        precondition(partialFiles().isEmpty)

        // 4. A different content version never sends Range.
        reset()
        result = await fetch(mode: .dropAfter(5 * mib))
        precondition(result.0 != nil)
        result = await fetch(version: Data("v2".utf8), mode: .full)
        precondition(result.0 == nil, "4: \(String(describing: result.0))")
        precondition(ResumeDownloadMock.requests.first?["Range"] == nil, "4: Range sent for new version")
        expect(try Data(contentsOf: result.1) == big)

        // 5. 416 / 500 on the resumed request: http error; the partial survives only the 500.
        reset()
        result = await fetch(mode: .dropAfter(5 * mib))
        precondition(result.0 != nil)
        result = await fetch(mode: .status(500))
        guard case CloudreveError.http(status: 500)? = result.0 else {
            preconditionFailure("5: expected 500, got \(String(describing: result.0))")
        }
        precondition(state()?.written == Int64(5 * mib), "5: partial kept for 500")
        result = await fetch(mode: .status(416))
        guard case CloudreveError.http(status: 416)? = result.0 else {
            preconditionFailure("5: expected 416, got \(String(describing: result.0))")
        }
        precondition(partialFiles().isEmpty, "5: partial removed for 416")

        // 6. A small file never creates partial files.
        reset()
        let small = Data(repeating: 0x42, count: mib)
        result = await fetch(small, mode: .dropAfter(mib / 2))
        precondition(result.0 != nil)
        precondition(partialFiles().isEmpty, "6: partial created for a small file")
        result = await fetch(small, mode: .full)
        precondition(result.0 == nil && partialFiles().isEmpty)
        expect(try Data(contentsOf: result.1) == small)

        // 7. Eviction: stale (> 7 days) partials go first, then the oldest over the size cap.
        reset()
        let now = Date()
        func fake(_ name: String, bytes: Int, age: TimeInterval) throws {
            let directory = PartialDownloadStore.partialRoot.appendingPathComponent("dl-resume")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let part = directory.appendingPathComponent(name + ".part")
            try Data(count: bytes).write(to: part)
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name + ".json"))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)],
                ofItemAtPath: part.path)
        }
        try fake("old", bytes: 100, age: 8 * 86400)
        try fake("mid", bytes: 100, age: 2 * 86400)
        try fake("new", bytes: 100, age: 3600)
        PartialDownloadStore.evict(now: now, maxAge: 7 * 86400, maxTotalBytes: 1000)
        let names = Set(partialFiles().map(\.lastPathComponent))
        precondition(names == ["mid.part", "mid.json", "new.part", "new.json"], "7a: \(names)")
        PartialDownloadStore.evict(now: now, maxAge: 7 * 86400, maxTotalBytes: 150)
        let remaining = Set(partialFiles().map(\.lastPathComponent))
        precondition(remaining == ["new.part", "new.json"], "7b: \(remaining)")

        // Paths never contain the item identifier.
        let paths = PartialDownloadStore.paths(driveID: "dl-resume", itemIdentifier: "secret-name.txt")
        precondition(!paths.part.path.contains("secret-name") && paths.part.pathExtension == "part")

        print("DownloadResumeTests: all tests passed")
    }
}
