use crate::drive::mounts::Mount;
#[cfg(not(target_os = "macos"))]
use crate::{
    cfapi::placeholder::LocalFileInfo,
    drive::{commands::MountCommand, sync::SyncMode},
};
#[cfg(not(target_os = "macos"))]
use anyhow::Context;
use anyhow::Result;
#[cfg(target_os = "macos")]
use cloudreve_api::api::explorer::ExplorerApi;
#[cfg(not(target_os = "macos"))]
use cloudreve_api::api::explorer::FileEventsApi;
#[cfg(target_os = "macos")]
use cloudreve_api::models::explorer::file_type;
use cloudreve_api::models::explorer::{FileEvent, FileEventData, FileEventType};
#[cfg(target_os = "macos")]
use std::collections::HashSet;
#[cfg(not(target_os = "macos"))]
use std::{collections::HashMap, path::Path};
use std::{path::PathBuf, sync::Arc, time::Duration};

const INITIAL_BACKOFF_SECS: u64 = 1;
const MAX_BACKOFF_SECS: u64 = 32;
const EVENT_STREAM_IDLE_TIMEOUT_SECS: u64 = 90;
const HEALTHY_STREAM_SECS: u64 = 60;
#[cfg(target_os = "macos")]
const EVENT_BATCH_COMMIT_ATTEMPTS: u32 = 5;
#[cfg(target_os = "macos")]
const EVENT_VERIFY_CONCURRENCY: usize = 8;
#[cfg(target_os = "macos")]
const EVENT_VERIFY_ATTEMPTS: u32 = 3;

#[cfg(target_os = "macos")]
const PUSH_HEALTH_NAMESPACE: &str = "fp-push-health";
#[cfg(target_os = "macos")]
const FINDER_ACTIVITY_NAMESPACE: &str = "fp-finder-activity";
#[cfg(target_os = "macos")]
const FALLBACK_TICK_SECS: u64 = 60;
#[cfg(target_os = "macos")]
const FALLBACK_WINDOW_MS: i64 = 3_600_000;

/// Persisted degraded-mode state, one row per drive.
#[cfg(target_os = "macos")]
#[derive(serde::Serialize, serde::Deserialize)]
struct PushHealthRecord {
    degraded_since: i64,
    reason: String,
    #[serde(default)]
    passes: Vec<i64>,
}

/// Heartbeat row written by the File Provider extension.
#[cfg(target_os = "macos")]
#[derive(serde::Deserialize)]
struct FinderActivity {
    at: i64,
}

#[cfg(target_os = "macos")]
fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(target_os = "macos")]
fn reason_name(reason: crate::drive::push_health::DegradedReason) -> &'static str {
    use crate::drive::push_health::DegradedReason;
    match reason {
        DegradedReason::Unsupported => "unsupported",
        DegradedReason::Flapping => "flapping",
        DegradedReason::Buffered => "buffered",
    }
}

#[cfg(target_os = "macos")]
fn parse_reason(name: &str) -> crate::drive::push_health::DegradedReason {
    use crate::drive::push_health::DegradedReason;
    match name {
        "flapping" => DegradedReason::Flapping,
        "buffered" => DegradedReason::Buffered,
        _ => DegradedReason::Unsupported,
    }
}

#[cfg(target_os = "macos")]
async fn write_push_health_record(drive_id: String, record: PushHealthRecord) -> Result<()> {
    crate::fileprovider_db::run_blocking(move || {
        let payload = serde_json::to_string(&record)?;
        crate::fileprovider_db::StateDb::open()?.put(PUSH_HEALTH_NAMESPACE, &drive_id, &payload)
    })
    .await
}

#[cfg(target_os = "macos")]
async fn read_push_health_record(drive_id: String) -> Result<Option<PushHealthRecord>> {
    crate::fileprovider_db::run_blocking(move || {
        let mut db = crate::fileprovider_db::StateDb::open()?;
        Ok(db
            .records(PUSH_HEALTH_NAMESPACE)?
            .into_iter()
            .find(|row| row.key == drive_id)
            .and_then(|row| serde_json::from_str::<PushHealthRecord>(&row.payload).ok()))
    })
    .await
}

/// Outcome of asking the server whether an event's path exists.
#[cfg(target_os = "macos")]
enum EventVerification {
    Exists(cloudreve_api::models::explorer::FileResponse),
    /// The server definitively answered that the path does not exist.
    Gone,
    /// The question could not be answered after retries.
    Unverified,
}

/// Cloudreve answers a missing path with HTTP 200 and code 40016 (verified
/// against a live 4.19 server); 404 is accepted for other deployments.
#[cfg(target_os = "macos")]
fn is_path_missing(error: &cloudreve_api::ApiError) -> bool {
    matches!(
        error,
        cloudreve_api::ApiError::ApiError { code, .. } if *code == 40016 || *code == 404
    )
}

/// A stream that stayed up for a while starts a fresh retry sequence; a
/// stream that ended quickly keeps backing off. Every resubscribe waits.
fn reconnect_delay(backoff: &mut BackoffState, connected_for: Duration) -> Duration {
    if connected_for >= Duration::from_secs(HEALTHY_STREAM_SECS) {
        backoff.reset();
    }
    backoff.next_delay()
}

#[cfg(target_os = "macos")]
fn should_retry_batch(attempt: u32) -> bool {
    attempt < EVENT_BATCH_COMMIT_ATTEMPTS
}

