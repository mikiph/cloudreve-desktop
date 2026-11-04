//! macOS File Provider (NSFileProvider) domain management.
//!
//! Registers one `NSFileProviderDomain` per configured drive. The domains are
//! served by the embedded `CloudreveFileProvider.appex` in `Contents/PlugIns`
//! of the app bundle, which materializes the drive contents in Finder under
//! `~/Library/CloudStorage/<AppName>-<DomainName>`.
//!
//! `objc2-file-provider` does not generate bindings for `NSFileProviderManager`
//! yet, so the (few) manager calls are hand-rolled with `msg_send!`.

#![cfg(target_os = "macos")]

use std::{
    collections::HashMap,
    ffi::CString,
    fs::File,
    io::Read,
    mem::MaybeUninit,
    ptr::NonNull,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{AllocAnyThread, class, msg_send};
use objc2_file_provider::NSFileProviderDomain;
use objc2_foundation::{
    NSArray, NSError, NSFileCoordinator, NSFileCoordinatorReadingOptions, NSRange, NSString, NSURL,
};
use tokio::sync::oneshot;

use crate::{DriveConfig, FileProviderStatus};

/// Prefix for domain identifiers owned by this app, so we never touch
/// domains registered by other providers (iCloud, Nextcloud, ...).
const DOMAIN_PREFIX: &str = "cloudreve.drive.";
const DOWNLOAD_RETRY_DIRECTORY: &str = "fileprovider-download-retries";
const ACTIVITY_DIRECTORY: &str = "fileprovider-activity";
const UPLOAD_RECEIPT_DIRECTORY: &str = "fileprovider-upload-receipts";

#[derive(Debug, Clone, serde::Deserialize)]
pub struct FileProviderActivityRecord {
    pub id: String,
    pub drive_id: String,
    pub operation: String,
    pub uri: String,
    pub item_identifier: String,
    pub filename: String,
    pub status: String,
    pub total_bytes: i64,
    pub processed_bytes: i64,
    pub speed_bytes_per_sec: i64,
    pub eta_seconds: Option<i64>,
    pub error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

pub fn read_activity(drive_id: &str) -> Result<Vec<FileProviderActivityRecord>> {
    let mut db = crate::fileprovider_db::StateDb::open()?;
    let records = db.records(ACTIVITY_DIRECTORY)?;
    let Some(record) = records.into_iter().find(|record| record.key == format!("{drive_id}.json")) else {
        return Ok(Vec::new());
    };
    Ok(serde_json::from_str::<Vec<FileProviderActivityRecord>>(&record.payload)?
        .into_iter().filter(|record| record.drive_id == drive_id).collect())
}

#[derive(serde::Deserialize)]
struct FileProviderUploadReceipt {
    drive_id: String,
    uri: String,
    completed_at: i64,
}

pub fn matching_upload_receipt(drive_id: &str, uri: &str) -> Result<Option<crate::fileprovider_db::Record>> {
    let mut db = crate::fileprovider_db::StateDb::open()?;
    let now = chrono::Utc::now().timestamp();
    for record in db.records(UPLOAD_RECEIPT_DIRECTORY)? {
        let receipt: FileProviderUploadReceipt = serde_json::from_str(&record.payload)?;
        let age = now.saturating_sub(receipt.completed_at);
        if age > 5 * 60 {
            db.consume(UPLOAD_RECEIPT_DIRECTORY, &record)?;
        } else if age >= -10 && receipt.drive_id == drive_id && receipt.uri == uri {
            return Ok(Some(record));
        }
    }
    Ok(None)
}

pub fn domain_identifier(drive_id: &str) -> String {
    format!("{DOMAIN_PREFIX}{drive_id}")
}

fn make_domain(id: &str, display_name: &str) -> Retained<NSFileProviderDomain> {
    let identifier = NSString::from_str(id);
    let name = NSString::from_str(display_name);
    unsafe {
        NSFileProviderDomain::initWithIdentifier_displayName(
            NSFileProviderDomain::alloc(),
            &identifier,
            &name,
        )
    }
}

/// The raw value of `NSFileProviderRootContainerItemIdentifier`
/// (used when signaling changes at the drive root).
pub const ROOT_CONTAINER: &str = "NSFileProviderRootContainerItemIdentifier";

/// Returns the user-visible location of a drive's File Provider domain
/// (e.g. `~/Library/CloudStorage/Cloudreve-<name>`), if the domain is
/// registered and active.
pub async fn user_visible_item_url(
    domain_id: &str,
    display_name: &str,
    item_identifier: &str,
) -> Option<String> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let identifier = NSString::from_str(item_identifier);
        let block = RcBlock::new(move |url: *mut NSURL, _error: *mut NSError| {
            let path = if url.is_null() {
                None
            } else {
                unsafe { (*url).path() }.map(|p| p.to_string())
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(path);
            }
        });
        unsafe {
            let manager: *mut AnyObject =
                msg_send![class!(NSFileProviderManager), managerForDomain: &*domain];
            if manager.is_null() {
                return None;
            }
            let _: () = msg_send![
                &*manager,
                getUserVisibleURLForItemIdentifier: &*identifier,
                completionHandler: &*block
            ];
        }
    }
    tokio::time::timeout(Duration::from_secs(10), rx).await.ok()?.ok().flatten()
}

static ROOT_CACHE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();

fn invalidate_root_cache(domain_id: &str) {
    if let Some(cache) = ROOT_CACHE.get() {
        cache.lock().unwrap().retain(|key, _| !key.starts_with(&format!("{domain_id}\0")));
    }
}

pub async fn user_visible_url(domain_id: &str, display_name: &str) -> Option<String> {
    let key = format!("{domain_id}\0{display_name}");
    if let Some(path) = ROOT_CACHE
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap()
        .get(&key)
        .cloned()
    {
        return Some(path);
    }

    let path = user_visible_item_url(domain_id, display_name, ROOT_CONTAINER).await?;
    ROOT_CACHE
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap()
        .insert(key, path.clone());
    Some(path)
}

const SF_DATALESS: u32 = 0x4000_0000;

pub fn is_materialized(path: &str) -> bool {
    let Ok(path) = CString::new(path) else {
        return false;
    };
    let mut metadata = MaybeUninit::<libc::stat>::uninit();
    let result = unsafe { libc::lstat(path.as_ptr(), metadata.as_mut_ptr()) };
    if result != 0 {
        return false;
    }
    unsafe { metadata.assume_init().st_flags & SF_DATALESS == 0 }
}

