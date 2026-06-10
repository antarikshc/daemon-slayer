import Foundation

/// The pure detection brain (spec §5). Feeds on `PollSnapshot`s, runs per-process
/// hysteresis state machines, and emits notification batches + auto-kill targets.
///
/// Design contract (dictated, supersedes SPEC.md where they differ):
/// - NO `Date()` / wall-clock: the clock is `snapshot.timestamp`; snooze-until is
///   passed in by the caller. NO I/O, NO threads. Fully deterministic.
/// - NOT thread-safe: the caller (Poller) serializes ingest + user-action calls on
///   a single queue. User actions (snooze/ignore/markKilling/clearKilling) arrive
///   between ingests, never concurrently.
final class RuleEngine {

    // MARK: - Per-process lifecycle (spec §5.5)

    private enum Lifecycle: Equatable {
        case healthy
        case flagged(Rule)
        case snoozed(until: Date)
        case ignored          // terminal for this identity (until it dies)
        case killing
    }

    // MARK: - Per-identity tracked state

    /// All RuleEngine memory about one `ProcessIdentity`. Dropped when the identity
    /// vanishes from a snapshot (died) or its start-time changes (PID reuse, §5.4/§12).
    private final class State {
        var lifecycle: Lifecycle = .healthy
        /// Consecutive matching samples per rule (hysteresis, §5.3).
        var counters: [Rule: Int] = [:]
        /// Timestamp of the first sample of the current consecutive run, per rule
        /// (the 0→1 edge). Becomes `candidateSince` when the rule fires.
        var runStart: [Rule: Date] = [:]
        /// Previous sample's cumulative CPU seconds + that sample's timestamp.
        var prevCpuSeconds: Double?
        var prevTimestamp: Date?
        /// Last resolved ownership verdict (for ownershipUnknown carry-over, §5.1 / edge 8).
        var prevOwned: Bool?
        /// When we last included this process in a notification batch (re-notify cadence, §6).
        var lastNotifiedAt: Date?

        // Last-seen bookkeeping for stateRecords()/--status (spec §11).
        var kind: DaemonKind
        var displayName: String
        var lastSeen: Date
        var rssBytes: UInt64
        /// cpuPercent of the most recent sample (R4 copy); nil on first sample.
        var lastCpuPercent: Double?

        init(kind: DaemonKind, displayName: String, lastSeen: Date, rssBytes: UInt64) {
            self.kind = kind
            self.displayName = displayName
            self.lastSeen = lastSeen
            self.rssBytes = rssBytes
        }
    }

    /// One sample's derived per-rule match results + the values the batch copy needs.
    private struct Derived {
        var matches: [Rule: Bool] = [:]
        var idleThisSample: Bool = false
        var cpuPercent: Double?       // nil on first sample (no delta)
    }

    // MARK: - Config (re-read live; counters preserved across updateConfig, §10)

    private var config: Config

    // MARK: - State table

    private var states: [ProcessIdentity: State] = [:]

    // MARK: - Rule priority (spec §5.5: runaway > R1 > R2 > R3)

    private static let priority: [Rule] = [.runaway, .ownerlessNoIDE, .ownerlessWithIDE, .idleTooLong]

    // MARK: - Init / config

    init(config: Config) {
        self.config = config
    }

    /// Thresholds re-read live on the next ingest; per-process counters preserved (§10).
    func updateConfig(_ config: Config) {
        self.config = config
    }

    // MARK: - Ingest (the one entry point per poll)

