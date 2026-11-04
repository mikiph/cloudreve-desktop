use super::mounts::Mount;
use crate::inventory::{FileProviderRemoteItem, NewFileProviderRemoteItem};
use anyhow::{Context, Result, ensure};
use cloudreve_api::{
    api::explorer::ExplorerApiExt,
    models::explorer::{FileEventData, FileEventType, FileResponse, file_type},
};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::Arc,
    time::Duration,
};

const PAGE_SIZE: i32 = 200;
const DIRECTORY_DELAY: Duration = Duration::from_millis(20);

fn canonical_uri(uri: &str) -> String {
    urlencoding::decode(uri)
        .map(|decoded| decoded.into_owned())
        .unwrap_or_else(|_| uri.to_string())
        .trim_end_matches('/')
        .to_string()
}

fn parent_uri(uri: &str) -> String {
    let uri = canonical_uri(uri);
    uri.rsplit_once('/')
        .map(|(parent, _)| parent.to_string())
        .unwrap_or_default()
}

fn ignored(name: &str) -> bool {
    name == ".DS_Store" || name == "Icon\r" || name.starts_with("._")
}

fn version(file: &FileResponse) -> String {
    format!("{}:{}:{}:{}", file.updated_at, file.size, file.file_type, file.primary_entity.as_deref().unwrap_or(""))
}

fn is_received_share(file: &FileResponse) -> bool {
    file.metadata
        .as_ref()
        .and_then(|metadata| metadata.get("sys:shared_redirect"))
        .is_some()
}

impl Mount {
    /// Query changes since the durable server-time checkpoint. Full traversal
    /// is reserved for the explicit Full check action in Settings.
    pub async fn schedule_fileprovider_recovery(self: &Arc<Self>) {
        self.schedule_recovery(false).await;
    }

    pub async fn schedule_fileprovider_full_recovery(self: &Arc<Self>) {
        self.schedule_recovery(true).await;
    }

    async fn schedule_recovery(self: &Arc<Self>, full: bool) {
        let mut slot = self.fileprovider_audit_handle.lock().await;
        if full {
            self.fileprovider_full_recovery_requested.store(true, std::sync::atomic::Ordering::Release);
        }
        if slot.as_ref().is_some_and(|handle| !handle.is_finished()) {
            // A new gap can affect a directory already visited by this pass.
            self.fileprovider_recovery_pending.store(true, std::sync::atomic::Ordering::Release);
            tracing::debug!(target: "fileprovider_audit", id=%self.id, "Queued another recovery pass");
            return;
        }
        self.report_recovery("checking", 0, 0, None);
        let mount = Arc::clone(self);
        *slot = Some(tokio::spawn(async move {
            let mut delay = 2;
            let mut refresh_presented = true;
            loop {
                let full = mount.fileprovider_full_recovery_requested.swap(false, std::sync::atomic::Ordering::AcqRel);
                let result = async {
                    // A failed server query must not add another folder refresh
                    // on every retry. Finder has already received this request.
                    if !full && refresh_presented {
                        crate::fileprovider::append_presented_refresh(&mount.id)?;
                        let config = mount.config.read().await;
                        signal_changes(&config.id, &config.name);
                        refresh_presented = false;
                    }
                    if full { mount.run_fileprovider_full_recovery().await }
                    else { mount.run_fileprovider_recovery().await }
                }.await;
                match result {
                    Ok(()) => {
                        let mut slot = mount.fileprovider_audit_handle.lock().await;
                        if mount.fileprovider_recovery_pending.swap(false, std::sync::atomic::Ordering::AcqRel) {
                            delay = 2;
                            refresh_presented = true;
                            continue;
                        }
                        // Clear while locked so a concurrent reconnect either
                        // queues a pass above or starts a new worker.
                        slot.take();
                        break;
                    },
                    Err(error) => {
                        if full { mount.fileprovider_full_recovery_requested.store(true, std::sync::atomic::Ordering::Release); }
                        tracing::warn!(target: "fileprovider_audit", id=%mount.id, %error, delay, "File Provider recovery will retry automatically");
                        mount.report_recovery("retrying", 0, 0, Some(format!("{error:#}")));
                        tokio::time::sleep(Duration::from_secs(delay)).await;
                        delay = (delay * 2).min(60);
                    }
                }
            }
        }));
    }