fn coordinated_content_read(path: &str) -> Result<()> {
    let path = NSString::from_str(path);
    let url = NSURL::fileURLWithPath(&path);
    let coordinator = NSFileCoordinator::new();
    let read_result = Arc::new(Mutex::new(None));
    let captured_result = Arc::clone(&read_result);
    let reader = RcBlock::new(move |coordinated_url: NonNull<NSURL>| {
        let result = unsafe { coordinated_url.as_ref() }
            .path()
            .ok_or_else(|| anyhow!("coordinated URL has no filesystem path"))
            .and_then(|path| {
                let mut file = File::open(path.to_string())?;
                let mut byte = [0_u8; 1];
                let _ = file.read(&mut byte)?;
                Ok(())
            });
        *captured_result.lock().unwrap() = Some(result);
    });
    let mut coordination_error = None;
    coordinator.coordinateReadingItemAtURL_options_error_byAccessor(
        &url,
        NSFileCoordinatorReadingOptions::WithoutChanges,
        Some(&mut coordination_error),
        &reader,
    );
    if let Some(error) = coordination_error {
        return Err(anyhow!(error.localizedDescription().to_string()));
    }
    read_result
        .lock()
        .unwrap()
        .take()
        .ok_or_else(|| anyhow!("coordinated read was not performed"))?
}

