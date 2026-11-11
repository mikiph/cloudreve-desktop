import FileProvider
import Darwin
import OSLog
import UniformTypeIdentifiers
import CryptoKit

extension RemoteStore {
    // MARK: Anchors and change replay

    /// Anchor for the last delivered event: "evt-<sequence>" (journal sequence, not a raw timestamp).
    func currentSyncAnchor() throws -> NSFileProviderSyncAnchor {
        let lastTs = try FileProviderStateDatabase().eventSnapshot(drive: drive.id, since: nil).latest
        return NSFileProviderSyncAnchor(Data("evt-\(lastTs)".utf8))
    }

    /// Return events after an anchor, or expire an unknown anchor.
    func changes(since anchorData: Data, for container: NSFileProviderItemIdentifier)
        throws -> ([FpEvent], NSFileProviderSyncAnchor, Bool)
    {
        guard let text = String(data: anchorData, encoding: .utf8),
            text.hasPrefix("evt-"), let since = Int64(text.dropFirst(4))
        else {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let snapshot = try FileProviderStateDatabase().eventSnapshot(drive: drive.id, since: since, limit: 32)
        guard since >= snapshot.floor, since <= snapshot.latest else {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let events = try snapshot.events.map { try JSONDecoder().decode(FpEvent.self, from: $0) }
        // A rescan marker invalidates all later anchors.
        if snapshot.hasRescan || events.contains(where: { $0.type == JournalEventType.rescan && $0.ts > since }) {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let relevant = events.filter { $0.ts > since }
        // One refresh request covers all older requests in this snapshot.
        // Never repeat a folder traversal once for every reconnect marker.
        let latestRefresh = relevant.last(where: { $0.type == JournalEventType.refreshPresented })?.ts
        let filtered = relevant.filter {
            ($0.type != JournalEventType.refreshPresented || $0.ts == latestRefresh)
                && changeTouchesContainer($0, container: container)
        }
        var page: [FpEvent] = []
        var cost = 0
        for event in filtered {
            let weight = max(1, (event.presentation?.items.count ?? 0)
                + (event.presentation?.deleted.count ?? 0))
            if !page.isEmpty && cost + weight > Self.changePageSize { break }
            page.append(event)
            cost += weight
            if cost >= Self.changePageSize { break }
        }
        let hasBufferedChanges = filtered.count > page.count
        let moreComing = hasBufferedChanges || snapshot.hasMore
        // Advance only over records actually read. A bounded database read may
        // still have later relevant events even when this batch is unrelated.
        let nextTimestamp = hasBufferedChanges ? (page.last?.ts ?? since) : snapshot.readThrough
        let newAnchor = NSFileProviderSyncAnchor(Data("evt-\(nextTimestamp)".utf8))
        logger.notice(
            "changes for \(container.rawValue, privacy: .private(mask: .hash)): anchor \(since), relevant \(relevant.count), delivered \(page.count), next \(nextTimestamp), moreComing \(moreComing)"
        )
        return (page, newAnchor, moreComing)
    }

    /// Convert an event path to a canonical URI.
    func uri(forEventPath path: String) -> String {
        if path.hasPrefix("cloudreve://") {
            return Self.canonicalURI(path)
        }
        return Self.canonicalURI(drive.remote_path + (path.hasPrefix("/") ? path : "/" + path))
    }

    private func changeTouchesContainer(
        _ change: FpEvent, container: NSFileProviderItemIdentifier
    ) -> Bool {
        if change.type == JournalEventType.refreshPresented || change.type == JournalEventType.presentedPage {
            return container == .workingSet
        }
        let fromURI = uri(forEventPath: change.from)
        let toURI = change.to.map { uri(forEventPath: $0) }
        let parentOf = { (uri: String) -> String in
            var u = uri
            if u.hasSuffix("/") { u.removeLast() }
            guard let idx = u.lastIndex(of: "/") else { return self.rootPath }
            let parent = String(u[..<idx])
            if parent == self.drive.remote_path || parent == "cloudreve://my" || parent.isEmpty {
                return self.rootPath
            }
            return Self.canonicalURI(parent)
        }

        // The working set is the domain-wide incremental feed. Every change
        // must pass through it, including a new hierarchy below a folder that
        // has never been opened. Items remain placeholders; this updates
        // metadata only and does not download file contents. The persistent
        // audit establishes its first snapshot without emitting events, and
        // paging above bounds later recovery bursts.
        if container == .workingSet { return true }

        let containerURI = container == .rootContainer
            ? rootPath : Self.canonicalURI(uri(for: container))
        if fromURI == containerURI || toURI == containerURI { return true }
        return parentOf(fromURI) == containerURI || (toURI.map { parentOf($0) } == containerURI)
    }

}
