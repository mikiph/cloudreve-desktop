import Foundation
import FileProvider

/// Records the `uri` query value and JSON body of each request.
final class WireProtocol: URLProtocol {
    static var decodedURIs: [String] = []
    static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
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
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        Self.bodies.append(body)
        let queryURI = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems?.first { $0.name == "uri" }?.value
        if let queryURI { Self.decodedURIs.append(queryURI) }
        let uri = queryURI ?? body["uri"] as? String ?? "cloudreve://my/x"
        let json: String
        if url.path.hasSuffix("/file/url") {
            json = #"{"code":0,"data":{"urls":[{"url":"https://test.invalid/dl"}]}}"#
        } else {
            let escaped = uri.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            json = #"{"code":0,"data":{"type":0,"id":"id1","name":"x","path":""# + escaped
                + #"","size":0,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z"}}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
enum UriWireEncodingTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uri-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)

        // Shared with crates/cloudreve-api/src/models/uri.rs.
        let fixtures: [([String], String)] = [
            (["a b.txt"], "cloudreve://my/a%20b.txt"),
            (["what?.txt"], "cloudreve://my/what%3F.txt"),
            (["#1 notes.md"], "cloudreve://my/%231%20notes.md"),
            (["100%.txt"], "cloudreve://my/100%25.txt"),
            (["C++ & co", "x=y.txt"], "cloudreve://my/C%2B%2B%20%26%20co/x%3Dy.txt"),
            (["Grüße.txt"], "cloudreve://my/Gr%C3%BC%C3%9Fe.txt"),
            (["(draft) it's!~*.txt"], "cloudreve://my/(draft)%20it's!~*.txt"),
            (["a:b;c,d@e$f.txt"], "cloudreve://my/a%3Ab%3Bc%2Cd%40e%24f.txt"),
        ]

        // 1. Fixture table.
        for (segments, expected) in fixtures {
            let got = wireCloudreveURI("cloudreve://my/" + segments.joined(separator: "/"))
            precondition(got == expected, "segments \(segments): got \(got), expected \(expected)")
        }

        // 2. Idempotence.
        for (_, expected) in fixtures {
            let got = wireCloudreveURI(expected)
            precondition(got == expected, "not idempotent: \(got) != \(expected)")
        }

        // 3. Pass-through.
        precondition(wireCloudreveURI("cloudreve://my") == "cloudreve://my")
        precondition(wireCloudreveURI("cloudreve://abc@share/x y") == "cloudreve://abc@share/x%20y")
        precondition(wireCloudreveURI("https://x/y z") == "https://x/y z")

        // 4. Query send site.
        let drive = DriveConfig(id: "uri-wire-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WireProtocol.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))
        _ = try await client.fileInfo(uri: "cloudreve://my/#1 notes.md")
        precondition(WireProtocol.decodedURIs.last == "cloudreve://my/%231%20notes.md",
            "query uri: \(WireProtocol.decodedURIs.last ?? "nil")")

        // 5. Body send sites.
        _ = try await client.createFileOrFolder(uri: "cloudreve://my/what?.txt", isFolder: false)
        precondition(WireProtocol.bodies.last?["uri"] as? String == "cloudreve://my/what%3F.txt",
            "create body: \(String(describing: WireProtocol.bodies.last))")

        try await client.deleteFile(uri: "cloudreve://my/100%.txt")
        precondition(WireProtocol.bodies.last?["uris"] as? [String] == ["cloudreve://my/100%25.txt"],
            "delete body: \(String(describing: WireProtocol.bodies.last))")

        try await client.moveFile(uri: "cloudreve://my/a b", toDirectory: "cloudreve://my/C++")
        precondition(WireProtocol.bodies.last?["uris"] as? [String] == ["cloudreve://my/a%20b"],
            "move body: \(String(describing: WireProtocol.bodies.last))")
        precondition(WireProtocol.bodies.last?["dst"] as? String == "cloudreve://my/C%2B%2B",
            "move dst: \(String(describing: WireProtocol.bodies.last))")

        _ = try await client.downloadURL(for: "cloudreve://my/#x")
        precondition(WireProtocol.bodies.last?["uris"] as? [String] == ["cloudreve://my/%23x"],
            "download body: \(String(describing: WireProtocol.bodies.last))")

        print("UriWireEncodingTests: all tests passed")
    }
}
