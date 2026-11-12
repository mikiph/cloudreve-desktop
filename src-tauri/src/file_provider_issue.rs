#![cfg(target_os = "macos")]

use crate::upload_conflict::UploadConflictRecord;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// Prefix of the message the File Provider extension attaches to items it
/// refuses because of a forbidden name (`CloudreveError.invalidName`).
pub const INVALID_NAME_MESSAGE_PREFIX: &str = "Cloudreve does not allow these characters in names";
pub const INVALID_NAME_KIND: &str = "invalid_name";
const FORBIDDEN_NAME_CHARS: [char; 9] = ['\\', '/', ':', '*', '?', '"', '<', '>', '|'];

/// Validates a name the user wants to give an item.
pub fn validate_target_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name == "." || name == ".." {
        return Err("Enter a valid name".to_string());
    }
    if name.chars().any(|c| FORBIDDEN_NAME_CHARS.contains(&c)) {
        return Err("Names cannot contain \\ / : * ? \" < > |".to_string());
    }
    Ok(())
}

/// Suggests a valid replacement for `name`: forbidden characters become `_`,
/// surrounding whitespace is trimmed, empty/`.`/`..` become `_`, and a numeric
/// suffix ` (2)`, ` (3)`... is added before the last extension while `taken`
/// reports a collision.
pub fn suggest_valid_name(name: &str, taken: &dyn Fn(&str) -> bool) -> String {
    let replaced: String = name
        .chars()
        .map(|c| if FORBIDDEN_NAME_CHARS.contains(&c) { '_' } else { c })
        .collect();
    let mut base = replaced.trim().to_string();
    if base.is_empty() || base == "." || base == ".." {
        base = "_".to_string();
    }
    if !taken(&base) {
        return base;
    }
    let (stem, ext) = match base.rfind('.') {
        Some(index) if index > 0 => base.split_at(index),
        _ => (base.as_str(), ""),
    };
    (2u32..)
        .map(|n| format!("{stem} ({n}){ext}"))
        .find(|candidate| !taken(candidate))
        .expect("an unused suffix exists")
}

/// Last path segment of a raw (undecoded) Cloudreve URI.
pub fn server_name_from_uri(uri: &str) -> Option<String> {
    uri.trim_end_matches('/')
        .rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .map(str::to_string)
}

/// Computes the destination path for renaming `current` to `target`.
/// Returns `Ok(None)` when the item already carries the target name.
pub fn rename_destination(
    current: &std::path::Path,
    target: &str,
) -> Result<Option<std::path::PathBuf>, String> {
    validate_target_name(target)?;
    if current.file_name().and_then(|n| n.to_str()) == Some(target) {
        return Ok(None);
    }
    let parent = current
        .parent()
        .ok_or_else(|| "Finder could not locate this item".to_string())?;
    let destination = parent.join(target);
    if destination.exists() {
        return Err(format!("An item named \"{target}\" already exists here"));
    }
    Ok(Some(destination))
}

#[derive(Clone, Debug, Deserialize)]
struct PendingSnapshot {
    drive_id: String,
    drive_name: String,
    updated_at: i64,
    items: Vec<PendingRecord>,
}

