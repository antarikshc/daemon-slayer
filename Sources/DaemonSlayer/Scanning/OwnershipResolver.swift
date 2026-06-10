import Foundation

// MARK: - OwnershipResolver (spec §5.1 ownership predicate, §5.4 data sources)
//
// One lsof spawn per resolve() call. Stateless across calls — the RuleEngine
// owns all history. Fills, per daemon: parentIsIDE (O1), hasAttachedClient (O2),
// listenPorts, linkedGradlePid (O4 input), ownershipUnknown (lsof failure).

final class OwnershipResolver {
    private let logger: DSLogger
    private let lsofTimeoutSeconds: Double

    private static let lsofPath = "/usr/sbin/lsof"
    /// Cycle guard for the ppid chain walk (spec §5.1 O1).
    private static let maxAncestorHops = 25

    init(logger: DSLogger, lsofTimeoutSeconds: Double = 5) {
        self.logger = logger
        self.lsofTimeoutSeconds = lsofTimeoutSeconds
    }

    // MARK: - Per-daemon network facts parsed from lsof

    /// Loopback ESTABLISHED connection (both endpoints on 127.0.0.1/[::1]).
    private struct Conn {
        let pid: Int32
        let localPort: Int
        let peerPort: Int
    }

    func resolve(daemons: [DaemonProcess], allProcesses: [RawProcess],
                 idePids: Set<Int32>, ideRunning: Bool, timestamp: Date) -> PollSnapshot {
        // Zero daemons → skip the spawn entirely (spec edge case 10, fast path).
        guard !daemons.isEmpty else {
            return PollSnapshot(timestamp: timestamp, daemons: [], ideRunning: ideRunning)
        }

        // O1 — pid→ppid map for the ancestor walk.
        let ppidMap = buildPpidMap(allProcesses)
        let watchedPids = Set(daemons.map { $0.pid })

        // O2/O4 — one lsof for ALL daemon pids.
        let lsof = runLsof(for: daemons.map { $0.pid })

        var observations: [DaemonObservation] = []
        observations.reserveCapacity(daemons.count)

        for daemon in daemons {
            let pid = daemon.pid
            let parentIsIDE = ancestorIsIDE(pid: pid, ppidMap: ppidMap, idePids: idePids)

            // lsof failed/timed out → fail safe toward NOT flagging (edge case 8):
            // ownershipUnknown, no client, no ports. O1 (parentIsIDE) is still
            // valid — it does not depend on lsof — so we keep it.
            guard let lsof = lsof else {
                logger.debug("OwnershipResolver pid=\(pid) \(daemon.kind.rawValue): ownershipUnknown (lsof failed); parentIsIDE=\(parentIsIDE)")
                observations.append(DaemonObservation(
                    process: daemon,
                    parentIsIDE: parentIsIDE,
                    hasAttachedClient: false,
                    listenPorts: [],
                    linkedGradlePid: nil,
                    ownershipUnknown: true))
                continue
            }

            let listen = lsof.listenPorts[pid] ?? []
            let myConns = lsof.connections.filter { $0.pid == pid }

            // O2 — inbound candidate = ESTABLISHED loopback row whose LOCAL port
            // is one of this daemon's LISTEN ports.
            let candidates = myConns.filter { listen.contains($0.localPort) }
            // hasAttachedClient iff at least one candidate has NO mirror on
            // another watched daemon (peer-daemon links don't count, §5.1 O2).
            let hasClient = candidates.contains { cand in
                !hasMirror(of: cand, in: lsof.connections, watched: watchedPids)
            }

            // O4 input — linkedGradlePid for Kotlin daemons only.
            let linked: Int32? = daemon.kind == .kotlin
                ? linkedGradlePid(for: daemon, myConns: myConns,
                                  daemons: daemons, lsof: lsof)
                : nil

            logger.debug("OwnershipResolver pid=\(pid) \(daemon.kind.rawValue) \(daemon.displayName): parentIsIDE=\(parentIsIDE) hasAttachedClient=\(hasClient) listen=\(listen.sorted()) candidates=\(candidates.count) linkedGradlePid=\(linked.map(String.init) ?? "nil")")

            observations.append(DaemonObservation(
                process: daemon,
                parentIsIDE: parentIsIDE,
                hasAttachedClient: hasClient,
                listenPorts: listen.sorted(),
                linkedGradlePid: linked,
                ownershipUnknown: false))
        }

        return PollSnapshot(timestamp: timestamp, daemons: observations, ideRunning: ideRunning)
    }