    fn report_recovery(&self, phase: &str, items: usize, folders: usize, error: Option<String>) {
        self.report_recovery_status(phase, items, folders, error, None);
    }

    fn report_completed_recovery(&self, items: usize, folders: usize) -> Result<()> {
        let target = crate::fileprovider_db::StateDb::open()?.latest_event_sequence(&self.id)?;
        self.report_recovery_status("completed", items, folders, None, Some(target));
        Ok(())
    }

    fn report_recovery_status(&self, phase: &str, items: usize, folders: usize, error: Option<String>, target_sequence: Option<i64>) {
        crate::fileprovider::write_recovery_status(&self.id, &crate::fileprovider::RecoveryStatus {
            phase: phase.into(), items_checked: items, folders_checked: folders,
            updated_at: chrono::Utc::now().timestamp_millis(), last_completed_at: None, error, target_sequence, folder_progress: None,
        });
    }

    async fn run_fileprovider_recovery(&self) -> Result<()> {
        self.report_recovery("checking", 0, 0, None);
        let (drive_id, drive_name, root_uri) = {
            let config = self.config.read().await;
            (config.id.clone(), config.name.clone(), config.remote_path.clone())
        };
        self.inventory.deliver_fileprovider_outbox(&drive_id)?;
        let started = self.cr_client.server_time().await?;
        let checkpoint = read_checkpoint(&drive_id)?;
        let since = if let Some(checkpoint) = checkpoint {
            ensure!(checkpoint.root_uri == root_uri, "The drive path changed. Run Full check in Settings to establish a new baseline.");
            checkpoint.since.min(started.saturating_sub(SEARCH_OVERLAP_SECONDS))
        } else {
            // Migrate the earlier inventory's oldest observation, translating
            // local elapsed time into server time. A new drive starts now and
            // obtains existing metadata through normal Finder enumeration.
            let previous = self.inventory.fileprovider_oldest_observation(&drive_id)?;
            let elapsed = previous.map(|time| (chrono::Utc::now().timestamp_millis() - time).max(0) / 1000).unwrap_or(0);
            let since = started.saturating_sub(elapsed).saturating_sub(SEARCH_OVERLAP_SECONDS).max(1);
            // Persist the initial lower bound before any search so retries after
            // a failed first pass cannot skip the original interval.
            write_checkpoint(&drive_id, &root_uri, since)?;
            since
        };
        tracing::info!(target: "fileprovider_audit", id=%drive_id, since, "Searching for remote changes");
        let mut checked = 0;
        for field in ["updated", "created"] {
            let uri = incremental_search_uri(&root_uri, field, since)?;
            let mut page = None;
            let mut tokens = HashSet::new();
            loop {
                let response = self.cr_client.list_files_all(page.as_ref(), &uri, PAGE_SIZE).await?;
                ensure!(response.res.recursion_limit_reached != Some(true),
                    "The server limited the change search. Run Full check in Settings to check the remaining folders.");
                // Fail visibly if an older server ignores the search predicate.
                for file in &response.res.files {
                    let timestamp = if field == "updated" { &file.updated_at } else { &file.created_at };
                    let timestamp = chrono::DateTime::parse_from_rfc3339(timestamp)
                        .context("The server returned an invalid file timestamp")?.timestamp();
                    ensure!(timestamp >= since, "The server did not apply the change search. Use Full check in Settings.");
                }
                let files = response.res.files.iter().filter(|file| !ignored(&file.name)).collect::<Vec<_>>();
                let previous = self.inventory.fileprovider_remote_items_by_ids(
                    &drive_id, &files.iter().map(|file| file.id.clone()).collect::<Vec<_>>(),
                )?.into_iter().map(|item| (item.remote_id.clone(), item)).collect::<HashMap<_, _>>();
                let mut rows = Vec::new();
                let mut events = Vec::new();
                for file in files {
                    let uri = canonical_uri(&file.path);
                    let item_version = version(file);
                    let old = previous.get(&file.id);
                    if let Some(event) = incremental_event(file, old) { events.push(event); }
                    rows.push(NewFileProviderRemoteItem {
                        drive_id: drive_id.clone(), remote_id: file.id.clone(),
                        parent_uri: parent_uri(&uri), uri, is_folder: file.file_type == file_type::FOLDER,
                        version: item_version, seen_generation: chrono::Utc::now().timestamp_millis(),
                    });
                    checked += 1;
                }
                self.inventory.upsert_fileprovider_remote_items_with_events(&rows, &events)?;
                self.inventory.deliver_fileprovider_outbox(&drive_id)?;
                if !events.is_empty() { signal_changes(&drive_id, &drive_name); }
                self.report_recovery("checking", checked, 0, None);
                if !response.more { break; }
                if let Some(token) = &response.res.pagination.next_token {
                    ensure!(tokens.insert(token.clone()), "The server repeated a search page. The check will retry.");
                }
                page = Some(response);
            }
        }
        // Search absence is never a deletion. Reconcile recently used Finder
        // folders separately, without walking the account or pinned subtrees.
        // Advance only after both searches and all durable deliveries succeed.
        // Overlap reduces timestamp boundary gaps. Search pagination is not a
        // snapshot and cannot replace directory reconciliation under mutation.
        write_checkpoint(&drive_id, &root_uri, started.saturating_sub(SEARCH_OVERLAP_SECONDS).max(1))?;
        self.report_completed_recovery(checked, 0)?;
        tracing::info!(target: "fileprovider_audit", id=%drive_id, checked, "Remote change search completed, waiting for Finder delivery");
        Ok(())
    }