#[derive(Clone, Debug, Deserialize)]
struct PendingRecord {
    item_identifier: String,
    filename: String,
    is_folder: bool,
    operation: String,
    error_domain: String,
    error_code: i64,
    message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct FileProviderIssue {
    pub id: String,
    pub drive_id: String,
    pub drive_name: String,
    pub item_identifier: String,
    pub filename: String,
    pub is_folder: bool,
    pub operation: String,
    pub source: String,
    pub kind: Option<String>,
    /// Last known server name (from the identity map); only for `invalid_name` issues.
    #[serde(default)]
    pub previous_name: Option<String>,
    /// Proposed valid name; only for `invalid_name` issues.
    #[serde(default)]
    pub suggested_name: Option<String>,
    pub application: Option<String>,
    pub message: String,
    pub error_domain: Option<String>,
    pub error_code: Option<i64>,
    pub conflict_id: Option<String>,
    /// Finder identifier of the containing folder; only for `refused_name` issues
    /// (and pending ones that share an item with a refused-name row).
    #[serde(default)]
    pub parent_identifier: Option<String>,
    pub updated_at: i64,
}

/// A name the extension refused, recorded by the extension itself because
/// macOS drops the failed item from its pending list shortly afterwards.
#[derive(Clone, Debug, Deserialize)]
struct RefusedNameRow {
    drive_id: String,
    item_identifier: String,
    parent_identifier: String,
    filename: String,
    operation: String,
    message: String,
    updated_at: i64,
}

const REFUSED_NAMES_NAMESPACE: &str = "fileprovider-refused-names";

fn parse_refused_rows(
    records: Vec<cloudreve_sync::fileprovider_db::Record>,
) -> Vec<(cloudreve_sync::fileprovider_db::Record, RefusedNameRow)> {
    records
        .into_iter()
        .filter_map(|record| match serde_json::from_str::<RefusedNameRow>(&record.payload) {
            Ok(row) => Some((record, row)),
            Err(error) => {
                tracing::warn!(target: "fileprovider", key = %record.key, %error, "Skipping unreadable refused-name record");
                None
            }
        })
        .collect()
}

/// Adds refused-name rows as `invalid_name` issues. A pending issue for the
/// same item wins (it carries the system's error) but learns the parent.
fn add_refused_names(
    issues: &mut Vec<FileProviderIssue>,
    rows: Vec<RefusedNameRow>,
    drive_names: &HashMap<String, String>,
) {
    for row in rows {
        let Some(drive_name) = drive_names.get(&row.drive_id) else {
            continue;
        };
        if let Some(existing) = issues
            .iter_mut()
            .find(|i| i.drive_id == row.drive_id && i.item_identifier == row.item_identifier)
        {
            existing.parent_identifier = Some(row.parent_identifier);
            continue;
        }
        let stable_id = uuid::Uuid::new_v5(
            &uuid::Uuid::NAMESPACE_OID,
            format!("{}\0{}", row.drive_id, row.item_identifier).as_bytes(),
        );
        issues.push(FileProviderIssue {
            id: format!("refused:{stable_id}"),
            drive_id: row.drive_id,
            drive_name: drive_name.clone(),
            item_identifier: row.item_identifier,
            filename: row.filename,
            is_folder: false,
            operation: row.operation,
            source: "refused_name".to_string(),
            kind: Some(INVALID_NAME_KIND.to_string()),
            previous_name: None,
            suggested_name: None,
            application: None,
            message: row.message,
            error_domain: None,
            error_code: None,
            conflict_id: None,
            parent_identifier: Some(row.parent_identifier),
            updated_at: row.updated_at,
        });
    }
    sort_issues(issues);
}

/// A refused-name row still applies while a file with an invalid name exists.
fn refused_row_still_applies(name_on_disk: Option<&str>) -> bool {
    name_on_disk.is_some_and(|name| validate_target_name(name).is_err())
}

/// `<local path of parent>/<filename>`.
fn join_parent_path(parent_local: &str, filename: &str) -> std::path::PathBuf {
    std::path::Path::new(parent_local).join(filename)
}

/// Candidate local paths of an item, most precise first: the item's own
/// Finder URL, then `<parent folder>/<filename>` (never-synced items have a
/// temporary identifier Finder may not resolve).
async fn local_path_candidates(
    domain_id: &str,
    drive_name: &str,
    item_identifier: &str,
    parent_identifier: Option<&str>,
    filename: &str,
) -> Vec<std::path::PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) =
        cloudreve_sync::fileprovider::user_visible_item_url(domain_id, drive_name, item_identifier).await
    {
        candidates.push(std::path::PathBuf::from(path));
    }
    if let Some(parent) = parent_identifier {
        let base = if parent == cloudreve_sync::fileprovider::ROOT_CONTAINER {
            cloudreve_sync::fileprovider::user_visible_url(domain_id, drive_name).await
        } else {
            cloudreve_sync::fileprovider::user_visible_item_url(domain_id, drive_name, parent).await
        };
        if let Some(base) = base {
            candidates.push(join_parent_path(&base, filename));
        }
    }
    candidates
}

