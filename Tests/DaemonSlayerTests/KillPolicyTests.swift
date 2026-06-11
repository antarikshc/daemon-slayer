import XCTest
@testable import daemonslayer

/// KillPolicy split (SPEC-UI §6/§13): `.userForced` bypasses EXACTLY the ownership
/// re-check; identity (pid + startTimeMicros) and argv gates hold under BOTH
/// policies. Driven entirely against fakes via Killer's injectable deps — no real
/// processes or signals. Determinism: `sendSignal` reports "gone" (ESRCH) the
/// instant a fake's pid is asked about, so escalation resolves immediately.
final class KillPolicyTests: XCTestCase {
    private let logger = SilentLogger()

    // MARK: - Fake process world

    /// Models the live process table the Killer probes during a kill. Each entry is
    /// keyed by pid → live startTimeMicros. A pid absent from the table is "gone".
    private final class FakeWorld {
        var liveStart: [Int32: Int64]
        /// pids that received SIGTERM / SIGKILL (in order), for assertions.
        var signalled: [(pid: Int32, sig: Int32)] = []
        /// paths passed to unlink.
        var unlinked: [String] = []
        /// pids that should "exit" (vanish) as soon as they're signalled with TERM/KILL.
        var diesOnSignal: Set<Int32>

        init(liveStart: [Int32: Int64], diesOnSignal: Set<Int32>) {
            self.liveStart = liveStart
            self.diesOnSignal = diesOnSignal
        }

        func sendSignal(_ pid: Int32, _ sig: Int32) -> Int32 {
            if sig == 0 {
                // Liveness probe.
                if liveStart[pid] != nil { errno = 0; return 0 }
                errno = ESRCH; return -1
            }
            // Real signal.
            guard liveStart[pid] != nil else { errno = ESRCH; return -1 }
            signalled.append((pid, sig))
            if diesOnSignal.contains(pid) { liveStart[pid] = nil }   // process exits
            errno = 0
            return 0
        }

        func liveStartMicros(_ pid: Int32) -> Int64? { liveStart[pid] }

        func unlink(_ path: String) -> Int32 { unlinked.append(path); errno = 0; return 0 }
    }

    private func killer(world: FakeWorld, snapshot: @escaping () -> PollSnapshot?) -> Killer {
        Killer(logger: logger, deps: KillerDependencies(
            escalationSeconds: { 0.1 },
            freshSnapshot: snapshot,
            sendSignal: { world.sendSignal($0, $1) },
            liveStartMicros: { world.liveStartMicros($0) },
            unlinkPath: { world.unlink($0) }
        ))
    }

    // MARK: - Builders (mirror RuleEngineTests' shape)

    private func daemon(_ pid: Int32, kind: DaemonKind = .gradle, start: Int64 = 1_000,
                        argvMarker: Bool = true) -> DaemonProcess {
        let marker = kind == .gradle ? DaemonKind.gradleArgvMarker : DaemonKind.kotlinArgvMarker
        return DaemonProcess(
            identity: ProcessIdentity(pid: pid, startTimeMicros: start),
            kind: kind, ppid: 1, rssBytes: 100 * 1_048_576, cpuTimeSeconds: 0,
            argv: argvMarker ? ["java", marker] : ["java", "something-else"],
            gradleVersion: kind == .gradle ? "8.13" : nil,
            projectHint: "proj",
            kotlinAliveMarkerPath: kind == .kotlin ? "/tmp/kotlin-compiler-in-proj.alive" : nil)
    }

    private func obs(_ p: DaemonProcess, client: Bool = false) -> DaemonObservation {
        DaemonObservation(process: p, parentIsIDE: false, hasAttachedClient: client,
                          listenPorts: [], linkedGradlePid: nil, ownershipUnknown: false)
    }

    private func flagged(_ p: DaemonProcess) -> FlaggedProcess {
        FlaggedProcess(process: p, rule: .ownerlessNoIDE,
                       candidateSince: Date(), idleSeconds: nil, cpuPercent: nil)
    }

    private func snapshot(_ observations: [DaemonObservation]) -> PollSnapshot {
        PollSnapshot(timestamp: Date(), daemons: observations, ideRunning: false)
    }