    async fn run_fileprovider_full_recovery(&self) -> Result<()> {
        self.report_recovery("checking", 0, 0, None);
        let (drive_id, drive_name, root_uri) = {
            let config = self.config.read().await;
            (
                config.id.clone(),
                config.name.clone(),
                canonical_uri(&config.remote_path),
            )
        };
        let generation = chrono::Utc::now().timestamp_millis();
        self.inventory.deliver_fileprovider_outbox(&drive_id)?;
        signal_changes(&drive_id, &drive_name);
        let previous = self
            .inventory
            .fileprovider_remote_items(&drive_id)?
            .into_iter()
            .map(|item| (item.remote_id.clone(), item))
            .collect::<HashMap<_, _>>();
        // An empty inventory means this is the first audit after installing a
        // version with persistent recovery state.  The remote tree is a
        // baseline, not thousands of newly-created Finder items.  Visible
        // folders are reconciled separately when the SSE stream reconnects;
        // subsequent audits can then emit precise deltas against this
        // snapshot.
        let establishing_baseline = previous.is_empty();

        let server_started = self.cr_client.server_time().await.ok();
        tracing::info!(target: "fileprovider_audit", id=%drive_id, known=previous.len(), "Starting metadata-only File Provider recovery audit");
        let mut queue = VecDeque::from([root_uri]);
        let mut visited = HashSet::new();
        let mut events = Vec::new();
        let mut seen = 0usize;

        while let Some(directory) = queue.pop_front() {
            if !visited.insert(directory.clone()) {
                continue;
            }
            let mut page = None;
            loop {
                let response = self
                    .cr_client
                    .list_files_all(page.as_ref(), &directory, PAGE_SIZE)
                    .await
                    .with_context(|| format!("could not list {directory}"))?;
                let more = response.more;
                let files = response.res.files.clone();
                let mut rows = Vec::with_capacity(files.len());
                for file in files.into_iter().filter(|file| !ignored(&file.name)) {
                    let uri = canonical_uri(&file.path);
                    let item_version = version(&file);
                    let old = previous.get(&file.id);
                    let event_type = match old {
                        None => Some(FileEventType::Create),
                        Some(old) if canonical_uri(&old.uri) != uri => Some(FileEventType::Rename),
                        Some(old) if old.version != item_version => Some(FileEventType::Modify),
                        _ => None,
                    };
                    if !establishing_baseline && let Some(event_type) = event_type {
                        events.push(FileEventData {
                            event_type,
                            file_id: file.id.clone(),
                            from: old
                                .map(|item| canonical_uri(&item.uri))
                                .unwrap_or_else(|| uri.clone()),
                            to: if event_type == FileEventType::Rename {
                                uri.clone()
                            } else {
                                String::new()
                            },
                        });
                    }
                    rows.push(NewFileProviderRemoteItem {
                        drive_id: drive_id.clone(),
                        remote_id: file.id.clone(),
                        uri: uri.clone(),
                        parent_uri: parent_uri(&uri),
                        is_folder: file.file_type == file_type::FOLDER,
                        version: item_version,
                        seen_generation: generation,
                    });
                    if file.file_type == file_type::FOLDER && !is_received_share(&file) {
                        queue.push_back(uri);
                    }
                    seen += 1;
                }
                let records = events
                    .drain(..)
                    .map(|event| crate::fileprovider::FpEventRecord {
                        ts: 0,
                        event_type: format!("{:?}", event.event_type).to_lowercase(),
                        from: event.from,
                        to: event.to,
                        local_echo: false,
                        file_id: event.file_id.clone(),
                    })
                    .collect::<Vec<_>>();
                self.inventory
                    .upsert_fileprovider_remote_items_with_events(&rows, &records)?;
                self.inventory.deliver_fileprovider_outbox(&drive_id)?;
                if !records.is_empty() {
                    signal_changes(&drive_id, &drive_name);
                }
                self.report_recovery("checking", seen, visited.len(), None);
                if !more {
                    break;
                }
                page = Some(response);
            }
            tokio::time::sleep(DIRECTORY_DELAY).await;
        }

        self.inventory
            .finish_fileprovider_remote_generation(&drive_id, generation)?;
        self.inventory.deliver_fileprovider_outbox(&drive_id)?;
        signal_changes(&drive_id, &drive_name);
        crate::fileprovider::append_rescan_marker(&drive_id)?;
        signal_changes(&drive_id, &drive_name);
        let raw_root = self.config.read().await.remote_path.clone();
        if let Some(server_started) = server_started {
            write_checkpoint(&drive_id, &raw_root, server_started.saturating_sub(SEARCH_OVERLAP_SECONDS).max(1))?;
        }
        self.report_completed_recovery(seen, visited.len())?;
        tracing::info!(target: "fileprovider_audit", id=%drive_id, seen, "Metadata-only File Provider recovery audit completed");
        Ok(())
    }
}