/// Delay after a listener error. Only a stream that stayed up long enough
/// starts a fresh retry sequence; a subscribe that dies quickly keeps backing off.
fn error_delay(backoff: &mut BackoffState, was_connected: bool, connected_for: Duration) -> Duration {
    if was_connected {
        reconnect_delay(backoff, connected_for)
    } else {
        backoff.next_delay()
    }
}

struct BackoffState {
    retry_count: u32,
    current_delay: Duration,
}

impl BackoffState {
    fn new() -> Self {
        Self {
            retry_count: 0,
            current_delay: Duration::from_secs(INITIAL_BACKOFF_SECS),
        }
    }

    fn reset(&mut self) {
        self.retry_count = 0;
        self.current_delay = Duration::from_secs(INITIAL_BACKOFF_SECS);
    }

    fn next_delay(&mut self) -> Duration {
        let delay = self.current_delay;
        self.retry_count += 1;
        self.current_delay =
            Duration::from_secs((self.current_delay.as_secs() * 2).min(MAX_BACKOFF_SECS));
        delay
    }
}

enum ListenResult {
    Error {
        error: anyhow::Error,
        was_connected: bool,
        /// `(http status, envelope code)` when the server answered the
        /// subscribe request over HTTP without upgrading to SSE.
        #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
        not_upgraded: Option<(Option<u16>, i32)>,
    },
    ReconnectRequired,
    /// The stream stayed silent before any `subscribed` event arrived.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    IdleBeforeSubscribed,
    StreamEnded,
}

impl Mount {
    pub async fn process_remote_events(s: Arc<Self>) {
        tracing::info!(target: "drive::remote_events", "Listening to remote events");
        let mut backoff = BackoffState::new();
        #[cfg(target_os = "macos")]
        let mut probe_attempt: u32 = 0;
        #[cfg(target_os = "macos")]
        s.restore_push_health().await;

        loop {
            let started = std::time::Instant::now();
            let result = s.listen_remote_events().await;
            #[cfg(target_os = "macos")]
            {
                use crate::drive::push_health::Observation;
                let observation = match &result {
                    ListenResult::Error {
                        not_upgraded: Some((status, code)),
                        ..
                    } => Observation::NotUpgraded {
                        status: *status,
                        code: *code,
                    },
                    ListenResult::Error {
                        was_connected: true,
                        ..
                    }
                    | ListenResult::ReconnectRequired
                    | ListenResult::StreamEnded => Observation::StreamLost {
                        connected_for: started.elapsed(),
                    },
                    ListenResult::IdleBeforeSubscribed => Observation::IdleBeforeSubscribed,
                    ListenResult::Error { .. } => Observation::OtherFailure,
                };
                s.on_push_observation(observation).await;
            }
            let delay = match result {
                ListenResult::ReconnectRequired | ListenResult::IdleBeforeSubscribed => {
                    let delay = reconnect_delay(&mut backoff, started.elapsed());
                    tracing::info!(target: "drive::remote_events", delay_secs = delay.as_secs(), "Reconnect required, re-subscribing after delay");
                    delay
                }
                ListenResult::StreamEnded => {
                    let delay = reconnect_delay(&mut backoff, started.elapsed());
                    tracing::warn!(target: "drive::remote_events", delay_secs = delay.as_secs(), "Event stream ended unexpectedly, reconnecting after delay");
                    delay
                }
                ListenResult::Error {
                    error: e,
                    was_connected,
                    ..
                } => {
                    let delay = error_delay(&mut backoff, was_connected, started.elapsed());
                    tracing::error!(
                        target: "drive::remote_events",
                        error = %e,
                        retry_count = backoff.retry_count,
                        delay_secs = delay.as_secs(),
                        "Failed to listen to remote events, retrying"
                    );
                    delay
                }
            };
            // While live events are unavailable, probe on a slow jittered
            // schedule instead of hammering the server.
            #[cfg(target_os = "macos")]
            let delay = {
                use crate::drive::push_health::{PushState, probe_delay};
                if s.push_health.lock().await.state() == PushState::Degraded {
                    let jitter = f64::from(uuid::Uuid::new_v4().as_bytes()[0]) / 127.5 - 1.0;
                    let delay = probe_delay(probe_attempt, jitter);
                    probe_attempt = probe_attempt.saturating_add(1);
                    tracing::info!(target: "drive::remote_events", delay_secs = delay.as_secs(), "Live updates unavailable, probing again after delay");
                    delay
                } else {
                    probe_attempt = 0;
                    delay
                }
            };
            tokio::time::sleep(delay).await;
        }
    }

