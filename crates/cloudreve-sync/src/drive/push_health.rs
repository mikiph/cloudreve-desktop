//! Pure state machine tracking whether the server's live event stream (SSE)
//! works for a drive. No I/O: the listener feeds it observations and acts on
//! the resulting state.

use std::time::Duration;

const UNSUPPORTED_STRIKES: usize = 3;
const UNSUPPORTED_MIN_SPAN_MS: i64 = 60_000;
const FLAP_STREAMS: usize = 4;
const FLAP_WINDOW_MS: i64 = 600_000;
const HEALTHY_STREAM: Duration = Duration::from_secs(60);
const BUFFERED_STRIKES: u32 = 2;
const OFFLINE_FAILURES: u32 = 2;

const PROBE_BASE_SECS: u64 = 60;
const PROBE_CAP_SECS: u64 = 900;
const PROBE_JITTER: f64 = 0.2;

const ACTIVITY_MAX_AGE_MS: i64 = 600_000;
const PASS_MIN_INTERVAL_MS: i64 = 300_000;
const PASS_WINDOW_MS: i64 = 3_600_000;
const MAX_PASSES_PER_HOUR: usize = 12;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushState {
    Healthy,
    Reconnecting,
    Degraded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DegradedReason {
    Unsupported,
    Flapping,
    Buffered,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Observation {
    /// `subscribed`/`resumed` received.
    Subscribed,
    /// The stream has stayed up for HEALTHY_STREAM (60 s) after Subscribed.
    StreamHealthy,
    /// Subscribe answered over HTTP without SSE.
    NotUpgraded { status: Option<u16>, code: i32 },
    /// Stream ended / errored / reconnect-required after Subscribed.
    StreamLost { connected_for: Duration },
    /// Idle timeout before any Subscribed on this attempt.
    IdleBeforeSubscribed,
    /// Network error, auth error, or anything else: never evidence of missing SSE.
    OtherFailure,
}

#[derive(Debug, Clone)]
pub struct PushHealth {
    state: PushState,
    reason: Option<DegradedReason>,
    unsupported_strikes: Vec<i64>,
    buffered_strikes: u32,
    short_streams: Vec<i64>,
    other_failures: u32,
    offline: bool,
}

impl Default for PushHealth {
    fn default() -> Self {
        Self::new()
    }
}

impl PushHealth {
    pub fn new() -> Self {
        Self {
            state: PushState::Reconnecting,
            reason: None,
            unsupported_strikes: Vec::new(),
            buffered_strikes: 0,
            short_streams: Vec::new(),
            other_failures: 0,
            offline: false,
        }
    }

    /// Restored from the persisted record.
    pub fn degraded(reason: DegradedReason) -> Self {
        let mut health = Self::new();
        health.state = PushState::Degraded;
        health.reason = Some(reason);
        health
    }

    pub fn state(&self) -> PushState {
        self.state
    }

    pub fn reason(&self) -> Option<DegradedReason> {
        self.reason
    }

    pub fn is_offline(&self) -> bool {
        self.offline
    }

    fn enter_degraded(&mut self, reason: DegradedReason) {
        if self.state != PushState::Degraded {
            self.state = PushState::Degraded;
            self.reason = Some(reason);
            self.other_failures = 0;
            self.offline = false;
        }
    }

    fn mark_reachable(&mut self) {
        self.other_failures = 0;
        self.offline = false;
    }

    fn lose_health(&mut self) {
        if self.state == PushState::Healthy {
            self.state = PushState::Reconnecting;
        }
    }

    /// Feed one observation at wall time `now_ms`; returns the new state.
    pub fn observe(&mut self, observation: Observation, now_ms: i64) -> PushState {
        match observation {
            Observation::Subscribed => {
                self.unsupported_strikes.clear();
                self.buffered_strikes = 0;
                self.mark_reachable();
                if self.state != PushState::Degraded {
                    self.state = PushState::Healthy;
                }
            }
            Observation::StreamHealthy => {
                self.unsupported_strikes.clear();
                self.buffered_strikes = 0;
                self.short_streams.clear();
                self.mark_reachable();
                self.state = PushState::Healthy;
                self.reason = None;
            }
            Observation::NotUpgraded { status, code } => {
                self.mark_reachable();
                let server_trouble = matches!(status, Some(500..=599));
                let auth = code == 401 || code == 403;
                if !server_trouble && !auth {
                    self.unsupported_strikes.push(now_ms);
                    if self.unsupported_strikes.len() > UNSUPPORTED_STRIKES {
                        self.unsupported_strikes.remove(0);
                    }
                    if self.unsupported_strikes.len() == UNSUPPORTED_STRIKES
                        && now_ms - self.unsupported_strikes[0] >= UNSUPPORTED_MIN_SPAN_MS
                    {
                        self.enter_degraded(DegradedReason::Unsupported);
                    }
                }
                self.lose_health();
            }
            Observation::StreamLost { connected_for } => {
                if connected_for < HEALTHY_STREAM {
                    self.short_streams.push(now_ms);
                    self.short_streams.retain(|t| now_ms - *t <= FLAP_WINDOW_MS);
                    if self.short_streams.len() >= FLAP_STREAMS {
                        self.enter_degraded(DegradedReason::Flapping);
                    }
                }
                if self.state != PushState::Degraded {
                    self.state = PushState::Reconnecting;
                }
            }
            Observation::IdleBeforeSubscribed => {
                self.mark_reachable();
                self.buffered_strikes += 1;
                if self.buffered_strikes >= BUFFERED_STRIKES {
                    self.enter_degraded(DegradedReason::Buffered);
                }
                self.lose_health();
            }
            Observation::OtherFailure => {
                self.lose_health();
                if self.state == PushState::Degraded {
                    self.other_failures += 1;
                    if self.other_failures >= OFFLINE_FAILURES {
                        self.offline = true;
                    }
                }
            }
        }
        self.state
    }
}

/// Delay before the next subscribe attempt while Degraded: attempt 0 -> 60 s,
/// then 120, 240, 480, 900 (cap). `jitter` in [-1.0, 1.0] scales +-20 %.
pub fn probe_delay(attempt: u32, jitter: f64) -> Duration {
    let base = PROBE_BASE_SECS
        .saturating_mul(1u64 << attempt.min(16))
        .min(PROBE_CAP_SECS);
    let jitter = jitter.clamp(-1.0, 1.0);
    Duration::from_secs_f64(base as f64 * (1.0 + PROBE_JITTER * jitter))
}

/// Whether a fallback pass may run now. `last_activity_ms` = Finder heartbeat
/// (None = never), `passes_ms` = timestamps of passes already run.
pub fn fallback_pass_due(
    state: PushState,
    now_ms: i64,
    last_activity_ms: Option<i64>,
    passes_ms: &[i64],
) -> bool {
    if state != PushState::Degraded {
        return false;
    }
    match last_activity_ms {
        Some(at) if now_ms - at < ACTIVITY_MAX_AGE_MS => {}
        _ => return false,
    }
    if let Some(newest) = passes_ms.iter().max() {
        if now_ms - *newest < PASS_MIN_INTERVAL_MS {
            return false;
        }
    }
    passes_ms
        .iter()
        .filter(|t| now_ms - **t < PASS_WINDOW_MS)
        .count()
        < MAX_PASSES_PER_HOUR
}

/// Domain connected predicate used by the supervisor and manager.
pub fn domain_connected(subscribed: bool, degraded: bool, credential_expired: bool) -> bool {
    (subscribed || degraded) && !credential_expired
}

#[cfg(test)]
mod tests {
    use super::*;

    fn not_upgraded(status: u16, code: i32) -> Observation {
        Observation::NotUpgraded {
            status: Some(status),
            code,
        }
    }

    fn short() -> Observation {
        Observation::StreamLost {
            connected_for: Duration::from_secs(5),
        }
    }

    #[test]
    fn unsupported_after_three_strikes_spanning_a_minute() {
        let mut h = PushHealth::new();
        h.observe(not_upgraded(404, -1), 0);
        h.observe(not_upgraded(404, -1), 30_000);
        assert_eq!(h.observe(not_upgraded(404, -1), 61_000), PushState::Degraded);
        assert_eq!(h.reason(), Some(DegradedReason::Unsupported));

        let mut h = PushHealth::new();
        h.observe(not_upgraded(404, -1), 0);
        h.observe(not_upgraded(404, -1), 25_000);
        assert_ne!(h.observe(not_upgraded(404, -1), 50_000), PushState::Degraded);
    }

    #[test]
    fn server_errors_are_not_strikes() {
        let mut h = PushHealth::new();
        for t in [0, 60_000, 120_000] {
            h.observe(not_upgraded(502, -1), t);
        }
        assert_ne!(h.state(), PushState::Degraded);
    }

    #[test]
    fn auth_errors_are_not_strikes() {
        let mut h = PushHealth::new();
        for t in [0, 60_000, 120_000] {
            h.observe(not_upgraded(200, 401), t);
        }
        assert_ne!(h.state(), PushState::Degraded);
    }

    #[test]
    fn other_failures_never_degrade() {
        let mut h = PushHealth::new();
        for t in [0, 60_000, 120_000] {
            h.observe(Observation::OtherFailure, t);
        }
        assert_ne!(h.state(), PushState::Degraded);
    }

    #[test]
    fn flapping_streams_degrade_only_within_the_window() {
        let mut h = PushHealth::new();
        for t in [0, 10_000, 20_000] {
            h.observe(short(), t);
        }
        assert_eq!(h.observe(short(), 30_000), PushState::Degraded);
        assert_eq!(h.reason(), Some(DegradedReason::Flapping));

        let mut h = PushHealth::new();
        for t in [0, 800_000, 1_600_000, 2_400_000] {
            h.observe(short(), t);
        }
        assert_ne!(h.state(), PushState::Degraded);
    }

    #[test]
    fn idle_before_subscribed_twice_is_buffered() {
        let mut h = PushHealth::new();
        h.observe(Observation::IdleBeforeSubscribed, 0);
        assert_eq!(
            h.observe(Observation::IdleBeforeSubscribed, 90_000),
            PushState::Degraded
        );
        assert_eq!(h.reason(), Some(DegradedReason::Buffered));
    }

    #[test]
    fn subscribe_while_degraded_needs_a_healthy_stream() {
        let mut h = PushHealth::degraded(DegradedReason::Unsupported);
        assert_eq!(h.observe(Observation::Subscribed, 0), PushState::Degraded);
        assert_eq!(h.observe(Observation::StreamHealthy, 60_000), PushState::Healthy);
        assert_eq!(h.reason(), None);
    }

    #[test]
    fn long_stream_loss_is_only_reconnecting() {
        let mut h = PushHealth::new();
        assert_eq!(h.observe(Observation::Subscribed, 0), PushState::Healthy);
        let lost = Observation::StreamLost {
            connected_for: Duration::from_secs(90),
        };
        assert_eq!(h.observe(lost, 90_000), PushState::Reconnecting);
    }

    #[test]
    fn offline_while_degraded_is_tracked() {
        let mut h = PushHealth::degraded(DegradedReason::Flapping);
        h.observe(Observation::OtherFailure, 0);
        assert!(!h.is_offline());
        h.observe(Observation::OtherFailure, 1_000);
        assert!(h.is_offline());
        assert_eq!(h.state(), PushState::Degraded);
        assert_eq!(h.reason(), Some(DegradedReason::Flapping));
        h.observe(not_upgraded(404, -1), 2_000);
        assert!(!h.is_offline());
    }

    #[test]
    fn probe_delay_schedule_and_jitter() {
        let secs = (0..7)
            .map(|a| probe_delay(a, 0.0).as_secs())
            .collect::<Vec<_>>();
        assert_eq!(secs, [60, 120, 240, 480, 900, 900, 900]);
        assert_eq!(probe_delay(0, 1.0).as_secs_f64(), 72.0);
        assert_eq!(probe_delay(0, -1.0).as_secs_f64(), 48.0);
        let capped = probe_delay(6, 1.0).as_secs_f64();
        assert!((720.0..=1080.0).contains(&capped));
    }

    #[test]
    fn fallback_pass_gating() {
        let now = 10_000_000i64;
        let min = 60_000i64;
        let d = PushState::Degraded;
        assert!(!fallback_pass_due(PushState::Healthy, now, Some(now), &[]));
        assert!(!fallback_pass_due(d, now, None, &[]));
        assert!(!fallback_pass_due(d, now, Some(now - 11 * min), &[]));
        assert!(!fallback_pass_due(d, now, Some(now), &[now - 4 * min]));
        let twelve = (0..12).map(|i| now - 6 * min - i * 4 * min).collect::<Vec<_>>();
        assert!(twelve.iter().all(|t| now - t < 3_600_000));
        assert!(!fallback_pass_due(d, now, Some(now), &twelve));
        assert!(fallback_pass_due(d, now, Some(now - min), &[now - 6 * min]));
        assert!(fallback_pass_due(d, now, Some(now), &[]));
    }

    #[test]
    fn domain_connected_truth_table() {
        for subscribed in [false, true] {
            for degraded in [false, true] {
                for expired in [false, true] {
                    assert_eq!(
                        domain_connected(subscribed, degraded, expired),
                        (subscribed || degraded) && !expired
                    );
                }
            }
        }
        assert!(!domain_connected(false, false, false));
        assert!(domain_connected(false, true, false));
        assert!(!domain_connected(true, true, true));
    }
}