    @discardableResult
    func ingest(_ snapshot: PollSnapshot) -> RuleEngineOutput {
        let now = snapshot.timestamp

        // 1. Reconcile the state table with what's present this snapshot.
        let present = reconcile(snapshot)

        // 2. Resolve ownership per observation (ownershipUnknown → previous verdict, §5.1).
        var ownedByPid: [Int32: Bool] = [:]
        var obsByIdentity: [ProcessIdentity: DaemonObservation] = [:]
        for obs in snapshot.daemons {
            let id = obs.process.identity
            let owned: Bool
            if obs.ownershipUnknown {
                // Fail-safe (edge case 8): keep last verdict; default owned if never resolved.
                owned = states[id]?.prevOwned ?? true
            } else {
                owned = Ownership.isOwned(obs, in: snapshot)
            }
            ownedByPid[obs.process.pid] = owned
            obsByIdentity[id] = obs
        }

        // 3. Compute per-sample derived match values. Gradle daemons are evaluated
        //    first; Kotlin daemons then copy linked Gradle counters/run-starts (O4, §5.1).
        var derived: [ProcessIdentity: Derived] = [:]
        let gradle = snapshot.daemons.filter { $0.process.kind == .gradle }
        let kotlin = snapshot.daemons.filter { $0.process.kind == .kotlin }

        for obs in gradle {
            let id = obs.process.identity
            derived[id] = evaluate(obs, owned: ownedByPid[obs.process.pid] ?? false,
                                   snapshot: snapshot, state: states[id], now: now)
        }
        for obs in kotlin {
            let id = obs.process.identity
            derived[id] = evaluate(obs, owned: ownedByPid[obs.process.pid] ?? false,
                                   snapshot: snapshot, state: states[id], now: now)
        }

        // 4. Advance counters. For Kotlin daemons under O4 lockstep, COPY the linked
        //    Gradle's R1/R2/R3 counters + run-starts after Gradle counters are advanced
        //    (same rule, same batch). R4 stays the Kotlin's own.
        //    Gradle first, then Kotlin (so the copy reads already-advanced Gradle state).
        for obs in gradle {
            advanceCounters(for: obs.process.identity, derived: derived[obs.process.identity]!, now: now)
        }
        for obs in kotlin {
            let id = obs.process.identity
            advanceCounters(for: id, derived: derived[id]!, now: now)
            applyO4Lockstep(kotlin: obs, snapshot: snapshot, ownedByPid: ownedByPid)
        }

        // 5. Record per-sample bookkeeping (prev sample, owned verdict, lastCpuPercent).
        for obs in snapshot.daemons {
            let id = obs.process.identity
            guard let st = states[id] else { continue }
            st.prevCpuSeconds = obs.process.cpuTimeSeconds
            st.prevTimestamp = now
            st.prevOwned = ownedByPid[obs.process.pid]
            st.lastCpuPercent = derived[id]?.cpuPercent
        }

        // 6. Drive lifecycle transitions and collect what to notify / auto-kill.
        var output = RuleEngineOutput()
        var toNotify: [(FlaggedProcess)] = []

        for id in present {
            guard let st = states[id], let obs = obsByIdentity[id], let dv = derived[id] else { continue }
            let result = step(id: id, state: st, obs: obs, derived: dv, now: now)
            switch result {
            case .none:
                break
            case .notify(let flagged):
                toNotify.append(flagged)
            case .autoKill(let flagged):
                output.autoKill.append(flagged)
            }
        }

        // 7. Batch (spec §6): runaway → RUNAWAY_FOUND; everything else → ORPHAN_FOUND.
        output.notifications = batch(toNotify)
        return output
    }

    // MARK: - User actions (arrive between ingests; spec §6/§7)

    /// flagged → snoozed(until). No-op on unknown identity or non-flagged state.
    func snooze(_ ids: [ProcessIdentity], until: Date) {
        for id in ids {
            guard let st = states[id] else { continue }
            if case .flagged = st.lifecycle {
                st.lifecycle = .snoozed(until: until)
            }
            // snooze from non-flagged → no-op (spec).
        }
    }

    /// Terminal per identity. Works from any state (spec).
    func ignore(_ ids: [ProcessIdentity]) {
        for id in ids {
            states[id]?.lifecycle = .ignored
        }
    }

    /// flagged/healthy → killing (user Kill All action, or auto-kill policy). Unknown → no-op.
    func markKilling(_ ids: [ProcessIdentity]) {
        for id in ids {
            guard let st = states[id] else { continue }
            switch st.lifecycle {
            case .flagged, .healthy:
                st.lifecycle = .killing
            default:
                break   // snoozed/ignored/killing → no-op
            }
        }
    }

    /// Kill attempt finished; survivors → healthy, ALL counters reset (spec §5.5).
    func clearKilling(_ ids: [ProcessIdentity]) {
        for id in ids {
            guard let st = states[id], st.lifecycle == .killing else { continue }
            st.lifecycle = .healthy
            st.counters = [:]
            st.runStart = [:]
        }
    }