pub async fn refresh_materialized_item_after_remote_update(
    domain_id: String,
    item_identifier: String,
    local_path: String,
) {
    for _ in 0..50 {
        if !is_materialized(&local_path) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    if is_materialized(&local_path) {
        tracing::warn!(
            target: "fileprovider",
            item_identifier,
            "Old content generation could not be evicted; deferring remote refresh"
        );
        return;
    }

    tokio::time::sleep(Duration::from_millis(200)).await;
    if let Err(error) = mark_download_retry(&domain_id, &item_identifier) {
        tracing::warn!(
            target: "fileprovider",
            %error,
            item_identifier,
            "Could not mark proactive content refresh"
        );
    }

    let read_path = local_path.clone();
    let result = tokio::task::spawn_blocking(move || coordinated_content_read(&read_path)).await;
    match result {
        Ok(Ok(())) if is_materialized(&local_path) => tracing::info!(
            target: "fileprovider",
            item_identifier,
            "Proactively materialized the latest remote content"
        ),
        Ok(Ok(())) => tracing::warn!(
            target: "fileprovider",
            item_identifier,
            "Proactive content read completed but the item remains dataless"
        ),
        Ok(Err(error)) => tracing::warn!(
            target: "fileprovider",
            %error,
            item_identifier,
            "Proactive content refresh failed"
        ),
        Err(error) => tracing::warn!(
            target: "fileprovider",
            %error,
            item_identifier,
            "Proactive content refresh worker failed"
        ),
    }
}

/// The raw value of `NSFileProviderWorkingSetContainerItemIdentifier`.
pub const WORKING_SET_CONTAINER: &str = "NSFileProviderWorkingSetContainerItemIdentifier";

fn canonical_fileprovider_uri(uri: &str) -> String {
    urlencoding::decode(uri)
        .map(|decoded| decoded.into_owned())
        .unwrap_or_else(|_| uri.to_string())
}

fn download_retry_identifier(drive_id: &str, item_identifier: &str) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in drive_id
        .bytes()
        .chain(std::iter::once(0))
        .chain(item_identifier.bytes())
    {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn mark_download_retry(domain_id: &str, item_identifier: &str) -> Result<()> {
    let drive_id = domain_id.strip_prefix(DOMAIN_PREFIX).unwrap_or(domain_id);
    crate::fileprovider_db::StateDb::open()?.put(
        DOWNLOAD_RETRY_DIRECTORY,
        &download_retry_identifier(drive_id, item_identifier),
        &chrono::Utc::now().timestamp_millis().to_string(),
    )
}

// MARK: - Shared event log

/// One recorded remote event, stored transactionally in fileprovider.db.
/// The File Provider extension replays the journal in enumerateChanges (it cannot run a
/// long-lived SSE listener itself: XPC services get suspended when idle).
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct FpEventRecord {
    /// Unix epoch milliseconds when the app received the event.
    pub ts: i64,
    #[serde(rename = "type")]
    pub event_type: String,
    /// Relative event path, or an absolute Cloudreve URI for metadata events.
    pub from: String,
    #[serde(default)]
    pub to: String,
    #[serde(default)]
    pub local_echo: bool,
}


/// Ask the next extension process to discard its local identity and pin state.
pub fn request_local_state_reset(drive_id: &str) -> Result<()> {
    let token = format!(
        "{}-{}\n",
        chrono::Utc::now().timestamp_millis(),
        uuid::Uuid::new_v4()
    );
    // Destructive commands must never be imported from legacy state directories.
    crate::fileprovider_db::StateDb::open()?.put("fp-reset-requests-v2", &format!("{drive_id}.marker"), &token)
}

/// Commit a batch before signalling Finder. Sequence allocation is transactional.
pub fn append_domain_events(
    drive_id: &str,
    events: &[cloudreve_api::models::explorer::FileEventData],
    local_echo_paths: &std::collections::HashSet<String>,
    receipts: &[crate::fileprovider_db::Record],
) -> Result<()> {
    let mut records = events.iter().map(|event| FpEventRecord {
        ts: 0,
        event_type: format!("{:?}", event.event_type).to_lowercase(),
        from: event.from.clone(),
        to: event.to.clone(),
        local_echo: local_echo_paths.contains(&event.from) || (!event.to.is_empty() && local_echo_paths.contains(&event.to)),
    }).collect::<Vec<_>>();
    crate::fileprovider_db::StateDb::open()?.append_events_consuming(drive_id, &mut records, receipts)
}

/// A bounded refresh of root and recently presented folders. Does not expire
/// the working-set anchor or recursively enumerate Keep Downloaded trees.
pub fn append_presented_refresh(drive_id: &str) -> Result<()> {
    append_state_events(drive_id, "refresh_presented", &[String::new()])
}

pub fn append_rescan_marker(drive_id: &str) -> Result<()> {
    append_state_events(drive_id, "rescan", &[String::new()])
}

pub fn append_metadata_events(drive_id: &str, source_uris: &[String]) -> Result<()> {
    if source_uris.is_empty() {
        append_state_events(drive_id, "metadata_rescan", &[String::new()])
    } else {
        append_state_events(drive_id, "metadata", source_uris)
    }
}

pub fn append_metadata_name_events(drive_id: &str, names: &[String]) -> Result<()> {
    append_state_events(drive_id, "metadata_name", names)
}

fn append_state_events(drive_id: &str, kind: &str, paths: &[String]) -> Result<()> {
    let mut records = paths.iter().map(|path| FpEventRecord {
        ts: 0, event_type: kind.into(), from: path.clone(),
        to: String::new(), local_echo: false,
    }).collect::<Vec<_>>();
    crate::fileprovider_db::StateDb::open()?.append_events(drive_id, &mut records)
}

/// Tell the system that new content is available in the given containers of a
/// drive's File Provider domain. The system then asks the extension for
/// changes (launching it if needed).
pub fn signal_containers(domain_id: &str, display_name: &str, containers: &[String]) {
    let domain = make_domain(domain_id, display_name);
    unsafe {
        let manager: *mut AnyObject =
            msg_send![class!(NSFileProviderManager), managerForDomain: &*domain];
        if manager.is_null() {
            tracing::warn!(target: "fileprovider", "no NSFileProviderManager for domain {domain_id} (not registered?)");
            return;
        }
        for container in containers {
            let identifier = NSString::from_str(container);
            let container_log = container.clone();
            let block = RcBlock::new(move |error: *mut NSError| {
                if !error.is_null() {
                    let desc = (*error).localizedDescription();
                    tracing::warn!(target: "fileprovider", "signalEnumerator({container_log}) failed: {desc}");
                } else {
                    tracing::info!(target: "fileprovider", "signalEnumerator({container_log}) completed");
                }
            });
            let _: () = msg_send![
                &*manager,
                signalEnumeratorForContainerItemIdentifier: &*identifier,
                completionHandler: &*block
            ];
        }
    }
}

async fn signal_error_resolved(
    domain_id: &str,
    display_name: &str,
    error_domain: &str,
    error_code: i64,
) -> Result<()> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let error_domain = NSString::from_str(error_domain);
        let error_code = isize::try_from(error_code).context("invalid File Provider error code")?;
        let resolved_error = NSError::new(error_code, &error_domain);
        let block = RcBlock::new(move |error: *mut NSError| {
            let result = if error.is_null() {
                Ok(())
            } else {
                Err(describe_error(error))
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(result);
            }
        });
        unsafe {
            let manager: *mut AnyObject =
                msg_send![class!(NSFileProviderManager), managerForDomain: &*domain];
            if manager.is_null() {
                return Err(anyhow!("no File Provider manager for domain {domain_id}"));
            }
            let _: () = msg_send![
                &*manager,
                signalErrorResolved: &*resolved_error,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("File Provider resolution callback dropped"))?
}

/// Resume File Provider operations paused with CannotSynchronize.
pub async fn signal_cannot_synchronize_resolved(domain_id: &str, display_name: &str) -> Result<()> {
    signal_error_resolved(domain_id, display_name, "NSFileProviderErrorDomain", -2005).await
}

async fn clear_retry_error(
    domain_id: &str,
    display_name: &str,
    error_domain: Option<&str>,
    error_code: Option<i64>,
) {
    let (Some(error_domain), Some(error_code)) = (error_domain, error_code) else {
        return;
    };
    if let Err(error) =
        signal_error_resolved(domain_id, display_name, error_domain, error_code).await
    {
        tracing::warn!(
            target: "fileprovider",
            %error,
            error_domain,
            error_code,
            "Could not clear the saved File Provider error before retrying"
        );
    }
}

/// Retry the original failed deletion. Never request a content modification,
/// which could upload an item the user has already removed.
pub async fn retry_item_deletion(
    domain_id: &str,
    display_name: &str,
    error_domain: Option<&str>,
    error_code: Option<i64>,
) -> Result<()> {
    let error_domain = error_domain.ok_or_else(|| anyhow!("Missing deletion error domain"))?;
    let error_code = error_code.ok_or_else(|| anyhow!("Missing deletion error code"))?;
    signal_error_resolved(domain_id, display_name, error_domain, error_code).await
}

/// Ask File Provider to retry uploading one materialized file.
pub async fn retry_item_upload(
    domain_id: &str,
    display_name: &str,
    item_identifier: &str,
    error_domain: Option<&str>,
    error_code: Option<i64>,
) -> Result<()> {
    clear_retry_error(domain_id, display_name, error_domain, error_code).await;
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let identifier = NSString::from_str(item_identifier);
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |error: *mut NSError| {
            let result = if error.is_null() {
                Ok(())
            } else {
                Err(describe_error(error))
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(result);
            }
        });
        unsafe {
            let manager: *mut AnyObject =
                msg_send![class!(NSFileProviderManager), managerForDomain: &*domain];
            if manager.is_null() {
                return Err(anyhow!("no File Provider manager for domain {domain_id}"));
            }
            let _: () = msg_send![
                &*manager,
                requestModificationOfFields: 1usize,
                forItemWithIdentifier: &*identifier,
                options: 0usize,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("File Provider upload retry callback dropped"))?
}

/// Ask File Provider to retry downloading one item.
pub async fn retry_item_download(
    domain_id: &str,
    display_name: &str,
    item_identifier: &str,
    error_domain: Option<&str>,
    error_code: Option<i64>,
) -> Result<()> {
    mark_download_retry(domain_id, item_identifier)?;
    clear_retry_error(domain_id, display_name, error_domain, error_code).await;
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let identifier = NSString::from_str(item_identifier);
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |error: *mut NSError| {
            let result = if error.is_null() {
                Ok(())
            } else {
                Err(describe_error(error))
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(result);
            }
        });
        unsafe {
            let manager: *mut AnyObject =
                msg_send![class!(NSFileProviderManager), managerForDomain: &*domain];
            if manager.is_null() {
                return Err(anyhow!("no File Provider manager for domain {domain_id}"));
            }
            let full_file = NSRange::new(isize::MAX as usize, 0);
            let _: () = msg_send![
                &*manager,
                requestDownloadForItemWithIdentifier: &*identifier,
                requestedRange: full_file,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("File Provider download retry callback dropped"))?
}

/// Refresh shared metadata in the replicated working set.
pub fn signal_metadata_refresh(drive_id: &str, display_name: &str, source_uris: &[String]) {
    let canonical_uris = source_uris
        .iter()
        .map(|uri| canonical_fileprovider_uri(uri))
        .collect::<Vec<_>>();

    if let Err(error) = append_metadata_events(drive_id, &canonical_uris) {
        tracing::warn!(
            target: "fileprovider",
            error = %error,
            "Failed to record metadata refresh"
        );
    }

    let mut containers = vec![WORKING_SET_CONTAINER.to_string()];
    for uri in &canonical_uris {
        let trimmed = uri.trim_end_matches('/');
        let parent = trimmed
            .rsplit_once('/')
            .map(|(parent, _)| parent)
            .unwrap_or("");
        let container = if parent.is_empty() || parent == "cloudreve:" || parent == "cloudreve://my"
        {
            ROOT_CONTAINER.to_string()
        } else {
            parent.to_string()
        };
        if !containers.contains(&container) {
            containers.push(container);
        }
    }

    signal_containers(&domain_identifier(drive_id), display_name, &containers);
}

pub fn signal_metadata_name_refresh(drive_id: &str, display_name: &str, names: &[String]) {
    if let Err(error) = append_metadata_name_events(drive_id, names) {
        tracing::warn!(target: "fileprovider", error = %error, "Failed to record named metadata refresh");
    }
    signal_containers(
        &domain_identifier(drive_id),
        display_name,
        &[WORKING_SET_CONTAINER.to_string()],
    );
}

#[derive(Debug)]
struct NativeFileProviderError {
    domain: String,
    code: isize,
    description: String,
}

impl std::fmt::Display for NativeFileProviderError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{} (domain: {}, code: {})", self.description, self.domain, self.code)
    }
}
impl std::error::Error for NativeFileProviderError {}

