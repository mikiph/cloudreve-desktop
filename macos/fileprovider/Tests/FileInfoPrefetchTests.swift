import Foundation

private final class InfoProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let uri = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            .first(where: { $0.name == "uri" })!.value!
        var payload: [String: Any] = ["code": 0]
        if uri.hasSuffix("missing.txt") {
            payload = ["code": 40016, "msg": "Path not exist"]
        } else {
            payload["data"] = ["type": 0, "id": "id-\(uri)", "name": "f", "path": uri, "size": 1]
        }
        // Answer on another queue so requests genuinely overlap.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int.random(in: 0...5))) {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main enum FileInfoPrefetchTests {
    static func main() async throws {
        let drive = DriveConfig(id: "prefetch-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InfoProtocol.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))

        for round in 0..<60 {
            let uris = (0..<100).map { "cloudreve://my/r\(round)/f\($0).txt" } + ["cloudreve://my/r\(round)/missing.txt"]
            let results = await FileInfoPrefetch.fetch(uris, using: client)
            precondition(results.count == uris.count, "round \(round): \(results.count) results")
            for uri in uris where !uri.hasSuffix("missing.txt") {
                guard case .success(let file) = results[uri] else { preconditionFailure("\(uri) failed") }
                precondition(file.path == uri)
            }
            guard case .failure(let error) = results["cloudreve://my/r\(round)/missing.txt"],
                case CloudreveError.noSuchItem = error else { preconditionFailure("missing path must fail as noSuchItem") }
        }
        print("FileInfoPrefetchTests: 6,060 concurrent lookups passed")
    }
}