    /// Run a kill synchronously and return the reports.
    private func runKill(_ k: Killer, _ targets: [FlaggedProcess], policy: KillPolicy) -> [KillReport] {
        let done = expectation(description: "kill done")
        var out: [KillReport] = []
        k.kill(targets, policy: policy) { out = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return out
    }

    private func isKilled(_ r: KillReport?) -> Bool {
        if case .killed = r?.outcome { return true }
        return false
    }
    private func isSkippedNowOwned(_ r: KillReport?) -> Bool {
        if case .skippedNowOwned = r?.outcome { return true }
        return false
    }
    private func isSkippedGone(_ r: KillReport?) -> Bool {
        if case .skippedGone = r?.outcome { return true }
        return false
    }

    // MARK: - Ownership bypass

    func testUserForcedKillsAnOwnedTarget() {
        let g = daemon(1, start: 1_000)
        let world = FakeWorld(liveStart: [1: 1_000], diesOnSignal: [1])
        // Fresh snapshot shows the daemon OWNED (client attached).
        let k = killer(world: world) { self.snapshot([self.obs(g, client: true)]) }
        let reports = runKill(k, [flagged(g)], policy: .userForced)
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(isKilled(reports.first), ".userForced kills even an owned daemon (ownership check bypassed)")
        XCTAssertEqual(world.signalled.first?.sig, SIGTERM)
    }

    func testRespectOwnershipSkipsAnOwnedTarget() {
        let g = daemon(2, start: 1_000)
        let world = FakeWorld(liveStart: [2: 1_000], diesOnSignal: [2])
        let k = killer(world: world) { self.snapshot([self.obs(g, client: true)]) }
        let reports = runKill(k, [flagged(g)], policy: .respectOwnership)
        XCTAssertTrue(isSkippedNowOwned(reports.first), ".respectOwnership skips a now-owned daemon")
        XCTAssertTrue(world.signalled.isEmpty, "no signal sent to an owned daemon under respectOwnership")
    }

    func testRespectOwnershipKillsAnUnownedTarget() {
        let g = daemon(3, start: 1_000)
        let world = FakeWorld(liveStart: [3: 1_000], diesOnSignal: [3])
        let k = killer(world: world) { self.snapshot([self.obs(g, client: false)]) }
        let reports = runKill(k, [flagged(g)], policy: .respectOwnership)
        XCTAssertTrue(isKilled(reports.first), "unowned daemon is killed under respectOwnership")
    }

    // MARK: - Identity gates hold under BOTH policies

    func testBothPoliciesSkipStartTimeMismatchIdentically() {
        // Snapshot has the SAME pid but a DIFFERENT startTimeMicros (PID reuse).
        for policy in [KillPolicy.respectOwnership, .userForced] {
            let target = daemon(4, start: 1_000)
            let live = daemon(4, start: 9_999)   // recycled pid, new start
            let world = FakeWorld(liveStart: [4: 9_999], diesOnSignal: [4])
            let k = killer(world: world) { self.snapshot([self.obs(live, client: false)]) }
            let reports = runKill(k, [flagged(target)], policy: policy)
            XCTAssertTrue(isSkippedGone(reports.first),
                          "\(policy): PID-reuse (start mismatch) must skip — a recycled PID is unkillable")
            XCTAssertTrue(world.signalled.isEmpty, "\(policy): no signal to a recycled pid")
        }
    }

    func testBothPoliciesSkipArgvChangeIdentically() {
        // Snapshot has matching identity but argv no longer carries the daemon marker.
        for policy in [KillPolicy.respectOwnership, .userForced] {
            let target = daemon(5, start: 1_000)
            let live = daemon(5, start: 1_000, argvMarker: false)   // re-execed
            let world = FakeWorld(liveStart: [5: 1_000], diesOnSignal: [5])
            let k = killer(world: world) { self.snapshot([self.obs(live, client: false)]) }
            let reports = runKill(k, [flagged(target)], policy: policy)
            XCTAssertTrue(isSkippedGone(reports.first),
                          "\(policy): argv no longer a daemon → skip under both policies")
            XCTAssertTrue(world.signalled.isEmpty)
        }
    }

    func testBothPoliciesSkipVanishedTargetIdentically() {
        // Target absent from the fresh snapshot entirely (died).
        for policy in [KillPolicy.respectOwnership, .userForced] {
            let target = daemon(6, start: 1_000)
            let world = FakeWorld(liveStart: [:], diesOnSignal: [])
            let k = killer(world: world) { self.snapshot([]) }
            let reports = runKill(k, [flagged(target)], policy: policy)
            XCTAssertTrue(isSkippedGone(reports.first), "\(policy): gone target → skippedGone")
        }
    }

    // MARK: - userForced still reports honest skips

    func testUserForcedStillReportsSkippedGoneForRecycledPid() {
        // Even though userForced bypasses ownership, a gone/recycled pid is reported honestly.
        let target = daemon(7, start: 1_000)
        let world = FakeWorld(liveStart: [:], diesOnSignal: [])
        let k = killer(world: world) { self.snapshot([]) }
        let reports = runKill(k, [flagged(target)], policy: .userForced)
        XCTAssertTrue(isSkippedGone(reports.first))
    }

    // MARK: - Abort on revalidation scan failure (fail-safe holds under both)

    func testFreshSnapshotFailureAbortsBatchUnderBothPolicies() {
        for policy in [KillPolicy.respectOwnership, .userForced] {
            let g = daemon(8, start: 1_000)
            let world = FakeWorld(liveStart: [8: 1_000], diesOnSignal: [8])
            let k = killer(world: world) { nil }   // scan failed
            let reports = runKill(k, [flagged(g)], policy: policy)
            if case .failed = reports.first?.outcome {} else {
                XCTFail("\(policy): scan failure must fail-safe (abort), not signal")
            }
            XCTAssertTrue(world.signalled.isEmpty)
        }
    }
}

/// No-op logger so tests don't spew.
private final class SilentLogger: DSLogger {
    func log(_ level: LogLevel, _ message: String) {}
}
