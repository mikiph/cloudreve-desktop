import Foundation
import OSLog

// MARK: - drives.json decoding

/// Mirrors the Rust `Credentials` in cloudreve-sync (unknown keys ignored).
struct Credentials: Codable {
    var access_token: String?
    var refresh_token: String
    var access_expires: String?
    var refresh_expires: String?
}

/// Mirrors the Rust `DriveConfig` (only the fields the extension needs).
struct DriveConfig: Codable {
    var id: String
    var name: String
    var instance_url: String
    /// Drive root URI, e.g. "cloudreve://my/h"
    var remote_path: String
    var user_id: String?
    var enabled: Bool
    var credentials: Credentials
}

struct DrivesFile: Codable {
    var drives: [DriveConfig]
}

/// Reads `~/.cloudreve/drives.json` written by the main app.
enum DriveStore {
    static var drivesURL: URL {
        // In a sandboxed process, NSHomeDirectory() points at the container.
        // Resolve the real home directory via the user database instead.
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
                .appendingPathComponent(".cloudreve/drives.json")
        }
        return URL(fileURLWithPath: "/Users/\(NSUserName())/.cloudreve/drives.json")
    }

    static func loadDrive(driveID: String) -> DriveConfig? {
        let logger = Logger(subsystem: "cloudreve.desktop.fileprovider", category: "config")
        do {
            let data = try Data(contentsOf: drivesURL)
            let file = try JSONDecoder().decode(DrivesFile.self, from: data)
            let drive = file.drives.first { $0.id == driveID && $0.enabled }
            if drive == nil {
                logger.error("drive \(driveID, privacy: .public) not found in drives.json")
            }
            return drive
        } catch {
            logger.error(
                "failed to read \(drivesURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

// MARK: - API DTOs

struct RemoteFile: Codable {
    /// 0 = file, 1 = folder
    let type: Int
    let id: String
    let name: String
    let path: String
    let size: Int64
    let created_at: String?
    let updated_at: String?
    let metadata: [String: String]?
    let shared: Bool?
    let owned: Bool?
    let primary_entity: String?

    struct ShareDetails: Codable {
        struct Link: Codable {
            struct Owner: Codable { let id: String }
            let id: String
            let owner: Owner
        }
        let shares: [Link]?
    }
    var extended_info: ShareDetails? = nil
    var sharingContextURI: String? = nil

    func hasOwnShare(currentUserID: String?) -> Bool {
        guard let currentUserID, !currentUserID.isEmpty else { return false }
        let incoming = URLComponents(string: metadata?["sys:shared_redirect"] ?? sharingContextURI ?? path)?.user
        return extended_info?.shares?.contains {
            $0.owner.id == currentUserID && $0.id != incoming
        } ?? (shared == true && owned == true)
    }

    var presentationIdentity: String?

    func isSharedWithMe(currentUserID: String?) -> Bool {
        // Use the target owner because the shortcut belongs to this drive.
        if let owner = metadata?["sys:shared_owner"], !owner.isEmpty,
            let currentUserID, !currentUserID.isEmpty {
            return owner != currentUserID
        }
        return owned == false && (
            metadata?["sys:shared_redirect"] != nil || presentationIdentity != nil
                || path.contains("@shared_with_me"))
    }

    func presented(at uri: String, name: String? = nil) -> RemoteFile {
        guard path != uri else { return self }
        var file = RemoteFile(
            type: type, id: id, name: name ?? self.name, path: uri, size: size,
            created_at: created_at, updated_at: updated_at, metadata: metadata,
            shared: shared, owned: owned, primary_entity: primary_entity)
        // Keep each shortcut as a separate Finder item.
        file.presentationIdentity = uri
        file.extended_info = extended_info
        file.sharingContextURI = sharingContextURI ?? path
        return file
    }

    var isFolder: Bool { type == 1 }

    /// Combine the shortcut identity with the target's content metadata.
    func withContent(of target: RemoteFile) -> RemoteFile {
        var file = RemoteFile(
            type: type, id: id, name: name, path: path, size: target.size,
            created_at: created_at, updated_at: target.updated_at,
            metadata: (target.metadata ?? [:]).merging(metadata ?? [:]) { content, _ in content },
            shared: shared, owned: owned, primary_entity: target.primary_entity)
        file.presentationIdentity = presentationIdentity
        file.extended_info = extended_info
        file.sharingContextURI = sharingContextURI
        return file
    }
}

struct ListPayload: Decodable {
    let files: [RemoteFile]
    let pagination: Pagination

    struct Pagination: Decodable {
        let page: Int?
        let page_size: Int?
        let total_items: Int64?
        let next_token: String?
    }
}

struct TokenPayload: Decodable {
    let access_token: String
    let refresh_token: String
    let access_expires: String?
    let refresh_expires: String?
}

struct FileURLPayload: Decodable {
    let urls: [EntityURL]
    struct EntityURL: Decodable {
        let url: String
    }
}

struct FileThumbPayload: Decodable {
    let url: String
    let expires: String?
    let obfuscated: Bool
}

struct ApiEnvelope<T: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let data: T?
}

/// Placeholder for endpoints whose `data` we don't care about.
struct EmptyPayload: Decodable {}

/// Envelope without the payload, for error inspection.
private struct BaseEnvelope: Decodable {
    let code: Int
    let msg: String?
}

private struct LockConflictEnvelope: Decodable {
    let data: [LockConflictEntry]?
}

private struct LockConflictEntry: Decodable {
    let path: String?
    let owner: LockOwner?
}

private struct LockOwner: Decodable {
    let owner: String?
    let application: LockApplication?
}

private struct LockApplication: Decodable {
    let type: String?
}

/// Serializes concurrent refresh attempts so only one network call is made.
private actor RefreshCoordinator {
    private var inFlight: Task<String, Error>?

    func coordinate(_ work: @escaping @Sendable () async throws -> String) async throws -> String {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await work() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

enum CloudreveError: Error, LocalizedError {
    case api(code: Int, message: String)
    case http(status: Int)
    case notAuthenticated
    case noSuchItem
    case nameCollision
    case staleVersion
    case unsupportedPackage
    case lockConflict(path: String?, application: String?, ownerID: String?)
    case badResponse(String)
    case unsupportedStoragePolicy(String)
    /// The body was not a Cloudreve envelope (proxy error page, captive portal, empty body).
    case invalidEnvelope(status: Int)

    var errorDescription: String? {
        switch self {
        case .api(let code, let message): return "Cloudreve API error \(code): \(message)"
        case .http(let status): return "HTTP \(status)"
        case .notAuthenticated: return "Not authenticated"
        case .noSuchItem: return "No such item"
        case .nameCollision: return "An item with the same name already exists"
        case .unsupportedPackage: return "This macOS package cannot be uploaded directly. Compress it into a ZIP file and upload the ZIP instead."
        case .staleVersion: return "The item changed on the server before this update was saved"
        case .lockConflict(_, let application, _):
            return application == "upload"
                ? "An unfinished upload is holding this item"
                : "Someone has this file open online"
        case .badResponse(let detail): return "Bad response: \(detail)"
        case .invalidEnvelope(let status): return "The server returned an unexpected response (HTTP \(status))"
        case .unsupportedStoragePolicy(let type):
            return "This storage policy (\(type)) is not supported by the macOS Finder integration. Upload the file from the Cloudreve website instead."
        }
    }
}

/// Thread-safe holder for the in-memory credentials. The lock is never held across an await.
private final class CredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials
    private var rejected: String?
    init(_ value: Credentials) { self.value = value }
    func get() -> Credentials { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Credentials) { lock.lock(); value = new; lock.unlock() }
    /// Clears the access token only if it is still `token` (compare-and-invalidate),
    /// so a request that failed with an old token cannot wipe a newer one.
    func invalidate(ifAccessToken token: String) {
        lock.lock(); defer { lock.unlock() }
        if value.access_token == token {
            value.access_token = nil
            rejected = token
        }
    }
    /// The most recently rejected access token; it must never be re-adopted.
    func rejectedToken() -> String? { lock.lock(); defer { lock.unlock() }; return rejected }
}

/// Characters left unescaped in query names/values: RFC 3986 unreserved only,
/// matching the Rust client's `urlencoding::encode`. `URLComponents.queryItems`
/// leaves `+`, `&`-adjacent and other sub-delims alone; servers that use
/// form decoding (Go, JS URLSearchParams, Rust query_pairs) read `+` as space.
private let strictQueryAllowed: CharacterSet = {
    var set = CharacterSet()
    set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return set
}()

func strictlyEncodedQueryItems(_ items: [URLQueryItem]) -> [URLQueryItem] {
    items.map { item in
        URLQueryItem(
            name: item.name.addingPercentEncoding(withAllowedCharacters: strictQueryAllowed) ?? item.name,
            value: item.value?.addingPercentEncoding(withAllowedCharacters: strictQueryAllowed))
    }
}

/// Maps Cloudreve API error codes to typed errors.
func mapApiError(code: Int, message: String?, responseData: Data? = nil) -> CloudreveError {
    switch code {
    case 40004: return .nameCollision  // ObjectExisted
    case 40016, 40077, 40081: return .noSuchItem  // Entity/parent/target does not exist
    case 401, 40020, 40089: return .notAuthenticated  // CredentialInvalid / SessionExpired
    case 40073:
        let detail = responseData.flatMap {
            try? JSONDecoder().decode(LockConflictEnvelope.self, from: $0)
        }?.data?.first
        return .lockConflict(
            path: detail?.path,
            application: detail?.owner?.application?.type,
            ownerID: detail?.owner?.owner)
    case 40076: return .staleVersion
    default: return .api(code: code, message: message ?? "unknown")
    }
}

// MARK: - API client

/// Minimal async Cloudreve V4 API client for the extension process.
/// Tokens are refreshed in memory only; the main app owns drives.json.
final class CloudreveClient {
    private let logger = Logger(
        subsystem: "cloudreve.desktop.fileprovider", category: "client")

    let baseURL: URL
    private let driveID: String
    private let credentials: CredentialBox
    /// Re-reads the host's persisted credentials (drives.json).
    private let reloadCredentials: @Sendable () -> Credentials?
    /// Deduplicates concurrent token refreshes.
    private let refreshCoordinator = RefreshCoordinator()

    /// Configuration for the per-download delegate session (the injected session's, in tests).
    private let downloadConfiguration: URLSessionConfiguration

    private let session: URLSession

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = rfc3339.date(from: s) { return d }
        // Some timestamps omit fractional seconds
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    init(
        drive: DriveConfig, session: URLSession? = nil,
        credentialReloader: (@Sendable () -> Credentials?)? = nil
    ) {
        self.driveID = drive.id
        self.baseURL = URL(string: drive.instance_url)!
        self.credentials = CredentialBox(drive.credentials)
        let id = drive.id
        self.reloadCredentials =
            credentialReloader ?? { DriveStore.loadDrive(driveID: id)?.credentials }
        self.downloadConfiguration = session?.configuration ?? .default
        self.session = session ?? Self.makeDefaultSession()
    }

    // MARK: Tokens

    private static func isValid(_ c: Credentials) -> Bool {
        guard let token = c.access_token, !token.isEmpty,
            let expires = parseDate(c.access_expires)
        else { return false }
        return expires.timeIntervalSinceNow > 30
    }

    /// Returns a usable access token, refreshing in memory if needed.
    func validAccessToken() async throws -> String {
        let snapshot = credentials.get()
        if Self.isValid(snapshot), let token = snapshot.access_token {
            return token
        }
        return try await refreshCoordinator.coordinate { [self] in
            // Re-check: another task may have refreshed while we waited.
            let current = credentials.get()
            if Self.isValid(current), let token = current.access_token {
                return token
            }
            // The host persists rotated tokens to drives.json (mounts.rs
            // RefreshCredentials -> PersistConfig). Prefer them so the two
            // processes don't fight over refresh-token rotation.
            if let reloaded = reloadCredentials() {
                if Self.isValid(reloaded), let token = reloaded.access_token,
                    token != current.access_token, token != credentials.rejectedToken()
                {
                    credentials.set(reloaded)
                    return token
                }
                if reloaded.refresh_token != current.refresh_token {
                    credentials.set(reloaded)
                }
            }
            try await performRefresh()
            guard let token = credentials.get().access_token else {
                throw CloudreveError.notAuthenticated
            }
            return token
        }
    }

    private func performRefresh() async throws {
        let url = baseURL.appendingPathComponent("/api/v4/session/token/refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ["refresh_token": credentials.get().refresh_token])

        logger.notice("refreshing access token")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudreveError.badResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else {
            logger.error("token refresh failed: HTTP \(http.statusCode)")
            throw CloudreveError.notAuthenticated
        }
        let envelope = try JSONDecoder().decode(ApiEnvelope<TokenPayload>.self, from: data)
        guard envelope.code == 0, let token = envelope.data else {
            logger.error("token refresh rejected: \(envelope.msg ?? "?", privacy: .public)")
            throw CloudreveError.notAuthenticated
        }
        credentials.set(
            Credentials(
                access_token: token.access_token,
                refresh_token: token.refresh_token,
                access_expires: token.access_expires,
                refresh_expires: token.refresh_expires))
        logger.notice("access token refreshed")
    }

    // MARK: Request plumbing

    private static let authCodes: Set<Int> = [401, 40020, 40089]

    private static func decodeBaseEnvelope(_ data: Data, status: Int) throws -> BaseEnvelope {
        do { return try JSONDecoder().decode(BaseEnvelope.self, from: data) }
        catch { throw CloudreveError.invalidEnvelope(status: status) }
    }

    /// Performs an authenticated API call and unwraps the envelope.
    /// Retries once after a forced token refresh on 401.
    private func call<Req: Encodable, Res: Decodable>(
        _ method: String, _ path: String, body: Req?, query: [URLQueryItem] = [],
        retryOnAuthError: Bool = true
    ) async throws -> Res {
        let (data, status, usedToken) = try await rawRequest(
            method, path, body: body, query: query)
        let base: BaseEnvelope? =
            status == 401 ? nil : try Self.decodeBaseEnvelope(data, status: status)
        if status == 401 || Self.authCodes.contains(base?.code ?? 0) {
            guard retryOnAuthError else { throw CloudreveError.notAuthenticated }
            credentials.invalidate(ifAccessToken: usedToken)
            return try await self.call(
                method, path, body: body, query: query,
                retryOnAuthError: false)
        }
        guard let base else { throw CloudreveError.badResponse("missing envelope") }
        guard base.code == 0 else {
            throw mapApiError(code: base.code, message: base.msg, responseData: data)
        }
        let envelope = try JSONDecoder().decode(ApiEnvelope<Res>.self, from: data)
        guard let payload = envelope.data else {
            throw CloudreveError.badResponse("missing data for \(path)")
        }
        return payload
    }

    /// Shared HTTP plumbing: request, returns raw response body and status.
    private func rawRequest<Req: Encodable>(
        _ method: String, _ path: String, body: Req?, query: [URLQueryItem] = []
    ) async throws -> (Data, Int, String) {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v4\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.percentEncodedQueryItems = strictlyEncodedQueryItems(query) }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        let token = try await validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudreveError.badResponse("not an HTTP response")
        }
        // Cloudreve reports missing objects as envelope codes (HTTP 200).
        // An HTTP 404 is a routing/proxy problem and must not be treated
        // as a deletion: callers evict identities and pins on noSuchItem.
        if http.statusCode == 404 {
            logger.error("HTTP 404 for \(path, privacy: .public)")
            throw CloudreveError.http(status: 404)
        }
        return (data, http.statusCode, token)
    }

    /// Like `call`, for endpoints that return no meaningful payload.
    private func callVoid<Req: Encodable>(
        _ method: String, _ path: String, body: Req?,
        retryOnAuthError: Bool = true
    ) async throws {
        let (data, status, usedToken) = try await rawRequest(
            method, path, body: body, query: [])
        let base: BaseEnvelope? =
            status == 401 ? nil : try Self.decodeBaseEnvelope(data, status: status)
        if status == 401 || Self.authCodes.contains(base?.code ?? 0) {
            guard retryOnAuthError else { throw CloudreveError.notAuthenticated }
            credentials.invalidate(ifAccessToken: usedToken)
            return try await self.callVoid(
                method, path, body: body, retryOnAuthError: false)
        }
        guard let base else { throw CloudreveError.badResponse("missing envelope") }
        guard base.code == 0 else {
            throw mapApiError(code: base.code, message: base.msg, responseData: data)
        }
    }

    // MARK: Endpoints

    struct ListResult {
        let files: [RemoteFile]
        /// Opaque continuation: "t:<next_token>" or "p:<next page>"; nil when done.
        let nextPage: String?
    }

    private func resolvedURI(_ uri: String, followLeaf: Bool) async throws -> String {
        try await ShortcutResolver.resolve(uri, followLeaf: followLeaf) { candidate in
            let file: RemoteFile = try await self.call(
                "GET", "/file/info", body: nil as String?,
                query: [URLQueryItem(name: "uri", value: candidate)])
            return file.metadata?["sys:shared_redirect"]
        }
    }

    func listDirectory(uri: String, page: String?) async throws -> ListResult {
        let target = try await resolvedURI(uri, followLeaf: true)
        var query = [
            URLQueryItem(name: "uri", value: target),
            URLQueryItem(name: "page_size", value: "200"),
        ]
        if let page {
            if page.hasPrefix("t:") {
                query.append(URLQueryItem(name: "next_page_token", value: String(page.dropFirst(2))))
            } else if page.hasPrefix("p:") {
                query.append(URLQueryItem(name: "page", value: String(page.dropFirst(2))))
            }
        }
        let payload: ListPayload = try await call("GET", "/file", body: nil as String?, query: query)

        let next: String?
        if let token = payload.pagination.next_token, !token.isEmpty {
            next = "t:\(token)"
        } else if let total = payload.pagination.total_items,
            let currentPage = payload.pagination.page,
            let pageSize = payload.pagination.page_size, pageSize > 0
        {
            let totalPages = Int((Double(total) / Double(pageSize)).rounded(.up))
            next = currentPage + 1 < totalPages ? "p:\(currentPage + 1)" : nil
        } else {
            next = nil
        }
        let files = target == uri ? payload.files : payload.files.map {
            $0.presented(at: ShortcutResolver.child($0.name, of: uri))
        }
        var hydrated = files
        for index in hydrated.indices {
            do {
                if hydrated[index].shared == true && hydrated[index].owned != true {
                    hydrated[index] = try await fileInfoWithShareState(uri: hydrated[index].path)
                } else {
                    hydrated[index] = try await fileShortcutContent(hydrated[index])
                }
            } catch {
                // A broken shortcut should not hide its siblings.
                logger.notice("file shortcut target is unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        return ListResult(files: hydrated, nextPage: next)
    }

    func fileInfo(uri: String) async throws -> RemoteFile {
        try await fileInfoWithShareState(uri: uri)
    }

    /// Keep the shortcut itself addressable for rename/delete; only ancestors
    /// redirect metadata requests for its descendants.
    func fileInfoWithShareState(uri: String) async throws -> RemoteFile {
        let target = try await resolvedURI(uri, followLeaf: false)
        let file: RemoteFile = try await call(
            "GET", "/file/info", body: nil as String?,
            query: [
                URLQueryItem(name: "uri", value: target),
                URLQueryItem(name: "extended", value: "true"),
            ])
        let presented = target == uri ? file : file.presented(at: uri)
        return try await fileShortcutContent(presented)
    }

    private func fileShortcutContent(_ file: RemoteFile) async throws -> RemoteFile {
        guard !file.isFolder, file.metadata?["sys:shared_redirect"] != nil else { return file }
        let target = try await resolvedURI(file.path, followLeaf: true)
        let content: RemoteFile = try await call(
            "GET", "/file/info", body: nil as String?,
            query: [URLQueryItem(name: "uri", value: target)])
        return file.withContent(of: content)
    }

    /// Fetches the server-generated thumbnail without materializing the file.
    func thumbnail(uri: String) async throws -> Data {
        let uri = try await resolvedURI(uri, followLeaf: true)
        var payload: FileThumbPayload?
        var lastError: Error = CloudreveError.badResponse("thumbnail was not generated")
        // Cloudreve can enqueue generation and initially answer 40077. Retry
        // briefly inside File Provider's deadline; if it still is not ready,
        // propagate an error so Finder retries later instead of caching a
        // permanent "no thumbnail" result.
        for delaySeconds: UInt64 in [0, 1, 2, 4] {
            if delaySeconds > 0 {
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
            do {
                payload = try await call(
                    "GET", "/file/thumb", body: nil as String?,
                    query: [URLQueryItem(name: "uri", value: uri)])
                break
            } catch CloudreveError.noSuchItem {
                lastError = CloudreveError.noSuchItem
            } catch {
                throw error
            }
        }
        guard let payload else { throw lastError }
        let value = payload.obfuscated ? try Self.decodeTimeFlowString(payload.url) : payload.url
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            throw CloudreveError.badResponse("invalid thumbnail URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudreveError.badResponse("thumbnail response is not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudreveError.http(status: http.statusCode)
        }
        // Finder thumbnails should be small. Refuse unexpectedly large bodies
        // so a bad endpoint cannot exhaust the extension process.
        let maximumThumbnailBytes = 32 * 1024 * 1024
        guard data.count <= maximumThumbnailBytes else {
            throw CloudreveError.badResponse("thumbnail exceeds 32 MiB")
        }
        return data
    }

    /// Cloudreve may scramble signed thumbnail URLs using the current time.
    /// This intentionally mirrors the Rust API client's time handling.
    private static func decodeTimeFlowString(_ value: String) throws -> String {
        let nowSeconds = Int64(Date().timeIntervalSince1970)
        for candidate in [nowSeconds, nowSeconds - 1000, nowSeconds + 1000] {
            if let decoded = decodeTimeFlowString(value, timeValue: candidate) {
                return decoded
            }
        }
        throw CloudreveError.badResponse("invalid obfuscated thumbnail URL")
    }

    private static func decodeTimeFlowString(_ value: String, timeValue: Int64) -> String? {
        let decodedTime = timeValue / 1000
        guard !value.isEmpty else { return "" }

        var time = decodedTime
        var digits: [Int] = []
        while time > 0 {
            digits.append(Int(time % 10))
            time /= 10
        }
        guard !digits.isEmpty else { return nil }

        var result = Array(value)
        var secret = result
        var add = secret.count.isMultiple(of: 2)
        var digitIndex = (secret.count - 1) % digits.count

        for position in 0..<secret.count {
            let resultIndex = result.count - 1 - position
            var newIndex = resultIndex
            if add {
                newIndex += digits[digitIndex] * digitIndex
            } else {
                newIndex = 2 * digitIndex * digits[digitIndex] - newIndex
            }
            newIndex = abs(newIndex) % secret.count
            result[resultIndex] = secret[newIndex]
            secret.swapAt(resultIndex, newIndex)
            secret.removeLast()
            add.toggle()
            digitIndex = digitIndex == 0 ? digits.count - 1 : digitIndex - 1
        }

        let decoded = String(result)
        let prefix = "\(decodedTime)|"
        guard decoded.hasPrefix(prefix) else { return nil }
        return String(decoded.dropFirst(prefix.count))
    }

    // MARK: Mutations

    /// Creates an empty file or folder. Returns the created item.
    func createFileOrFolder(uri: String, isFolder: Bool) async throws -> RemoteFile {
        struct Body: Encodable {
            let uri: String
            let type: String
        }
        let target = try await resolvedURI(uri, followLeaf: false)
        let file: RemoteFile = try await call(
            "POST", "/file/create",
            body: Body(uri: target, type: isFolder ? "folder" : "file"))
        return target == uri ? file : file.presented(at: uri)
    }

    func renameFile(uri: String, to newName: String) async throws -> RemoteFile {
        struct Body: Encodable {
            let uri: String
            let new_name: String
        }
        let target = try await resolvedURI(uri, followLeaf: false)
        let file: RemoteFile = try await call(
            "POST", "/file/rename", body: Body(uri: target, new_name: newName))
        return target == uri ? file : file.presented(
            at: ShortcutResolver.child(newName, of: ShortcutResolver.parent(uri)))
    }

    /// Moves `uri` into directory `dstURI`.
    func moveFile(uri: String, toDirectory dstURI: String) async throws {
        struct Body: Encodable {
            let uris: [String]
            let dst: String
        }
        let uri = try await resolvedURI(uri, followLeaf: false)
        let dstURI = try await resolvedURI(dstURI, followLeaf: true)
        try await callVoid("POST", "/file/move", body: Body(uris: [uri], dst: dstURI))
    }

    /// Deleting locally may supersede an interrupted upload from this desktop.
    /// Never force-unlock editor sessions or uploads belonging to another client.
    func cancelOwnedUploads(under uri: String) async throws {
        let db = try FileProviderStateDatabase()
        let records = try db.rows("SELECT key,payload FROM fp_records WHERE namespace=?",
            ["fileprovider-upload-sessions"])
        let root = uri.hasSuffix("/") ? String(uri.dropLast()) : uri
        for record in records where record[0].hasPrefix(driveID + ":") {
            let value = try JSONDecoder().decode([String: String].self, from: Data(record[1].utf8))
            guard let path = value["uri"], let id = value["id"],
                path == root || path.hasPrefix(root + "/") else { continue }
            struct Body: Encodable { let id: String; let uri: String }
            do {
                let current = try await fileInfo(uri: path)
                guard current.metadata?["sys:upload_session_id"] == id else {
                    // The old session finished or another client started a newer one.
                    try db.remove("fileprovider-upload-sessions", record[0])
                    continue
                }
                try await callVoid("DELETE", "/file/upload", body: Body(id: id, uri: path))
            } catch CloudreveError.noSuchItem {
                // A completed or already-cancelled session needs no further cancellation.
            }
            try db.remove("fileprovider-upload-sessions", record[0])
        }
    }

    /// Soft-deletes (moves to the Cloudreve trash).
    func deleteFile(uri: String) async throws {
        struct Body: Encodable {
            let uris: [String]
        }
        let uri = try await resolvedURI(uri, followLeaf: false)
        try await callVoid("DELETE", "/file", body: Body(uris: [uri]))
    }

    // MARK: Upload

    private struct UploadCredentialPayload: Decodable {
        let session_id: String
        let chunk_size: Int64?
        let upload_urls: [String]?
        let encrypt_metadata: UploadEncryptMetadata?
        let credential: String?
        let storage_policy: UploadStoragePolicy?
    }

    private struct UploadStoragePolicy: Decodable { let type: String? }

    /// True when `url` has the same scheme, host and port as the instance.
    private func isSameOrigin(_ url: URL) -> Bool {
        func port(_ u: URL) -> Int? {
            u.port ?? (u.scheme?.lowercased() == "https" ? 443 : (u.scheme?.lowercased() == "http" ? 80 : nil))
        }
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
            scheme == baseURL.scheme?.lowercased(), host == baseURL.host?.lowercased()
        else { return false }
        return port(url) == port(baseURL)
    }

    /// Uploads the local file to `uri`. When `overwrite` is true, the content
    /// becomes a new version of the existing file at `uri`.
    /// Works for local/relay storage policies (server-side completion).
    func uploadFile(
        at uri: String,
        from fileURL: URL,
        overwrite: Bool,
        previousVersion: String? = nil,
        progress: Progress,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) async throws
    {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        // File Provider may supply a package directory as one content item.
        // Opening it as a byte stream produces misleading permission errors and
        // automatic retries. Preserve local content and pause before networking.
        if attrs[.type] as? FileAttributeType == .typeDirectory {
            throw CloudreveError.unsupportedPackage
        }
        guard let size = (attrs[.size] as? NSNumber)?.int64Value else {
            throw CloudreveError.badResponse("cannot stat \(fileURL.path)")
        }
        let uri = try await resolvedURI(uri, followLeaf: overwrite)
        let mtime = (attrs[.modificationDate] as? Date).map {
            Int64($0.timeIntervalSince1970)
        }

        struct SessionRequest: Encodable {
            let uri: String
            let size: Int64
            let policy_id: String
            let last_modified: Int64?
            let entity_type: String?
            let encryption_supported: [String]
            let previous: String?
        }
        let credential: UploadCredentialPayload = try await call(
            "PUT", "/file/upload",
            body: SessionRequest(
                uri: uri, size: size, policy_id: "",
                last_modified: mtime,
                entity_type: overwrite ? "version" : nil,
                encryption_supported: [UploadEncryptor.supportedAlgorithm],
                previous: overwrite ? previousVersion : nil))

        let sessionKey = driveID + ":" + credential.session_id
        do {
            try FileProviderStateDatabase().put("fileprovider-upload-sessions", sessionKey,
                try JSONEncoder().encode(["id": credential.session_id, "uri": uri]))
        } catch {
            try? await cancelUploadSession(credential: credential, uri: uri)
            throw error
        }
        let chunkSize = max(credential.chunk_size ?? 0, 1)
        progress.totalUnitCount = size
        onProgress?(0, size)

        do {
            let encryptor = try credential.encrypt_metadata.map(UploadEncryptor.init(metadata:))
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            var index = 0
            var byteOffset: UInt64 = 0
            while true {
                if progress.isCancelled { throw CocoaError(.userCancelled) }
                let data = try handle.read(upToCount: Int(chunkSize)) ?? Data()
                if data.isEmpty && !(size == 0 && index == 0) { break }
                let uploadData = try encryptor?.encrypt(data, at: byteOffset) ?? data
                try await uploadChunk(credential: credential, index: index, data: uploadData)
                progress.completedUnitCount += Int64(data.count)
                onProgress?(progress.completedUnitCount, size)
                byteOffset += UInt64(data.count)
                index += 1
                if data.isEmpty { break }  // zero-byte file: single empty chunk
            }
        } catch {
            // Cancel this client's session after a failed upload.
            try? await cancelUploadSession(credential: credential, uri: uri)
            throw error
        }
        try FileProviderStateDatabase().remove("fileprovider-upload-sessions", sessionKey)
        logger.info("uploaded \(uri, privacy: .public) (\(size) bytes, chunks ok)")
    }

    private func cancelUploadSession(credential: UploadCredentialPayload, uri: String)
        async throws
    {
        struct Body: Encodable {
            let id: String
            let uri: String
        }
        try await callVoid(
            "DELETE", "/file/upload",
            body: Body(id: credential.session_id, uri: uri))
        try FileProviderStateDatabase().remove("fileprovider-upload-sessions",
            driveID + ":" + credential.session_id)
    }

    private func uploadChunk(
        credential: UploadCredentialPayload, index: Int, data: Data
    ) async throws {
        let target: URL
        if let relay = credential.upload_urls?.first, !relay.isEmpty {
            // Relay/remote policy: POST chunk to the provided URL
            let base =
                relay.hasPrefix("/") ? baseURL.absoluteString + relay : relay
            let sep = base.contains("?") ? "&" : "?"
            guard let url = URL(string: "\(base)\(sep)chunk=\(index)") else {
                throw CloudreveError.badResponse("invalid upload URL")
            }
            target = url
        } else {
            // Local policy: POST chunk to the server
            target = baseURL.appendingPathComponent(
                "/api/v4/file/upload/\(credential.session_id)/\(index)")
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        if isSameOrigin(target) {
            request.setValue(
                "Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        } else if credential.storage_policy?.type == "remote",
            let slaveCredential = credential.credential, !slaveCredential.isEmpty
        {
            // Slave node: the upload session credential, never the account token.
            request.setValue(slaveCredential, forHTTPHeaderField: "Authorization")
        } else {
            throw CloudreveError.unsupportedStoragePolicy(
                credential.storage_policy?.type ?? "unknown")
        }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (respData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudreveError.badResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudreveError.http(status: http.statusCode)
        }
        if let envelope = try? JSONDecoder().decode(ApiEnvelope<EmptyPayload>.self, from: respData),
            envelope.code != 0
        {
            throw mapApiError(code: envelope.code, message: envelope.msg)
        }
    }

    func downloadURL(for uri: String) async throws -> URL {
        let uri = try await resolvedURI(uri, followLeaf: true)
        struct Body: Encodable {
            let uris: [String]
            let download: Bool
        }
        let payload: FileURLPayload = try await call(
            "POST", "/file/url", body: Body(uris: [uri], download: true))
        guard let first = payload.urls.first, let url = URL(string: first.url) else {
            throw CloudreveError.badResponse("no download URL")
        }
        return url
    }

    // MARK: Downloading

    /// Downloads `sourceURL` to `dest`, reporting into `progress`.
    func download(
        _ sourceURL: URL,
        to dest: URL,
        itemSize: Int64,
        progress: Progress,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) async throws {
        let delegate = DownloadDelegate(
            dest: dest,
            progress: progress,
            expectedSize: itemSize,
            onProgress: onProgress)
        let session = URLSession(configuration: downloadConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let task = session.downloadTask(with: sourceURL)
                progress.cancellationHandler = { task.cancel() }
                task.resume()
            }
        } onCancel: {
            progress.cancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let dest: URL
    let progress: Progress
    let expectedSize: Int64
    let onProgress: ((Int64, Int64) -> Void)?
    var continuation: CheckedContinuation<Void, Error>?
    private let logger = Logger(
        subsystem: "cloudreve.desktop.fileprovider", category: "download")

    init(
        dest: URL,
        progress: Progress,
        expectedSize: Int64,
        onProgress: ((Int64, Int64) -> Void)?
    ) {
        self.dest = dest
        self.progress = progress
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        if total > 0 { progress.totalUnitCount = total }
        progress.completedUnitCount = totalBytesWritten
        onProgress?(totalBytesWritten, total)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
            !(200..<300).contains(http.statusCode)
        {
            logger.error("download failed: HTTP \(http.statusCode, privacy: .public)")
            continuation?.resume(throwing: CloudreveError.http(status: http.statusCode))
            continuation = nil
            return
        }
        let written =
            (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?
            .int64Value ?? -1
        // URLSession transparently decodes Content-Encoding, so the advertised
        // (encoded) length says nothing about the decoded bytes on disk.
        let encoding = (downloadTask.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let encoded = encoding.map { !$0.isEmpty && $0 != "identity" } ?? false
        let advertised = encoded ? -1 : (downloadTask.response?.expectedContentLength ?? -1)
        if advertised > 0 && advertised != written {
            logger.error("download truncated: \(written, privacy: .public) of \(advertised, privacy: .public)")
            continuation?.resume(throwing: CloudreveError.badResponse("download truncated"))
            continuation = nil
            return
        } else if advertised <= 0 && expectedSize > 0 && written != expectedSize {
            logger.error("download size mismatch: \(written, privacy: .public) of \(self.expectedSize, privacy: .public)")
            continuation?.resume(throwing: CloudreveError.badResponse("download size mismatch"))
            continuation = nil
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            logger.error("move downloaded file failed: \(error.localizedDescription)")
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        if let error {
            continuation?.resume(throwing: error)
        } else if FileManager.default.fileExists(atPath: dest.path) {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: CloudreveError.badResponse("download incomplete"))
        }
        continuation = nil
    }
}
