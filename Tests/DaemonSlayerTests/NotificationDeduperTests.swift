import XCTest
@testable import daemonslayer

/// NotificationDeduper is pure (clock passed in): synthetic batches in, admit/suppress out.
final class NotificationDeduperTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ minutes: Double) -> Date { epoch.addingTimeInterval(minutes * 60) }

    private func flagged(_ pid: Int32, start: Int64 = 1_000, rule: Rule = .ownerlessNoIDE) -> FlaggedProcess {
        let proc = DaemonProcess(
            identity: ProcessIdentity(pid: pid, startTimeMicros: start),
            kind: .gradle,
            ppid: 1,
            rssBytes: 100 * 1_048_576,
            cpuTimeSeconds: 0,
            argv: ["java", DaemonKind.gradleArgvMarker],
            gradleVersion: "8.13",
            projectHint: "proj",
            kotlinAliveMarkerPath: nil
        )
        return FlaggedProcess(process: proc, rule: rule, candidateSince: epoch,
                              idleSeconds: nil, cpuPercent: rule == .runaway ? 140 : nil)
    }

    private func batch(_ procs: [FlaggedProcess],
                       _ category: NotificationCategory = .orphanFound) -> NotificationBatch {
        NotificationBatch(category: category, processes: procs, identifier: "id")
    }

    // MARK: - Core gating

    func testFirstAlertAdmitted() {
        var d = NotificationDeduper(window: 3600)
        XCTAssertTrue(d.admit(batch([flagged(100)]), now: t(0)))
    }

    func testRepeatWithinWindowSuppressed() {
        var d = NotificationDeduper(window: 3600)
        XCTAssertTrue(d.admit(batch([flagged(100)]), now: t(0)))
        XCTAssertFalse(d.admit(batch([flagged(100)]), now: t(10)))   // 10 min later
        XCTAssertFalse(d.admit(batch([flagged(100)]), now: t(59)))   // still inside the hour
    }

    func testReadmittedAfterWindowElapses() {
        var d = NotificationDeduper(window: 3600)
        XCTAssertTrue(d.admit(batch([flagged(100)]), now: t(0)))
        XCTAssertTrue(d.admit(batch([flagged(100)]), now: t(60)))    // exactly one hour → through
        XCTAssertFalse(d.admit(batch([flagged(100)]), now: t(90)))   // then gated again off t(60)
    }

    // MARK: - "Same build" identity semantics

    func testRespawnedDaemonNotSuppressed() {
        var d = NotificationDeduper(window: 3600)
        XCTAssertTrue(d.admit(batch([flagged(100, start: 1_000)]), now: t(0)))
        // Same pid, fresh start time = a genuinely new daemon → must alert.
        XCTAssertTrue(d.admit(batch([flagged(100, start: 2_000)]), now: t(5)))
    }

    func testRunawayNotSuppressedByPriorOrphan() {
        var d = NotificationDeduper(window: 3600)
        XCTAssertTrue(d.admit(batch([flagged(100, rule: .ownerlessNoIDE)], .orphanFound), now: t(0)))
        // Same daemon escalating to a runaway is a different, more urgent category.
        XCTAssertTrue(d.admit(batch([flagged(100, rule: .runaway)], .runawayFound), now: t(5)))
    }

    // MARK: - Multi-member batches

    func testNewMemberBreaksThroughThenStampsAll() {
        var d = NotificationDeduper(window: 3600)
        XCTAssertTrue(d.admit(batch([flagged(100)]), now: t(0)))
        // 101 is new → whole batch admitted even though 100 was just alerted.
        XCTAssertTrue(d.admit(batch([flagged(100), flagged(101)]), now: t(10)))
        // Both now stamped at t(10): neither alone breaks through before the hour.
        XCTAssertFalse(d.admit(batch([flagged(100)]), now: t(20)))
        XCTAssertFalse(d.admit(batch([flagged(101)]), now: t(20)))
    }

    func testAllMembersRecentSuppressed() {
        var d = NotificationDeduper(window: 3600)
        XCTAssertTrue(d.admit(batch([flagged(100), flagged(101)]), now: t(0)))
        XCTAssertFalse(d.admit(batch([flagged(100), flagged(101)]), now: t(30)))
    }

    // MARK: - Window is live-tunable (config hot-reload)

    func testShrinkingWindowReadmitsSooner() {
        var d = NotificationDeduper(window: 3600)
        XCTAssertTrue(d.admit(batch([flagged(100)]), now: t(0)))
        XCTAssertFalse(d.admit(batch([flagged(100)]), now: t(10)))
        d.window = 300   // 5 min
        XCTAssertTrue(d.admit(batch([flagged(100)]), now: t(10)))
    }
}