    async fn listen_remote_events(self: &Arc<Self>) -> ListenResult {
        let (remote_base, sync_path) = {
            let config = self.config.read().await;
            (config.remote_path.clone(), config.sync_path.clone())
        };

        // macOS: a fresh ID avoids sharing the previous handler's subscription
        // state during overlapping reconnects. A delayed old handler can mark a
        // reused subscriber offline while the new connection still heartbeats.
        // This forgoes best-effort replay, so subscribe always schedules recovery.
        // Neither SSE replay nor timestamp searches prove complete continuity.
        #[cfg(target_os = "macos")]
        let subscription = self
            .cr_client
            .subscribe_file_events_with_client_id(&remote_base, &uuid::Uuid::new_v4().to_string())
            .await;
        #[cfg(not(target_os = "macos"))]
        let subscription = self.cr_client.subscribe_file_events(&remote_base).await;

        let mut subscription = match subscription {
            Ok(sub) => sub,
            Err(e) => {
                let not_upgraded = match &e {
                    cloudreve_api::ApiError::SseNotUpgraded { code, status, .. } => {
                        Some((*status, *code))
                    }
                    _ => None,
                };
                return ListenResult::Error {
                    error: e.into(),
                    was_connected: false,
                    not_upgraded,
                };
            }
        };
        let mut was_connected = false;
        let idle_timeout = Duration::from_secs(EVENT_STREAM_IDLE_TIMEOUT_SECS);
        let mut last_activity = std::time::Instant::now();
        #[cfg(target_os = "macos")]
        let mut subscribed_at: Option<std::time::Instant> = None;
        #[cfg(target_os = "macos")]
        let mut healthy_reported = false;

        loop {
            let wait = idle_timeout.saturating_sub(last_activity.elapsed());
            #[cfg(target_os = "macos")]
            let wait = match subscribed_at {
                Some(at) if !healthy_reported => {
                    wait.min(Duration::from_secs(HEALTHY_STREAM_SECS).saturating_sub(at.elapsed()))
                }
                _ => wait,
            };
            let next_event = tokio::time::timeout(wait, subscription.next_event()).await;
            if next_event.is_ok() {
                last_activity = std::time::Instant::now();
            }

            match next_event {
                Err(_) => {
                    if last_activity.elapsed() < idle_timeout {
                        // Woke for the stream-health deadline, not for silence.
                        #[cfg(target_os = "macos")]
                        if let Some(at) = subscribed_at {
                            if !healthy_reported
                                && at.elapsed() >= Duration::from_secs(HEALTHY_STREAM_SECS)
                            {
                                healthy_reported = true;
                                // Report subscribed before the health change so a
                                // recovered drive never shows as disconnected.
                                self.set_event_push_subscribed(true).await;
                                self.on_push_observation(
                                    crate::drive::push_health::Observation::StreamHealthy,
                                )
                                .await;
                            }
                        }
                        continue;
                    }
                    tracing::warn!(
                        target: "drive::remote_events",
                        idle_secs = EVENT_STREAM_IDLE_TIMEOUT_SECS,
                        "Event stream became idle, reconnecting"
                    );
                    self.set_event_push_subscribed(false).await;
                    #[cfg(target_os = "macos")]
                    if !was_connected {
                        return ListenResult::IdleBeforeSubscribed;
                    }
                    return ListenResult::ReconnectRequired;
                }
                Ok(Ok(Some(event))) => match event {
                    FileEvent::Event(events) => {
                        tracing::trace!(target: "drive::remote_events", events = ?events, "Handling file events batch");
                        #[cfg(target_os = "macos")]
                        {
                            let mut retry = BackoffState::new();
                            let mut attempt = 0u32;
                            loop {
                                attempt += 1;
                                match self.handle_file_events(sync_path.clone(), events.clone()).await {
                                    Ok(()) => break,
                                    Err(error) if should_retry_batch(attempt) => {
                                        tracing::warn!(target: "drive::remote_events", %error, attempt, "Retrying uncommitted File Provider events");
                                        tokio::time::sleep(retry.next_delay()).await;
                                    }
                                    Err(error) => {
                                        tracing::error!(target: "drive::remote_events", %error, attempts = EVENT_BATCH_COMMIT_ATTEMPTS, "Abandoning File Provider event batch; reconnecting to recover");
                                        let drive_id_for_marker = self.config.read().await.id.clone();
                                        let _ = crate::fileprovider_db::run_blocking(move || {
                                            crate::fileprovider::append_rescan_marker(
                                                &drive_id_for_marker,
                                            )
                                        })
                                        .await;
                                        self.set_event_push_subscribed(false).await;
                                        return ListenResult::Error {
                                            error: error.context("File Provider events could not be committed"),
                                            was_connected,
                                            not_upgraded: None,
                                        };
                                    }
                                }
                            }
                        }
                        #[cfg(not(target_os = "macos"))]
                        if let Err(e) = self.handle_file_events(sync_path.clone(), events).await {
                            tracing::error!(target: "drive::remote_events", error = ?e, "Failed to handle file events");
                        }
                    }
                    FileEvent::Resumed => {
                        was_connected = true;
                        self.mark_event_push_subscribed().await;
                        tracing::debug!(target: "drive::remote_events", "Subscription resumed");
                        #[cfg(target_os = "macos")]
                        {
                            subscribed_at = Some(std::time::Instant::now());
                            healthy_reported = false;
                            self.on_push_observation(crate::drive::push_health::Observation::Subscribed)
                                .await;
                            self.record_rescan_marker().await;
                        }
                    }
                    FileEvent::Subscribed => {
                        was_connected = true;
                        self.mark_event_push_subscribed().await;
                        #[cfg(target_os = "macos")]
                        {
                            subscribed_at = Some(std::time::Instant::now());
                            healthy_reported = false;
                            self.on_push_observation(crate::drive::push_health::Observation::Subscribed)
                                .await;
                        }
                        tracing::info!(target: "drive::remote_events", "New subscription established, scheduling recovery");
                        #[cfg(target_os = "macos")]
                        {
                            self.record_rescan_marker().await;
                        }
                        #[cfg(not(target_os = "macos"))]
                        {
                            let _ = self.command_tx.send(MountCommand::Sync {
                                local_paths: vec![sync_path.clone()],
                                mode: SyncMode::FullHierarchy,
                                user_initiated: false,
                            });
                        }
                    }
                    FileEvent::KeepAlive => {
                        tracing::trace!(target: "drive::remote_events", "Keep-alive");
                    }
                    FileEvent::ReconnectRequired => {
                        tracing::debug!(target: "drive::remote_events", "Reconnect required");
                        self.set_event_push_subscribed(false).await;
                        return ListenResult::ReconnectRequired;
                    }
                },
                Ok(Ok(None)) => {
                    self.set_event_push_subscribed(false).await;
                    return ListenResult::StreamEnded;
                }
                Ok(Err(e)) => {
                    self.set_event_push_subscribed(false).await;
                    return ListenResult::Error {
                        error: e.into(),
                        was_connected,
                        not_upgraded: None,
                    };
                }
            }
        }
    }