    // MARK: - O1: ancestor chain walk

    private func buildPpidMap(_ procs: [RawProcess]) -> [Int32: Int32] {
        var map: [Int32: Int32] = [:]
        map.reserveCapacity(procs.count)
        for p in procs { map[p.pid] = p.ppid }
        return map
    }

    /// True iff any ancestor (the daemon's parent or further up) is a running
    /// IDE. Cycle-guarded and hop-capped (spec §5.1 O1: "parent is an IDE *or a
    /// descendant of one*").
    private func ancestorIsIDE(pid: Int32, ppidMap: [Int32: Int32], idePids: Set<Int32>) -> Bool {
        var current = pid
        var seen: Set<Int32> = [current]
        for _ in 0..<Self.maxAncestorHops {
            guard let parent = ppidMap[current], parent != 0, parent != current else { return false }
            if idePids.contains(parent) { return true }
            if !seen.insert(parent).inserted { return false } // cycle
            if parent == 1 { return false }                   // reached launchd
            current = parent
        }
        return false
    }

    // MARK: - O2: peer-daemon mirror exclusion

    /// A candidate connection (local p, peer q) is a daemon-to-daemon link if
    /// ANOTHER watched daemon has the mirrored ESTABLISHED row (local q, peer p).
    private func hasMirror(of cand: Conn, in conns: [Conn], watched: Set<Int32>) -> Bool {
        conns.contains { other in
            other.pid != cand.pid
                && watched.contains(other.pid)
                && other.localPort == cand.peerPort
                && other.peerPort == cand.localPort
        }
    }

    // MARK: - O4 input: linkedGradlePid for a Kotlin daemon

    /// Primary: ppid if it is a scanned Gradle daemon. Fallback: the Gradle
    /// daemon on the other end of a mirrored loopback connection involving this
    /// Kotlin daemon (Gradle holds an RMI connection to the Kotlin daemon's
    /// LISTEN port in practice, so the mirror can appear in either direction —
    /// we handle both).
    private func linkedGradlePid(for kotlin: DaemonProcess, myConns: [Conn],
                                 daemons: [DaemonProcess], lsof: LsofResult) -> Int32? {
        let gradlePids = Set(daemons.filter { $0.kind == .gradle }.map { $0.pid })

        // Primary: PPID match.
        if gradlePids.contains(kotlin.ppid) { return kotlin.ppid }

        // Fallback: find a mirrored connection between this Kotlin daemon and a
        // Gradle daemon, regardless of which side holds the LISTEN.
        for conn in myConns {
            for gpid in gradlePids {
                let gradleConns = lsof.connections.filter { $0.pid == gpid }
                let mirrored = gradleConns.contains {
                    $0.localPort == conn.peerPort && $0.peerPort == conn.localPort
                }
                if mirrored { return gpid }
            }
        }
        return nil
    }

    // MARK: - lsof spawn + field-mode parse

    private struct LsofResult {
        var listenPorts: [Int32: Set<Int>] = [:]
        var connections: [Conn] = []
    }

    /// Loopback hosts (spec §5.4). Wildcard `*` is tolerated for LISTEN — Gradle
    /// daemons bind loopback, but lsof may render a wildcard bind; counting it is
    /// the tolerant choice and cannot widen client detection (ESTABLISHED rows
    /// always carry concrete addresses).
    private static func isLoopbackHost(_ host: Substring, allowWildcard: Bool) -> Bool {
        host == "127.0.0.1" || host == "[::1]" || (allowWildcard && host == "*")
    }

    /// Spawn `lsof -a -p <pids> -i TCP -n -P -F pnT`, drain stdout off-thread to
    /// avoid pipe-buffer deadlock, wait up to lsofTimeoutSeconds. Returns nil on
    /// timeout or hard failure (→ ownershipUnknown for all daemons, edge case 8).
    private func runLsof(for pids: [Int32]) -> LsofResult? {
        let pidArg = pids.map(String.init).joined(separator: ",")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.lsofPath)
        proc.arguments = ["-a", "-p", pidArg, "-i", "TCP", "-n", "-P", "-F", "pnT"]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Drain stdout on a background thread so a large lsof dump can never
        // deadlock against the pipe buffer while we wait (spec §9.3).
        var stdoutData = Data()
        let drainQueue = DispatchQueue(label: "dev.antariksh.daemonslayer.lsof.drain")
        let drainGroup = DispatchGroup()

