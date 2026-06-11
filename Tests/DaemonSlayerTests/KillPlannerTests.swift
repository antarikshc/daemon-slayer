import XCTest
@testable import daemonslayer

/// V2-M3 pure decision-core coverage (SPEC-UI §6.2): the friction ladder, Kill
/// Orphans visibility/enablement, Kill All target sets, busy-casualty marking, and
/// post-kill toast phrasing — plus the load-bearing invariant that NO one-click
/// (dialog-free) plan can ever yield `.userForced`. Views are thin; this is where
/// the kill logic lives, so it's exhaustively tested here.
final class KillPlannerTests: XCTestCase {

    // MARK: - Row builders (one per §6.2 verdict class)

    private func row(pid: Int32 = 1,
                     kind: DaemonKind = .gradle,
                     name: String = "Gradle 8.13 (proj)",
                     busy: Bool = false,
                     busySince: Date? = nil,
                     owned: Bool = false,
                     ownedTag: String? = nil,
                     ownershipUnknown: Bool = false,
                     client: String? = nil,
                     flaggedRule: Rule? = nil,
                     pendingSamples: Int = 0,
                     pendingRequired: Int = 0,
                     agentState: String? = nil,
                     rss: UInt64 = 1_000) -> DaemonRow {
        DaemonRow(
            identity: ProcessIdentity(pid: pid, startTimeMicros: 1),
            kind: kind, displayName: name,
            rssBytes: rss, cpuPercent: busy ? 150 : 1, uptime: 100,
            busyNow: busy, busySince: busySince,
            owned: owned, ownedTag: ownedTag, ownershipUnknown: ownershipUnknown,
            attachedClientDescription: client,
            agentStateDescription: agentState, agentFlaggedRule: flaggedRule,
            pendingSamples: pendingSamples, pendingRequired: pendingRequired)
    }

    private func flaggedRow(pid: Int32 = 3, rule: Rule = .ownerlessWithIDE) -> DaemonRow {
        row(pid: pid, name: "Gradle 8.7 (androidcommon)", flaggedRule: rule)
    }
    private func busyRow(pid: Int32 = 1) -> DaemonRow {
        row(pid: pid, name: "Gradle 8.13 (mojmultiproject)", busy: true,
            busySince: Date(timeIntervalSince1970: 1_000))
    }
    private func ownedIdleRow(pid: Int32 = 2) -> DaemonRow {
        row(pid: pid, name: "Kotlin daemon (mojmultiproject)", owned: true,
            ownedTag: "O4", client: "Android Studio")
    }

    // MARK: - §6.2 row 1: per-row Kill on flagged/orphaned → one click, respectOwnership

    func testPlanFlaggedRowIsOneClickRespectOwnership() {
        let plan = KillPlanner.planRow(flaggedRow())
        XCTAssertEqual(plan.friction, .none)
        XCTAssertEqual(plan.policy, .respectOwnership)
        XCTAssertNil(plan.dialogMessage)
    }

    func testPlanHealthyAndWatchingRowsAreOneClickRespectOwnership() {
        for r in [row(), row(pendingSamples: 2, pendingRequired: 4)] {
            let plan = KillPlanner.planRow(r)
            XCTAssertEqual(plan.friction, .none, "unowned non-busy → one click")
            XCTAssertEqual(plan.policy, .respectOwnership)
        }
    }

    // MARK: - §6.2 row 2: per-row Kill on owned idle → owned warning, userForced

    func testPlanOwnedIdleRowWarnsAndUserForced() {
        let plan = KillPlanner.planRow(ownedIdleRow())
        XCTAssertEqual(plan.friction, .ownedWarning)
        XCTAssertEqual(plan.policy, .userForced)
        XCTAssertEqual(plan.dialogMessage, "Owned by Android Studio — it will likely respawn this daemon.")
    }

    func testPlanOwnedRowWithoutNamedClientStillWarns() {
        let plan = KillPlanner.planRow(row(pid: 9, owned: true, ownedTag: "O1", client: nil))
        XCTAssertEqual(plan.friction, .ownedWarning)
        XCTAssertEqual(plan.policy, .userForced)
        XCTAssertEqual(plan.dialogMessage, "Owned by a client — it will likely respawn this daemon.")
    }

