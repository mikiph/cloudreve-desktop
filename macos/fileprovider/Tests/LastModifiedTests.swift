import Foundation

private final class BodyProtocol: URLProtocol {
    static var putBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var payload: [String: Any] = ["code": 0]
        if request.httpMethod == "PUT", url.path == "/api/v4/file/upload" {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                stream.close()
                body = data
            }
            Self.putBody = body
            payload["data"] = ["session_id": "s", "chunk_size": 3]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum LastModifiedTests {
    static func main() async throws {
        precondition(CloudreveClient.lastModifiedMillis(Date(timeIntervalSince1970: 1_795_525_664.5)) == 1_795_525_664_500)
        precondition(CloudreveClient.lastModifiedMillis(nil) == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        let drive = DriveConfig(id: "lm-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyProtocol.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))
        let file = root.appendingPathComponent("source")
        try Data("abc".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_795_525_664)], ofItemAtPath: file.path)

        try await client.uploadFile(at: "cloudreve://my/f.txt", from: file, overwrite: false, progress: Progress())
        guard let body = BodyProtocol.putBody else { preconditionFailure("no PUT body recorded") }
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let value = (json["last_modified"] as? NSNumber)?.int64Value
        precondition(value == 1_795_525_664_000, "last_modified was \(String(describing: value))")
        precondition(value! > 1_000_000_000_000)
        print("LastModifiedTests: all tests passed")
    }
}
