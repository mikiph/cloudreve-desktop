import Foundation
import FileProvider

private final class NotFoundProtocol: URLProtocol {
    enum Mode { case httpNotFound, envelopeMissing }
    static var mode: Mode = .httpNotFound
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status: Int
        let body: String
        switch Self.mode {
        case .httpNotFound: status = 404; body = "404 page not found"
        case .envelopeMissing: status = 200; body = #"{"code":40016,"msg":"Object not exist"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum HttpNotFoundTests {
    static func file() -> RemoteFile {
        RemoteFile(type: 0, id: "A", name: "a.txt", path: "cloudreve://my/a.txt",
            size: 1, created_at: "2026-10-19T12:00:00Z", updated_at: "2026-10-19T12:00:00Z",
            metadata: nil, shared: false, owned: true, primary_entity: "e")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CLOUDREVE_FP_STATE_ROOT", root.path, 1)
        let drive = DriveConfig(id: "http-404-test", name: "Test", instance_url: "https://test.invalid",
            remote_path: "cloudreve://my", enabled: true,
            credentials: Credentials(access_token: "test", refresh_token: "test", access_expires: "2099-01-01T00:00:00Z"))
        let domain = NSFileProviderDomain(identifier: .init("http-404-test"), displayName: "Test")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NotFoundProtocol.self]
        let client = CloudreveClient(drive: drive, session: URLSession(configuration: config))
        let store = RemoteStore(drive: drive, domain: domain, stateDirectory: root, client: client)
        let id = NSFileProviderItemIdentifier("cloudreve-item:/A")

        // 1. HTTP 404 is a transport error.
        NotFoundProtocol.mode = .httpNotFound
        do {
            _ = try await client.fileInfo(uri: "cloudreve://my/a.txt")
            preconditionFailure("expected a throw")
        } catch {
            if case CloudreveError.http(let s) = error { precondition(s == 404) } else { preconditionFailure("got \(error)") }
        }

        // 2. The envelope code still means noSuchItem.
        NotFoundProtocol.mode = .envelopeMissing
        do {
            _ = try await client.fileInfo(uri: "cloudreve://my/a.txt")
            preconditionFailure("expected a throw")
        } catch CloudreveError.noSuchItem {
        } catch { preconditionFailure("got \(error)") }

        // 3. Identity survives an HTTP 404.
        _ = store.makeItem(file())
        precondition(store.uri(for: id) == "cloudreve://my/a.txt")
        NotFoundProtocol.mode = .httpNotFound
        do {
            _ = try await store.refreshItem(for: id, displayName: "Test")
            preconditionFailure("expected a throw")
        } catch CloudreveError.noSuchItem {
            preconditionFailure("HTTP 404 must not be reported as noSuchItem")
        } catch {}
        precondition(store.uri(for: id) == "cloudreve://my/a.txt", "identity must not be evicted by HTTP 404")

        // 4. The envelope code still evicts.
        NotFoundProtocol.mode = .envelopeMissing
        do {
            _ = try await store.refreshItem(for: id, displayName: "Test")
            preconditionFailure("expected a throw")
        } catch CloudreveError.noSuchItem {
        } catch { preconditionFailure("got \(error)") }
        precondition(store.identifier(forURI: "cloudreve://my/a.txt").rawValue != id.rawValue,
            "envelope noSuchItem must still evict")
        print("HttpNotFoundTests: all tests passed")
    }
}