    // MARK: - State export (state.json + --status, spec §11)

    func stateRecords() -> [ProcessStateRecord] {
        states.map { (id, st) in
            ProcessStateRecord(
                identity: id,
                kind: st.kind,
                displayName: st.displayName,
                stateDescription: describe(st.lifecycle),
                ruleCounters: Dictionary(uniqueKeysWithValues: st.counters.map { ($0.key.rawValue, $0.value) }),
                owned: st.prevOwned ?? false,
                flaggedRule: flaggedRule(st.lifecycle),
                snoozedUntil: snoozedUntil(st.lifecycle),
                lastSeen: st.lastSeen,
                rssBytes: st.rssBytes
            )
        }
    }

    // MARK: - Reconciliation (identity lifecycle, §5.4/§12)

    /// Returns the set of identities present this snapshot, after dropping vanished
    /// states and resetting PID-reused identities (same pid, different start time).
    private func reconcile(_ snapshot: PollSnapshot) -> [ProcessIdentity] {
        let presentIdentities = snapshot.daemons.map { $0.process.identity }
        let presentSet = Set(presentIdentities)

        // Drop states for identities not present this snapshot. This covers BOTH cases by
        // exact-identity match: a process that died (pid gone), and PID reuse (same pid back
        // with a different startTimeMicros → the old identity is absent → dropped; the new
        // identity gets fresh state below). Spec §5.4/§12.
        for id in Array(states.keys) where !presentSet.contains(id) {
            states[id] = nil
        }

        // Establish fresh state for newly-seen identities; refresh last-seen bookkeeping.
        for obs in snapshot.daemons {
            let id = obs.process.identity
            if let st = states[id] {
                st.kind = obs.process.kind
                st.displayName = obs.process.displayName
                st.lastSeen = snapshot.timestamp
                st.rssBytes = obs.process.rssBytes
            } else {
                states[id] = State(kind: obs.process.kind,
                                   displayName: obs.process.displayName,
                                   lastSeen: snapshot.timestamp,
                                   rssBytes: obs.process.rssBytes)
            }
        }

        return presentIdentities
    }

    // MARK: - Per-sample evaluation (spec §5.2/§5.3)

    /// Compute which rules match THIS sample (no counter mutation here).
    private func evaluate(_ obs: DaemonObservation, owned: Bool,
                          snapshot: PollSnapshot, state: State?, now: Date) -> Derived {
        var d = Derived()

        // cpuDelta / wallDelta / cpuPercent / idleThisSample (spec §5.3).
        // First sample → no delta → idleThisSample = false, R4 unmatchable.
        if let prevCpu = state?.prevCpuSeconds, let prevTs = state?.prevTimestamp {
            let cpuDelta = obs.process.cpuTimeSeconds - prevCpu
            let wallDelta = now.timeIntervalSince(prevTs)
            d.idleThisSample = cpuDelta < config.idleCpuSecondsPerPoll
            if wallDelta > 0 {
                d.cpuPercent = cpuDelta / wallDelta * 100
            }
        } else {
            d.idleThisSample = false
            d.cpuPercent = nil
        }

        let p = obs.process

        // R1 — ownerlessNoIDE: !owned && !ideRunning.
        if isEnabled(.ownerlessNoIDE) {
            d.matches[.ownerlessNoIDE] = !owned && !snapshot.ideRunning
        }
        // R2 — ownerlessWithIDE: !owned && ideRunning && detached && idleThisSample.
        if isEnabled(.ownerlessWithIDE) {
            d.matches[.ownerlessWithIDE] = !owned && snapshot.ideRunning && p.isDetached && d.idleThisSample
        }
        // R3 — idleTooLong: owned && idleThisSample.
        if isEnabled(.idleTooLong) {
            d.matches[.idleTooLong] = owned && d.idleThisSample
        }
        // R4 — runaway: !hasAttachedClient && cpuPercent > threshold. Ignores `owned`
        //      deliberately (spec table: clientless + hot). Unmatchable on first sample.
        //      Fail-safe (spec §13 row 8): when lsof failed this cycle the resolver
        //      hard-codes hasAttachedClient=false, so a busy daemon could spuriously look
        //      clientless+hot. ownershipUnknown → R4 must NOT match (fail toward not
        //      flagging); the counter resets via normal non-match semantics.
        if isEnabled(.runaway) {
            let threshold = config.rules.runaway.cpuThresholdPercent ?? 50
            if let pct = d.cpuPercent, !obs.ownershipUnknown {
                d.matches[.runaway] = !obs.hasAttachedClient && pct > threshold
            } else {
                d.matches[.runaway] = false
            }
        }

        return d
    }

