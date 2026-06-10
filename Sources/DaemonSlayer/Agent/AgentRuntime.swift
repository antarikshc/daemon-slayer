import AppKit
import Foundation

/// The resident watcher (spec §9.2): owns the poll loop, wires scanner →
/// resolver → engine → notifier/killer, persists the agent view after each
/// poll. All engine access is serialized on `pollQueue`.
final class AgentRuntime {
    private let pollQueue = DispatchQueue(label: "dev.antariksh.daemonslayer.poll")
    private let logger: FileLogger
    private let configStore: ConfigStore
    private let stateStore: StateStore
    private let scanner: ProcessScanner
    private let resolver: OwnershipResolver
    private let ideMonitor: IDEMonitor
    private let engine: RuleEngine
    private var notifier: NotificationManager!
    private var killer: Killer!

    private var config: Config
    private var timer: DispatchSourceTimer?
    private var currentInterval: Double = 0
    private var lastPollAt = Date.distantPast
    private var lastIDERunning = false

    init(configPath: String, statePath: String, logPath: String?) {
        let logger = FileLogger(path: logPath, minLevel: .info)
        self.logger = logger
        configStore = ConfigStore(path: configPath, logger: logger)
        config = configStore.load()
        logger.minLevel = config.logLevelValue
        stateStore = StateStore(path: statePath, logger: logger)
        scanner = ProcessScanner(logger: logger)
        resolver = OwnershipResolver(logger: logger)
        ideMonitor = IDEMonitor(bundlePrefixes: config.ownerAppBundlePrefixes, logger: logger)
        engine = RuleEngine(config: config)

        notifier = NotificationManager(logger: logger, actions: NotificationActions(
            killAll: { [weak self] procs in
                self?.pollQueue.async { self?.performKill(procs, userInitiated: true) }
            },
            snooze: { [weak self] ids in
                self?.pollQueue.async {
                    guard let self else { return }
                    let until = Date().addingTimeInterval(self.config.snoozeMinutes * 60)
                    self.logger.info("user snoozed \(ids.map(\.pid)) until \(until)")
                    self.engine.snooze(ids, until: until)
                    self.writeState()
                }
            },
            ignore: { [weak self] ids in
                self?.pollQueue.async {
                    self?.logger.info("user ignored \(ids.map(\.pid))")
                    self?.engine.ignore(ids)
                    self?.writeState()
                }
            }
        ))
        killer = Killer(logger: logger, deps: KillerDependencies(
            escalationSeconds: { [weak self] in self?.config.killEscalationSeconds ?? 10 },
            freshSnapshot: { [weak self] in self?.freshSnapshot() }
        ))
    }

    /// Never returns: parks the main thread in a run loop (NSApplication when
    /// bundled — notification action callbacks need a live app, spec §9.1).
    func run() -> Never {
        logger.info("DaemonSlayer agent starting (pid \(getpid()), config \(configStore.path))")
        let isFirstRun = stateStore.read() == nil

        notifier.bootstrap { [weak self] granted in
            guard let self else { return }
            // Denial is logged by NotificationManager.bootstrap (the auth owner); no
            // duplicate "permission DENIED" line here (spec §13 row 11).
            if granted, isFirstRun { self.notifier.postTest() }
        }

        configStore.onInvalidConfig = { [weak self] message in
            self?.notifier.postConfigError(message)
        }
        configStore.startWatching { [weak self] newConfig in
            self?.pollQueue.async { self?.apply(newConfig) }
        }

        ideMonitor.onChange = { [weak self] running in
            // IDE quit must start R1's clock now, not at the next tick (§5.3).
            self?.pollQueue.async {
                self?.logger.info("IDE launch/terminate event (ideRunning=\(running)) — polling out of band")
                self?.poll()
            }
        }
        ideMonitor.start()

        pollQueue.async { self.poll() }

        if Bundle.main.bundleIdentifier != nil {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.run()
        } else {
            RunLoop.main.run()
        }
        fatalError("main run loop exited")
    }