/// Deletes refused-name rows whose file is gone or whose name is now valid.
/// Rows whose path cannot be resolved at all are kept (unverified).
async fn prune_refused_rows(
    rows: Vec<(cloudreve_sync::fileprovider_db::Record, RefusedNameRow)>,
    drive_names: &HashMap<String, String>,
) -> Result<Vec<RefusedNameRow>> {
    let mut kept = Vec::new();
    for (record, row) in rows {
        let Some(drive_name) = drive_names.get(&row.drive_id) else {
            continue;
        };
        let domain_id = cloudreve_sync::fileprovider::domain_identifier(&row.drive_id);
        let candidates = local_path_candidates(
            &domain_id,
            drive_name,
            &row.item_identifier,
            Some(&row.parent_identifier),
            &row.filename,
        )
        .await;
        let existing = candidates.iter().find(|path| path.exists());
        let applies = if candidates.is_empty() {
            true
        } else {
            refused_row_still_applies(
                existing
                    .and_then(|path| path.file_name())
                    .and_then(|name| name.to_str()),
            )
        };
        if applies {
            kept.push(row);
        } else {
            cloudreve_sync::fileprovider_db::StateDb::open()?
                .consume(REFUSED_NAMES_NAMESPACE, &record)?;
        }
    }
    Ok(kept)
}

fn parse_snapshots(records: Vec<cloudreve_sync::fileprovider_db::Record>) -> Vec<PendingSnapshot> {
    records
        .into_iter()
        .filter(|record| record.key.ends_with(".json"))
        .filter_map(|record| match serde_json::from_str::<PendingSnapshot>(&record.payload) {
            Ok(snapshot) => Some(snapshot),
            Err(error) => {
                tracing::warn!(target: "fileprovider", key = %record.key, %error, "Skipping unreadable Finder pending snapshot");
                None
            }
        })
        .collect()
}

/// `drive_names` maps every known drive id to its display name.
pub async fn list(drive_names: &HashMap<String, String>) -> Result<Vec<FileProviderIssue>> {
    let known_drive_ids = drive_names.keys().cloned().collect::<HashSet<_>>();
    let known_drive_ids = &known_drive_ids;
    let snapshots = parse_snapshots(
        cloudreve_sync::fileprovider_db::StateDb::open()?.records("fileprovider-pending")?,
    );
    let delete_intents = cloudreve_sync::fileprovider_db::StateDb::open()?
        .records("fileprovider-delete-intents")?
        .into_iter().map(|record| record.key).collect::<HashSet<_>>();
    let mut snapshots = snapshots;
    for snapshot in &mut snapshots {
        for item in &mut snapshot.items {
            if delete_intents.contains(&format!("{}:{}", snapshot.drive_id, item.item_identifier)) {
                item.operation = "delete".into();
            }
        }
    }
    let conflicts = crate::upload_conflict::list()?;
    let mut issues = merge(snapshots, conflicts, known_drive_ids);
    let refused = parse_refused_rows(
        cloudreve_sync::fileprovider_db::StateDb::open()?.records(REFUSED_NAMES_NAMESPACE)?,
    );
    let refused = prune_refused_rows(refused, drive_names).await?;
    add_refused_names(&mut issues, refused, drive_names);
    annotate_invalid_names(&mut issues, &|drive_id| {
        crate::saved_items::read_state(&format!("identities-{drive_id}.json")).unwrap_or_default()
    });
    Ok(issues)
}

/// Fills `previous_name` / `suggested_name` for `invalid_name` issues.
/// `identities` loads the identity map (item identifier -> raw URI) of a drive.
fn annotate_invalid_names(
    issues: &mut [FileProviderIssue],
    identities: &dyn Fn(&str) -> HashMap<String, String>,
) {
    let mut cache = HashMap::<String, HashMap<String, String>>::new();
    for issue in issues
        .iter_mut()
        .filter(|issue| issue.kind.as_deref() == Some(INVALID_NAME_KIND))
    {
        let map = cache
            .entry(issue.drive_id.clone())
            .or_insert_with(|| identities(&issue.drive_id));
        issue.previous_name = map
            .get(&issue.item_identifier)
            .and_then(|uri| server_name_from_uri(uri));
        issue.suggested_name = Some(suggest_valid_name(&issue.filename, &|_| false));
    }
}

