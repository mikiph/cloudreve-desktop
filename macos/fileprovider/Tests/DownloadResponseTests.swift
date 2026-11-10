import Foundation

private final class DownloadMock: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let name = request.url!.lastPathComponent
        let (status, body): (Int, String)
        switch name {
        case "ok": (status, body) = (200, "hello")
        case "forbidden": (status, body) = (403, "<Error>AccessDenied</Error>")
        case "missing": (status, body) = (404, "not found")
        case "short": (status, body) = (200, "hel")
        case "encoded": (status, body) = (200, "hello")
        default: (status, body) = (500, "unexpected")
        }
        let data = Data(body.utf8)
        // "short" omits Content-Length so only the caller-supplied item size can catch it.
        var headers = name == "short" ? [:] : ["Content-Length": String(data.count)]
        if name == "encoded" {
            // Simulates decoded output with a compressed-length header.
            headers = ["Content-Encoding": "gzip", "Content-Length": "99"]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum DownloadResponseTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        let drive = DriveConfig(id: "download-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadMock.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))

        func fetch(_ name: String, size: Int64) async -> (Error?, URL) {
            let dest = root.appendingPathComponent(UUID().uuidString)
            do {
                try await client.download(URL(string: "https://storage.invalid/\(name)")!, to: dest,
                    itemSize: size, progress: Progress())
                return (nil, dest)
            } catch { return (error, dest) }
        }

        let ok = await fetch("ok", size: 5)
        precondition(ok.0 == nil)
        let content = try String(contentsOf: ok.1, encoding: .utf8)
        precondition(content == "hello")

        let forbidden = await fetch("forbidden", size: 5)
        guard case CloudreveError.http(status: 403)? = forbidden.0 else {
            preconditionFailure("403 not rejected: \(String(describing: forbidden.0))")
        }
        precondition(!FileManager.default.fileExists(atPath: forbidden.1.path))

        let missing = await fetch("missing", size: 5)
        guard case CloudreveError.http(status: 404)? = missing.0 else {
            preconditionFailure("404 not rejected: \(String(describing: missing.0))")
        }
        precondition(!FileManager.default.fileExists(atPath: missing.1.path))

        let short = await fetch("short", size: 5)
        guard case CloudreveError.badResponse? = short.0 else {
            preconditionFailure("short not rejected: \(String(describing: short.0))")
        }
        precondition(!FileManager.default.fileExists(atPath: short.1.path))

        let unknown = await fetch("ok", size: 0)
        precondition(unknown.0 == nil)

        let encodedOK = await fetch("encoded", size: 5)
        precondition(encodedOK.0 == nil, "encoded failed: \(String(describing: encodedOK.0))")
        let encodedContent = try String(contentsOf: encodedOK.1, encoding: .utf8)
        precondition(encodedContent == "hello")

        let encodedBad = await fetch("encoded", size: 7)
        guard case CloudreveError.badResponse? = encodedBad.0 else {
            preconditionFailure("encoded mismatch not rejected: \(String(describing: encodedBad.0))")
        }
        precondition(!FileManager.default.fileExists(atPath: encodedBad.1.path))

        print("DownloadResponseTests: all tests passed")
    }
}
