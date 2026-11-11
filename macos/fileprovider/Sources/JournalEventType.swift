import Foundation

/// `type` values in the fp_events journal. The Rust host writes the same
/// strings (`journal_type` in crates/cloudreve-sync/src/fileprovider.rs); both
/// are checked against macos/fileprovider/Tests/Fixtures/journal-event-types.txt.
enum JournalEventType {
    static let create = "create"
    static let modify = "modify"
    static let rename = "rename"
    static let delete = "delete"
    static let rescan = "rescan"
    static let refreshPresented = "refresh_presented"
    static let metadata = "metadata"
    static let metadataRescan = "metadata_rescan"
    static let metadataName = "metadata_name"
    /// Written by the extension itself (RemoteStore.commitPresentedPage).
    static let presentedPage = "presented_page"

    static let hostWritten: Set<String> = [
        create, modify, rename, delete, rescan, refreshPresented,
        metadata, metadataRescan, metadataName,
    ]
    static let extensionWritten: Set<String> = [presentedPage]
}