fn is_domain_name_collision(error: &anyhow::Error) -> bool {
    error.downcast_ref::<NativeFileProviderError>().is_some_and(|error|
        // NSFileWriteFileExistsError. Do not hide authentication, disabled
        // extension or generic provider failures behind a rename attempt.
        error.domain == "NSCocoaErrorDomain" && error.code == 516)
}

fn collision_display_name(domain_id: &str, display_name: &str) -> String {
    let identity = domain_id.strip_prefix(DOMAIN_PREFIX).unwrap_or(domain_id);
    format!("{display_name} ({})", identity.chars().take(8).collect::<String>())
}

fn describe_error(error: *mut NSError) -> anyhow::Error {
    if error.is_null() {
        return anyhow!("unknown FileProvider error");
    }
    let (domain, code, desc) = unsafe {
        (
            (*error).domain().to_string(),
            (*error).code(),
            (*error).localizedDescription().to_string(),
        )
    };
    NativeFileProviderError { domain, code, description: desc }.into()
}

/// Serializes host domain registration, removal, reset and connection updates.
/// Callers hold this across the entire lifecycle operation, not individual APIs.
pub static DOMAIN_OPERATIONS: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RecoveryStatus {
    pub phase: String,
    pub items_checked: usize,
    pub folders_checked: usize,
    pub updated_at: i64,
    #[serde(default)]
    pub last_completed_at: Option<i64>,
    /// Journal head produced by the latest completed server check. Finder must
    /// acknowledge this sequence before that check has finished updating Finder.
    #[serde(default)]
    pub target_sequence: Option<i64>,
    #[serde(default)]
    pub folder_progress: Option<FolderCheckProgress>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FolderCheckProgress {
    pub remaining: usize,
    #[serde(default)]
    pub completed: usize,
    #[serde(default)]
    pub total: usize,
    pub pages_checked: usize,
    pub items_checked: usize,
    pub retrying: usize,
}

#[derive(serde::Deserialize)]
struct FinderApplied {
    sequence: i64,
}

#[derive(serde::Deserialize)]
struct FolderRefreshRecord {
    requested: i64,
    completed: i64,
    pending: bool,
    latest_sequence: i64,
    #[serde(default)]
    folders: Vec<FolderCheckRecord>,
    pages_checked: Option<usize>,
    items_checked: Option<usize>,
    folders_checked: Option<usize>,
}

impl FolderRefreshRecord {
    fn has_pending_work(&self) -> bool {
        self.pending || self.requested > self.completed || !self.folders.is_empty()
    }
}

#[derive(serde::Deserialize)]
struct FolderCheckRecord {
    #[serde(default)]
    failures: usize,
}

const PENDING_REFRESH_WAKE_INTERVAL: Duration = Duration::from_secs(5);

#[derive(Default)]
struct PendingRefreshWakeThrottle {
    last_wake: HashMap<String, Instant>,
}

impl PendingRefreshWakeThrottle {
    fn should_wake(&mut self, drive_id: &str, pending: bool, now: Instant) -> bool {
        if !pending {
            self.last_wake.remove(drive_id);
            return false;
        }
        if self.last_wake.get(drive_id).is_some_and(|last|
            now.saturating_duration_since(*last) < PENDING_REFRESH_WAKE_INTERVAL)
        {
            return false;
        }
        self.last_wake.insert(drive_id.into(), now);
        true
    }
}

static PENDING_REFRESH_WAKES: OnceLock<Mutex<PendingRefreshWakeThrottle>> = OnceLock::new();

/// macOS can suspend the extension after it acknowledges a refresh marker but
/// before its independent folder worker has finished. Keep unfinished durable
/// work eligible for another native callback even when no new event arrives.
/// This only wakes the working-set enumerator: it never adds a refresh marker,
/// starts another server search, or changes the queue/checkpoint.
pub fn wake_pending_refresh(drive_id: &str, display_name: &str) -> Result<bool> {
    let pending = pending_refresh_from_db(&mut crate::fileprovider_db::StateDb::open()?, drive_id)?;
    let should_wake = PENDING_REFRESH_WAKES
        .get_or_init(|| Mutex::new(PendingRefreshWakeThrottle::default()))
        .lock()
        .map_err(|_| anyhow!("Finder refresh wake throttle is unavailable"))?
        .should_wake(drive_id, pending, Instant::now());
    if should_wake {
        signal_containers(&domain_identifier(drive_id), display_name, &[WORKING_SET_CONTAINER.into()]);
    }
    Ok(should_wake)
}

fn pending_refresh_from_db(db: &mut crate::fileprovider_db::StateDb, drive_id: &str) -> Result<bool> {
    // Read the acknowledgement before its work record: a newer acknowledgement
    // cannot then be paired with an earlier empty queue to hide pending work.
    let applied = db.records("fp-applied")?.into_iter().find(|row| row.key == drive_id)
        .map(|row| serde_json::from_str::<FinderApplied>(&row.payload).map(|applied| applied.sequence))
        .transpose()?;
    let refresh = db.records("fp-folder-refresh")?.into_iter().find(|row| row.key == drive_id)
        .map(|row| serde_json::from_str::<FolderRefreshRecord>(&row.payload)).transpose()?;
    if refresh.as_ref().is_some_and(FolderRefreshRecord::has_pending_work) {
        return Ok(true);
    }
    let recovery = db.records("fp-recovery")?.into_iter().find(|row| row.key == drive_id)
        .map(|row| serde_json::from_str::<RecoveryStatus>(&row.payload)).transpose()?;
    let target = refresh.as_ref().map(|refresh| refresh.latest_sequence).unwrap_or(0)
        .max(recovery.and_then(|recovery| recovery.target_sequence).unwrap_or(0));
    Ok(target > 0 && applied.is_none_or(|sequence| sequence < target))
}

pub fn write_recovery_status(drive_id: &str, status: &RecoveryStatus) {
    let result = (|| -> Result<()> {
        write_recovery_status_to_db(&mut crate::fileprovider_db::StateDb::open()?, drive_id, status)
    })();
    if let Err(error) = result {
        tracing::warn!(target: "fileprovider", %error, "Could not persist recovery progress");
    }
}

fn write_recovery_status_to_db(db: &mut crate::fileprovider_db::StateDb, drive_id: &str, status: &RecoveryStatus) -> Result<()> {
    let mut status = status.clone();
    if status.phase == "completed" {
        // This timestamp intentionally describes the server check. The read
        // projection below separately reports outstanding Finder delivery.
        status.last_completed_at = Some(status.updated_at);
    } else if let Some(previous) = read_recovery_status_from_db(db, drive_id)? {
        status.last_completed_at = previous.last_completed_at;
        status.target_sequence = status.target_sequence.or(previous.target_sequence);
    }
    db.put("fp-recovery", drive_id, &serde_json::to_string(&status)?)
}

pub fn read_recovery_status(drive_id: &str) -> Result<Option<RecoveryStatus>> {
    read_recovery_status_from_db(&mut crate::fileprovider_db::StateDb::open()?, drive_id)
}

fn read_recovery_status_from_db(db: &mut crate::fileprovider_db::StateDb, drive_id: &str) -> Result<Option<RecoveryStatus>> {
    let Some(row) = db.records("fp-recovery")?.into_iter().find(|row| row.key == drive_id) else {
        return Ok(None);
    };
    let mut status: RecoveryStatus = serde_json::from_str(&row.payload)?;
    // Preserve successful checks from older builds, which did not record an
    // acknowledgement target. Missing acknowledgement for a new target must
    // never be mistaken for a completed Finder update.
    if status.phase == "completed" {
        status.last_completed_at.get_or_insert(status.updated_at);
        {
            let target = status.target_sequence.unwrap_or(0);
            let delivery_finished = (|| -> Result<bool> {
                // Read the acknowledgement first. The extension persists any
                // refresh request before acknowledging its marker. Reading the
                // queue first could pair an old empty queue with a newer ack.
                let applied = db.records("fp-applied")?.into_iter().find(|row| row.key == drive_id)
                    .map(|row| serde_json::from_str::<FinderApplied>(&row.payload).map(|applied| applied.sequence))
                    .transpose()?;
                let refresh: Option<FolderRefreshRecord> = db.records("fp-folder-refresh")?.into_iter()
                    .find(|row| row.key == drive_id)
                    .map(|row| serde_json::from_str(&row.payload)).transpose()?;
                let pending = refresh.as_ref().is_some_and(FolderRefreshRecord::has_pending_work);
                if let Some(refresh) = &refresh {
                    status.folder_progress = Some(FolderCheckProgress {
                        remaining: refresh.folders.len(),
                        completed: refresh.folders_checked.unwrap_or(0),
                        total: refresh.folders_checked.unwrap_or(0).saturating_add(refresh.folders.len()),
                        pages_checked: refresh.pages_checked.unwrap_or(0),
                        items_checked: refresh.items_checked.unwrap_or(0),
                        retrying: refresh.folders.iter().filter(|folder| folder.failures > 0).count(),
                    });
                }
                let target = target.max(refresh.map(|refresh| refresh.latest_sequence).unwrap_or(0));
                Ok(!pending && (target <= 0 || applied.is_some_and(|sequence| sequence >= target)))
            })();
            let acknowledged = match delivery_finished {
                Ok(finished) => finished,
                Err(error) => {
                    tracing::warn!(target: "fileprovider", %error, "Could not read Finder delivery progress");
                    false
                }
            };
            if !acknowledged {
                status.phase = "applying".into();
            }
        }
    }
    Ok(Some(status))
}

/// macOS may finish the removal callback before its domain list catches up.
/// Never recreate a domain until its old registration has disappeared.
pub async fn wait_for_domain_removal(domain_id: &str) -> Result<()> {
    for _ in 0..40 {
        if !list_domains().await?.iter().any(|(id, _)| id == domain_id) {
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }
    Err(anyhow!("Finder is still removing this location. Wait a moment and retry. Your drive configuration has been retained."))
}

/// Reuse an existing identity. Never remove another configured drive merely
/// because its display name matches (including domains owned by an older app).
pub async fn ensure_domain(domain_id: &str, display_name: &str) -> Result<()> {
    if !list_domains().await?.iter().any(|(id, _)| id == domain_id) {
        if let Err(error) = add_domain(domain_id, display_name).await {
            if !is_domain_name_collision(&error) { return Err(error).context("Finder could not create this location"); }
            // An older app identity can still own the requested name. Preserve
            // it and its contents, and register our stable ID under a distinct
            // display name. Never delete CloudStorage paths to free a name.
            let alternate = collision_display_name(domain_id, display_name);
            add_domain(domain_id, &alternate).await.with_context(||
                format!("Finder could not create {display_name} or {alternate}. An older Cloudreve location may still own these names. Disconnect that location in its original app, or choose a different name. No local folders were deleted"))?;
        }
    }
    Ok(())
}

/// List domains currently registered by this app process's bundle.
pub async fn list_domains() -> Result<Vec<(String, String)>> {
    Ok(list_domain_states().await?.into_iter().map(|(id, name, _, _)| (id, name)).collect())
}

async fn list_domain_states() -> Result<Vec<(String, String, bool, bool)>> {
    let (tx, rx) = oneshot::channel();
    // Non-Send ObjC objects (block) are confined to this scope; the ObjC
    // runtime copies the completion handler, so it outlives our RcBlock.
    {
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(
            move |domains: *mut NSArray<NSFileProviderDomain>, error: *mut NSError| {
                let result = if !error.is_null() {
                    Err(describe_error(error))
                } else if domains.is_null() {
                    Ok(Vec::new())
                } else {
                    let domains = unsafe { &*domains };
                    Ok(domains
                        .iter()
                        .map(|d| unsafe {
                            (d.identifier().to_string(), d.displayName().to_string(), d.isDisconnected(), d.userEnabled())
                        })
                        .collect())
                };
                if let Some(tx) = tx.lock().unwrap().take() {
                    let _ = tx.send(result);
                }
            },
        );
        unsafe {
            let _: () = msg_send![
                class!(NSFileProviderManager),
                getDomainsWithCompletionHandler: &*block
            ];
        }
    }
    tokio::time::timeout(Duration::from_secs(10), rx).await
        .map_err(|_| anyhow!("Finder did not respond when listing domains"))?
        .map_err(|_| anyhow!("domain list callback dropped"))?
}

/// Register a new domain. Errors if the domain already exists.
pub async fn add_domain(domain_id: &str, display_name: &str) -> Result<()> {
    invalidate_root_cache(domain_id);
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |error: *mut NSError| {
            let result = if error.is_null() {
                Ok(())
            } else {
                Err(describe_error(error))
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(result);
            }
        });
        unsafe {
            let _: () = msg_send![
                class!(NSFileProviderManager),
                addDomain: &*domain,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("addDomain callback dropped"))?
}

/// Remove a domain. WARNING: this deletes the local replica of the domain
/// (the folder under ~/Library/CloudStorage). Locally modified but not yet
/// uploaded ("dirty") items are preserved by the system; clean downloaded
/// content is discarded so a fresh domain cannot re-ingest stale downloads
/// as new uploads (the legacy removeDomain API preserves downloaded data).
pub async fn remove_domain(domain_id: &str, display_name: &str) -> Result<Option<String>> {
    invalidate_root_cache(domain_id);
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(
            move |preserved_location: *mut NSURL, error: *mut NSError| {
                let result = if error.is_null() {
                    Ok(if preserved_location.is_null() { None } else {
                        unsafe { (*preserved_location).path().map(|path| path.to_string()) }
                    })
                } else {
                    Err(describe_error(error))
                };
                if let Some(tx) = tx.lock().unwrap().take() {
                    let _ = tx.send(result);
                }
            },
        );
        unsafe {
            // NSFileProviderDomainRemovalModePreserveDirtyUserData = 1
            let _: () = msg_send![
                class!(NSFileProviderManager),
                removeDomain: &*domain,
                mode: 1isize,
                completionHandler: &*block
            ];
        }
    }
    rx.await
        .map_err(|_| anyhow!("removeDomain callback dropped"))?
}

/// Tell macOS whether the host application is available for a registered
/// domain. Disconnecting keeps downloaded files visible, but prevents Finder
/// from asking the extension to enumerate or mutate remote content and shows
/// the localized reason at the top of the domain.
pub async fn set_domain_connected(domain_id: &str, display_name: &str, connected: bool, reason: &str) -> Result<()> {
    let (tx, rx) = oneshot::channel();
    {
        let domain = make_domain(domain_id, display_name);
        let tx = Mutex::new(Some(tx));
        let block = RcBlock::new(move |error: *mut NSError| {
            let result = if error.is_null() {
                Ok(())
            } else {
                Err(describe_error(error))
            };
            if let Some(tx) = tx.lock().unwrap().take() {
                let _ = tx.send(result);
            }
        });
        unsafe {
            let manager: *mut AnyObject =
                msg_send![class!(NSFileProviderManager), managerForDomain: &*domain];
            if manager.is_null() {
                return Err(anyhow!("no File Provider manager for domain {domain_id}"));
            }
            if connected {
                let _: () = msg_send![&*manager, reconnectWithCompletionHandler: &*block];
            } else {
                let reason = NSString::from_str(reason);
                let _: () = msg_send![
                    &*manager,
                    disconnectWithReason: &*reason,
                    options: 0usize,
                    completionHandler: &*block
                ];
            }
        }
    }
    tokio::time::timeout(Duration::from_secs(10), rx).await
        .map_err(|_| anyhow!("Finder did not respond to the connection update"))?
        .map_err(|_| anyhow!("domain connection callback dropped"))?
}

/// Update all enabled domains without changing their identifiers, sync
/// anchors, event logs, or local replicas.
pub async fn set_domains_connected(drives: &[DriveConfig], connected: bool) {
    for drive in drives.iter().filter(|drive| drive.enabled) {
        let id = domain_identifier(&drive.id);
        if let Err(error) = set_domain_connected(&id, &drive.name, connected, "Cloudreve is closed. Reopen the app to reconnect.").await {
            tracing::warn!(
                target: "fileprovider",
                domain = %id,
                connected,
                error = %error,
                "failed to update File Provider connection state"
            );
        }
    }
}

/// Lightweight status for Drive Settings. This deliberately checks only the
/// stable domain registration and leaves enumeration and sync behavior alone.
pub async fn domain_status(drive_id: &str, _display_name: &str) -> FileProviderStatus {
    let id = domain_identifier(drive_id);
    match list_domain_states().await {
        Ok(domains) => match domains.into_iter().find(|(registered, _, _, _)| registered == &id) {
            Some((_, _, disconnected, enabled)) => FileProviderStatus {
                connected: enabled && !disconnected,
                message: if !enabled { Some("Approve Cloudreve in Finder, or enable it in System Settings → General → Login Items & Extensions → File Providers.".into()) }
                    else { disconnected.then(|| "Finder is disconnected. Cloudreve reconnects automatically when the server connection is restored.".into()) },
            },
            None => FileProviderStatus {
                connected: false,
                message: Some("Finder location is not registered. Choose Set up Finder to finish setup without resetting your account.".into()),
            },
        },
        Err(error) => FileProviderStatus {
            connected: false,
            message: Some(format!("Could not inspect Finder integration: {error:#}")),
        },
    }
}

/// Reconcile registered File Provider domains with the configured drives:
/// add domains for new drives, remove domains whose drive is gone.
/// Errors are logged, not propagated: file provider integration is best-effort.
pub async fn sync_domains_with_drives(drives: &[DriveConfig]) {
    let _operation = DOMAIN_OPERATIONS.lock().await;
    let registered = match list_domains().await {
        Ok(domains) => domains,
        Err(e) => {
            tracing::warn!(target: "fileprovider", "failed to list FP domains: {e:#}");
            return;
        }
    };

    tracing::info!(
        target: "fileprovider",
        "FP sync: registered={registered:?}, drives={:?}",
        drives.iter().map(|d| (&d.id, &d.name, d.enabled)).collect::<Vec<_>>()
    );

    let wanted: Vec<(&DriveConfig, String)> = drives
        .iter()
        .filter(|d| d.enabled)
        .map(|d| (d, domain_identifier(&d.id)))
        .collect();

    // Remove stale domains (ours, but drive no longer configured)
    for (id, name) in &registered {
        if id.starts_with(DOMAIN_PREFIX) && !wanted.iter().any(|(_, wid)| wid == id) {
            tracing::info!(target: "fileprovider", "removing stale FP domain {id} ({name})");
            if let Err(e) = remove_domain(id, name).await {
                tracing::warn!(target: "fileprovider", "failed to remove FP domain {id}: {e:#}");
            } else if let Err(error) = wait_for_domain_removal(id).await {
                tracing::warn!(target: "fileprovider", %error, "Stale domain removal is still pending");
            }
        }
    }

    // Add missing domains
    for (drive, id) in &wanted {
        if registered.iter().any(|(rid, _)| rid == id) {
            continue;
        }
        tracing::info!(target: "fileprovider", "registering FP domain {id} ({})", drive.name);
        if let Err(e) = ensure_domain(id, &drive.name).await {
            tracing::warn!(target: "fileprovider", "failed to add FP domain {id}: {e:#}");
        }
    }

    // The host connection supervisor reconnects only after a confirmed SSE
    // subscription. Registration alone is not evidence of a live connection.
}

#[cfg(test)]
mod recovery_status_tests {
    use super::*;

    fn status(phase: &str, target_sequence: Option<i64>) -> RecoveryStatus {
        RecoveryStatus {
            phase: phase.into(), items_checked: 3, folders_checked: 0,
            updated_at: 1_000, last_completed_at: None, target_sequence, folder_progress: None, error: None,
        }
    }

    #[test]
    fn folder_check_progress_reports_remaining_work_and_retries() {
        let directory = tempfile::tempdir().unwrap();
        let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
        write_recovery_status_to_db(&mut db, "drive", &status("completed", Some(42))).unwrap();
        db.put("fp-applied", "drive", r#"{"sequence":42}"#).unwrap();
        db.put("fp-folder-refresh", "drive", r#"{"requested":42,"completed":0,"pending":true,"latest_sequence":42,"folders":[{"failures":0},{"failures":2}],"pages_checked":3,"items_checked":20,"folders_checked":7}"#).unwrap();
        let status = read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap();
        assert_eq!(status.phase, "applying");
        let progress = status.folder_progress.unwrap();
        assert_eq!((progress.remaining, progress.pages_checked, progress.items_checked, progress.retrying), (2, 3, 20, 1));
        assert_eq!((progress.completed, progress.total), (7, 9));
    }

    #[test]
    fn nonempty_folder_queue_remains_pending_even_with_a_stale_pending_flag() {
        let directory = tempfile::tempdir().unwrap();
        let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
        write_recovery_status_to_db(&mut db, "drive", &status("completed", Some(42))).unwrap();
        db.put("fp-applied", "drive", r#"{"sequence":42}"#).unwrap();
        db.put("fp-folder-refresh", "drive", r#"{"requested":42,"completed":42,"pending":false,"latest_sequence":42,"folders":[{"failures":0}]}"#).unwrap();
        assert!(pending_refresh_from_db(&mut db, "drive").unwrap());
        assert_eq!(read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap().phase, "applying");
    }

    #[test]
    fn suspended_folder_work_can_be_woken_without_adding_another_check() {
        let directory = tempfile::tempdir().unwrap();
        let queue = r#"{"requested":42,"completed":0,"pending":true,"latest_sequence":42,"folders":[{"id":"remaining","failures":0}],"folders_checked":115,"pages_checked":130,"items_checked":25000}"#;
        let checkpoint = r#"{"root_uri":"cloudreve://my","since":12345}"#;
        {
            let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
            db.put("fp-applied", "drive", r#"{"sequence":42}"#).unwrap();
            db.put("fp-folder-refresh", "drive", queue).unwrap();
            db.put("fp-search-checkpoint", "drive", checkpoint).unwrap();
        }
        // A new host handle sees exactly the remaining work even though the
        // extension that created it has exited and its marker was acknowledged.
        let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
        let head = db.latest_event_sequence("drive").unwrap();
        let mut throttle = PendingRefreshWakeThrottle::default();
        let now = Instant::now();
        assert!(throttle.should_wake("drive", pending_refresh_from_db(&mut db, "drive").unwrap(), now));
        assert!(!throttle.should_wake("drive", pending_refresh_from_db(&mut db, "drive").unwrap(), now + Duration::from_secs(3)));
        assert!(throttle.should_wake("drive", pending_refresh_from_db(&mut db, "drive").unwrap(), now + Duration::from_secs(6)));
        assert_eq!(db.latest_event_sequence("drive").unwrap(), head);
        assert_eq!(db.records("fp-folder-refresh").unwrap()[0].payload, queue);
        assert_eq!(db.records("fp-search-checkpoint").unwrap()[0].payload, checkpoint);
    }

    #[test]
    fn pending_wake_waits_for_result_delivery_and_then_becomes_quiet() {
        let directory = tempfile::tempdir().unwrap();
        let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
        db.put("fp-folder-refresh", "drive", r#"{"requested":42,"completed":42,"pending":false,"latest_sequence":50,"folders":[]}"#).unwrap();
        assert!(pending_refresh_from_db(&mut db, "drive").unwrap(), "An absent native acknowledgement must not hide undelivered results");
        db.put("fp-applied", "drive", r#"{"sequence":49}"#).unwrap();
        assert!(pending_refresh_from_db(&mut db, "drive").unwrap());
        db.put("fp-applied", "drive", r#"{"sequence":50}"#).unwrap();
        assert!(!pending_refresh_from_db(&mut db, "drive").unwrap());
        write_recovery_status_to_db(&mut db, "drive", &status("completed", Some(60))).unwrap();
        assert!(pending_refresh_from_db(&mut db, "drive").unwrap(), "The server-check target also needs delivery");
        db.put("fp-applied", "drive", r#"{"sequence":60}"#).unwrap();
        assert!(!pending_refresh_from_db(&mut db, "drive").unwrap());
        assert!(!pending_refresh_from_db(&mut db, "unknown").unwrap());
    }

    #[test]
    fn pending_wake_handles_requested_markers_and_corrupt_records() {
        let directory = tempfile::tempdir().unwrap();
        let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
        db.put("fp-folder-refresh", "drive", r#"{"requested":42,"completed":41,"pending":false,"latest_sequence":0,"folders":[]}"#).unwrap();
        assert!(pending_refresh_from_db(&mut db, "drive").unwrap());
        db.put("fp-folder-refresh", "drive", "invalid JSON").unwrap();
        assert!(pending_refresh_from_db(&mut db, "drive").is_err());
        db.put("fp-folder-refresh", "drive", r#"{"requested":42,"completed":42,"pending":false,"latest_sequence":50,"folders":[]}"#).unwrap();
        db.put("fp-applied", "drive", "invalid JSON").unwrap();
        assert!(pending_refresh_from_db(&mut db, "drive").is_err());
    }

    #[test]
    fn pending_wake_throttle_is_per_drive_and_resets_after_completion() {
        let now = Instant::now();
        let mut throttle = PendingRefreshWakeThrottle::default();
        assert!(throttle.should_wake("a", true, now));
        assert!(throttle.should_wake("b", true, now));
        assert!(!throttle.should_wake("a", true, now + Duration::from_secs(4)));
        assert!(throttle.should_wake("a", true, now + PENDING_REFRESH_WAKE_INTERVAL));
        assert!(!throttle.should_wake("a", false, now + Duration::from_secs(6)));
        assert!(throttle.should_wake("a", true, now + Duration::from_secs(6)));
    }

    #[test]
    fn recovery_waits_for_finder_to_acknowledge_the_entire_check() {
        let directory = tempfile::tempdir().unwrap();
        let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
        write_recovery_status_to_db(&mut db, "drive", &status("completed", Some(42))).unwrap();
        assert_eq!(read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap().phase, "applying");
        db.put("fp-applied", "drive", r#"{"sequence":41,"updated_at":1200}"#).unwrap();
        assert_eq!(read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap().phase, "applying");
        db.put("fp-applied", "drive", r#"{"sequence":42,"updated_at":1300}"#).unwrap();
        let completed = read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap();
        assert_eq!(completed.phase, "completed");
        assert_eq!(completed.last_completed_at, Some(1_000));
    }

    #[test]
    fn unreadable_acknowledgement_does_not_claim_finder_is_finished() {
        let directory = tempfile::tempdir().unwrap();
        let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
        write_recovery_status_to_db(&mut db, "drive", &status("completed", Some(42))).unwrap();
        db.put("fp-applied", "drive", "invalid JSON").unwrap();
        assert_eq!(read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap().phase, "applying");
    }

    #[test]
    fn marker_acknowledgement_waits_for_folder_refresh_and_its_result_events() {
        let directory = tempfile::tempdir().unwrap();
        let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
        write_recovery_status_to_db(&mut db, "drive", &status("completed", Some(42))).unwrap();
        db.put("fp-applied", "drive", r#"{"sequence":42,"updated_at":1200}"#).unwrap();
        db.put("fp-folder-refresh", "drive", r#"{"requested":42,"completed":0,"pending":true,"latest_sequence":0}"#).unwrap();
        assert_eq!(read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap().phase, "applying");
        db.put("fp-folder-refresh", "drive", r#"{"requested":42,"completed":42,"pending":false,"latest_sequence":50}"#).unwrap();
        assert_eq!(read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap().phase, "applying");
        db.put("fp-applied", "drive", r#"{"sequence":50,"updated_at":1300}"#).unwrap();
        assert_eq!(read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap().phase, "completed");
        db.put("fp-folder-refresh", "drive", "invalid JSON").unwrap();
        assert_eq!(read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap().phase, "applying");
    }

    #[test]
    fn retry_retains_the_previous_server_check_and_finder_target() {
        let directory = tempfile::tempdir().unwrap();
        let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
        write_recovery_status_to_db(&mut db, "drive", &status("completed", Some(42))).unwrap();
        let mut retry = status("retrying", None);
        retry.updated_at = 2_000;
        write_recovery_status_to_db(&mut db, "drive", &retry).unwrap();
        let retry = read_recovery_status_from_db(&mut db, "drive").unwrap().unwrap();
        assert_eq!(retry.phase, "retrying");
        assert_eq!(retry.last_completed_at, Some(1_000));
        assert_eq!(retry.target_sequence, Some(42));
    }

    #[test]
    fn legacy_checks_without_a_target_and_empty_journals_remain_completed() {
        let directory = tempfile::tempdir().unwrap();
        let mut db = crate::fileprovider_db::StateDb::at(directory.path()).unwrap();
        db.put("fp-recovery", "legacy", r#"{"phase":"completed","items_checked":3,"folders_checked":0,"updated_at":1000,"error":null}"#).unwrap();
        let legacy = read_recovery_status_from_db(&mut db, "legacy").unwrap().unwrap();
        assert_eq!(legacy.phase, "completed");
        assert_eq!(legacy.last_completed_at, Some(1_000));
        write_recovery_status_to_db(&mut db, "empty", &status("completed", Some(0))).unwrap();
        assert_eq!(read_recovery_status_from_db(&mut db, "empty").unwrap().unwrap().phase, "completed");
        db.put("fp-folder-refresh", "empty", r#"{"requested":42,"completed":0,"pending":true,"latest_sequence":0}"#).unwrap();
        assert_eq!(read_recovery_status_from_db(&mut db, "empty").unwrap().unwrap().phase, "applying");
    }
}

#[cfg(test)]
mod lifecycle_tests {
    use super::*;

    #[test]
    fn only_a_native_name_collision_allows_the_safe_suffix_fallback() {
        let error = |domain: &str, code| -> anyhow::Error {
            NativeFileProviderError { domain: domain.into(), code, description: "failure".into() }.into()
        };
        assert!(is_domain_name_collision(&error("NSCocoaErrorDomain", 516)));
        assert!(!is_domain_name_collision(&error("NSFileProviderErrorDomain", 516)));
        assert!(!is_domain_name_collision(&error("NSCocoaErrorDomain", 257)));
        assert!(!is_domain_name_collision(&anyhow!("file exists")));
    }

    #[test]
    fn collision_name_uses_stable_identity_without_changing_the_domain_id() {
        assert_eq!(collision_display_name("cloudreve.drive.12345678-abc", "Cloudreve"), "Cloudreve (12345678)");
        assert_ne!(collision_display_name("cloudreve.drive.87654321-abc", "Cloudreve"), "Cloudreve (12345678)");
    }
}
