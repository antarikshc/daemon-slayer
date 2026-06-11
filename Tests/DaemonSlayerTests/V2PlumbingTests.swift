import XCTest
@testable import daemonslayer

/// V2-M0 plumbing assertions that don't fit the Killer/Config suites: the
/// CLI policy parse (the only `.userForced` origin), RuleEngine ignoring the new
/// display-only client fact, and the gating math the paused poll path relies on.
final class V2PlumbingTests: XCTestCase {

    // MARK: - CLI: the ONLY place `.userForced` can be constructed

    func testKillPidParsesPolicyAndAgentModeHasNoPolicy() {
        // --agent never carries a policy; the agent wiring hard-codes .respectOwnership.
        switch CLIOptions.parse(["daemonslayer", "--agent"]) {
        case .success(let o): XCTAssertEqual(o.mode, .agent)
        case .failure(let e): XCTFail("--agent should parse: \(e.message)")
        }
        // The hidden hook constructs .userForced ONLY via the explicit flag pair.
        switch CLIOptions.parse(["daemonslayer", "--kill-pid", "123", "--policy", "userForced"]) {
        case .success(let o): XCTAssertEqual(o.mode, .killPid(123, .userForced))
        case .failure(let e): XCTFail("kill-pid userForced should parse: \(e.message)")
        }
        switch CLIOptions.parse(["daemonslayer", "--kill-pid", "123", "--policy", "respectOwnership"]) {
        case .success(let o): XCTAssertEqual(o.mode, .killPid(123, .respectOwnership))
        case .failure(let e): XCTFail("kill-pid respectOwnership should parse: \(e.message)")
        }
    }

    func testKillPidRequiresPolicyAndPolicyRequiresKillPid() {
        // --kill-pid without --policy is rejected (no implicit/default policy).
        if case .success = CLIOptions.parse(["daemonslayer", "--kill-pid", "5"]) {
            XCTFail("--kill-pid without --policy must error (no default policy)")
        }
        // --policy without --kill-pid is rejected (policy is meaningless alone).
        if case .success = CLIOptions.parse(["daemonslayer", "--policy", "userForced"]) {
            XCTFail("--policy without --kill-pid must error")
        }
        // Bad policy value rejected.
        if case .success = CLIOptions.parse(["daemonslayer", "--kill-pid", "5", "--policy", "nope"]) {
            XCTFail("invalid policy value must error")
        }
    }

    func testHiddenKillHookNotInUsageText() {
        // The hook is intentionally undocumented (test/debug only).
        XCTAssertFalse(usageText.contains("--kill-pid"))
        XCTAssertFalse(usageText.contains("--policy"))
    }

    // MARK: - RuleEngine ignores attachedClientDescription (display-only fact)

    func testRuleEngineIgnoresAttachedClientDescription() {
        // Two identical ownerless daemons differing ONLY in attachedClientDescription
        // must reach the identical verdict (R1 fires for both) — the field is cosmetic.
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        func t(_ s: Int) -> Date { epoch.addingTimeInterval(Double(s) * 30) }
        func proc(_ pid: Int32) -> DaemonProcess {
            DaemonProcess(identity: ProcessIdentity(pid: pid, startTimeMicros: 1_000),
                          kind: .gradle, ppid: 1, rssBytes: 100, cpuTimeSeconds: 0,
                          argv: ["java", DaemonKind.gradleArgvMarker],
                          gradleVersion: "8.13", projectHint: "p", kotlinAliveMarkerPath: nil)
        }
        func obs(_ pid: Int32, desc: String?) -> DaemonObservation {
            DaemonObservation(process: proc(pid), parentIsIDE: false, hasAttachedClient: false,
                              listenPorts: [], linkedGradlePid: nil, ownershipUnknown: false,
                              attachedClientDescription: desc)
        }
        let e = RuleEngine(config: .default)
        let req = Config.default.requiredConsecutiveSamples(for: .ownerlessNoIDE)
        var out: RuleEngineOutput!
        for i in 0..<req {
            out = e.ingest(PollSnapshot(timestamp: t(i), daemons: [
                obs(10, desc: nil),
                obs(11, desc: "Android Studio (pid 999)"),
            ], ideRunning: false))
        }
        let batch = out.notifications.first { $0.category == .orphanFound }
        XCTAssertNotNil(batch)
        XCTAssertEqual(Set(batch!.processes.map { $0.process.pid }), [10, 11],
                       "both flag identically; attachedClientDescription is ignored by the engine")
    }

    // MARK: - Agent path (resolveClientDescriptions=false) never names clients

    func testAgentPathResolveYieldsNilClientDescriptions() {
        // The agent's poll path opts OUT of client naming. Run the real resolver
        // against the live process table with false: no observation may carry an
        // attachedClientDescription, regardless of what loopback clients exist.
        // (Deterministic with no fixtures — the gate is independent of socket state;
        // if no daemons are running the resolve short-circuits and the assertion is
        // vacuously true, still proving the false path never populates the field.)
        let logger = FileLogger(path: nil, minLevel: .error)
        let scanner = ProcessScanner(logger: logger)
        let raw = scanner.allProcesses()
        let daemons = ProcessScanner.daemons(in: raw)
        let snapshot = OwnershipResolver(logger: logger).resolve(
            daemons: daemons, allProcesses: raw,
            idePids: [], ideRunning: false, timestamp: Date(),
            resolveClientDescriptions: false)
        for obs in snapshot.daemons {
            XCTAssertNil(obs.attachedClientDescription,
                         "agent path (false) must never populate attachedClientDescription")
        }
    }

    func testAttachedClientDescriptionDefaultsNil() {
        let p = DaemonProcess(identity: ProcessIdentity(pid: 1, startTimeMicros: 1),
                              kind: .gradle, ppid: 1, rssBytes: 0, cpuTimeSeconds: 0,
                              argv: [DaemonKind.gradleArgvMarker], gradleVersion: nil,
                              projectHint: nil, kotlinAliveMarkerPath: nil)
        let o = DaemonObservation(process: p)
        XCTAssertNil(o.attachedClientDescription, "new fact defaults nil (back-compatible init)")
    }
}