const SEARCH_OVERLAP_SECONDS: i64 = 120;

#[derive(serde::Serialize, serde::Deserialize)]
struct RecoveryCheckpoint { root_uri: String, since: i64 }

fn read_checkpoint(drive: &str) -> Result<Option<RecoveryCheckpoint>> {
    crate::fileprovider_db::StateDb::open()?.records("fp-search-checkpoint")?
        .into_iter().find(|record| record.key == drive)
        .map(|record| serde_json::from_str(&record.payload).map_err(Into::into)).transpose()
}

fn write_checkpoint(drive: &str, root: &str, since: i64) -> Result<()> {
    crate::fileprovider_db::StateDb::open()?.put("fp-search-checkpoint", drive,
        &serde_json::to_string(&RecoveryCheckpoint { root_uri: root.into(), since })?)
}

fn incremental_search_uri(root: &str, field: &str, since: i64) -> Result<String> {
    ensure!(matches!(field, "updated" | "created"), "Invalid change-search field");
    let mut uri = url::Url::parse(root)?;
    ensure!(uri.query().is_none(), "Change search requires a folder, not a saved search");
    uri.query_pairs_mut().append_pair(&format!("{field}_gte"), &since.max(1).to_string());
    Ok(uri.to_string())
}

fn incremental_event(file: &FileResponse, old: Option<&FileProviderRemoteItem>) -> Option<crate::fileprovider::FpEventRecord> {
    let uri = canonical_uri(&file.path);
    let kind = match old {
        Some(old) if canonical_uri(&old.uri) != uri => "rename",
        Some(old) if old.version == version(file) => return None,
        _ => "modify", // Unknown items may already exist in Finder after migration.
    };
    Some(crate::fileprovider::FpEventRecord {
        ts: 0, event_type: kind.into(),
        from: if kind == "rename" { old.unwrap().uri.clone() } else { uri.clone() },
        to: if kind == "rename" { uri } else { String::new() }, local_echo: false, file_id: file.id.clone(),
    })
}

