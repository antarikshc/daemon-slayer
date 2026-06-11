import Foundation

/// Agent-health banner state derived PURELY from the agent's published `state.json`
/// (or its absence), the wall-clock now, and the config cadences (SPEC-UI §7.2).
///
/// This is the model only — the banner VIEW lands in M4. The derivation is a pure
/// function so the fresh/paused/stale matrices (incl. idle-backoff and post-sleep
/// staleness) are exhaustively unit-testable with fabricated timestamps.
enum BannerState: Equatable {
    /// Heartbeat fresh, not paused. `lastPollAgo` is now − state.lastPollAt.
    case watching(lastPollAgo: TimeInterval)
    /// Heartbeat fresh, `paused: true`.
    case paused
    /// state.json missing, or its heartbeat is staler than the effective threshold.
    case dead
}

enum BannerDeriver {
    /// Extra grace on top of 2× the effective poll interval before declaring the
    /// agent dead. Covers timer leeway (~5 s, §5.3) + write latency so a healthy
    /// agent on its slowest sane cadence never flickers to "dead".
    static let staleGraceSeconds: TimeInterval = 30

    /// Derive the banner state.
    ///
    /// - `snapshot`: the agent's last published view, or nil when state.json is
    ///   missing/corrupt (→ dead).
    /// - `now`: wall clock. Staleness is `now − snapshot.writtenAt` (the heartbeat),
    ///   NOT lastPollAt — a paused agent never polls but still beats.
    /// - `config`: supplies the effective cadence. We respect BOTH the idle backoff
    ///   (`idlePollIntervalSeconds`, an idle agent legitimately writes slowly) and
    ///   the paused heartbeat cadence (also the idle interval, per AgentRuntime).
    ///
    /// Effective interval = idlePollIntervalSeconds (the slowest legitimate beat for
    /// a running OR paused agent). Threshold = 2× that + grace. A fresh snapshot
    /// with `paused == true` is `.paused`; fresh and running is `.watching`.
    static func derive(snapshot: AgentStateSnapshot?, now: Date, config: Config) -> BannerState {
        guard let snapshot else { return .dead }

        let effectiveInterval = max(config.pollIntervalSeconds, config.idlePollIntervalSeconds)
        let staleThreshold = 2 * effectiveInterval + staleGraceSeconds
        let heartbeatAge = now.timeIntervalSince(snapshot.writtenAt)

        // A future-dated or fresh heartbeat is alive; only a genuinely old one is dead.
        // (Mac-sleep flicker, edge 9: writtenAt trips stale after wake until the next
        //  beat lands — accepted, banner self-heals.)
        if heartbeatAge > staleThreshold { return .dead }

        if snapshot.paused { return .paused }
        return .watching(lastPollAgo: max(0, now.timeIntervalSince(snapshot.lastPollAt)))
    }
}
