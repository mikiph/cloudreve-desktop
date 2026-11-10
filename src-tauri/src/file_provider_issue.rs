#![cfg(target_os = "macos")]

use crate::upload_conflict::UploadConflictRecord;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

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
    pub application: Option<String>,
    pub message: String,
    pub error_domain: Option<String>,
    pub error_code: Option<i64>,
    pub conflict_id: Option<String>,
    pub updated_at: i64,
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

pub fn list(known_drive_ids: &HashSet<String>) -> Result<Vec<FileProviderIssue>> {
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
    Ok(merge(snapshots, conflicts, known_drive_ids))
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
                    kind: None,
                    application: None,
                    message: item.message,
                    error_domain: Some(item.error_domain),
                    error_code: Some(item.error_code),
                    conflict_id: None,
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
                application: conflict.application,
                message,
                error_domain: Some("NSFileProviderErrorDomain".to_string()),
                error_code: Some(-2005),
                conflict_id: Some(conflict.id),
                updated_at: conflict.updated_at,
            },
        );
    }

    let mut issues = issues.into_values().collect::<Vec<_>>();
    issues.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.drive_name.cmp(&right.drive_name))
            .then_with(|| left.filename.cmp(&right.filename))
            .then_with(|| left.item_identifier.cmp(&right.item_identifier))
    });
    issues
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
}
