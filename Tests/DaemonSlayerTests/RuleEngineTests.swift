import XCTest
@testable import daemonslayer

/// RuleEngine is pure logic (spec §15): synthetic snapshots in, asserted transitions out.
/// All time is fabricated — snapshots step a fixed `poll` (30 s) apart from a fixed epoch.
/// No Date(), no I/O, deterministic.
final class RuleEngineTests: XCTestCase {

    // MARK: - Builders

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let poll: TimeInterval = 30   // matches default pollIntervalSeconds

    private func t(_ step: Int) -> Date { epoch.addingTimeInterval(Double(step) * poll) }

    private func identity(_ pid: Int32, start: Int64 = 1_000) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeMicros: start)
    }

    private func daemon(_ pid: Int32, kind: DaemonKind = .gradle, ppid: Int32 = 1,
                        cpu: Double = 0, start: Int64 = 1_000,
                        rss: UInt64 = 100 * 1_048_576) -> DaemonProcess {
        DaemonProcess(
            identity: identity(pid, start: start),
            kind: kind,
            ppid: ppid,
            rssBytes: rss,
            cpuTimeSeconds: cpu,
            argv: ["java", kind == .gradle ? DaemonKind.gradleArgvMarker : DaemonKind.kotlinArgvMarker],
            gradleVersion: kind == .gradle ? "8.13" : nil,
            projectHint: "proj",
            kotlinAliveMarkerPath: kind == .kotlin ? "/tmp/marker.alive" : nil
        )
    }

    /// One observation. `owned` is expressed via parentIsIDE / hasAttachedClient.
    /// Argument order is permissive: every parameter is keyworded with a default, but
    /// Swift requires call-site order to match this declaration order, so keep the
    /// "shape" arguments (parentIsIDE/client/linkedGradlePid/unknown) before cpu/start.
    private func obs(_ pid: Int32, kind: DaemonKind = .gradle, ppid: Int32 = 1,
                     parentIsIDE: Bool = false, client: Bool = false,
                     linkedGradlePid: Int32? = nil, unknown: Bool = false,
                     cpu: Double = 0, start: Int64 = 1_000,
                     rss: UInt64 = 100 * 1_048_576) -> DaemonObservation {
        DaemonObservation(
            process: daemon(pid, kind: kind, ppid: ppid, cpu: cpu, start: start, rss: rss),
            parentIsIDE: parentIsIDE,
            hasAttachedClient: client,
            listenPorts: [],
            linkedGradlePid: linkedGradlePid,
            ownershipUnknown: unknown
        )
    }

    private func snap(_ step: Int, ideRunning: Bool, _ daemons: [DaemonObservation]) -> PollSnapshot {
        PollSnapshot(timestamp: t(step), daemons: daemons, ideRunning: ideRunning)
    }

    private func engine(_ config: Config = .default) -> RuleEngine { RuleEngine(config: config) }

    // Convenience assertions over a single output.
    private func orphanBatch(_ out: RuleEngineOutput) -> NotificationBatch? {
        out.notifications.first { $0.category == .orphanFound }
    }
    private func runawayBatch(_ out: RuleEngineOutput) -> NotificationBatch? {
        out.notifications.first { $0.category == .runawayFound }
    }

    // MARK: - R1: ownerlessNoIDE

    func testR1FiresAfterExactlyThresholdConsecutiveSamples() {
        // Default R1 = 2 min / 30 s poll = 4 consecutive samples.
        let e = engine()
        let required = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)
        XCTAssertEqual(required, 4)

        // First (required-1) samples: counting up, never fires.
        for i in 0..<(required - 1) {
            let out = e.ingest(snap(i, ideRunning: false, [obs(100)]))
            XCTAssertTrue(out.notifications.isEmpty, "must not fire before threshold (sample \(i))")
        }
        // The required-th matching sample fires R1.
        let out = e.ingest(snap(required - 1, ideRunning: false, [obs(100)]))
        let batch = orphanBatch(out)
        XCTAssertNotNil(batch)
        XCTAssertEqual(batch?.processes.count, 1)
        XCTAssertEqual(batch?.processes.first?.rule, .ownerlessNoIDE)
        // candidateSince = run-start = first matching sample's timestamp.
        XCTAssertEqual(batch?.processes.first?.candidateSince, t(0))
    }

    func testR1OwnershipRegainMidWindowResetsCounter() {
        let e = engine()
        // 3 ownerless samples (one short of firing).
        _ = e.ingest(snap(0, ideRunning: false, [obs(100)]))
        _ = e.ingest(snap(1, ideRunning: false, [obs(100)]))
        _ = e.ingest(snap(2, ideRunning: false, [obs(100)]))
        // Sample 3: regains ownership (client attached) → counter resets.
        let regained = e.ingest(snap(3, ideRunning: false, [obs(100, client: true)]))
        XCTAssertTrue(regained.notifications.isEmpty)
        // Now needs a FULL fresh window of 4 again.
        _ = e.ingest(snap(4, ideRunning: false, [obs(100)]))   // 1
        _ = e.ingest(snap(5, ideRunning: false, [obs(100)]))   // 2
        let three = e.ingest(snap(6, ideRunning: false, [obs(100)]))  // 3 — still nothing
        XCTAssertTrue(three.notifications.isEmpty)
        let four = e.ingest(snap(7, ideRunning: false, [obs(100)]))   // 4 — fires
        XCTAssertNotNil(orphanBatch(four))
        XCTAssertEqual(orphanBatch(four)?.processes.first?.candidateSince, t(4))
    }

    // MARK: - R1 vs R2 selection by ideRunning

    func testR2RequiresIdeRunningPlusDetachedPlusIdle() {
        // R2 = 15 min / 30 s = 30 samples.
        let e = engine()
        let required = Config.default.requiredConsecutiveSamples(for: .ownerlessWithIDE)
        XCTAssertEqual(required, 30)

        // First sample establishes a baseline (no CPU delta yet → not idle, R2 unmatchable).
        // ownerless + IDE running + detached(ppid 1) + idle thereafter.
        var cpu = 0.0
        for i in 0..<required {
            // CPU stays flat → idleThisSample true from sample 1 on.
            let out = e.ingest(snap(i, ideRunning: true, [obs(200, ppid: 1, cpu: cpu)]))
            XCTAssertTrue(out.notifications.isEmpty, "R2 must not fire early (sample \(i))")
            cpu += 0.0   // flat CPU
        }
        // Sample `required` (index required, the 30th *matching* sample) fires.
        // Sample 0 had no delta → idle started at sample 1, so matching run is samples 1..required.
        // Need 30 matching samples → fires at index 30.
        let out = e.ingest(snap(required, ideRunning: true, [obs(200, ppid: 1, cpu: cpu)]))
        XCTAssertNotNil(orphanBatch(out))
        XCTAssertEqual(orphanBatch(out)?.processes.first?.rule, .ownerlessWithIDE)
    }

    func testR2DoesNotFireWhenNotDetached() {
        // Same as above but ppid != 1 → R2 condition (detached) fails forever.
        let e = engine()
        let required = Config.default.requiredConsecutiveSamples(for: .ownerlessWithIDE)
        for i in 0...(required + 2) {
            let out = e.ingest(snap(i, ideRunning: true, [obs(201, ppid: 999, cpu: 0)]))
            XCTAssertTrue(out.notifications.isEmpty, "R2 needs detached; ppid 999 must never fire")
        }
    }

    func testR2DoesNotFireWhenBusy() {
        // Detached + IDE running, but burning CPU each sample → not idle → R2 never fires.
        let e = engine()
        let required = Config.default.requiredConsecutiveSamples(for: .ownerlessWithIDE)
        var cpu = 0.0
        for i in 0...(required + 2) {
            cpu += 5.0   // way above idleCpuSecondsPerPoll
            let out = e.ingest(snap(i, ideRunning: true, [obs(202, ppid: 1, cpu: cpu)]))
            // R2 stays silent. (R4 also won't fire: a client is not attached but cpuPercent
            //  here is 5/30*100 ≈ 16.7% < 50% threshold.)
            XCTAssertTrue(out.notifications.isEmpty)
        }
    }

    func testR1SelectedWhenNoIDEEvenIfDetachedAndIdle() {
        // No IDE → R1 path (4 samples), NOT R2.
        let e = engine()
        for i in 0..<3 { _ = e.ingest(snap(i, ideRunning: false, [obs(203, ppid: 1, cpu: 0)])) }
        let out = e.ingest(snap(3, ideRunning: false, [obs(203, ppid: 1, cpu: 0)]))
        XCTAssertEqual(orphanBatch(out)?.processes.first?.rule, .ownerlessNoIDE)
    }

    // MARK: - R3: idleTooLong

    func testR3FiresWhenOwnedAndIdleForWindow() {
        // R3 = 120 min / 30 s = 240 samples. Use a tiny config to keep the loop short.
        var cfg = Config.default
        cfg.rules.idleTooLong = RuleConfig(enabled: true, thresholdMinutes: 1.5)  // 90s/30 = 3 samples
        // Disable R1/R2 noise so only R3 is in play.
        cfg.rules.ownerlessNoIDE = RuleConfig(enabled: false, thresholdMinutes: 2)
        cfg.rules.ownerlessWithIDE = RuleConfig(enabled: false, thresholdMinutes: 15)
        let e = engine(cfg)
        let required = cfg.requiredConsecutiveSamples(for: .idleTooLong)
        XCTAssertEqual(required, 3)

        // Owned (client attached) + idle (flat CPU). Sample 0 = baseline (no delta).
        for i in 0..<required {
            let out = e.ingest(snap(i, ideRunning: true, [obs(300, client: true, cpu: 0)]))
            XCTAssertTrue(out.notifications.isEmpty)
        }
        // Matching run is samples 1..required → fires at index `required`.
        let out = e.ingest(snap(required, ideRunning: true, [obs(300, client: true, cpu: 0)]))
        XCTAssertEqual(orphanBatch(out)?.processes.first?.rule, .idleTooLong)
        // idleSeconds present for R3.
        XCTAssertNotNil(orphanBatch(out)?.processes.first?.idleSeconds)
    }

    func testR3SingleBusySampleResets() {
        var cfg = Config.default
        cfg.rules.idleTooLong = RuleConfig(enabled: true, thresholdMinutes: 1.5)  // 3 samples
        cfg.rules.ownerlessNoIDE = RuleConfig(enabled: false, thresholdMinutes: 2)
        cfg.rules.ownerlessWithIDE = RuleConfig(enabled: false, thresholdMinutes: 15)
        let e = engine(cfg)

        _ = e.ingest(snap(0, ideRunning: true, [obs(301, client: true, cpu: 0)]))   // baseline
        _ = e.ingest(snap(1, ideRunning: true, [obs(301, client: true, cpu: 0)]))   // idle 1
        _ = e.ingest(snap(2, ideRunning: true, [obs(301, client: true, cpu: 0)]))   // idle 2
        // Busy sample → reset.
        _ = e.ingest(snap(3, ideRunning: true, [obs(301, client: true, cpu: 10)]))  // busy, reset
        let out = e.ingest(snap(4, ideRunning: true, [obs(301, client: true, cpu: 10)])) // idle again (1)
        XCTAssertTrue(out.notifications.isEmpty, "one busy sample must reset R3")
    }

    // MARK: - R4: runaway

    func testR4RequiresClientlessAndSustainedHotCPU() {
        // R4 = 2 min / 30 s = 4 samples. cpuThreshold default 50% of one core.
        let e = engine()
        let required = Config.default.requiredConsecutiveSamples(for: .runaway)
        XCTAssertEqual(required, 4)

        // Clientless + hot: +30 CPU-seconds per 30 s poll = 100% → > 50%.
        // ideRunning=true isolates R4: R1 needs no-IDE, R2 needs idle, R3 needs owned —
        // none apply to a hot, IDE-present, clientless daemon, so only R4 is in play.
        var cpu = 0.0
        // Sample 0 = baseline (no delta → R4 unmatchable).
        _ = e.ingest(snap(0, ideRunning: true, [obs(400, client: false, cpu: cpu)]))
        // Samples 1..4 are matching → fires on the 4th matching sample (index 4).
        for i in 1..<required {
            cpu += 30
            let out = e.ingest(snap(i, ideRunning: true, [obs(400, client: false, cpu: cpu)]))
            XCTAssertTrue(out.notifications.isEmpty, "R4 needs 4 sustained samples (i=\(i))")
        }
        cpu += 30
        let out = e.ingest(snap(required, ideRunning: true, [obs(400, client: false, cpu: cpu)]))
        let rb = runawayBatch(out)
        XCTAssertNotNil(rb)
        XCTAssertEqual(rb?.processes.first?.rule, .runaway)
        // cpuPercent present for R4 (~100%).
        XCTAssertEqual(rb?.processes.first?.cpuPercent ?? 0, 100, accuracy: 1)
    }

    func testR4NeverFiresWithClientAttachedEvenWhenHot() {
        let e = engine()
        let required = Config.default.requiredConsecutiveSamples(for: .runaway)
        var cpu = 0.0
        for i in 0...(required + 2) {
            cpu += 30   // hot
            let out = e.ingest(snap(i, ideRunning: true, [obs(401, client: true, cpu: cpu)]))
            // client attached → R4 condition false; owned+busy → not idle → R3 false too.
            XCTAssertTrue(runawayBatch(out) == nil, "client attached → never R4")
        }
    }

    func testR4FiresForO1OwnedClientlessHotDaemon() {
        // R4 deliberately ignores `owned`: a parent-IDE-owned but clientless hot daemon
        // still flags as runaway (spec table: clientless + hot).
        let e = engine()
        let required = Config.default.requiredConsecutiveSamples(for: .runaway)
        var cpu = 0.0
        _ = e.ingest(snap(0, ideRunning: true, [obs(402, ppid: 555, parentIsIDE: true, client: false, cpu: cpu)]))
        for i in 1..<required {
            cpu += 30
            _ = e.ingest(snap(i, ideRunning: true, [obs(402, ppid: 555, parentIsIDE: true, client: false, cpu: cpu)]))
        }
        cpu += 30
        let out = e.ingest(snap(required, ideRunning: true, [obs(402, ppid: 555, parentIsIDE: true, client: false, cpu: cpu)]))
        XCTAssertEqual(runawayBatch(out)?.processes.first?.rule, .runaway)
    }

    // MARK: - Hysteresis exactness

    func testHysteresisExactnessThresholdMinusOneNoFireThenFires() {
        let e = engine()
        let required = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)  // 4
        for i in 0..<(required - 1) {
            XCTAssertTrue(e.ingest(snap(i, ideRunning: false, [obs(110)])).notifications.isEmpty)
        }
        XCTAssertNotNil(orphanBatch(e.ingest(snap(required - 1, ideRunning: false, [obs(110)]))))
    }

    // MARK: - Snooze

    func testSnoozeSilencesUntilExpiryThenReflagsIfStillMatching() {
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)  // 4
        // Flag R1.
        for i in 0..<(req - 1) { _ = e.ingest(snap(i, ideRunning: false, [obs(500)])) }
        let fired = e.ingest(snap(req - 1, ideRunning: false, [obs(500)]))
        XCTAssertNotNil(orphanBatch(fired))

        // User snoozes until t(req-1 + 10) (=5 min later).
        let until = t(req - 1 + 10)
        e.snooze([identity(500)], until: until)

        // While snoozed and condition persists → silent.
        for i in (req)...(req + 8) {
            let out = e.ingest(snap(i, ideRunning: false, [obs(500)]))
            XCTAssertTrue(out.notifications.isEmpty, "snoozed → silent (i=\(i))")
        }
        // At/after expiry, still matching → re-flagged + emitted.
        let reflag = e.ingest(snap(req - 1 + 10, ideRunning: false, [obs(500)]))
        XCTAssertNotNil(orphanBatch(reflag), "expiry with condition still matching → re-flag")
        XCTAssertEqual(orphanBatch(reflag)?.processes.first?.rule, .ownerlessNoIDE)
    }

    func testSnoozeExpiryWithConditionClearedGoesHealthySilent() {
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)
        for i in 0..<(req - 1) { _ = e.ingest(snap(i, ideRunning: false, [obs(501)])) }
        _ = e.ingest(snap(req - 1, ideRunning: false, [obs(501)]))
        let until = t(req - 1 + 10)
        e.snooze([identity(501)], until: until)

        // During snooze the condition CLEARS (regains ownership) → counter resets while snoozed.
        for i in (req)...(req + 8) {
            _ = e.ingest(snap(i, ideRunning: false, [obs(501, client: true)]))
        }
        // At expiry, no rule over threshold → healthy, silent.
        let out = e.ingest(snap(req - 1 + 10, ideRunning: false, [obs(501, client: true)]))
        XCTAssertTrue(out.notifications.isEmpty)
        // Confirm healthy via stateRecords.
        let rec = e.stateRecords().first { $0.identity == identity(501) }
        XCTAssertEqual(rec?.stateDescription, "healthy")
    }

    func testSnoozeOnNonFlaggedIsNoOp() {
        let e = engine()
        _ = e.ingest(snap(0, ideRunning: false, [obs(502)]))  // healthy, counter 1
        e.snooze([identity(502)], until: t(100))
        let rec = e.stateRecords().first { $0.identity == identity(502) }
        XCTAssertEqual(rec?.stateDescription, "healthy", "snooze from non-flagged → no-op")
        e.snooze([identity(9999)], until: t(100))  // unknown identity → no crash, no-op
    }

    // MARK: - Re-notify cadence

    func testReNotifyOnlyAfterSnoozeMinutesAndStableIdentifier() {
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)  // 4
        for i in 0..<(req - 1) { _ = e.ingest(snap(i, ideRunning: false, [obs(600)])) }
        let first = e.ingest(snap(req - 1, ideRunning: false, [obs(600)]))
        let firstId = orphanBatch(first)?.identifier
        XCTAssertNotNil(firstId)

        // snoozeMinutes default = 60 min = 120 samples. Within that window → no re-notify.
        let cadence = Int(Config.default.snoozeMinutes * 60 / poll)  // 120
        for i in (req)..<(req - 1 + cadence) {
            XCTAssertTrue(e.ingest(snap(i, ideRunning: false, [obs(600)])).notifications.isEmpty,
                          "no re-notify before snoozeMinutes (i=\(i))")
        }
        // At exactly lastNotifiedAt + snoozeMinutes → re-notify with the SAME identifier.
        let re = e.ingest(snap(req - 1 + cadence, ideRunning: false, [obs(600)]))
        XCTAssertNotNil(orphanBatch(re))
        XCTAssertEqual(orphanBatch(re)?.identifier, firstId, "identifier stable for identical process-set")
    }

    func testBatchIdentifierStableRegardlessOfInputOrder() {
        // Two daemons flagged together → identifier sorts pids deterministically.
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)
        for i in 0..<(req - 1) {
            _ = e.ingest(snap(i, ideRunning: false, [obs(700), obs(701)]))
        }
        let out = e.ingest(snap(req - 1, ideRunning: false, [obs(701), obs(700)]))  // reversed order
        let id = orphanBatch(out)?.identifier
        XCTAssertEqual(id, "ORPHAN_FOUND-700.1000+701.1000")
    }

    // MARK: - Ignore terminal

    func testIgnoreIsTerminal() {
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)
        for i in 0..<(req - 1) { _ = e.ingest(snap(i, ideRunning: false, [obs(800)])) }
        _ = e.ingest(snap(req - 1, ideRunning: false, [obs(800)]))
        e.ignore([identity(800)])
        // Never emitted again, even though condition persists for many samples.
        for i in (req)...(req + 20) {
            XCTAssertTrue(e.ingest(snap(i, ideRunning: false, [obs(800)])).notifications.isEmpty)
        }
        // Still present in stateRecords as ignored.
        let rec = e.stateRecords().first { $0.identity == identity(800) }
        XCTAssertEqual(rec?.stateDescription, "ignored")
    }

    func testIgnoreWorksFromHealthy() {
        let e = engine()
        _ = e.ingest(snap(0, ideRunning: false, [obs(801)]))  // healthy
        e.ignore([identity(801)])
        for i in 1...10 {
            XCTAssertTrue(e.ingest(snap(i, ideRunning: false, [obs(801)])).notifications.isEmpty)
        }
        XCTAssertEqual(e.stateRecords().first { $0.identity == identity(801) }?.stateDescription, "ignored")
    }

    // MARK: - PID reuse / vanished identity

    func testPidReuseMidWindowRestartsCounters() {
        let e = engine()
        // 3 ownerless samples for pid 900 / start 1000.
        for i in 0..<3 { _ = e.ingest(snap(i, ideRunning: false, [obs(900, start: 1_000)])) }
        // Sample 3: SAME pid, DIFFERENT start time → brand-new process, old state dropped.
        let out = e.ingest(snap(3, ideRunning: false, [obs(900, start: 2_000)]))
        XCTAssertTrue(out.notifications.isEmpty, "PID reuse must restart counters")
        // The new identity needs a full fresh window.
        _ = e.ingest(snap(4, ideRunning: false, [obs(900, start: 2_000)]))  // 2
        _ = e.ingest(snap(5, ideRunning: false, [obs(900, start: 2_000)]))  // 3
        let fired = e.ingest(snap(6, ideRunning: false, [obs(900, start: 2_000)]))  // 4
        XCTAssertNotNil(orphanBatch(fired))
        XCTAssertEqual(orphanBatch(fired)?.processes.first?.candidateSince, t(3))
        // Only the new identity is tracked.
        XCTAssertNil(e.stateRecords().first { $0.identity == identity(900, start: 1_000) })
        XCTAssertNotNil(e.stateRecords().first { $0.identity == identity(900, start: 2_000) })
    }

    func testVanishedIdentityDropsState() {
        let e = engine()
        _ = e.ingest(snap(0, ideRunning: false, [obs(910)]))
        XCTAssertNotNil(e.stateRecords().first { $0.identity == identity(910) })
        // Next snapshot lacks pid 910 → state dropped.
        _ = e.ingest(snap(1, ideRunning: false, []))
        XCTAssertNil(e.stateRecords().first { $0.identity == identity(910) })
    }

    // MARK: - O4 lockstep

    func testO4KotlinLinkedToUnownedGradleFlagsSameBatchEvenWhenKotlinAppearedLater() {
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)  // 4
        // Gradle (pid 1000) ownerless+noIDE for the full window; Kotlin (pid 1001) only
        // appears at the LAST sample, linked to the Gradle. O4 copies Gradle's counters
        // so the Kotlin fires in the SAME ingest + batch as the Gradle.
        let g: () -> DaemonObservation = { self.obs(1000, kind: .gradle, ppid: 1) }
        for i in 0..<(req - 1) { _ = e.ingest(snap(i, ideRunning: false, [g()])) }
        let k = obs(1001, kind: .kotlin, ppid: 1, linkedGradlePid: 1000)
        let out = e.ingest(snap(req - 1, ideRunning: false, [g(), k]))
        let batch = orphanBatch(out)
        XCTAssertNotNil(batch)
        XCTAssertEqual(batch?.processes.count, 2, "Gradle + lockstepped Kotlin both fire same batch")
        let rules = Set(batch!.processes.map { $0.rule })
        XCTAssertEqual(rules, [.ownerlessNoIDE])
        let pids = Set(batch!.processes.map { $0.process.pid })
        XCTAssertEqual(pids, [1000, 1001])
    }

    func testO4KotlinLinkedToOwnedGradleNeverFlags() {
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)
        // Gradle owned via client; Kotlin inherits ownership (O4 in Ownership.isOwned).
        for i in 0...(req + 4) {
            let g = obs(1010, kind: .gradle, client: true)
            let k = obs(1011, kind: .kotlin, ppid: 1, linkedGradlePid: 1010)
            let out = e.ingest(snap(i, ideRunning: false, [g, k]))
            XCTAssertTrue(out.notifications.isEmpty, "linked-to-owned Gradle → Kotlin never flags (i=\(i))")
        }
    }

    func testO4KotlinWithNoGradleEvaluatedStandalone() {
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)  // 4
        // No Gradle at all; Kotlin has no linkedGradlePid → standalone R1 after own window.
        for i in 0..<(req - 1) {
            XCTAssertTrue(e.ingest(snap(i, ideRunning: false, [obs(1020, kind: .kotlin, ppid: 1)])).notifications.isEmpty)
        }
        let out = e.ingest(snap(req - 1, ideRunning: false, [obs(1020, kind: .kotlin, ppid: 1)]))
        XCTAssertEqual(orphanBatch(out)?.processes.first?.rule, .ownerlessNoIDE)
    }

    // MARK: - ownershipUnknown

    func testOwnershipUnknownKeepsPreviousVerdict() {
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)  // 4
        // Sample 0: resolved as OWNED (client). prevOwned = true.
        _ = e.ingest(snap(0, ideRunning: false, [obs(1100, client: true)]))
        // Samples 1..: ownershipUnknown → carry over previous verdict (owned) → R1 won't match.
        for i in 1...(req + 4) {
            let out = e.ingest(snap(i, ideRunning: false, [obs(1100, unknown: true)]))
            XCTAssertTrue(out.notifications.isEmpty, "unknown carries previous owned verdict → no R1 (i=\(i))")
        }
        let rec = e.stateRecords().first { $0.identity == identity(1100) }
        XCTAssertEqual(rec?.owned, true)
    }

    func testOwnershipUnknownFromFirstSightDefaultsOwned() {
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)
        // Unknown from the very first sample → defaults owned → R1 cannot match.
        for i in 0...(req + 4) {
            let out = e.ingest(snap(i, ideRunning: false, [obs(1101, unknown: true)]))
            XCTAssertTrue(out.notifications.isEmpty, "unknown-from-first-sight defaults owned (i=\(i))")
        }
        XCTAssertEqual(e.stateRecords().first { $0.identity == identity(1101) }?.owned, true)
    }

    // MARK: - Auto-kill routing

    func testAutoKillRoutesToOutputAutoKillNotBatchAndSetsKilling() {
        var cfg = Config.default
        cfg.autoKill = AutoKillConfig(enabled: true, rules: [Rule.ownerlessNoIDE.rawValue])
        let e = engine(cfg)
        let req = cfg.requiredConsecutiveSamples(for: .ownerlessNoIDE)  // 4
        for i in 0..<(req - 1) { _ = e.ingest(snap(i, ideRunning: false, [obs(1200)])) }
        let out = e.ingest(snap(req - 1, ideRunning: false, [obs(1200)]))
        // No notification; goes to autoKill instead.
        XCTAssertTrue(out.notifications.isEmpty)
        XCTAssertEqual(out.autoKill.count, 1)
        XCTAssertEqual(out.autoKill.first?.rule, .ownerlessNoIDE)
        // Lifecycle is killing.
        XCTAssertEqual(e.stateRecords().first { $0.identity == identity(1200) }?.stateDescription, "killing")
        // While killing → nothing emitted on subsequent ingests.
        let after = e.ingest(snap(req, ideRunning: false, [obs(1200)]))
        XCTAssertTrue(after.notifications.isEmpty && after.autoKill.isEmpty)
    }

    func testClearKillingSurvivorGoesHealthyAndResetsCounters() {
        var cfg = Config.default
        cfg.autoKill = AutoKillConfig(enabled: true, rules: [Rule.ownerlessNoIDE.rawValue])
        let e = engine(cfg)
        let req = cfg.requiredConsecutiveSamples(for: .ownerlessNoIDE)
        for i in 0..<(req - 1) { _ = e.ingest(snap(i, ideRunning: false, [obs(1201)])) }
        _ = e.ingest(snap(req - 1, ideRunning: false, [obs(1201)]))   // → killing + autoKill
        // Kill attempt finishes but the process survived.
        e.clearKilling([identity(1201)])
        let rec = e.stateRecords().first { $0.identity == identity(1201) }
        XCTAssertEqual(rec?.stateDescription, "healthy")
        XCTAssertEqual(rec?.ruleCounters[Rule.ownerlessNoIDE.rawValue] ?? 0, 0, "counters reset after clearKilling")
        // Needs a full fresh window again.
        for i in (req)..<(req + req - 1) {
            XCTAssertTrue(e.ingest(snap(i, ideRunning: false, [obs(1201)])).autoKill.isEmpty)
        }
        let refire = e.ingest(snap(req + req - 1, ideRunning: false, [obs(1201)]))
        XCTAssertEqual(refire.autoKill.count, 1, "re-flags after a fresh window")
    }

    func testNonAutoKillRuleStillNotifiesUnderAutoKillMode() {
        // autoKill enabled for R1 only; an R4 runaway must still NOTIFY (spec §8).
        var cfg = Config.default
        cfg.autoKill = AutoKillConfig(enabled: true, rules: [Rule.ownerlessNoIDE.rawValue])
        let e = engine(cfg)
        let req = cfg.requiredConsecutiveSamples(for: .runaway)  // 4
        var cpu = 0.0
        _ = e.ingest(snap(0, ideRunning: true, [obs(1202, client: false, cpu: cpu)]))
        for i in 1..<req {
            cpu += 30
            _ = e.ingest(snap(i, ideRunning: true, [obs(1202, client: false, cpu: cpu)]))
        }
        cpu += 30
        let out = e.ingest(snap(req, ideRunning: true, [obs(1202, client: false, cpu: cpu)]))
        XCTAssertNotNil(runawayBatch(out), "R4 not in autoKill rules → still notifies")
        XCTAssertTrue(out.autoKill.isEmpty)
    }

    // MARK: - Disabled rule

    func testDisabledRuleNeverFires() {
        var cfg = Config.default
        cfg.rules.ownerlessNoIDE = RuleConfig(enabled: false, thresholdMinutes: 2)
        let e = engine(cfg)
        for i in 0...20 {
            XCTAssertTrue(e.ingest(snap(i, ideRunning: false, [obs(1300)])).notifications.isEmpty,
                          "disabled R1 never fires")
        }
    }

    // MARK: - updateConfig

    func testUpdateConfigAppliesOnNextIngest() {
        // Start with R1 disabled, build up samples, then enable R1 → fires once threshold met.
        var cfg = Config.default
        cfg.rules.ownerlessNoIDE = RuleConfig(enabled: false, thresholdMinutes: 2)
        let e = engine(cfg)
        for i in 0..<6 { _ = e.ingest(snap(i, ideRunning: false, [obs(1400)])) }
        // Counters didn't advance while disabled. Enable R1 now.
        var enabled = cfg
        enabled.rules.ownerlessNoIDE = RuleConfig(enabled: true, thresholdMinutes: 2)
        e.updateConfig(enabled)
        // Now needs a fresh 4-sample window (counters were 0 while disabled).
        for i in 6..<9 {
            XCTAssertTrue(e.ingest(snap(i, ideRunning: false, [obs(1400)])).notifications.isEmpty)
        }
        let out = e.ingest(snap(9, ideRunning: false, [obs(1400)]))
        XCTAssertNotNil(orphanBatch(out), "updateConfig thresholds applied on next ingest")
    }

    func testUpdateConfigPreservesCounters() {
        // Lower the threshold mid-flight; preserved counters should let it fire sooner.
        let e = engine()
        // 3 ownerless samples (one short of R1's default 4).
        for i in 0..<3 { _ = e.ingest(snap(i, ideRunning: false, [obs(1401)])) }
        // Lower R1 threshold to 1.5 min → 3 samples. Counter is already 3 → fires next ingest.
        var cfg = Config.default
        cfg.rules.ownerlessNoIDE = RuleConfig(enabled: true, thresholdMinutes: 1.5)  // 3 samples
        e.updateConfig(cfg)
        let out = e.ingest(snap(3, ideRunning: false, [obs(1401)]))  // counter now 4 ≥ 3 → fires
        XCTAssertNotNil(orphanBatch(out), "counters preserved across updateConfig")
    }

    // MARK: - Priority

    func testPriorityRunawayBeatsR1WhenBothCross() {
        // A clientless hot daemon with no IDE crosses both R4 and R1 on the SAME poll.
        // Priority: runaway > ownerlessNoIDE → it batches as RUNAWAY_FOUND only.
        let e = engine()
        // R1 and R4 both = 4 samples by default. Sample 0 is OWNED (client) so R1 doesn't
        // start counting until sample 1 — that aligns R1's window with R4's (which can't
        // match sample 0 anyway, no CPU delta). Both then cross together at index 4.
        var cpu = 0.0
        _ = e.ingest(snap(0, ideRunning: false, [obs(1500, client: true, cpu: cpu)]))  // owned baseline
        for i in 1..<4 {
            cpu += 30
            _ = e.ingest(snap(i, ideRunning: false, [obs(1500, client: false, cpu: cpu)]))
        }
        cpu += 30
        let out = e.ingest(snap(4, ideRunning: false, [obs(1500, client: false, cpu: cpu)]))
        // R4 fires (priority); R1 counter is also at threshold but runaway wins.
        XCTAssertNotNil(runawayBatch(out))
        XCTAssertNil(orphanBatch(out), "runaway priority → no separate orphan batch for this process")
        XCTAssertEqual(runawayBatch(out)?.processes.first?.rule, .runaway)
    }

    // MARK: - Separate batches

    func testOrphanAndRunawayBatchSeparately() {
        let req = 4  // R1 and R4 both default to 4 samples
        // ideRunning=false; pid 1600 → ownerless+noIDE (R1, orphan batch).
        // pid 1601 → parent-IDE-owned but clientless+hot (R4, runaway batch). R4 ignores owned.
        // Sample 0 keeps 1600 owned (client) so R1 starts counting at sample 1 — aligning
        // it with R4 (which can't match sample 0, no CPU delta); both fire together at index req.
        let e2 = engine()
        var cpu = 0.0
        _ = e2.ingest(snap(0, ideRunning: false, [obs(1600, client: true, cpu: 0),
                                                  obs(1601, ppid: 7, parentIsIDE: true, client: false, cpu: cpu)]))
        for i in 1..<req {
            cpu += 30
            _ = e2.ingest(snap(i, ideRunning: false, [obs(1600, client: false, cpu: 0),
                                                      obs(1601, ppid: 7, parentIsIDE: true, client: false, cpu: cpu)]))
        }
        cpu += 30
        let out = e2.ingest(snap(req, ideRunning: false, [obs(1600, client: false, cpu: 0),
                                                          obs(1601, ppid: 7, parentIsIDE: true, client: false, cpu: cpu)]))
        // 1600 → R1 (orphan batch); 1601 → R4 (runaway batch). Two batches.
        XCTAssertNotNil(orphanBatch(out))
        XCTAssertNotNil(runawayBatch(out))
        XCTAssertEqual(orphanBatch(out)?.processes.first?.process.pid, 1600)
        XCTAssertEqual(runawayBatch(out)?.processes.first?.process.pid, 1601)
    }

    // MARK: - markKilling user action

    func testMarkKillingFromFlaggedSuppressesEmission() {
        let e = engine()
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)
        for i in 0..<(req - 1) { _ = e.ingest(snap(i, ideRunning: false, [obs(1700)])) }
        _ = e.ingest(snap(req - 1, ideRunning: false, [obs(1700)]))  // flagged + notified
        // User taps Kill All → markKilling.
        e.markKilling([identity(1700)])
        XCTAssertEqual(e.stateRecords().first { $0.identity == identity(1700) }?.stateDescription, "killing")
        let out = e.ingest(snap(req, ideRunning: false, [obs(1700)]))
        XCTAssertTrue(out.notifications.isEmpty && out.autoKill.isEmpty)
    }

    func testMarkKillingUnknownIdentityNoOp() {
        let e = engine()
        e.markKilling([identity(9998)])  // must not crash
        XCTAssertTrue(e.stateRecords().isEmpty)
    }
}
