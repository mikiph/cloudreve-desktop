import Foundation
import FileProvider

private final class QueryProtocol: URLProtocol {
    static var rawQueries: [String] = []
    static var decodedURIs: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        Self.rawQueries.append(components.percentEncodedQuery ?? "")
        let uri = components.queryItems!.first(where: { $0.name == "uri" })!.value!
        Self.decodedURIs.append(uri)
        let payload: [String: Any] = [
            "code": 0,
            "data": ["type": 0, "id": "file", "name": "x", "path": uri, "size": 1],
        ]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum QueryEncodingTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)

        // 1. Helper unit test.
        let original = "cloudreve://my/C++ notes & a=b?.txt"
        let encoded = strictlyEncodedQueryItems([URLQueryItem(name: "uri", value: original)])
        precondition(encoded[0].value == "cloudreve%3A%2F%2Fmy%2FC%2B%2B%20notes%20%26%20a%3Db%3F.txt",
            "got \(encoded[0].value ?? "nil")")

        // 2. Round trip.
        var components = URLComponents()
        components.percentEncodedQueryItems = encoded
        precondition(components.queryItems?.first?.value == original)

        // 3. Request level.
        let drive = DriveConfig(id: "query-encoding-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QueryProtocol.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))
        _ = try await client.fileInfo(uri: "cloudreve://my/C++ notes.txt")
        let raw = QueryProtocol.rawQueries.last!
        precondition(QueryProtocol.decodedURIs.last == "cloudreve://my/C%2B%2B%20notes.txt",
            "uri: \(QueryProtocol.decodedURIs.last ?? "nil")")
        precondition(raw.contains("C%252B%252B%2520notes.txt"), "raw query: \(raw)")
        precondition(!raw.contains("+"), "raw query: \(raw)")

        // 4. Non-ASCII.
        let unicode = "cloudreve://my/Grüße.txt"
        _ = try await client.fileInfo(uri: unicode)
        precondition(QueryProtocol.decodedURIs.last == "cloudreve://my/Gr%C3%BC%C3%9Fe.txt")

        print("QueryEncodingTests: all tests passed")
    }
}