    // MARK: - Poll cycle

    private func poll() {
        let now = Date()
        let raw = scanner.allProcesses()
        let daemons = ProcessScanner.daemons(in: raw)
        let snapshot = resolver.resolve(daemons: daemons, allProcesses: raw,
                                        idePids: ideMonitor.runningIDEPids(),
                                        ideRunning: ideMonitor.ideRunning,
                                        timestamp: now)
        lastPollAt = now
        lastIDERunning = snapshot.ideRunning

        let output = engine.ingest(snapshot)
        for batch in output.notifications {
            logger.info("flagging \(batch.processes.count) process(es) [\(batch.category.rawValue)]: "
                + batch.processes.map { "\($0.process.pid) \($0.process.displayName) via \($0.rule.shortName)" }.joined(separator: ", "))
            notifier.post(batch)
        }
        if !output.autoKill.isEmpty {
            logger.info("auto-kill (\(config.autoKill.rules.joined(separator: ","))): "
                + output.autoKill.map { "\($0.process.pid)" }.joined(separator: ", "))
            performKill(output.autoKill, userInitiated: false)
        }
        writeState()

        // Adaptive cadence (§5.3): nothing to watch → slow down.
        let desired = daemons.isEmpty ? config.idlePollIntervalSeconds : config.pollIntervalSeconds
        if desired != currentInterval { scheduleTimer(interval: desired) }
    }

    private func freshSnapshot() -> PollSnapshot? {
        // Called from the Killer's queue for kill-time re-validation (§7).
        // Scanner/resolver are stateless; IDEMonitor is thread-safe.
        let raw = scanner.allProcesses()
        guard !raw.isEmpty else { return nil }
        let daemons = ProcessScanner.daemons(in: raw)
        return resolver.resolve(daemons: daemons, allProcesses: raw,
                                idePids: ideMonitor.runningIDEPids(),
                                ideRunning: ideMonitor.ideRunning,
                                timestamp: Date())
    }

    private func performKill(_ procs: [FlaggedProcess], userInitiated: Bool) {
        if userInitiated { engine.markKilling(procs.map(\.process.identity)) }
        killer.kill(procs) { [weak self] reports in
            guard let self else { return }
            self.pollQueue.async {
                // Anything not actually killed returns to normal evaluation.
                let survivors = reports.compactMap { report -> ProcessIdentity? in
                    if case .killed = report.outcome { return nil }
                    return report.target.process.identity
                }
                self.engine.clearKilling(survivors)
                self.notifier.postKillSummary(reports)
                self.writeState()
            }
        }
    }

    private func scheduleTimer(interval: Double) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        // ~5 s leeway lets macOS coalesce wakeups (§5.3 power efficiency).
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        currentInterval = interval
        logger.debug("poll cadence: every \(Int(interval)) s")
    }

    private func apply(_ newConfig: Config) {
        logger.info("config reloaded")
        config = newConfig
        logger.minLevel = newConfig.logLevelValue
        ideMonitor.updatePrefixes(newConfig.ownerAppBundlePrefixes)
        engine.updateConfig(newConfig)
        // Do NOT touch the timer here: rescheduling on every save resets the timer
        // PHASE (repeated saves can starve polling) and pins fast cadence even when
        // idle. Instead run one immediate out-of-band poll (apply() already runs on
        // pollQueue) with the fresh thresholds; poll()'s tail re-establishes the
        // correct cadence (desired != currentInterval → scheduleTimer) and leaves an
        // unchanged-interval timer's existing phase alone.
        poll()
    }

    private func writeState() {
        stateStore.write(AgentStateSnapshot(
            writtenAt: Date(),
            agentPid: Int32(getpid()),
            lastPollAt: lastPollAt,
            ideRunning: lastIDERunning,
            notificationsAuthorized: notifier.authorized,
            configPath: configStore.path,
            records: engine.stateRecords()
        ))
    }
}