    /// Mark the stream subscribed. While degraded, the drive keeps its
    /// degraded status until the stream proves healthy for 60 s; a short-lived
    /// subscribe must not flip the UI back to Active.
    async fn mark_event_push_subscribed(&self) {
        #[cfg(target_os = "macos")]
        if self.push_health.lock().await.state() == crate::drive::push_health::PushState::Degraded {
            return;
        }
        self.set_event_push_subscribed(true).await;
    }

    #[cfg(target_os = "macos")]
    async fn verify_event_path(&self, uri: String) -> EventVerification {
        let mut delay = Duration::from_millis(400);
        for attempt in 1..=EVENT_VERIFY_ATTEMPTS {
            let info = self
                .cr_client
                .get_file_info(&cloudreve_api::models::explorer::GetFileInfoService {
                    uri: Some(uri.clone()),
                    ..Default::default()
                })
                .await;
            match info {
                Ok(info) => return EventVerification::Exists(info),
                Err(error) if is_path_missing(&error) => return EventVerification::Gone,
                Err(error) => {
                    tracing::debug!(target: "drive::remote_events", %error, attempt, "Could not verify event path");
                    if attempt < EVENT_VERIFY_ATTEMPTS {
                        tokio::time::sleep(delay).await;
                        delay *= 3;
                    }
                }
            }
        }
        EventVerification::Unverified
    }

    /// Feed one observation to the push-health state machine and apply the
    /// resulting status flag and persisted record.
    #[cfg(target_os = "macos")]
    pub(crate) async fn on_push_observation(&self, observation: crate::drive::push_health::Observation) {
        use crate::drive::push_health::PushState;
        let now_ms = now_millis();
        let (previous, state, offline, reason) = {
            let mut health = self.push_health.lock().await;
            let previous = health.state();
            let state = health.observe(observation, now_ms);
            (previous, state, health.is_offline(), health.reason())
        };
        // Offline while degraded reads as disconnected, as it did before
        // degraded mode existed.
        self.set_event_push_degraded(state == PushState::Degraded && !offline)
            .await;

        let drive_id = self.config.read().await.id.clone();
        if previous != PushState::Degraded && state == PushState::Degraded {
            let reason = reason.map(reason_name).unwrap_or("unsupported");
            tracing::warn!(target: "drive::remote_events", drive = %drive_id, reason, "Live updates unavailable; using bounded refreshes while Finder is in use");
            let record = PushHealthRecord {
                degraded_since: now_ms,
                reason: reason.to_string(),
                passes: Vec::new(),
            };
            if let Err(error) = write_push_health_record(drive_id, record).await {
                tracing::warn!(target: "drive::remote_events", %error, "Could not persist degraded live-update state");
            }
        } else if previous == PushState::Degraded && state != PushState::Degraded {
            tracing::info!(target: "drive::remote_events", drive = %drive_id, "Live updates restored");
            let result = crate::fileprovider_db::run_blocking(move || {
                crate::fileprovider_db::StateDb::open()?.remove(PUSH_HEALTH_NAMESPACE, &drive_id)
            })
            .await;
            if let Err(error) = result {
                tracing::warn!(target: "drive::remote_events", %error, "Could not clear degraded live-update state");
            }
        }
    }

    /// Start in degraded mode when the previous run ended degraded.
    #[cfg(target_os = "macos")]
    async fn restore_push_health(&self) {
        let drive_id = self.config.read().await.id.clone();
        match read_push_health_record(drive_id).await {
            Ok(Some(record)) => {
                let reason = parse_reason(&record.reason);
                *self.push_health.lock().await = crate::drive::push_health::PushHealth::degraded(reason);
                self.set_event_push_degraded(true).await;
                tracing::info!(target: "drive::remote_events", reason = reason_name(reason), "Starting in degraded live-update mode");
            }
            Ok(None) => {}
            Err(error) => {
                tracing::warn!(target: "drive::remote_events", %error, "Could not read degraded live-update state");
            }
        }
    }

