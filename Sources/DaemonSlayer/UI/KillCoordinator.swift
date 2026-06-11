import Foundation

/// Drives a UI-initiated kill batch (SPEC-UI §6). Mirrors `KillCommand` exactly: a
/// fresh scan + ownership resolve, wrap the matching daemons as `FlaggedProcess`
/// targets, and run the REAL `Killer` once under the chosen `KillPolicy`. The Killer
/// is never weakened — the UI only chooses the target set + policy. Kotlin-before-
/// Gradle ordering comes free from the Killer's batch path.
///
/// Everything runs on a private background queue so the main thread never blocks on
/// `lsof` or escalation waits; `completion` hops back to the main queue.
final class KillCoordinator {
    private let logger: DSLogger
    private let options: CLIOptions
    private let scanner: ProcessScanner
    private let resolver: OwnershipResolver
    private let ideMonitor: IDEMonitor
    private let configStore: ConfigStore
    private let queue = DispatchQueue(label: "dev.antariksh.daemonslayer.ui.kill")

    init(options: CLIOptions, logger: DSLogger, scanner: ProcessScanner,
         resolver: OwnershipResolver, ideMonitor: IDEMonitor, configStore: ConfigStore) {
        self.options = options
        self.logger = logger
        self.scanner = scanner
        self.resolver = resolver
        self.ideMonitor = ideMonitor
        self.configStore = configStore
    }

    /// Kill the daemons identified by `identities` under `policy`. Identities are the
    /// rows the user acted on; the coordinator re-scans and only targets daemons that
    /// still match (the Killer re-validates again per phase regardless). `completion`
    /// runs on the main queue with the batch's reports.
    func kill(identities: [ProcessIdentity], policy: KillPolicy,
              completion: @escaping ([KillReport]) -> Void) {
        queue.async { [self] in
            let reports = run(identities: identities, policy: policy)
            DispatchQueue.main.async { completion(reports) }
        }
    }

    private func run(identities: [ProcessIdentity], policy: KillPolicy) -> [KillReport] {
        guard !identities.isEmpty else { return [] }
        let config = configStore.load()

        let snapshot = freshSnapshot()
        let wanted = Set(identities)
        // Match by full identity (pid + startTimeMicros) so a recycled PID between
        // click and scan is simply not in the target set.
        let targets: [FlaggedProcess] = snapshot?.daemons
            .filter { wanted.contains($0.process.identity) }
            .map { FlaggedProcess(process: $0.process, rule: .ownerlessNoIDE,
                                  candidateSince: Date(), idleSeconds: nil, cpuPercent: nil) }
            ?? []

        guard !targets.isEmpty else {
            logger.info("[ui-kill] none of \(identities.count) target(s) present in fresh scan — nothing to do")
            return []
        }

        let killer = Killer(logger: logger, deps: KillerDependencies(
            escalationSeconds: { config.killEscalationSeconds },
            freshSnapshot: { [self] in freshSnapshot() }))

        logger.info("[ui-kill] killing \(targets.count) daemon(s) under policy \(policy)")
        let done = DispatchSemaphore(value: 0)
        var reports: [KillReport] = []
        killer.kill(targets, policy: policy) { r in reports = r; done.signal() }
        done.wait()
        return reports
    }

    /// Fresh scan + ownership resolve, identical to `KillCommand`/`AgentRuntime`.
    /// Kill-time re-validation needs ownership facts only — no client descriptions.
    private func freshSnapshot() -> PollSnapshot? {
        let raw = scanner.allProcesses()
        guard !raw.isEmpty else { return nil }
        let daemons = ProcessScanner.daemons(in: raw)
        return resolver.resolve(daemons: daemons, allProcesses: raw,
                                idePids: ideMonitor.runningIDEPids(),
                                ideRunning: ideMonitor.ideRunning,
                                timestamp: Date(),
                                resolveClientDescriptions: false)
    }
}
