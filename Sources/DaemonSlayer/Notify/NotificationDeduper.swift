import Foundation

/// In-memory, per-daemon re-notification gate that suppresses banner spam for the
/// same orphaned/runaway JVM.
///
/// The RuleEngine already paces re-notifications via `snoozeMinutes`, but that
/// cadence is anchored to a single flagged lifecycle. A daemon that bounces
/// flagged→healthy→flagged (e.g. ownership flapping on `lsof` noise) re-fires from
/// the healthy edge immediately, and a daemon that briefly drops out of the
/// process table loses its engine state entirely — both bypass the cadence and
/// re-alert the user. This is the belt-and-suspenders backstop: regardless of WHY
/// the engine re-emitted, a given (category, daemon) is admitted at most once per
/// `window`.
///
/// Pure and deterministic — the clock is passed in, no I/O — so it unit-tests the
/// way the RuleEngine does. NOT thread-safe: it is mutated only from
/// NotificationManager.post(), which the agent calls on its serial pollQueue.
///
/// "Same build" == the same daemon JVM, keyed on `ProcessIdentity` (pid + start
/// time): a killed-and-respawned daemon gets a fresh start time and so notifies
/// again. Category is part of the key on purpose — a daemon already flagged as an
/// orphan can still raise a (more urgent) runaway alert inside the window.
struct NotificationDeduper {

    private struct Key: Hashable {
        let category: NotificationCategory
        let identity: ProcessIdentity
    }

    /// Minimum spacing between alerts about one daemon. Defaults to an hour and
    /// mirrors the engine's `snoozeMinutes` cadence so every "how often do I hear
    /// about this" knob moves together.
    var window: TimeInterval

    private var lastNotified: [Key: Date] = [:]

    init(window: TimeInterval) {
        self.window = window
    }

    /// Decide whether to post `batch`. Returns true iff at least one of its
    /// processes has not been alerted for this category within `window` — a
    /// genuinely new member (or one whose window has lapsed) lets the whole batch
    /// through, because the situation has changed and the batch copy re-lists it.
    /// On admit, every member's clock is stamped to `now`. Stale entries are
    /// pruned each call so the map stays bounded by the set of live daemons.
    mutating func admit(_ batch: NotificationBatch, now: Date) -> Bool {
        prune(now: now)
        let keys = batch.processes.map {
            Key(category: batch.category, identity: $0.process.identity)
        }
        let hasFresh = keys.contains { key in
            guard let last = lastNotified[key] else { return true }
            return now.timeIntervalSince(last) >= window
        }
        guard hasFresh else { return false }
        for key in keys { lastNotified[key] = now }
        return true
    }

    /// Drop entries whose window has fully elapsed: they no longer suppress, and
    /// dropping them keeps the map sized to recently-seen daemons rather than every
    /// daemon ever notified about.
    private mutating func prune(now: Date) {
        lastNotified = lastNotified.filter { now.timeIntervalSince($0.value) < window }
    }
}
