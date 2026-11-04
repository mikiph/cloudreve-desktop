import Foundation

/// Reads metadata for many URIs with a fixed number of requests in flight.
enum FileInfoPrefetch {
    static let concurrency = 8
    typealias Results = [String: Result<RemoteFile, Error>]

    /// Fetches in fixed-size waves of unstructured tasks. Results are keyed by URI; failures are kept, not thrown.
    static func fetch(_ uris: [String], using client: CloudreveClient) async -> Results {
        var results: Results = [:]
        var start = 0
        while start < uris.count {
            let wave = Array(uris[start..<min(start + concurrency, uris.count)])
            start += wave.count
            let tasks = wave.map { uri in
                Task { () -> Result<RemoteFile, Error> in
                    do { return .success(try await client.fileInfoWithShareState(uri: uri)) }
                    catch { return .failure(error) }
                }
            }
            for (uri, task) in zip(wave, tasks) { results[uri] = await task.value }
        }
        return results
    }
}