    private func isEnabled(_ rule: Rule) -> Bool { config.rules[rule].enabled }

    // MARK: - Hysteresis counters (spec §5.3)

    /// Matching sample → counter++ (record run-start on the 0→1 edge); non-matching → 0.
    private func advanceCounters(for id: ProcessIdentity, derived: Derived, now: Date) {
        guard let st = states[id] else { return }
        for rule in Rule.allCases {
            let matched = derived.matches[rule] ?? false
            if matched {
                let prior = st.counters[rule] ?? 0
                if prior == 0 { st.runStart[rule] = now }
                st.counters[rule] = prior + 1
            } else {
                st.counters[rule] = 0
                st.runStart[rule] = nil
            }
        }
    }

    /// O4 lockstep (spec §5.1): a Kotlin daemon whose linkedGradlePid maps to a Gradle
    /// daemon present this snapshot and NOT owned this sample COPIES that Gradle's
    /// R1/R2/R3 counters + run-starts (same rule, same batch, killed together). R4 stays
    /// the Kotlin's own. Linked-to-owned Gradle is already owned via Ownership.isOwned
    /// (so the Kotlin won't match R1/R2 anyway); no-linked-Gradle Kotlin is standalone.
    private func applyO4Lockstep(kotlin obs: DaemonObservation, snapshot: PollSnapshot,
                                 ownedByPid: [Int32: Bool]) {
        guard let gpid = obs.linkedGradlePid,
              let gradle = snapshot.daemons.first(where: { $0.process.pid == gpid && $0.process.kind == .gradle })
        else { return }
        // O4 is an EXTRA ownership source that ORs with the Kotlin's own O1/O2 (spec §5.1):
        // a Kotlin with its own attached client / IDE parent is owned regardless of its
        // Gradle, so it must never inherit an unowned Gradle's orphan counters. Lockstep
        // only when BOTH the Gradle AND the Kotlin are un-owned this sample.
        guard ownedByPid[gradle.process.pid] == false else { return }
        guard ownedByPid[obs.process.pid] == false else { return }
        guard let kst = states[obs.process.identity], let gst = states[gradle.process.identity] else { return }
        for rule in [Rule.ownerlessNoIDE, .ownerlessWithIDE, .idleTooLong] {
            kst.counters[rule] = gst.counters[rule]
            kst.runStart[rule] = gst.runStart[rule]
        }
    }

    // MARK: - Lifecycle stepping (spec §5.5/§6)

    private enum StepResult {
        case none
        case notify(FlaggedProcess)
        case autoKill(FlaggedProcess)
    }

    /// Drive one identity's lifecycle for this poll and return its emission (if any).
    private func step(id: ProcessIdentity, state st: State, obs: DaemonObservation,
                      derived dv: Derived, now: Date) -> StepResult {
        switch st.lifecycle {

        case .ignored, .killing:
            // Terminal / in-flight: never emitted.
            return .none

        case .healthy:
            // Fire if any rule's counter crossed its threshold; resolve ties by priority.
            guard let rule = firedRule(st) else { return .none }
            if config.autoKill.enabledRules.contains(rule) {
                st.lifecycle = .killing
                return .autoKill(makeFlagged(rule: rule, obs: obs, state: st, derived: dv, now: now))
            } else {
                st.lifecycle = .flagged(rule)
                st.lastNotifiedAt = now
                return .notify(makeFlagged(rule: rule, obs: obs, state: st, derived: dv, now: now))
            }

        case .flagged(let rule):
            // Condition clears (any sample where THAT rule isn't matching) → healthy;
            // that rule's counter resets (others untouched). Spec §5.5.
            if !(dv.matches[rule] ?? false) {
                st.lifecycle = .healthy
                st.counters[rule] = 0
                st.runStart[rule] = nil
                return .none
            }
            // Still matching → re-notify only after snoozeMinutes (dismissal == implicit snooze).
            let dueAt = (st.lastNotifiedAt ?? .distantPast).addingTimeInterval(config.snoozeMinutes * 60)
            if now >= dueAt {
                st.lastNotifiedAt = now
                return .notify(makeFlagged(rule: rule, obs: obs, state: st, derived: dv, now: now))
            }
            return .none

        case .snoozed(let until):
            // Counters keep advancing during snooze (handled in advanceCounters). When the
            // window expires, re-evaluate: any rule over threshold → flagged + notify; else healthy.
            guard now >= until else { return .none }
            if let rule = firedRule(st) {
                st.lifecycle = .flagged(rule)
                st.lastNotifiedAt = now
                return .notify(makeFlagged(rule: rule, obs: obs, state: st, derived: dv, now: now))
            } else {
                st.lifecycle = .healthy
                return .none
            }
        }
    }