    // MARK: - §6.2 row 3: per-row Kill on busy → scary warning, userForced

    func testPlanBusyRowIsScaryWarningAndUserForced() {
        let plan = KillPlanner.planRow(busyRow(pid: 61452))
        XCTAssertEqual(plan.friction, .busyWarning)
        XCTAssertEqual(plan.policy, .userForced)
        XCTAssertEqual(plan.dialogMessage,
                       "PID 61452 is running a build for Gradle 8.13 (mojmultiproject) right now. "
                       + "Killing it will fail that build.")
    }

    func testBusyBeatsOwnedInPlanning() {
        // A busy AND owned row gets the scary busy warning, not the milder owned one.
        let r = row(pid: 5, busy: true, busySince: Date(), owned: true, ownedTag: "O1", client: "Studio")
        XCTAssertEqual(KillPlanner.planRow(r).friction, .busyWarning)
    }

    // MARK: - §8: ownershipUnknown per-row → owned-class fail-safe

    func testPlanOwnershipUnknownRowWarnsAndUserForced() {
        let plan = KillPlanner.planRow(row(pid: 7, ownershipUnknown: true))
        XCTAssertEqual(plan.friction, .ownedWarning)
        XCTAssertEqual(plan.policy, .userForced)
        XCTAssertNotNil(plan.dialogMessage)
    }

    // MARK: - THE FENCE: no one-click path can ever yield .userForced