/// The `invalid_name` issues a batch fix applies to, optionally for one drive.
pub fn invalid_name_issues<'a>(
    issues: &'a [FileProviderIssue],
    drive_id: Option<&str>,
) -> Vec<&'a FileProviderIssue> {
    issues
        .iter()
        .filter(|issue| issue.kind.as_deref() == Some(INVALID_NAME_KIND))
        .filter(|issue| drive_id.map_or(true, |id| issue.drive_id == id))
        .collect()
}

/// Whether a fixed issue's item should be asked to upload (files only).
pub fn should_request_upload(issue: &FileProviderIssue) -> bool {
    !issue.is_folder
}

/// Delay giving the system time to notice a local rename before prodding it.
pub const UPLOAD_REQUEST_DELAY: std::time::Duration = std::time::Duration::from_millis(1500);

/// Best effort: asks File Provider to upload a just-renamed item. Never fails the caller.
pub async fn request_upload_best_effort(domain_id: &str, drive_name: &str, issue: &FileProviderIssue) {
    if !should_request_upload(issue) {
        return;
    }
    if let Err(error) = cloudreve_sync::fileprovider::retry_item_upload(
        domain_id,
        drive_name,
        &issue.item_identifier,
        issue.error_domain.as_deref(),
        issue.error_code,
    )
    .await
    {
        tracing::warn!(target: "fileprovider", %error, "Could not request upload after name fix");
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct FixFailure {
    pub filename: String,
    pub error: String,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct AutoFixResult {
    pub fixed: u32,
    pub failed: Vec<FixFailure>,
}

impl AutoFixResult {
    pub fn record(&mut self, filename: &str, outcome: Result<(), String>) {
        match outcome {
            Ok(()) => self.fixed += 1,
            Err(error) => self.failed.push(FixFailure { filename: filename.to_string(), error }),
        }
    }
}

/// Target name for an auto-fix of an item whose current name is `current_name`.
/// A name that is already valid is kept (the issue is stale); otherwise the
/// suggested replacement is used. `taken` must ignore the item's own path.
pub fn auto_fix_target(current_name: &str, taken: &dyn Fn(&str) -> bool) -> String {
    if validate_target_name(current_name).is_ok() {
        current_name.to_string()
    } else {
        suggest_valid_name(current_name, taken)
    }
}

pub enum RenameTarget {
    Name(String),
    /// Rename to `suggest_valid_name` of the item's current local name.
    AutoFix,
}

/// Renames the item's current local file (resolved through Finder) to the
/// target, using the same validation and sibling check for every action.
/// Does not signal; callers signal once resolution is complete.
pub async fn rename_item_locally(
    domain_id: &str,
    drive_name: &str,
    item_identifier: &str,
    parent_identifier: Option<&str>,
    filename: &str,
    target: RenameTarget,
) -> Result<(), String> {
    let candidates = local_path_candidates(
        domain_id,
        drive_name,
        item_identifier,
        parent_identifier,
        filename,
    )
    .await;
    let current = candidates
        .iter()
        .find(|path| path.exists())
        .or(candidates.first())
        .cloned()
        .ok_or_else(|| "Finder could not locate this item".to_string())?;
    let target = match target {
        RenameTarget::Name(name) => name,
        RenameTarget::AutoFix => {
            let name = current
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or_else(|| "Finder could not locate this item".to_string())?
                .to_string();
            let parent = current.parent().map(|p| p.to_path_buf());
            auto_fix_target(&name, &|candidate| {
                candidate != name
                    && parent.as_ref().is_some_and(|p| p.join(candidate).exists())
            })
        }
    };
    if let Some(destination) = rename_destination(&current, &target)? {
        tokio::task::spawn_blocking(move || std::fs::rename(current, destination))
            .await
            .map_err(|error| error.to_string())?
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn merge(
    snapshots: Vec<PendingSnapshot>,
    conflicts: Vec<UploadConflictRecord>,
    known_drive_ids: &HashSet<String>,
) -> Vec<FileProviderIssue> {
    let mut issues = HashMap::<(String, String), FileProviderIssue>::new();

    for snapshot in snapshots {
        if !known_drive_ids.contains(&snapshot.drive_id) {
            continue;
        }
        for item in snapshot.items {
            let key = (snapshot.drive_id.clone(), item.item_identifier.clone());
            let stable_id = uuid::Uuid::new_v5(
                &uuid::Uuid::NAMESPACE_OID,
                format!("{}\0{}", key.0, key.1).as_bytes(),
            );
            issues.insert(
                key,
                FileProviderIssue {
                    id: format!("pending:{stable_id}"),
                    drive_id: snapshot.drive_id.clone(),
                    drive_name: snapshot.drive_name.clone(),
                    item_identifier: item.item_identifier,
                    filename: item.filename,
                    is_folder: item.is_folder,
                    operation: item.operation,
                    source: "pending".to_string(),
                    kind: item
                        .message
                        .starts_with(INVALID_NAME_MESSAGE_PREFIX)
                        .then(|| INVALID_NAME_KIND.to_string()),
                    previous_name: None,
                    suggested_name: None,
                    application: None,
                    message: item.message,
                    error_domain: Some(item.error_domain),
                    error_code: Some(item.error_code),
                    conflict_id: None,
                    parent_identifier: None,
                    updated_at: snapshot.updated_at,
                },
            );
        }
    }

    for conflict in conflicts {
        if !known_drive_ids.contains(&conflict.drive_id) {
            continue;
        }
        let key = (conflict.drive_id.clone(), conflict.item_identifier.clone());
        // A local deletion supersedes stale upload recovery actions.
        if issues.get(&key).is_some_and(|issue| issue.operation == "delete") {
            continue;
        }
        if conflict.action.is_some() {
            issues.remove(&key);
            continue;
        }
        let message = match conflict.kind.as_str() {
            "locked" => "Someone has this file open online.".to_string(),
            "stale" => "The online file changed before your edit could be uploaded.".to_string(),
            _ => "Cloudreve could not verify which online version you edited.".to_string(),
        };
        issues.insert(
            key,
            FileProviderIssue {
                id: format!("conflict:{}", conflict.id),
                drive_id: conflict.drive_id,
                drive_name: conflict.drive_name,
                item_identifier: conflict.item_identifier,
                filename: conflict.filename,
                is_folder: false,
                operation: "upload".to_string(),
                source: "upload_conflict".to_string(),
                kind: Some(conflict.kind),
                previous_name: None,
                suggested_name: None,
                application: conflict.application,
                message,
                error_domain: Some("NSFileProviderErrorDomain".to_string()),
                error_code: Some(-2005),
                conflict_id: Some(conflict.id),
                parent_identifier: None,
                updated_at: conflict.updated_at,
            },
        );
    }

    let mut issues = issues.into_values().collect::<Vec<_>>();
    sort_issues(&mut issues);
    issues
}

fn sort_issues(issues: &mut [FileProviderIssue]) {
    issues.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.drive_name.cmp(&right.drive_name))
            .then_with(|| left.filename.cmp(&right.filename))
            .then_with(|| left.item_identifier.cmp(&right.item_identifier))
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unreadable_pending_snapshot_does_not_hide_others() {
        use cloudreve_sync::fileprovider_db::Record;
        let good = r#"{"drive_id":"drive-1","drive_name":"My Files","updated_at":1,"items":[{"item_identifier":"i","filename":"f","is_folder":false,"operation":"upload","error_domain":"d","error_code":1,"message":"m"}]}"#;
        let parsed = parse_snapshots(vec![
            Record { key: "bad.json".into(), payload: "{".into() },
            Record { key: "good.json".into(), payload: good.into() },
            Record { key: "ignored.txt".into(), payload: "x".into() },
        ]);
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].drive_id, "drive-1");
    }

    #[test]
    fn upload_is_requested_for_files_only() {
        let mut issue = conflict_issue_for_upload_test();
        issue.is_folder = false;
        assert!(should_request_upload(&issue));
        issue.is_folder = true;
        assert!(!should_request_upload(&issue));
    }

    fn conflict_issue_for_upload_test() -> FileProviderIssue {
        let known = HashSet::from(["drive-1".to_string()]);
        merge(vec![pending_snapshot()], Vec::new(), &known)
            .into_iter()
            .next()
            .expect("issue")
    }

    fn pending_snapshot() -> PendingSnapshot {
        PendingSnapshot {
            drive_id: "drive-1".to_string(),
            drive_name: "My Files".to_string(),
            updated_at: 10,
            items: vec![PendingRecord {
                item_identifier: "cloudreve-item:/abc".to_string(),
                filename: "report.docx".to_string(),
                is_folder: false,
                operation: "upload".to_string(),
                error_domain: "NSFileProviderErrorDomain".to_string(),
                error_code: -2005,
                message: "Could not synchronize".to_string(),
            }],
        }
    }

    fn conflict() -> UploadConflictRecord {
        UploadConflictRecord {
            id: "0123456789abcdef".to_string(),
            drive_id: "drive-1".to_string(),
            drive_name: "My Files".to_string(),
            uri: "cloudreve://my/report.docx".to_string(),
            item_identifier: "cloudreve-item:/abc".to_string(),
            filename: "report.docx".to_string(),
            kind: "locked".to_string(),
            application: Some("OnlyOffice".to_string()),
            owner_id: Some("user-1".to_string()),
            owner_name: None,
            previous_version: None,
            action: None,
            presented_at: 0,
            updated_at: 20,
        }
    }

    #[test]
    fn managed_conflict_replaces_the_matching_pending_error() {
        let known = HashSet::from(["drive-1".to_string()]);
        let issues = merge(vec![pending_snapshot()], vec![conflict()], &known);
        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].source, "upload_conflict");
        assert_eq!(issues[0].application.as_deref(), Some("OnlyOffice"));
    }

    #[test]
    fn deletion_supersedes_upload_conflicts_and_their_retry_actions() {
        for action in [None, Some("retry".to_string()), Some("discard".to_string())] {
            let mut snapshot = pending_snapshot();
            snapshot.items[0].operation = "delete".into();
            let mut upload = conflict();
            upload.action = action;
            let known = HashSet::from(["drive-1".to_string()]);
            let issues = merge(vec![snapshot], vec![upload], &known);
            assert_eq!(issues.len(), 1);
            assert_eq!(issues[0].operation, "delete");
            assert_eq!(issues[0].source, "pending");
            assert!(issues[0].conflict_id.is_none());
        }
    }

    #[test]
    fn ignores_snapshots_for_removed_drives() {
        let issues = merge(vec![pending_snapshot()], Vec::new(), &HashSet::new());
        assert!(issues.is_empty());
    }

    #[test]
    fn hides_a_conflict_while_its_resolution_is_pending() {
        let known = HashSet::from(["drive-1".to_string()]);
        let mut conflict = conflict();
        conflict.action = Some("retry".to_string());
        let issues = merge(vec![pending_snapshot()], vec![conflict], &known);
        assert!(issues.is_empty());
    }

    #[test]
    fn pending_items_with_the_same_timestamp_have_a_stable_order() {
        let known = HashSet::from(["drive-1".to_string()]);
        let mut snapshot = pending_snapshot();
        snapshot.items = vec![
            PendingRecord {
                item_identifier: "cloudreve-item:/two".to_string(),
                filename: "zebra.docx".to_string(),
                is_folder: false,
                operation: "download".to_string(),
                error_domain: "NSFileProviderErrorDomain".to_string(),
                error_code: -1004,
                message: "Could not synchronize".to_string(),
            },
            PendingRecord {
                item_identifier: "cloudreve-item:/one".to_string(),
                filename: "alpha.docx".to_string(),
                is_folder: false,
                operation: "download".to_string(),
                error_domain: "NSFileProviderErrorDomain".to_string(),
                error_code: -1004,
                message: "Could not synchronize".to_string(),
            },
        ];

        let issues = merge(vec![snapshot], Vec::new(), &known);
        let filenames = issues
            .iter()
            .map(|issue| issue.filename.as_str())
            .collect::<Vec<_>>();
        assert_eq!(filenames, vec!["alpha.docx", "zebra.docx"]);
    }

    #[test]
    fn forbidden_name_message_marks_the_issue_as_invalid_name() {
        let known = HashSet::from(["drive-1".to_string()]);
        let mut snapshot = pending_snapshot();
        snapshot.items[0].filename = "100%.txt".into();
        snapshot.items[0].message = "Cloudreve does not allow these characters in names: \\ / : * ? \" < > |. Rename the item to continue.".into();
        let issues = merge(vec![snapshot], Vec::new(), &known);
        assert_eq!(issues[0].kind.as_deref(), Some("invalid_name"));
        let issues = merge(vec![pending_snapshot()], Vec::new(), &known);
        assert_eq!(issues[0].kind, None);
    }

    #[test]
    fn target_name_validation() {
        for ch in ['\\', '/', ':', '*', '?', '"', '<', '>', '|'] {
            assert!(validate_target_name(&format!("a{ch}b.txt")).is_err(), "{ch}");
        }
        for ok in ["100%.txt", "a b.txt", "a#b.txt", "\u{e9}.txt"] {
            assert!(validate_target_name(ok).is_ok(), "{ok}");
        }
        for bad in ["", ".", ".."] {
            assert!(validate_target_name(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn server_name_is_the_last_uri_segment() {
        assert_eq!(server_name_from_uri("cloudreve://my/dir/100%.txt").as_deref(), Some("100%.txt"));
        assert_eq!(server_name_from_uri("cloudreve://my/a b#c.txt").as_deref(), Some("a b#c.txt"));
        assert_eq!(server_name_from_uri(""), None);
    }

    #[test]
    fn rename_destination_handles_same_name_conflict_and_success() {
        let dir = std::env::temp_dir().join(format!("cr-034-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let current = dir.join("a?b.txt");
        std::fs::write(&current, b"x").unwrap();
        std::fs::write(dir.join("taken.txt"), b"x").unwrap();
        assert_eq!(rename_destination(&current, "a?b.txt").unwrap_err(), "Names cannot contain \\ / : * ? \" < > |");
        assert_eq!(rename_destination(&current, "ok.txt").unwrap(), Some(dir.join("ok.txt")));
        assert!(rename_destination(&current, "taken.txt").is_err());
        let same = dir.join("taken.txt");
        assert_eq!(rename_destination(&same, "taken.txt").unwrap(), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn suggests_valid_names() {
        let free = |_: &str| false;
        assert_eq!(suggest_valid_name("a?b.txt", &free), "a_b.txt");
        assert_eq!(suggest_valid_name("what*?.txt", &free), "what__.txt");
        assert_eq!(suggest_valid_name("?", &free), "_");
        assert_eq!(suggest_valid_name("  ", &free), "_");
        assert_eq!(suggest_valid_name("..", &free), "_");
        assert_eq!(suggest_valid_name(" a:b ", &free), "a_b");
        let taken = |n: &str| n == "a_b.txt" || n == "a_b (2).txt";
        assert_eq!(suggest_valid_name("a?b.txt", &taken), "a_b (3).txt");
        let taken = |n: &str| n == "a_b.tar.gz";
        assert_eq!(suggest_valid_name("a?b.tar.gz", &taken), "a_b.tar (2).gz");
        let taken = |n: &str| n == "a_b";
        assert_eq!(suggest_valid_name("a?b", &taken), "a_b (2)");
        let taken = |n: &str| n == ".hidden";
        assert_eq!(suggest_valid_name(".hidden", &taken), ".hidden (2)");
    }

    fn invalid_issue(drive: &str, id: &str, filename: &str) -> FileProviderIssue {
        let mut snapshot = pending_snapshot();
        snapshot.drive_id = drive.into();
        snapshot.items[0].item_identifier = id.into();
        snapshot.items[0].filename = filename.into();
        snapshot.items[0].message = format!("{INVALID_NAME_MESSAGE_PREFIX}: x");
        let known = HashSet::from([drive.to_string()]);
        merge(vec![snapshot], Vec::new(), &known).remove(0)
    }

    #[test]
    fn previous_name_known_and_unknown_identifier() {
        let mut issues = vec![
            invalid_issue("drive-1", "cloudreve-item:/known", "a?b.txt"),
            invalid_issue("drive-1", "cloudreve-item:/new", "c?d.txt"),
        ];
        annotate_invalid_names(&mut issues, &|_| {
            HashMap::from([("cloudreve-item:/known".to_string(), "cloudreve://my/dir/100%.txt".to_string())])
        });
        let known = issues.iter().find(|i| i.filename == "a?b.txt").unwrap();
        assert_eq!(known.previous_name.as_deref(), Some("100%.txt"));
        assert_eq!(known.suggested_name.as_deref(), Some("a_b.txt"));
        let unknown = issues.iter().find(|i| i.filename == "c?d.txt").unwrap();
        assert_eq!(unknown.previous_name, None);
        assert_eq!(unknown.suggested_name.as_deref(), Some("c_d.txt"));
    }

    #[test]
    fn batch_selects_invalid_name_issues_and_records_results() {
        let mut other = pending_snapshot();
        other.items[0].item_identifier = "cloudreve-item:/other".into();
        let known = HashSet::from(["drive-1".to_string(), "drive-2".to_string()]);
        let mut issues = merge(vec![other], Vec::new(), &known);
        issues.push(invalid_issue("drive-1", "i1", "a?b"));
        issues.push(invalid_issue("drive-2", "i2", "c?d"));
        assert_eq!(invalid_name_issues(&issues, None).len(), 2);
        let only = invalid_name_issues(&issues, Some("drive-2"));
        assert_eq!(only.len(), 1);
        assert_eq!(only[0].filename, "c?d");

        let mut result = AutoFixResult::default();
        result.record("a?b", Ok(()));
        result.record("c?d", Err("exists".into()));
        assert_eq!(result.fixed, 1);
        assert_eq!(result.failed.len(), 1);
        assert_eq!(result.failed[0].filename, "c?d");
    }

    fn refused_row(drive: &str, item: &str, filename: &str) -> RefusedNameRow {
        RefusedNameRow {
            drive_id: drive.into(),
            item_identifier: item.into(),
            parent_identifier: "cloudreve-item:/parent".into(),
            filename: filename.into(),
            operation: "upload".into(),
            message: format!("{INVALID_NAME_MESSAGE_PREFIX}: x"),
            updated_at: 5,
        }
    }

    fn names() -> HashMap<String, String> {
        HashMap::from([("drive-1".to_string(), "My Files".to_string())])
    }

    #[test]
    fn refused_name_row_becomes_an_invalid_name_issue() {
        let mut issues = Vec::new();
        add_refused_names(
            &mut issues,
            vec![refused_row("drive-1", "tmp-1", "CleanShot X?.zip"), refused_row("gone", "tmp-2", "a?")],
            &names(),
        );
        assert_eq!(issues.len(), 1, "rows of unknown drives are skipped");
        assert_eq!(issues[0].kind.as_deref(), Some("invalid_name"));
        assert_eq!(issues[0].source, "refused_name");
        assert_eq!(issues[0].drive_name, "My Files");
        assert_eq!(issues[0].parent_identifier.as_deref(), Some("cloudreve-item:/parent"));
        assert_eq!(issues[0].previous_name, None);
    }

    #[test]
    fn refused_row_dedupes_against_the_pending_issue_for_the_same_item() {
        let mut issues = vec![invalid_issue("drive-1", "tmp-1", "a?b.txt")];
        add_refused_names(&mut issues, vec![refused_row("drive-1", "tmp-1", "a?b.txt")], &names());
        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].source, "pending");
        assert_eq!(issues[0].parent_identifier.as_deref(), Some("cloudreve-item:/parent"));
    }

    #[test]
    fn refused_row_is_pruned_when_file_missing_or_name_valid() {
        assert!(refused_row_still_applies(Some("a?b.txt")));
        assert!(!refused_row_still_applies(None));
        assert!(!refused_row_still_applies(Some("a_b.txt")));
    }

    #[test]
    fn parent_fallback_joins_the_filename_onto_the_parent_path() {
        assert_eq!(
            join_parent_path("/Users/x/Library/CloudStorage/Drive/docs", "a?b.zip"),
            std::path::PathBuf::from("/Users/x/Library/CloudStorage/Drive/docs/a?b.zip")
        );
    }

    #[test]
    fn auto_fix_keeps_valid_names_and_renames_invalid_ones() {
        let always_taken = |_: &str| true;
        assert_eq!(auto_fix_target("fine (1).txt", &always_taken), "fine (1).txt");
        assert_eq!(auto_fix_target("a?b.txt", &|_| false), "a_b.txt");
        assert_eq!(auto_fix_target("a?b.txt", &|n| n == "a_b.txt"), "a_b (2).txt");
    }
}