    /// The highest-priority rule whose counter has reached its threshold (spec §5.5).
    private func firedRule(_ st: State) -> Rule? {
        for rule in Self.priority {
            guard isEnabled(rule) else { continue }
            let count = st.counters[rule] ?? 0
            if count >= config.requiredConsecutiveSamples(for: rule) { return rule }
        }
        return nil
    }

    /// Build the FlaggedProcess payload (spec §6/§8):
    /// candidateSince = fired rule's run-start; idleSeconds = now - candidateSince for
    /// R2/R3 (else nil); cpuPercent = last sample's value for R4 (else nil).
    private func makeFlagged(rule: Rule, obs: DaemonObservation, state st: State,
                             derived dv: Derived, now: Date) -> FlaggedProcess {
        let candidateSince = st.runStart[rule] ?? now
        let idleSeconds: Double?
        switch rule {
        case .ownerlessWithIDE, .idleTooLong:
            idleSeconds = now.timeIntervalSince(candidateSince)
        default:
            idleSeconds = nil
        }
        let cpuPercent: Double? = (rule == .runaway) ? dv.cpuPercent : nil
        return FlaggedProcess(process: obs.process, rule: rule,
                              candidateSince: candidateSince,
                              idleSeconds: idleSeconds, cpuPercent: cpuPercent)
    }

    // MARK: - Batching (spec §6)

    /// runaway → one RUNAWAY_FOUND batch; all others → one ORPHAN_FOUND batch.
    /// identifier is stable per process-set: "<category>-" + sorted("pid.start") joined "+".
    private func batch(_ flagged: [FlaggedProcess]) -> [NotificationBatch] {
        var out: [NotificationBatch] = []
        let runaways = flagged.filter { $0.rule == .runaway }
        let orphans = flagged.filter { $0.rule != .runaway }
        if !orphans.isEmpty { out.append(makeBatch(.orphanFound, orphans)) }
        if !runaways.isEmpty { out.append(makeBatch(.runawayFound, runaways)) }
        return out
    }

    private func makeBatch(_ category: NotificationCategory, _ procs: [FlaggedProcess]) -> NotificationBatch {
        let keys = procs
            .map { "\($0.process.identity.pid).\($0.process.identity.startTimeMicros)" }
            .sorted()
        let identifier = "\(category.rawValue)-" + keys.joined(separator: "+")
        return NotificationBatch(category: category, processes: procs, identifier: identifier)
    }

    // MARK: - State description helpers (spec §11)

    private func describe(_ lifecycle: Lifecycle) -> String {
        switch lifecycle {
        case .healthy: return "healthy"
        case .flagged(let rule): return "flagged(\(rule.shortName))"
        case .snoozed(let until): return "snoozed until \(Self.iso8601.string(from: until))"
        case .ignored: return "ignored"
        case .killing: return "killing"
        }
    }

    private func flaggedRule(_ lifecycle: Lifecycle) -> Rule? {
        if case .flagged(let rule) = lifecycle { return rule }
        return nil
    }

    private func snoozedUntil(_ lifecycle: Lifecycle) -> Date? {
        if case .snoozed(let until) = lifecycle { return until }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
