#![cfg(target_os = "macos")]

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct UploadConflictRecord {
    pub id: String,
    pub drive_id: String,
    pub drive_name: String,
    pub uri: String,
    pub item_identifier: String,
    pub filename: String,
    pub kind: String,
    pub application: Option<String>,
    pub owner_id: Option<String>,
    pub owner_name: Option<String>,
    pub previous_version: Option<String>,
    pub action: Option<String>,
    pub presented_at: i64,
    pub updated_at: i64,
}

fn validate_id(id: &str) -> Result<()> {
    if id.len() == 16 && id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(anyhow!("Invalid upload conflict identifier"))
    }
}

pub fn get(id: &str) -> Result<UploadConflictRecord> {
    validate_id(id)?;
    let key = format!("{id}.json");
    let record = cloudreve_sync::fileprovider_db::StateDb::open()?
        .records("upload-conflicts")?
        .into_iter()
        .find(|record| record.key == key)
        .context("Upload conflict is no longer available")?;
    Ok(serde_json::from_str(&record.payload)?)
}

fn parse_conflicts(records: Vec<cloudreve_sync::fileprovider_db::Record>) -> Vec<UploadConflictRecord> {
    records
        .into_iter()
        .filter(|record| record.key.ends_with(".json"))
        .filter_map(|record| match serde_json::from_str::<UploadConflictRecord>(&record.payload) {
            Ok(conflict) => Some(conflict),
            Err(error) => {
                tracing::warn!(target: "fileprovider", key = %record.key, %error, "Skipping unreadable upload conflict record");
                None
            }
        })
        .collect()
}

pub fn list() -> Result<Vec<UploadConflictRecord>> {
    Ok(parse_conflicts(
        cloudreve_sync::fileprovider_db::StateDb::open()?.records("upload-conflicts")?,
    ))
}

pub fn set_action(id: &str, action: &str) -> Result<UploadConflictRecord> {
    validate_id(id)?;
    if !matches!(action, "save_copy" | "retry" | "discard") {
        return Err(anyhow!("Invalid upload conflict action"));
    }
    let payload = cloudreve_sync::fileprovider_db::StateDb::open()?.update(
        "upload-conflicts",
        &format!("{id}.json"),
        |payload| {
            let mut record: UploadConflictRecord = serde_json::from_str(payload)?;
            record.action = Some(action.to_string());
            record.presented_at = 0;
            record.updated_at = chrono::Utc::now().timestamp_millis();
            Ok(serde_json::to_string(&record)?)
        },
    )?;
    Ok(serde_json::from_str(&payload)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use cloudreve_sync::fileprovider_db::Record;

    #[test]
    fn unreadable_conflict_does_not_hide_others() {
        let good = UploadConflictRecord {
            id: "0123456789abcdef".into(),
            drive_id: "drive-1".into(),
            drive_name: "My Files".into(),
            uri: "cloudreve://my/a".into(),
            item_identifier: "i".into(),
            filename: "a".into(),
            kind: "lock".into(),
            application: None,
            owner_id: None,
            owner_name: None,
            previous_version: None,
            action: None,
            presented_at: 1,
            updated_at: 2,
        };
        let parsed = parse_conflicts(vec![
            Record { key: "bad.json".into(), payload: "{".into() },
            Record { key: "good.json".into(), payload: serde_json::to_string(&good).unwrap() },
            Record { key: "ignored.txt".into(), payload: "x".into() },
        ]);
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].drive_id, "drive-1");
    }
}
