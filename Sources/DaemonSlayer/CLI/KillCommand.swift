import Foundation

/// Hidden test/debug command: kill a single pid under an explicit `KillPolicy`
/// (CLIMode.killPid). NOT advertised in --help. This is the ONLY place a
/// `.userForced` kill can originate — the agent poll loop has no code path to it
/// (it always calls `Killer.kill(_:policy:)` with `.respectOwnership`). The
/// integration harness uses this to exercise the policy split against real fakes.
///
/// It does a fresh scan + ownership resolve (same machinery the agent uses), wraps
/// the matching daemon as a FlaggedProcess, and runs the real Killer once. The
/// Killer's own identity/argv/start-time gates still apply under both policies —
/// `.userForced` only bypasses the ownership re-check.
enum KillCommand {
    static func run(pid: Int32, policy: KillPolicy, options: CLIOptions) -> Int32 {
        let logger = FileLogger(path: options.logPath, minLevel: .debug)
        let configStore = ConfigStore(path: options.configPath, logger: logger)
        let config = configStore.load()

        let scanner = ProcessScanner(logger: logger)
        let resolver = OwnershipResolver(logger: logger)
        let ideMonitor = IDEMonitor(bundlePrefixes: config.ownerAppBundlePrefixes, logger: logger)

        // Fresh scan + resolve, the same way AgentRuntime.freshSnapshot() does.
        let raw = scanner.allProcesses()
        let daemons = ProcessScanner.daemons(in: raw)
        let snapshot = resolver.resolve(daemons: daemons, allProcesses: raw,
                                        idePids: ideMonitor.runningIDEPids(),
                                        ideRunning: ideMonitor.ideRunning,
                                        timestamp: Date(),
                                        // Kill path needs ownership facts only.
                                        resolveClientDescriptions: false)

        guard let obs = snapshot.daemons.first(where: { $0.process.pid == pid }) else {
            logger.info("[kill-pid] no watched daemon with pid \(pid) in the current scan")
            print("no watched Gradle/Kotlin daemon with pid \(pid)")
            return 1
        }

        // The Killer takes FlaggedProcess targets; the rule is cosmetic here (this
        // path bypasses the engine entirely). Tag it ownerlessNoIDE for the report.
        let target = FlaggedProcess(process: obs.process, rule: .ownerlessNoIDE,
                                    candidateSince: Date(), idleSeconds: nil, cpuPercent: nil)

        let killer = Killer(logger: logger, deps: KillerDependencies(
            escalationSeconds: { config.killEscalationSeconds },
            freshSnapshot: {
                let raw = scanner.allProcesses()
                guard !raw.isEmpty else { return nil }
                let daemons = ProcessScanner.daemons(in: raw)
                return resolver.resolve(daemons: daemons, allProcesses: raw,
                                        idePids: ideMonitor.runningIDEPids(),
                                        ideRunning: ideMonitor.ideRunning,
                                        timestamp: Date(),
                                        // Kill-time re-validation needs ownership facts only.
                                        resolveClientDescriptions: false)
            }
        ))

        logger.info("[kill-pid] killing pid \(pid) (\(obs.process.displayName)) under policy \(policy)")
        let done = DispatchSemaphore(value: 0)
        var reports: [KillReport] = []
        killer.kill([target], policy: policy) { r in
            reports = r
            done.signal()
        }
        done.wait()

        let report = reports.first
        switch report?.outcome {
        case .killed(let method):
            print("killed pid \(pid) via \(method.rawValue)")
            return 0
        case .skippedNowOwned:
            print("refused: pid \(pid) is owned (respectOwnership)")
            return 2
        case .skippedGone:
            print("skipped: pid \(pid) gone or PID reused")
            return 3
        case .failed(let why):
            print("failed to kill pid \(pid): \(why)")
            return 4
        case nil:
            print("no kill report for pid \(pid)")
            return 4
        }
    }
}