    func testNoOneClickPlanCanBeUserForced() {
        // Sweep a broad cartesian of row shapes; ANY plan with friction == .none MUST
        // be .respectOwnership, and conversely .userForced MUST carry a dialog message.
        var checked = 0
        for busy in [false, true] {
            for owned in [false, true] {
                for unknown in [false, true] {
                    for rule: Rule? in [nil, .ownerlessNoIDE, .runaway] {
                        for pending in [0, 2] {
                            let r = row(busy: busy, busySince: busy ? Date() : nil,
                                        owned: owned, ownedTag: owned ? "O1" : nil,
                                        ownershipUnknown: unknown,
                                        client: owned ? "Studio" : nil,
                                        flaggedRule: rule,
                                        pendingSamples: pending, pendingRequired: pending > 0 ? 4 : 0)
                            let plan = KillPlanner.planRow(r)
                            if plan.friction == .none {
                                XCTAssertEqual(plan.policy, .respectOwnership,
                                               "a dialog-free plan must be respectOwnership")
                                XCTAssertNil(plan.dialogMessage)
                            } else {
                                XCTAssertEqual(plan.policy, .userForced,
                                               "a dialog-bearing plan is userForced")
                                XCTAssertNotNil(plan.dialogMessage,
                                                "every .userForced plan carries dialog text")
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 2 * 2 * 2 * 3 * 2)
    }

    // MARK: - §6.2 row 4: Kill Orphans visibility + ownershipUnknown disable

    func testKillOrphansHiddenWithNoFlaggedDaemons() {
        let b = KillPlanner.orphansButton(rows: [busyRow(), ownedIdleRow(), row()], ownershipUnknown: false)
        XCTAssertFalse(b.isVisible)
        XCTAssertFalse(b.isEnabled)
    }

    func testKillOrphansVisibleAndEnabledWithAFlaggedDaemon() {
        let b = KillPlanner.orphansButton(rows: [flaggedRow(), busyRow()], ownershipUnknown: false)
        XCTAssertTrue(b.isVisible)
        XCTAssertTrue(b.isEnabled)
    }

    func testKillOrphansVisibleButDisabledUnderOwnershipUnknown() {
        let b = KillPlanner.orphansButton(rows: [flaggedRow()], ownershipUnknown: true)
        XCTAssertTrue(b.isVisible, "still shown — there is a flagged daemon")
        XCTAssertFalse(b.isEnabled, "but disabled: can't trust the orphan set (§8)")
    }

    // MARK: - Target sets

    func testOrphanTargetsAreFlaggedOnly() {
        let rows = [busyRow(pid: 1), ownedIdleRow(pid: 2), flaggedRow(pid: 3),
                    flaggedRow(pid: 4, rule: .runaway), row(pid: 5)]
        let targets = KillPlanner.orphanTargets(rows)
        XCTAssertEqual(Set(targets.map { $0.identity.pid }), [3, 4],
                       "only flagged rows; never busy/owned/healthy")
    }

    func testKillAllTargetsIsEveryDaemon() {
        let rows = [busyRow(pid: 1), ownedIdleRow(pid: 2), flaggedRow(pid: 3), row(pid: 5)]
        XCTAssertEqual(KillPlanner.allTargets(rows).map { $0.identity.pid }, [1, 2, 3, 5])
    }

    func testBusyCasualtyMarking() {
        XCTAssertTrue(KillPlanner.isBusyCasualty(busyRow()))
        XCTAssertFalse(KillPlanner.isBusyCasualty(ownedIdleRow()))
        XCTAssertFalse(KillPlanner.isBusyCasualty(flaggedRow()))
    }

    // MARK: - Toast phrasing (SPEC-UI §6 / §6.2)

    private func killed(_ pid: Int32, rss: UInt64) -> KillReport {
        let p = DaemonProcess(identity: ProcessIdentity(pid: pid, startTimeMicros: 1),
                              kind: .gradle, ppid: 1, rssBytes: rss, cpuTimeSeconds: 0,
                              argv: [], gradleVersion: nil, projectHint: nil, kotlinAliveMarkerPath: nil)
        let f = FlaggedProcess(process: p, rule: .ownerlessNoIDE, candidateSince: Date(),
                               idleSeconds: nil, cpuPercent: nil)
        return KillReport(target: f, outcome: .killed(.sigterm))
    }

    private func report(_ pid: Int32, _ outcome: KillOutcome) -> KillReport {
        let p = DaemonProcess(identity: ProcessIdentity(pid: pid, startTimeMicros: 1),
                              kind: .gradle, ppid: 1, rssBytes: 0, cpuTimeSeconds: 0,
                              argv: [], gradleVersion: nil, projectHint: nil, kotlinAliveMarkerPath: nil)
        let f = FlaggedProcess(process: p, rule: .ownerlessNoIDE, candidateSince: Date(),
                               idleSeconds: nil, cpuPercent: nil)
        return KillReport(target: f, outcome: outcome)
    }

    func testToastCleanKillShowsFreedRSSAndNoRedundantDetail() {
        let t = KillPlanner.toast(from: [killed(1, rss: 1_073_741_824), killed(2, rss: 1_073_741_824)])
        XCTAssertEqual(t.headline, "Reclaimed 2.0 GB")
        XCTAssertNil(t.detail, "a clean batch needs no second line")
    }

    func testToastKilledWithAlreadyGone() {
        let t = KillPlanner.toast(from: [killed(1, rss: 500 * 1_048_576),
                                         killed(2, rss: 500 * 1_048_576),
                                         killed(3, rss: 1_000 * 1_048_576),
                                         report(4, .skippedGone)])
        XCTAssertEqual(t.headline, "Reclaimed 2.0 GB")
        XCTAssertEqual(t.detail, "Killed 3 · 1 already gone")
    }

    func testToastSkippedNowBusyPhrasing() {
        let t = KillPlanner.toast(from: [killed(1, rss: 1_048_576), report(2, .skippedNowOwned)])
        XCTAssertEqual(t.detail, "Killed 1 · skipped 1 — now busy")
    }

    func testToastMixedGoneAndNowOwnedAndFailed() {
        let t = KillPlanner.toast(from: [killed(1, rss: 1_048_576),
                                         report(2, .skippedGone),
                                         report(3, .skippedNowOwned),
                                         report(4, .failed("EPERM"))])
        XCTAssertEqual(t.detail, "Killed 1 · 1 already gone · skipped 1 — now busy · 1 failed")
    }

    func testToastNothingKilledAllSkipped() {
        let t = KillPlanner.toast(from: [report(1, .skippedNowOwned), report(2, .skippedGone)])
        XCTAssertEqual(t.headline, "Killed 0")
        XCTAssertEqual(t.detail, "1 already gone · skipped 1 — now busy")
    }

    func testToastEmptyBatch() {
        let t = KillPlanner.toast(from: [])
        XCTAssertEqual(t.headline, "Nothing to kill")
        XCTAssertNil(t.detail)
    }
}
