import Foundation

/// `--status` / `--scan-once` (spec §11): fresh scan + ownership verdicts, and
/// for --status the resident agent's persisted view merged in. The two
/// diverging is itself diagnostic.
enum StatusCommand {
    static func run(options: CLIOptions, includeAgentView: Bool) -> Int32 {
        let logger = FileLogger(path: nil, minLevel: .warn)  // stderr; stdout stays clean
        let configStore = ConfigStore(path: options.configPath, logger: logger)
        let config = configStore.load()

        // Two samples ~1 s apart so CPU% is a real delta, not a guess.
        let scanner = ProcessScanner(logger: logger)
        let firstByID = Dictionary(
            uniqueKeysWithValues: scanner.allProcesses().map { (identityOf($0), $0.cpuTimeSeconds) }
        )
        let sampleGap: TimeInterval = 1.0
        Thread.sleep(forTimeInterval: sampleGap)
        let raw = scanner.allProcesses()
        let daemons = ProcessScanner.daemons(in: raw)

        let ideMonitor = IDEMonitor(bundlePrefixes: config.ownerAppBundlePrefixes, logger: logger)
        let now = Date()
        let snapshot = OwnershipResolver(logger: logger).resolve(
            daemons: daemons, allProcesses: raw,
            idePids: ideMonitor.runningIDEPids(), ideRunning: ideMonitor.ideRunning,
            timestamp: now)

        var out = "DaemonSlayer \(daemonSlayerVersion) — \(shortDate(now))\n"
        out += "IDE running: \(snapshot.ideRunning ? "yes" : "no")"
        out += " (prefixes: \(config.ownerAppBundlePrefixes.joined(separator: ", ")))\n"

        let agentState = includeAgentView
            ? StateStore(path: options.statePath, logger: logger).read()
            : nil
        if includeAgentView {
            out += agentHeader(agentState, config: config, now: now) + "\n"
        }
        out += "\n"

        if snapshot.daemons.isEmpty {
            out += "No Gradle/Kotlin daemons running.\n"
        } else {
            out += table(snapshot: snapshot, firstCPUByID: firstByID, sampleGap: sampleGap,
                         agentState: agentState, config: config, now: now)
        }

        if includeAgentView, let state = agentState {
            out += divergences(snapshot: snapshot, state: state)
            if state.notificationsAuthorized == false {
                out += "\n⚠ Notifications are DENIED — enable in System Settings → Notifications → DaemonSlayer\n"
                out += "  (and pick the “Alerts” style so they stick around).\n"
            }
        }
        print(out)
        return 0
    }

    // MARK: - Sections

    private static func agentHeader(_ state: AgentStateSnapshot?, config: Config, now: Date) -> String {
        guard let state else {
            return "Agent: no state file — agent not installed or never ran (make install)"
        }
        let alive = kill(state.agentPid, 0) == 0
        let age = now.timeIntervalSince(state.writtenAt)
        let stale = age > config.idlePollIntervalSeconds + 30
        var line = "Agent: pid \(state.agentPid) \(alive ? "running" : "NOT RUNNING")"
        line += ", last poll \(Format.duration(max(0, now.timeIntervalSince(state.lastPollAt)))) ago"
        if stale { line += " — STALE (state written \(Format.duration(age)) ago)" }
        line += " | notifications: " + authDescription(state.notificationsAuthorized)
        return line
    }

    private static func authDescription(_ authorized: Bool?) -> String {
        switch authorized {
        case .some(true): return "authorized"
        case .some(false): return "DENIED"
        case .none: return "undetermined"
        }
    }

    private static func table(snapshot: PollSnapshot, firstCPUByID: [ProcessIdentity: Double],
                              sampleGap: TimeInterval, agentState: AgentStateSnapshot?,
                              config: Config, now: Date) -> String {
        let recordsByID = Dictionary(uniqueKeysWithValues:
            (agentState?.records ?? []).map { ($0.identity, $0) })

        var rows: [[String]] = [["PID", "DAEMON", "AGE", "RSS", "CPU%", "OWNED", "WHY", "AGENT STATE"]]
        let sorted = snapshot.daemons.sorted { $0.process.kind == .gradle && $1.process.kind == .kotlin }
        for obs in sorted {
            let p = obs.process
            let cpuPct: String
            if let prior = firstCPUByID[p.identity] {
                cpuPct = String(format: "%.0f", max(0, (p.cpuTimeSeconds - prior) / sampleGap * 100))
            } else {
                cpuPct = "?"
            }
            let owned = Ownership.isOwned(obs, in: snapshot)
            rows.append([
                "\(p.pid)",
                p.displayName,
                Format.duration(now.timeIntervalSince(p.identity.startDate)),
                Format.bytes(p.rssBytes),
                cpuPct,
                obs.ownershipUnknown ? "?" : (owned ? "yes" : "NO"),
                whyString(obs, owned: owned),
                agentStateString(recordsByID[p.identity], config: config),
            ])
        }
        return render(rows)
    }

    private static func whyString(_ obs: DaemonObservation, owned: Bool) -> String {
        if obs.ownershipUnknown { return "lsof failed" }
        if obs.parentIsIDE { return "IDE parent" }
        if obs.hasAttachedClient { return "client attached" }
        if owned, let gpid = obs.linkedGradlePid { return "via gradle \(gpid)" }
        if obs.process.isDetached { return "detached, no client" }
        return "no owner"
    }

    private static func agentStateString(_ record: ProcessStateRecord?, config: Config) -> String {
        guard let record else { return "not yet seen" }
        var s = record.stateDescription
        let counters = Rule.allCases.compactMap { rule -> String? in
            guard let c = record.ruleCounters[rule.rawValue], c > 0 else { return nil }
            return "\(rule.shortName):\(c)/\(config.requiredConsecutiveSamples(for: rule))"
        }
        if !counters.isEmpty { s += " [" + counters.joined(separator: " ") + "]" }
        return s
    }

    private static func divergences(snapshot: PollSnapshot, state: AgentStateSnapshot) -> String {
        let fresh = Set(snapshot.daemons.map { $0.process.identity })
        let agent = Set(state.records.map(\.identity))
        var notes: [String] = []
        for id in fresh.subtracting(agent) {
            notes.append("pid \(id.pid) is live but the agent hasn't seen it yet (appeared since last poll)")
        }
        for id in agent.subtracting(fresh) {
            notes.append("agent still tracks pid \(id.pid) but it's gone (died since last poll)")
        }
        guard !notes.isEmpty else { return "" }
        return "\nDivergence (agent view vs now):\n" + notes.map { "  • \($0)" }.joined(separator: "\n") + "\n"
    }

    // MARK: - Rendering

    private static func render(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        var widths = header.map(\.count)
        for row in rows {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }
        return rows.enumerated().map { index, row in
            let line = row.enumerated()
                .map { i, cell in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
            return index == 0 ? line + "\n" + String(repeating: "─", count: line.count) : line
        }.joined(separator: "\n") + "\n"
    }

    private static func shortDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    private static func identityOf(_ raw: RawProcess) -> ProcessIdentity {
        ProcessIdentity(pid: raw.pid, startTimeMicros: raw.startTimeMicros)
    }
}