    /// While live events are unavailable, run the bounded Finder refresh every
    /// few minutes, but only while Finder is actually being used.
    #[cfg(target_os = "macos")]
    pub(crate) async fn run_push_fallback(s: Arc<Self>) {
        use crate::drive::push_health::{PushState, fallback_pass_due};
        loop {
            tokio::time::sleep(Duration::from_secs(FALLBACK_TICK_SECS)).await;
            let (state, offline) = {
                let health = s.push_health.lock().await;
                (health.state(), health.is_offline())
            };
            if state != PushState::Degraded || offline {
                continue;
            }
            let drive_id = s.config.read().await.id.clone();
            let read_id = drive_id.clone();
            let loaded = crate::fileprovider_db::run_blocking(move || {
                let mut db = crate::fileprovider_db::StateDb::open()?;
                let activity = db
                    .records(FINDER_ACTIVITY_NAMESPACE)?
                    .into_iter()
                    .find(|row| row.key == read_id)
                    .and_then(|row| serde_json::from_str::<FinderActivity>(&row.payload).ok())
                    .map(|activity| activity.at);
                let record = db
                    .records(PUSH_HEALTH_NAMESPACE)?
                    .into_iter()
                    .find(|row| row.key == read_id)
                    .and_then(|row| serde_json::from_str::<PushHealthRecord>(&row.payload).ok());
                Ok((activity, record))
            })
            .await;
            let (activity, record) = match loaded {
                Ok(loaded) => loaded,
                Err(error) => {
                    tracing::warn!(target: "drive::remote_events", %error, "Could not read Finder activity");
                    continue;
                }
            };
            let now_ms = now_millis();
            let mut record = record.unwrap_or_else(|| PushHealthRecord {
                degraded_since: now_ms,
                reason: "unsupported".into(),
                passes: Vec::new(),
            });
            if !fallback_pass_due(state, now_ms, activity, &record.passes) {
                continue;
            }
            tracing::info!(target: "drive::remote_events", "Degraded live updates: running bounded refresh");
            s.schedule_fileprovider_recovery().await;
            if s.push_health.lock().await.state() != PushState::Degraded {
                continue;
            }
            record.passes.retain(|t| now_ms - *t < FALLBACK_WINDOW_MS);
            record.passes.push(now_ms);
            if let Err(error) = write_push_health_record(drive_id, record).await {
                tracing::warn!(target: "drive::remote_events", %error, "Could not record fallback refresh");
            }
        }
    }

    /// Refresh the File Provider after a remote event stream reconnects.
    #[cfg(target_os = "macos")]
    async fn record_rescan_marker(self: &Arc<Self>) {
        // The worker requests a bounded Finder refresh before searching for
        // server-side changes. Do not expire anchors on ordinary reconnects.
        self.schedule_fileprovider_recovery().await;
    }