        do {
            try proc.run()
        } catch {
            logger.warn("OwnershipResolver: lsof spawn failed: \(error.localizedDescription)")
            return nil
        }

        drainGroup.enter()
        drainQueue.async {
            stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        // Wait for exit with timeout.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            proc.waitUntilExit()
            done.signal()
        }

        if done.wait(timeout: .now() + lsofTimeoutSeconds) == .timedOut {
            logger.warn("OwnershipResolver: lsof timed out after \(lsofTimeoutSeconds)s; SIGKILL, ownershipUnknown for all daemons")
            kill(proc.processIdentifier, SIGKILL)
            // Reap and let the drain finish so no fd/thread leaks.
            _ = done.wait(timeout: .now() + 1)
            _ = drainGroup.wait(timeout: .now() + 1)
            return nil
        }

        // Process exited within budget; ensure the drain completed.
        _ = drainGroup.wait(timeout: .now() + 1)

        let status = proc.terminationStatus
        let output = String(data: stdoutData, encoding: .utf8) ?? ""

        // lsof exits 1 when some pids own no sockets — NORMAL; parse whatever
        // output exists. Only a truly empty output with nonzero exit is failure.
        if output.isEmpty && status != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            logger.warn("OwnershipResolver: lsof exit \(status) with no output: \(err.trimmingCharacters(in: .whitespacesAndNewlines)); ownershipUnknown")
            return nil
        }

        return parse(output)
    }

    /// Field-mode parser. Output is a stream of single-char-tagged lines:
    ///   p<pid>          start of a process section
    ///   f<fd>           start of an fd record (flushes the previous one)
    ///   n<name>         host:port  (LISTEN)  OR  local->peer  (ESTABLISHED)
    ///   TST=<state>     TCP state
    /// We accumulate name+state per fd and classify on flush.
    private func parse(_ output: String) -> LsofResult {
        var result = LsofResult()

        var curPid: Int32?
        var curName: String?
        var curState: String?

        func flushFd() {
            defer { curName = nil; curState = nil }
            guard let pid = curPid, let name = curName, let state = curState else { return }
            switch state {
            case "LISTEN":
                if let (host, port) = splitHostPort(name[...]),
                   Self.isLoopbackHost(host, allowWildcard: true) {
                    result.listenPorts[pid, default: []].insert(port)
                }
            case "ESTABLISHED":
                guard let arrow = name.range(of: "->") else { return }
                let local = name[name.startIndex..<arrow.lowerBound]
                let peer = name[arrow.upperBound...]
                guard let (lh, lp) = splitHostPort(local),
                      let (ph, pp) = splitHostPort(peer) else { return }
                // Both endpoints must be loopback; non-loopback rows
                // (build-cache/dependency HTTP) are ignored entirely (§5.4).
                if Self.isLoopbackHost(lh, allowWildcard: false),
                   Self.isLoopbackHost(ph, allowWildcard: false) {
                    result.connections.append(Conn(pid: pid, localPort: lp, peerPort: pp))
                }
            default:
                break
            }
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = rawLine.first else { continue }
            let value = rawLine.dropFirst()
            switch tag {
            case "p":
                flushFd()
                curPid = Int32(value)
                curName = nil
                curState = nil
            case "f":
                flushFd()
            case "n":
                curName = String(value)
            case "T":
                if value.hasPrefix("ST=") { curState = String(value.dropFirst(3)) }
            default:
                break
            }
        }
        flushFd()

        return result
    }

    /// Split "host:port" on the LAST colon so IPv6 "[::1]:5391" parses (the
    /// bracketed host keeps its inner colons). Returns nil if the port is not an
    /// integer (e.g. a named service that slipped past -P, or "*:*").
    private func splitHostPort(_ s: Substring) -> (Substring, Int)? {
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = s[s.startIndex..<colon]
        let portStr = s[s.index(after: colon)...]
        guard let port = Int(portStr) else { return nil }
        return (host, port)
    }
}