fn signal_changes(drive_id: &str, drive_name: &str) {
    crate::fileprovider::signal_containers(
        &crate::fileprovider::domain_identifier(drive_id),
        drive_name,
        &[crate::fileprovider::WORKING_SET_CONTAINER.to_string()],
    );
}

/// Reporting a missing folder removes its descendants too, so avoid sending
/// redundant child deletions that can confuse File Provider ordering.
pub(crate) fn collapse_missing_items(
    mut items: Vec<FileProviderRemoteItem>,
) -> Vec<FileProviderRemoteItem> {
    items.sort_by_key(|item| item.uri.matches('/').count());
    let mut roots: Vec<FileProviderRemoteItem> = Vec::new();
    for item in items {
        if roots.iter().any(|root| {
            root.is_folder
                && canonical_uri(&item.uri).starts_with(&(canonical_uri(&root.uri) + "/"))
        }) {
            continue;
        }
        roots.push(item);
    }
    roots
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn change_search_preserves_scope_and_escaped_names() {
        let uri = incremental_search_uri("cloudreve://my/A%20folder%3F", "updated", 1234).unwrap();
        let parsed = url::Url::parse(&uri).unwrap();
        assert_eq!(parsed.path(), "/A%20folder%3F");
        assert_eq!(parsed.query(), Some("updated_gte=1234"));
        assert!(incremental_search_uri("cloudreve://my?name=test", "updated", 1234).is_err());
        assert!(incremental_search_uri("cloudreve://my", "deleted", 1234).is_err());
    }

    #[test]
    fn incremental_comparison_detects_moves_and_content_entity_changes() {
        let mut file = FileResponse { id: "item".into(), path: "cloudreve://my/file".into(),
            updated_at: "2026-10-19T12:00:00Z".into(), primary_entity: Some("entity1".into()), ..Default::default() };
        let old = FileProviderRemoteItem { drive_id: "drive".into(), remote_id: file.id.clone(),
            uri: file.path.clone(), parent_uri: "cloudreve://my".into(), is_folder: false,
            version: version(&file), seen_generation: 1 };
        assert!(incremental_event(&file, Some(&old)).is_none());
        // Same size and timestamp, different server content identity.
        file.primary_entity = Some("entity2".into());
        assert_eq!(incremental_event(&file, Some(&old)).unwrap().event_type, "modify");
        file.path = "cloudreve://my/moved/file".into();
        let event = incremental_event(&file, Some(&old)).unwrap();
        assert_eq!(event.event_type, "rename");
        assert_eq!(event.from, old.uri);
        assert_eq!(event.to, file.path);
        // An item absent from our inventory may already exist in Finder.
        assert_eq!(incremental_event(&file, None).unwrap().event_type, "modify");
    }

    #[test]
    fn collapses_children_of_missing_folders() {
        let item = |id: &str, uri: &str, is_folder: bool| FileProviderRemoteItem {
            drive_id: "drive".into(),
            remote_id: id.into(),
            uri: uri.into(),
            parent_uri: parent_uri(uri),
            is_folder,
            version: "v".into(),
            seen_generation: 1,
        };
        let result = collapse_missing_items(vec![
            item("child", "cloudreve://my/folder/file.txt", false),
            item("folder", "cloudreve://my/folder", true),
            item("other", "cloudreve://my/other.txt", false),
        ]);
        assert_eq!(
            result
                .iter()
                .map(|item| item.remote_id.as_str())
                .collect::<Vec<_>>(),
            ["folder", "other"]
        );
    }

    #[test]
    fn received_share_shortcuts_are_not_recursively_audited() {
        let mut file = FileResponse::default();
        file.metadata = Some(HashMap::from([(
            "sys:shared_redirect".into(),
            "cloudreve://user/root".into(),
        )]));
        assert!(is_received_share(&file));
    }
}