    async fn handle_file_events(
        &self,
        sync_root: PathBuf,
        events: Vec<FileEventData>,
    ) -> Result<()> {
        // On macOS the File Provider extension owns the file view; instead of
        // writing to a local replica, record the events to a shared log the
        // extension replays from, then signal the domain so the system pulls
        // the changes.
        #[cfg(target_os = "macos")]
        {
            let _ = sync_root;
            let (drive_id, drive_name, remote_path) = {
                let config = self.config.read().await;
                (
                    config.id.clone(),
                    config.name.clone(),
                    config.remote_path.clone(),
                )
            };

            // Some server-side operations (notably trash restore) emit events
            // whose paths don't exist (e.g. internal storage UUIDs). Verify
            // create/modify events; bogus ones trigger a full rescan instead.
            let mut verified_events: Vec<&FileEventData> = Vec::new();
            let mut content_refresh_candidates = Vec::new();
            let mut local_upload_echo_paths = HashSet::new();
            let mut upload_receipts = Vec::new();
            let mut needs_rescan = false;
            let mut needs_presented_refresh = false;

            // Verify create/modify events with bounded concurrency. A large
            // upload from another device arrives as one batch; checking each
            // path serially left Finder unsignalled for ~25 ms per file.
            let verifications = {
                use futures::StreamExt;
                let jobs = events
                    .iter()
                    .map(|e| {
                        (
                            format!("{}{}", remote_path, e.from),
                            matches!(e.event_type, FileEventType::Create | FileEventType::Modify),
                        )
                    })
                    .collect::<Vec<_>>();
                futures::stream::iter(jobs)
                    .map(|(uri, checked)| async move {
                        if checked { Some(self.verify_event_path(uri).await) } else { None }
                    })
                    .buffered(EVENT_VERIFY_CONCURRENCY)
                    .collect::<Vec<_>>()
                    .await
            };
            for (e, verification) in events.iter().zip(verifications) {
                let uri = format!("{}{}", remote_path, e.from);
                match verification {
                    None => verified_events.push(e),
                    Some(EventVerification::Exists(info)) => {
                        let local_upload_echo = if info.file_type == file_type::FILE {
                            let (receipt_drive, receipt_uri) = (drive_id.clone(), uri.clone());
                            match crate::fileprovider_db::run_blocking(move || {
                                crate::fileprovider::matching_upload_receipt(
                                    &receipt_drive,
                                    &receipt_uri,
                                )
                            })
                            .await?
                            {
                                Some(receipt) => {
                                    upload_receipts.push(receipt);
                                    true
                                }
                                None => false,
                            }
                        } else {
                            false
                        };
                        if local_upload_echo {
                            local_upload_echo_paths.insert(e.from.clone());
                        } else if e.event_type == FileEventType::Modify
                            && info.file_type == file_type::FILE
                        {
                            content_refresh_candidates.push(format!("cloudreve-item:/{}", info.id));
                        }
                        verified_events.push(e);
                    }
                    // Trash restore reports a path that never existed. Only that
                    // definite answer needs the full reconciliation.
                    Some(EventVerification::Gone) => needs_rescan = true,
                    // The server could not be asked (offline, 5xx, rate limit).
                    // That says nothing about the path. Journal the event as
                    // received, since the extension re-reads metadata itself, and
                    // ask for the bounded folder refresh instead of expiring every
                    // sync anchor.
                    Some(EventVerification::Unverified) => {
                        needs_presented_refresh = true;
                        verified_events.push(e);
                    }
                }
            }

            let marker = if needs_rescan {
                Some(crate::fileprovider::journal_type::RESCAN)
            } else if needs_presented_refresh {
                Some(crate::fileprovider::journal_type::REFRESH_PRESENTED)
            } else {
                None
            };
            let events_to_log: Vec<FileEventData> =
                verified_events.iter().map(|e| (*e).clone()).collect();
            {
                let (drive, events, echoes, receipts) = (
                    drive_id.clone(),
                    events_to_log.clone(),
                    local_upload_echo_paths.clone(),
                    upload_receipts.clone(),
                );
                crate::fileprovider_db::run_blocking(move || {
                    crate::fileprovider::append_domain_events_with_marker(
                        &drive, marker, &events, &echoes, &receipts,
                    )
                })
                .await?;
            }
            if !events_to_log.is_empty() {
                {
                    for event in &events_to_log {
                        tracing::info!(
                            target: "drive::remote_events",
                            event_type = ?event.event_type,
                            from = %event.from,
                            to = %event.to,
                            "Recorded File Provider event"
                        );
                    }
                }
            }

            // Wake Finder immediately after the durable commit. Resolving local
            // URLs and materialized items below can take seconds per item.
            crate::fileprovider::signal_containers(
                &crate::fileprovider::domain_identifier(&drive_id), &drive_name,
                &[crate::fileprovider::WORKING_SET_CONTAINER.to_string()],
            );

            // Record activity so the tray popup's RECENT list reflects FP
            // sync. Paths point at the File Provider location.
            let fp_root = crate::fileprovider::user_visible_url(
                &crate::fileprovider::domain_identifier(&drive_id),
                &drive_name,
            )
            .await;
            let domain_id = crate::fileprovider::domain_identifier(&drive_id);
            let mut materialized_updates = Vec::new();
            for item_identifier in content_refresh_candidates {
                if let Some(local_path) = crate::fileprovider::user_visible_item_url(
                    &domain_id,
                    &drive_name,
                    &item_identifier,
                )
                .await
                {
                    if crate::fileprovider::is_materialized(&local_path) {
                        materialized_updates.push((item_identifier, local_path));
                    }
                }
            }
            for e in &events_to_log {
                if local_upload_echo_paths.contains(&e.from)
                    || (!e.to.is_empty() && local_upload_echo_paths.contains(&e.to))
                {
                    continue;
                }
                let rel = if e.to.is_empty() { &e.from } else { &e.to };
                if rel
                    .rsplit('/')
                    .next()
                    .map(|name| name == ".DS_Store" || name.starts_with("._"))
                    .unwrap_or(true)
                {
                    continue; // Finder metadata, not real activity
                }
                let local_path = match &fp_root {
                    Some(root) => format!(
                        "{}/{}",
                        root.trim_end_matches('/'),
                        rel.trim_start_matches('/')
                    ),
                    None => rel.clone(),
                };
                let activity_type = match e.event_type {
                    FileEventType::Create => "sync_create",
                    FileEventType::Modify => "sync_modify",
                    FileEventType::Rename => "sync_rename",
                    FileEventType::Delete => "sync_delete",
                };
                let mut record = crate::inventory::NewTaskRecord::new(
                    format!("fp-{}", uuid::Uuid::new_v4()),
                    drive_id.clone(),
                    activity_type,
                    local_path,
                );
                record.status = crate::inventory::TaskStatus::Completed;
                record.progress = 1.0;
                if let Err(err) = self.inventory.insert_task_if_not_exist(&record) {
                    tracing::warn!(target: "drive::remote_events", error = %err, "Failed to record FP activity");
                }
            }

            tracing::info!(
                target: "drive::remote_events",
                id = %drive_id,
                count = events.len(),
                "Signaling File Provider working set for remote changes"
            );
            crate::fileprovider::signal_containers(
                &domain_id,
                &drive_name,
                &[crate::fileprovider::WORKING_SET_CONTAINER.to_string()],
            );
            for (item_identifier, local_path) in materialized_updates {
                tokio::spawn(
                    crate::fileprovider::refresh_materialized_item_after_remote_update(
                        domain_id.clone(),
                        item_identifier,
                        local_path,
                    ),
                );
            }
            return Ok(());
        }

        #[cfg(not(target_os = "macos"))]
        {
            // Group events by type
            let mut create_update_events: Vec<FileEventData> = Vec::new();
            let mut rename_events: Vec<FileEventData> = Vec::new();
            let mut delete_events: Vec<FileEventData> = Vec::new();

            for event in events {
                match event.event_type {
                    FileEventType::Create => create_update_events.push(event),
                    FileEventType::Modify => create_update_events.push(event),
                    FileEventType::Rename => rename_events.push(event),
                    FileEventType::Delete => delete_events.push(event),
                }
            }

            // Handle Create events grouped by parent
            if !create_update_events.is_empty() {
                self.handle_create_update_events(sync_root.clone(), create_update_events)
                    .await?;
            }

            // Handle Delete events
            if !delete_events.is_empty() {
                self.handle_delete_events(sync_root.clone(), delete_events)
                    .await?;
            }

            // Handle Rename events
            if !rename_events.is_empty() {
                self.handle_rename_events(sync_root.clone(), rename_events)
                    .await?;
            }

            Ok(())
        }
    }

