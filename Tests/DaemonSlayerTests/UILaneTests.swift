import XCTest
@testable import daemonslayer

/// V2-M2 pure-logic coverage (SPEC-UI §5/§7.2/§10): banner staleness matrices,
/// verdict precedence ordering, fast-lane CPU-delta + busy-since session math,
/// fast/slow merge (numbers update, verdicts persist), and ownershipUnknown
/// keeping previous verdicts. No UI / no snapshot tests — the views are thin and
/// every decision lives in these pure types.
final class UILaneTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    private func proc(_ pid: Int32, kind: DaemonKind = .gradle, ppid: Int32 = 1,
                      cpu: Double = 0, rss: UInt64 = 100, start: Int64 = 1_000) -> DaemonProcess {
        DaemonProcess(identity: ProcessIdentity(pid: pid, startTimeMicros: start),
                      kind: kind, ppid: ppid, rssBytes: rss, cpuTimeSeconds: cpu,
                      argv: ["java", kind == .gradle ? DaemonKind.gradleArgvMarker : DaemonKind.kotlinArgvMarker],
                      gradleVersion: kind == .gradle ? "8.13" : nil,
                      projectHint: "proj", kotlinAliveMarkerPath: nil)
    }

    private func agentState(writtenAgo: TimeInterval, lastPollAgo: TimeInterval,
                            paused: Bool, now: Date, records: [ProcessStateRecord] = []) -> AgentStateSnapshot {
        AgentStateSnapshot(writtenAt: now.addingTimeInterval(-writtenAgo),
                           agentPid: 999,
                           lastPollAt: now.addingTimeInterval(-lastPollAgo),
                           ideRunning: false, notificationsAuthorized: true,
                           configPath: "/x", records: records, paused: paused)
    }

    // MARK: - Banner derivation (SPEC-UI §7.2)

    func testBannerWatchingWhenFreshAndNotPaused() {
        let now = epoch
        let s = agentState(writtenAgo: 12, lastPollAgo: 12, paused: false, now: now)
        XCTAssertEqual(BannerDeriver.derive(snapshot: s, now: now, config: .default),
                       .watching(lastPollAgo: 12))
    }

    func testBannerPausedWhenFreshHeartbeatAndPaused() {
        let now = epoch
        // Paused agent beats on the idle cadence; a beat well within threshold → paused.
        let s = agentState(writtenAgo: 60, lastPollAgo: 5_000, paused: true, now: now)
        XCTAssertEqual(BannerDeriver.derive(snapshot: s, now: now, config: .default), .paused)
    }

    func testBannerDeadWhenMissingFile() {
        XCTAssertEqual(BannerDeriver.derive(snapshot: nil, now: epoch, config: .default), .dead)
    }

    func testBannerDeadWhenHeartbeatStale() {
        let now = epoch
        // Threshold = 2*idle(120) + grace(30) = 270 s. 271 s → dead.
        let s = agentState(writtenAgo: 271, lastPollAgo: 271, paused: false, now: now)
        XCTAssertEqual(BannerDeriver.derive(snapshot: s, now: now, config: .default), .dead)
    }

    func testBannerStalenessUsesIdleCadenceNotNormalPoll() {
        let now = epoch
        // An idle-backed-off agent writes every 120 s. At 200 s since write it is
        // well within 2*120+30 = 270 s, so it must NOT be declared dead (the bug the
        // effective-cadence math exists to prevent).
        let s = agentState(writtenAgo: 200, lastPollAgo: 200, paused: false, now: now)
        XCTAssertEqual(BannerDeriver.derive(snapshot: s, now: now, config: .default),
                       .watching(lastPollAgo: 200))
    }

    func testBannerThresholdRespectsCustomIdleInterval() {
        let now = epoch
        var cfg = Config.default
        cfg.idlePollIntervalSeconds = 300   // slower idle backoff
        // Threshold = 2*300 + 30 = 630 s. 500 s since write → still watching.
        let fresh = agentState(writtenAgo: 500, lastPollAgo: 500, paused: false, now: now)
        XCTAssertEqual(BannerDeriver.derive(snapshot: fresh, now: now, config: cfg),
                       .watching(lastPollAgo: 500))
        // 700 s → dead.
        let stale = agentState(writtenAgo: 700, lastPollAgo: 700, paused: false, now: now)
        XCTAssertEqual(BannerDeriver.derive(snapshot: stale, now: now, config: cfg), .dead)
    }

    func testBannerPostSleepStaleTripsDead() {
        let now = epoch
        // Mac slept overnight (edge 9): heartbeat is hours old → dead until the next
        // beat lands. Accepted flicker; the matrix must reflect it.
        let s = agentState(writtenAgo: 8 * 3600, lastPollAgo: 8 * 3600, paused: false, now: now)
        XCTAssertEqual(BannerDeriver.derive(snapshot: s, now: now, config: .default), .dead)
    }

    func testBannerLastPollAgoNeverNegative() {
        let now = epoch
        // A future-dated lastPollAt (clock skew) clamps to 0, never negative.
        let s = AgentStateSnapshot(writtenAt: now, agentPid: 1,
                                   lastPollAt: now.addingTimeInterval(5),
                                   ideRunning: false, notificationsAuthorized: nil,
                                   configPath: "/x", records: [], paused: false)
        XCTAssertEqual(BannerDeriver.derive(snapshot: s, now: now, config: .default),
                       .watching(lastPollAgo: 0))
    }

    // MARK: - Verdict precedence (SPEC-UI §10)

    func testVerdictPrecedenceBusyBeatsEverything() {
        let v = DisplayVerdictDeriver.derive(busy: true, owned: true, ownedTag: "O1",
                                             ownershipUnknown: false, agentRule: .runaway,
                                             pending: (3, 4))
        XCTAssertEqual(v, .busy)
    }

    func testVerdictOwnedBeatsFlaggedAndWatching() {
        let v = DisplayVerdictDeriver.derive(busy: false, owned: true, ownedTag: "O4",
                                             ownershipUnknown: false, agentRule: .ownerlessNoIDE,
                                             pending: (2, 4))
        XCTAssertEqual(v, .owned(ruleTag: "O4"))
    }

    func testVerdictFlaggedBeatsWatching() {
        let v = DisplayVerdictDeriver.derive(busy: false, owned: false, ownedTag: nil,
                                             ownershipUnknown: false, agentRule: .ownerlessWithIDE,
                                             pending: (1, 30))
        XCTAssertEqual(v, .flagged(rule: .ownerlessWithIDE))
    }

    func testVerdictUnknownBeatsWatchingButNotOwnedOrFlagged() {
        // ownershipUnknown, no owner/flag → unknown (the model shows last good verdict
        // separately; this is the explicit fallback).
        let v = DisplayVerdictDeriver.derive(busy: false, owned: false, ownedTag: nil,
                                             ownershipUnknown: true, agentRule: nil,
                                             pending: (2, 4))
        XCTAssertEqual(v, .unknown)
    }

    func testVerdictWatchingWhenUnownedPending() {
        let v = DisplayVerdictDeriver.derive(busy: false, owned: false, ownedTag: nil,
                                             ownershipUnknown: false, agentRule: nil,
                                             pending: (2, 4))
        XCTAssertEqual(v, .watching(samples: 2, required: 4))
    }

    func testVerdictHealthyWhenNothingToSay() {
        let v = DisplayVerdictDeriver.derive(busy: false, owned: false, ownedTag: nil,
                                             ownershipUnknown: false, agentRule: nil, pending: nil)
        XCTAssertEqual(v, .healthy)
    }

    func testVerdictPrecedenceOrderingIsStrict() {
        // The precedence integers must be a strict total order in the documented seq.
        let order: [DisplayVerdict] = [.busy, .owned(ruleTag: nil), .flagged(rule: .runaway),
                                       .watching(samples: 1, required: 4), .healthy, .unknown]
        let p = order.map { $0.precedence }
        XCTAssertEqual(p, p.sorted(), "precedence must already be ascending in spec order")
        XCTAssertEqual(Set(p).count, p.count, "no two verdict classes may share a precedence")
    }

    // MARK: - Fast-lane CPU-delta + busy-since (SPEC-UI §5, SPEC §5.3)

    func testFastLaneCPUPercentNilOnFirstSampleThenDelta() {
        var s = FastLaneSampler(idleCpuSecondsPerPoll: 0.5, pollIntervalSeconds: 30)
        let id = ProcessIdentity(pid: 10, startTimeMicros: 1)
        // First tick: no prior → nil CPU%, not busy.
        let t0 = s.ingest([(id, 5.0)], now: epoch)
        XCTAssertNil(t0[id]?.cpuPercent)
        XCTAssertEqual(t0[id]?.busyNow, false)
        // Second tick 2 s later, +4 cpu seconds → 200% (two cores).
        let t1 = s.ingest([(id, 9.0)], now: epoch.addingTimeInterval(2))
        XCTAssertEqual(t1[id]?.cpuPercent ?? 0, 200, accuracy: 0.01)
        XCTAssertEqual(t1[id]?.busyNow, true)
    }

    func testFastLaneBusyThresholdMatchesEngineIdleRate() {
        // idle floor = 0.5 cpu-sec / 30 s poll = 0.0167 cpu-sec/sec. Over a 2 s gap a
        // daemon at EXACTLY the engine's idle rate (0.0333 cpu-sec in 2 s) is NOT busy.
        var s = FastLaneSampler(idleCpuSecondsPerPoll: 0.5, pollIntervalSeconds: 30)
        let id = ProcessIdentity(pid: 11, startTimeMicros: 1)
        _ = s.ingest([(id, 0.0)], now: epoch)
        let idleRate = 0.5 / 30.0
        let belowDelta = idleRate * 2 * 0.9        // just below floor
        let r = s.ingest([(id, belowDelta)], now: epoch.addingTimeInterval(2))
        XCTAssertEqual(r[id]?.busyNow, false, "at/below the engine idle rate is not busy")
        // Just above the floor → busy.
        var s2 = FastLaneSampler(idleCpuSecondsPerPoll: 0.5, pollIntervalSeconds: 30)
        _ = s2.ingest([(id, 0.0)], now: epoch)
        let aboveDelta = idleRate * 2 * 1.5
        let r2 = s2.ingest([(id, aboveDelta)], now: epoch.addingTimeInterval(2))
        XCTAssertEqual(r2[id]?.busyNow, true)
    }

    func testBusySinceSticksAcrossConsecutiveBusyTicks() {
        var s = FastLaneSampler(idleCpuSecondsPerPoll: 0.5, pollIntervalSeconds: 30)
        let id = ProcessIdentity(pid: 12, startTimeMicros: 1)
        _ = s.ingest([(id, 0.0)], now: epoch)
        let firstBusy = epoch.addingTimeInterval(2)
        let r1 = s.ingest([(id, 10.0)], now: firstBusy)        // busy starts here
        XCTAssertEqual(r1[id]?.busySince, firstBusy)
        let r2 = s.ingest([(id, 20.0)], now: epoch.addingTimeInterval(4))  // still busy
        XCTAssertEqual(r2[id]?.busySince, firstBusy, "busy-since holds the original edge")
    }

    func testBusySinceResetsWhenBusyClears() {
        var s = FastLaneSampler(idleCpuSecondsPerPoll: 0.5, pollIntervalSeconds: 30)
        let id = ProcessIdentity(pid: 13, startTimeMicros: 1)
        _ = s.ingest([(id, 0.0)], now: epoch)
        _ = s.ingest([(id, 10.0)], now: epoch.addingTimeInterval(2))   // busy
        let idle = s.ingest([(id, 10.0)], now: epoch.addingTimeInterval(4))  // no cpu → idle
        XCTAssertEqual(idle[id]?.busyNow, false)
        XCTAssertNil(idle[id]?.busySince, "busy-since clears when busy ends")
        // Re-busy starts a NEW session timestamp.
        let reBusy = epoch.addingTimeInterval(6)
        let r = s.ingest([(id, 20.0)], now: reBusy)
        XCTAssertEqual(r[id]?.busySince, reBusy)
    }

    func testFastLaneDropsVanishedIdentities() {
        var s = FastLaneSampler(idleCpuSecondsPerPoll: 0.5, pollIntervalSeconds: 30)
        let a = ProcessIdentity(pid: 14, startTimeMicros: 1)
        let b = ProcessIdentity(pid: 15, startTimeMicros: 1)
        _ = s.ingest([(a, 0.0), (b, 0.0)], now: epoch)
        // b disappears; a stays. a still gets a delta, b is simply absent.
        let r = s.ingest([(a, 10.0)], now: epoch.addingTimeInterval(2))
        XCTAssertNotNil(r[a]?.cpuPercent)
        XCTAssertNil(r[b])
    }

    // MARK: - Fast/slow merge: numbers update, verdicts persist (SPEC-UI §5)

    func testMergeFastUpdatesNumbersSlowVerdictsPersist() {
        let id = ProcessIdentity(pid: 20, startTimeMicros: 1)
        let present = [(identity: id, kind: DaemonKind.gradle, displayName: "Gradle 8.13 (p)")]
        // Slow lane resolved: owned (O1). Fast lane: cheap numbers, low CPU.
        let slow = [id: DaemonRowMerger.SlowFacts(owned: true, ownedTag: "O1",
                                                  ownershipUnknown: false, attachedClientDescription: "Studio")]
        let fast0 = [id: DaemonRowMerger.FastFacts(rssBytes: 1_000, cpuPercent: 5, uptime: 10,
                                                   busyNow: false, busySince: nil)]
        let row0 = DaemonRowMerger.merge(present: present, fast: fast0, slow: slow, agent: [:]).first!
        XCTAssertEqual(row0.verdict, .owned(ruleTag: "O1"))
        XCTAssertEqual(row0.rssBytes, 1_000)

        // A fast tick later: numbers change, slow facts UNCHANGED → verdict still owned.
        let fast1 = [id: DaemonRowMerger.FastFacts(rssBytes: 2_500, cpuPercent: 12, uptime: 12,
                                                   busyNow: false, busySince: nil)]
        let row1 = DaemonRowMerger.merge(present: present, fast: fast1, slow: slow, agent: [:]).first!
        XCTAssertEqual(row1.rssBytes, 2_500, "fast lane updates RSS")
        XCTAssertEqual(row1.cpuPercent, 12, "fast lane updates CPU")
        XCTAssertEqual(row1.verdict, .owned(ruleTag: "O1"), "verdict persists between slow ticks")
    }

    func testMergeNewDaemonShowsNumbersBeforeSlowCatchesUp() {
        // A daemon that appeared since the last slow tick: fast facts present, no slow
        // facts yet → live numbers immediately, verdict healthy/watching (not crash).
        let id = ProcessIdentity(pid: 21, startTimeMicros: 1)
        let present = [(identity: id, kind: DaemonKind.gradle, displayName: "Gradle")]
        let fast = [id: DaemonRowMerger.FastFacts(rssBytes: 500, cpuPercent: 1, uptime: 1,
                                                  busyNow: false, busySince: nil)]
        let row = DaemonRowMerger.merge(present: present, fast: fast, slow: [:], agent: [:]).first!
        XCTAssertEqual(row.rssBytes, 500)
        XCTAssertEqual(row.verdict, .healthy)
    }

    func testMergeSortIsBusyOwnedFlaggedWatchingHealthy() {
        func mk(_ pid: Int32) -> (identity: ProcessIdentity, kind: DaemonKind, displayName: String) {
            (ProcessIdentity(pid: pid, startTimeMicros: 1), .gradle, "d\(pid)")
        }
        let busyID = mk(1), ownedID = mk(2), flaggedID = mk(3), watchID = mk(4), healthyID = mk(5)
        let present = [healthyID, watchID, flaggedID, ownedID, busyID]   // deliberately reversed
        let fast: [ProcessIdentity: DaemonRowMerger.FastFacts] = [
            busyID.identity: .init(rssBytes: 0, cpuPercent: 200, uptime: 0, busyNow: true, busySince: epoch),
        ]
        let slow: [ProcessIdentity: DaemonRowMerger.SlowFacts] = [
            ownedID.identity: .init(owned: true, ownedTag: "O1", ownershipUnknown: false, attachedClientDescription: nil),
        ]
        let agent: [ProcessIdentity: DaemonRowMerger.AgentFacts] = [
            flaggedID.identity: .init(stateDescription: "flagged(R1)", flaggedRule: .ownerlessNoIDE,
                                      pendingSamples: 0, pendingRequired: 0),
            watchID.identity: .init(stateDescription: "healthy", flaggedRule: nil,
                                    pendingSamples: 2, pendingRequired: 4),
        ]
        let sorted = DaemonRowMerger.sorted(
            DaemonRowMerger.merge(present: present, fast: fast, slow: slow, agent: agent))
        XCTAssertEqual(sorted.map { $0.identity.pid }, [1, 2, 3, 4, 5])
    }

    // MARK: - ownershipUnknown keeps previous verdict (SPEC-UI §8)

    func testOwnershipUnknownSlowFactKeepsModelFromFlagging() {
        // OwnershipFacts maps an ownershipUnknown observation to owned=false +
        // ownershipUnknown=true — never owned, never a flag source. The model carries
        // the PREVIOUS slow facts (it only overwrites per-identity on a successful
        // resolve), so a single bad lsof never downgrades a known-owned daemon.
        let id = ProcessIdentity(pid: 30, startTimeMicros: 1_000)
        let unknownObs = DaemonObservation(process: proc(30), ownershipUnknown: true)
        let snap = PollSnapshot(timestamp: epoch, daemons: [unknownObs], ideRunning: false)
        let facts = OwnershipFacts.derive(from: snap)
        XCTAssertEqual(facts[id]?.ownershipUnknown, true)
        XCTAssertEqual(facts[id]?.owned, false)
        // Verdict for an unknown daemon with no agent opinion → .unknown (not flagged).
        let present = [(identity: id, kind: DaemonKind.gradle, displayName: "g")]
        let row = DaemonRowMerger.merge(present: present, fast: [:], slow: facts, agent: [:]).first!
        XCTAssertEqual(row.verdict, .unknown)
    }

    func testOwnershipFactsTagsO1O2O4() {
        // O1: IDE parent.
        let g1 = DaemonObservation(process: proc(40, kind: .gradle), parentIsIDE: true)
        // O2: attached client.
        let g2 = DaemonObservation(process: proc(41, kind: .gradle), hasAttachedClient: true)
        // O4: Kotlin linked to an owned gradle.
        let gOwned = DaemonObservation(process: proc(42, kind: .gradle), hasAttachedClient: true)
        let k = DaemonObservation(process: proc(43, kind: .kotlin, ppid: 42), linkedGradlePid: 42)
        let snap = PollSnapshot(timestamp: epoch, daemons: [g1, g2, gOwned, k], ideRunning: true)
        let facts = OwnershipFacts.derive(from: snap)
        XCTAssertEqual(facts[g1.process.identity]?.ownedTag, "O1")
        XCTAssertEqual(facts[g2.process.identity]?.ownedTag, "O2")
        XCTAssertEqual(facts[k.process.identity]?.ownedTag, "O4")
        XCTAssertEqual(facts[k.process.identity]?.owned, true)
    }

    // MARK: - AgentFacts: highest-progress pending counter (SPEC-UI §10 watching n/m)

    func testAgentFactsPicksHighestProgressPendingRule() {
        let id = ProcessIdentity(pid: 50, startTimeMicros: 1)
        // R1 at 3/4 (0.75) vs R3 at 10/240 (0.04) → R1 wins for the watching label.
        let record = ProcessStateRecord(
            identity: id, kind: .gradle, displayName: "g", stateDescription: "healthy",
            ruleCounters: [Rule.ownerlessNoIDE.rawValue: 3, Rule.idleTooLong.rawValue: 10],
            owned: false, flaggedRule: nil, snoozedUntil: nil, lastSeen: epoch, rssBytes: 0)
        let snap = AgentStateSnapshot(writtenAt: epoch, agentPid: 1, lastPollAt: epoch,
                                      ideRunning: false, notificationsAuthorized: nil,
                                      configPath: "/x", records: [record], paused: false)
        let facts = AgentFactsDeriver.derive(from: snap, config: .default)
        XCTAssertEqual(facts[id]?.pendingSamples, 3)
        XCTAssertEqual(facts[id]?.pendingRequired,
                       Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE))
    }

    func testAgentFactsFlaggedRuleSurfaced() {
        let id = ProcessIdentity(pid: 51, startTimeMicros: 1)
        let record = ProcessStateRecord(
            identity: id, kind: .gradle, displayName: "g", stateDescription: "flagged(R2)",
            ruleCounters: [:], owned: false, flaggedRule: .ownerlessWithIDE,
            snoozedUntil: nil, lastSeen: epoch, rssBytes: 0)
        let snap = AgentStateSnapshot(writtenAt: epoch, agentPid: 1, lastPollAt: epoch,
                                      ideRunning: false, notificationsAuthorized: nil,
                                      configPath: "/x", records: [record], paused: false)
        let facts = AgentFactsDeriver.derive(from: snap, config: .default)
        XCTAssertEqual(facts[id]?.flaggedRule, .ownerlessWithIDE)
        XCTAssertEqual(facts[id]?.stateDescription, "flagged(R2)")
    }

    // MARK: - CLI: --ui mode entry (V2-M1)

    func testUIFlagParsesToUIMode() {
        switch CLIOptions.parse(["daemonslayer", "--ui"]) {
        case .success(let o): XCTAssertEqual(o.mode, .ui)
        case .failure(let e): XCTFail("--ui should parse: \(e.message)")
        }
    }

    func testNoArgsHasNilModeForUIDefault() {
        // No args → nil mode; main.swift routes nil (and .ui) into the window.
        switch CLIOptions.parse(["daemonslayer"]) {
        case .success(let o): XCTAssertNil(o.mode)
        case .failure(let e): XCTFail("no-args should parse: \(e.message)")
        }
    }
}