    #[cfg(not(target_os = "macos"))]
    async fn handle_rename_events(
        &self,
        sync_root: PathBuf,
        events: Vec<FileEventData>,
    ) -> Result<()> {
        // Handle rename as a combination of delete (from) and create (to)
        // Group by parent for both from paths (if they exist) and to paths
        let mut from_grouped_by_parent: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
        let mut to_grouped_by_parent: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();

        for event in events {
            // Handle `from` path (like delete) - only if it exists locally
            let from_relative: PathBuf = event.from.trim_start_matches('/').split('/').collect();
            let local_from_path = sync_root.join(&from_relative);

            let from_exists = match LocalFileInfo::from_path(&local_from_path) {
                Ok(info) => info.exists,
                Err(e) => {
                    tracing::trace!(
                        target: "drive::remote_events",
                        path = %local_from_path.display(),
                        error = ?e,
                        "Failed to get file info for rename from path, skipping"
                    );
                    false
                }
            };

            if from_exists {
                if let Some(parent) = local_from_path.parent() {
                    from_grouped_by_parent
                        .entry(parent.to_path_buf())
                        .or_default()
                        .push(local_from_path);
                }
            }

            // Handle `to` path (like create) - always process
            let to_relative: PathBuf = event.to.trim_start_matches('/').split('/').collect();
            let local_to_path = sync_root.join(&to_relative);

            if let Some(parent) = local_to_path.parent() {
                to_grouped_by_parent
                    .entry(parent.to_path_buf())
                    .or_default()
                    .push(local_to_path);
            }
        }

        // Process from paths (deletions)
        for (parent, paths) in from_grouped_by_parent {
            if let Err(e) = self
                .sync_last_presented_parent(sync_root.clone(), parent, paths)
                .await
            {
                tracing::error!(
                    target: "drive::remote_events",
                    error = ?e,
                    "Failed to sync parent for rename from paths"
                );
            }
        }

        // Process to paths (creations)
        for (parent, paths) in to_grouped_by_parent {
            if let Err(e) = self
                .sync_last_presented_parent(sync_root.clone(), parent, paths)
                .await
            {
                tracing::error!(
                    target: "drive::remote_events",
                    error = ?e,
                    "Failed to sync parent for rename to paths"
                );
            }
        }

        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    async fn handle_delete_events(
        &self,
        sync_root: PathBuf,
        events: Vec<FileEventData>,
    ) -> Result<()> {
        // Group delete events by parent of `from` path, filtering out non-existent files
        let mut grouped_by_parent: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();

        for event in events {
            // Remote paths use Unix-style separators, convert to OS-native path
            let relative_path: PathBuf = event.from.trim_start_matches('/').split('/').collect();
            let local_from_path = sync_root.join(&relative_path);

            // Check if file exists locally, skip if not
            let path_info = match LocalFileInfo::from_path(&local_from_path) {
                Ok(info) => info,
                Err(e) => {
                    tracing::trace!(
                        target: "drive::remote_events",
                        path = %local_from_path.display(),
                        error = ?e,
                        "Failed to get file info for delete event, skipping"
                    );
                    continue;
                }
            };

            if !path_info.exists {
                tracing::trace!(
                    target: "drive::remote_events",
                    path = %local_from_path.display(),
                    "File does not exist locally for delete event, skipping"
                );
                continue;
            }

            if let Some(parent) = local_from_path.parent() {
                grouped_by_parent
                    .entry(parent.to_path_buf())
                    .or_default()
                    .push(local_from_path);
            }
        }

        // Process each group
        for (parent, paths) in grouped_by_parent {
            if let Err(e) = self
                .sync_last_presented_parent(sync_root.clone(), parent, paths)
                .await
            {
                tracing::error!(
                    target: "drive::remote_events",
                    error = ?e,
                    "Failed to sync parent for delete events"
                );
            }
        }

        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    async fn handle_create_update_events(
        &self,
        sync_root: PathBuf,
        events: Vec<FileEventData>,
    ) -> Result<()> {
        // Group create events by parent of `from` path
        let mut grouped_by_parent: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();

        for event in events {
            // Remote paths use Unix-style separators, convert to OS-native path
            let relative_path: PathBuf = event.from.trim_start_matches('/').split('/').collect();
            let local_from_path = sync_root.join(&relative_path);

            if let Some(parent) = local_from_path.parent() {
                grouped_by_parent
                    .entry(parent.to_path_buf())
                    .or_default()
                    .push(local_from_path);
            }
        }

        // Process each group
        for (parent, paths) in grouped_by_parent {
            if let Err(e) = self
                .sync_last_presented_parent(sync_root.clone(), parent, paths)
                .await
            {
                tracing::error!(
                    target: "drive::remote_events",
                    error = ?e,
                    "Failed to sync parent for create events"
                );
            }
        }

        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    async fn sync_last_presented_parent(
        &self,
        sync_root: PathBuf,
        initial_parent: PathBuf,
        local_paths: Vec<PathBuf>,
    ) -> Result<()> {
        // Walk up from initial_parent to find the first existing & populated parent
        let mut current_path = initial_parent.clone();
        let mut child_of_existing: Option<PathBuf> = None;

        loop {
            // Check if we've gone above the sync root
            if !current_path.starts_with(&sync_root)
                || current_path == sync_root.parent().unwrap_or(Path::new(""))
            {
                tracing::warn!(
                    target: "drive::remote_events",
                    sync_root = %sync_root.display(),
                    initial_parent = %initial_parent.display(),
                    "File event parent is not under sync root, skipping"
                );
                return Ok(());
            }

            let path_info =
                LocalFileInfo::from_path(&current_path).context("failed to get path file info")?;

            if path_info.exists {
                if !path_info.is_placeholder() || path_info.is_folder_populated() {
                    // Found an existing & populated parent, sync from here
                    let (mode, sync_paths) = if let Some(child_path) = child_of_existing {
                        // We walked up, so sync the intermediate child folder
                        tracing::trace!(
                            target: "drive::remote_events",
                            existing_parent = %current_path.display(),
                            child_path = %child_path.display(),
                            "Syncing intermediate child path with PathOnly"
                        );
                        (SyncMode::PathOnly, vec![child_path])
                    } else if local_paths.len() > 1 {
                        // Multiple paths in same parent - sync parent with first layer
                        tracing::trace!(
                            target: "drive::remote_events",
                            parent_path = %current_path.display(),
                            path_count = local_paths.len(),
                            "Syncing parent path with PathAndFirstLayer for multiple new events"
                        );
                        (SyncMode::PathAndFirstLayer, vec![current_path.clone()])
                    } else {
                        // Single path - sync only that path
                        tracing::trace!(
                            target: "drive::remote_events",
                            parent_path = %current_path.display(),
                            "Syncing single path for new event"
                        );
                        (SyncMode::PathOnly, local_paths.clone())
                    };

                    self.command_tx
                        .send(MountCommand::Sync {
                            local_paths: sync_paths,
                            mode,
                            user_initiated: false,
                        })
                        .context("failed to send sync command")?;
                    return Ok(());
                } else {
                    tracing::trace!(
                        target: "drive::remote_events",
                        parent_path = %current_path.display(),
                        "Parent path is a placeholder and not populated, skipping"
                    );
                    return Ok(());
                }
            }

            // Current path doesn't exist, walk up to its parent
            // Remember current_path as the child that will need syncing
            child_of_existing = Some(current_path.clone());

            match current_path.parent() {
                Some(parent) => {
                    current_path = parent.to_path_buf();
                }
                None => {
                    tracing::warn!(
                        target: "drive::remote_events",
                        sync_root = %sync_root.display(),
                        "Reached filesystem root without finding existing parent"
                    );
                    return Ok(());
                }
            }
        }
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn reconnect_delay_backs_off_for_short_lived_streams() {
        let mut backoff = BackoffState::new();
        let short = Duration::from_secs(1);
        let delays = (0..3).map(|_| reconnect_delay(&mut backoff, short).as_secs()).collect::<Vec<_>>();
        assert_eq!(delays, [1, 2, 4]);
    }

    #[test]
    fn reconnect_delay_resets_after_a_healthy_stream() {
        let mut backoff = BackoffState::new();
        reconnect_delay(&mut backoff, Duration::from_secs(1));
        reconnect_delay(&mut backoff, Duration::from_secs(1));
        assert_eq!(reconnect_delay(&mut backoff, Duration::from_secs(61)).as_secs(), 1);
    }

    #[test]
    fn error_after_short_subscribed_stream_keeps_backing_off() {
        let mut backoff = BackoffState::new();
        let short = Duration::from_secs(5);
        let delays = (0..3)
            .map(|_| error_delay(&mut backoff, true, short).as_secs())
            .collect::<Vec<_>>();
        assert_eq!(delays, [1, 2, 4]);
        assert_eq!(error_delay(&mut backoff, true, Duration::from_secs(61)).as_secs(), 1);
    }

    #[test]
    fn batch_retries_are_bounded() {
        assert!((1..EVENT_BATCH_COMMIT_ATTEMPTS).all(should_retry_batch));
        assert!(!should_retry_batch(EVENT_BATCH_COMMIT_ATTEMPTS));
    }

    fn api_error(code: i32) -> cloudreve_api::ApiError {
        cloudreve_api::ApiError::ApiError {
            code, message: String::new(), error_detail: None,
            correlation_id: None, aggregated_errors: None,
        }
    }

    #[test]
    fn only_a_definite_missing_path_is_gone() {
        assert!(is_path_missing(&api_error(40016)));
        assert!(is_path_missing(&api_error(404)));
        // Rate limits, server faults, expired sessions and network errors say
        // nothing about whether the path exists.
        assert!(!is_path_missing(&api_error(50001)));
        assert!(!is_path_missing(&api_error(429)));
        assert!(!is_path_missing(&cloudreve_api::ApiError::AccessTokenExpired));
        assert!(!is_path_missing(&cloudreve_api::ApiError::Other("timeout".into())));
    }
}
