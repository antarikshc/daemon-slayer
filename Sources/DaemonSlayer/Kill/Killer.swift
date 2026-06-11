import Foundation
import Darwin

// MARK: - Dependencies (live reads supplied by the wiring layer)

struct KillerDependencies {
    /// Live config read: killEscalationSeconds at the moment of the kill.
    var escalationSeconds: () -> Double
    /// Fresh scan + ownership for kill-time re-validation (spec §7). Returning
    /// nil means the scan FAILED → the whole batch is aborted (fail-safe: we
    /// never signal a process we could not re-validate against current truth).
    var freshSnapshot: () -> PollSnapshot?

    // The following are injectable purely for unit-testing the kill machinery
    // against fakes (no real processes/signals). Production wiring leaves them at
    // their defaults, which are the exact Darwin syscalls the killer always used.

    /// Send `signal` to `pid`. Default: `Darwin.kill`. Returns 0 on success, else
    /// sets errno (the production path inspects errno for ESRCH/EPERM).
    var sendSignal: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) }
    /// Live start-time probe (proc_pidinfo PROC_PIDTBSDINFO) — same source/formula
    /// the scanner uses. nil = process gone. Default reads the live process table.
    var liveStartMicros: (Int32) -> Int64? = { pid in
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard n == size else { return nil }
        return Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
    }
    /// Unlink a path. Default: `Darwin.unlink`. (Errno semantics preserved.)
    var unlinkPath: (String) -> Int32 = { Darwin.unlink($0) }
}

// MARK: - Killer (SAFETY-CRITICAL — spec §7, goal #4 "never kill an active build")

/// Graceful-first, per-process kill escalation executed entirely off the
/// caller's thread. Every signal is gated behind a kill-time re-validation
/// against a single fresh snapshot, and start-time is re-verified again
/// immediately before SIGTERM and SIGKILL so a recycled PID can never be hit.
final class Killer {
    private let logger: DSLogger
    private let deps: KillerDependencies
    /// Serial: a batch is resolved start-to-finish before the next is accepted.
    /// Per-phase concurrency (Kotlin together, then Gradle together) is layered
    /// on top via a DispatchGroup + a dedicated worker queue.
    private let queue = DispatchQueue(label: "dev.antariksh.daemonslayer.killer")
    /// Concurrent workers for within-phase parallelism (spec §7 requirement 4).
    private let workers = DispatchQueue(label: "dev.antariksh.daemonslayer.killer.workers",
                                        attributes: .concurrent)

    /// Poll cadence while waiting for a signalled process to exit.
    private static let pollStep: TimeInterval = 0.25
    /// SIGKILL is near-instant; we only need a short grace to confirm reaping.
    private static let sigkillWindow: TimeInterval = 2.0

    init(logger: DSLogger, deps: KillerDependencies) {
        self.logger = logger
        self.deps = deps
    }

    /// Async, never blocks the caller; `completion` runs on an arbitrary queue.
    /// `policy` is required (no default) so every call site states its intent
    /// (SPEC-UI §6): the agent must always pass `.respectOwnership`.
    func kill(_ targets: [FlaggedProcess], policy: KillPolicy,
              completion: @escaping ([KillReport]) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { completion([]); return }
            completion(self.run(targets, policy: policy))
        }
    }

    // MARK: - Batch driver

    private func run(_ targets: [FlaggedProcess], policy: KillPolicy) -> [KillReport] {
        guard !targets.isEmpty else { return [] }

        let escalation = max(0.1, deps.escalationSeconds())

        // Kill order (spec §7 requirement 4): ALL Kotlin daemons fully resolved
        // first, THEN Gradle daemons — killing the parent Gradle first abandons
        // its child and re-creates the very leak we're fixing.
        let kotlin = targets.filter { $0.process.kind == .kotlin }
        let gradle = targets.filter { $0.process.kind == .gradle }

        // Re-validate per PHASE, not once per batch (spec §7, goal #4). The kotlin
        // phase can take 10–20+ s of escalation waits; a build may attach to a
        // gradle daemon during it. A single batch-wide snapshot would miss that and
        // kill a now-busy daemon. So each phase takes its OWN fresh snapshot +
        // full revalidation immediately before signalling that phase's targets.
        var reports: [KillReport] = []

        // Phase 1 — Kotlin daemons.
        if !kotlin.isEmpty {
            guard let snapshot = deps.freshSnapshot() else {
                logger.error("kill aborted — phase-1 (kotlin) revalidation scan failed; signalling nothing (fail-safe)")
                return targets.map { KillReport(target: $0, outcome: .failed("revalidation scan failed")) }
            }
            reports.append(contentsOf: resolvePhase(kotlin, snapshot: snapshot, escalation: escalation, phase2: false, policy: policy))
        }

        // Phase 2 — Gradle daemons. A SECOND fresh snapshot taken AFTER the kotlin
        // phase, re-validating gradle targets against current truth. Anything that
        // picked up a build between phases is skipped (.skippedNowOwned / .skippedGone),
        // exactly like phase 1.
        if !gradle.isEmpty {
            guard let snapshot = deps.freshSnapshot() else {
                logger.error("kill aborted — phase-2 (gradle) revalidation scan failed; signalling nothing (fail-safe)")
                reports.append(contentsOf: gradle.map { KillReport(target: $0, outcome: .failed("revalidation scan failed")) })
                return reports
            }
            reports.append(contentsOf: resolvePhase(gradle, snapshot: snapshot, escalation: escalation, phase2: true, policy: policy))
        }

        return reports
    }

    /// Process every target in a phase concurrently, joining before returning so
    /// the caller's phase ordering (Kotlin → Gradle) is preserved.
    private func resolvePhase(_ targets: [FlaggedProcess],
                              snapshot: PollSnapshot,
                              escalation: Double,
                              phase2: Bool,
                              policy: KillPolicy) -> [KillReport] {
        guard !targets.isEmpty else { return [] }

        let group = DispatchGroup()
        let lock = NSLock()
        var results: [Int: KillReport] = [:]   // index-keyed to preserve input order

        for (i, target) in targets.enumerated() {
            group.enter()
            workers.async { [weak self] in
                defer { group.leave() }
                guard let self = self else { return }
                let report = self.resolveOne(target, snapshot: snapshot, escalation: escalation, phase2: phase2, policy: policy)
                lock.lock(); results[i] = report; lock.unlock()
            }
        }
        // A phase may hold several processes, each escalating up to ~2× the
        // escalation window; bound the join generously so a hung wait can never
        // wedge the killer forever. resolveOne already self-bounds, so this is a
        // belt-and-braces ceiling.
        let ceiling: DispatchTime = .now() + (escalation * 2 + Self.sigkillWindow + 5) * Double(targets.count) + 5
        if group.wait(timeout: ceiling) == .timedOut {
            logger.error("kill phase exceeded its time ceiling — some targets may be unresolved")
        }
        return targets.indices.compactMap { results[$0] }
    }

    // MARK: - Per-process resolution (spec §7 requirements 3, 5)

    private func resolveOne(_ target: FlaggedProcess,
                            snapshot: PollSnapshot,
                            escalation: Double,
                            phase2: Bool,
                            policy: KillPolicy) -> KillReport {
        let proc = target.process
        let pid = proc.pid

        // (3) Re-validate EVERY target against the fresh snapshot before any
        // signal. A daemon that picked up a new build or owner since the
        // notification must be skipped (spec §7, goal #4) — unless `.userForced`,
        // which bypasses EXACTLY the ownership step (identity/argv still gate).
        switch revalidate(target, in: snapshot, phase2: phase2, policy: policy) {
        case .skip(let outcome):
            return KillReport(target: target, outcome: outcome)
        case .proceed:
            break
        }

        // (5) Escalation. Kotlin with a marker → try the clean marker-file
        // shutdown first.
        if proc.kind == .kotlin, let markerPath = proc.kotlinAliveMarkerPath {
            if tryMarkerShutdown(markerPath, pid: pid, name: proc.displayName, escalation: escalation) {
                return KillReport(target: target, outcome: .killed(.markerFile))
            }
            // Marker didn't bring it down (or was unsafe) → fall through to signals.
        }

        // SIGTERM — re-verify start time immediately before signalling.
        switch signalWithStartCheck(target, signal: SIGTERM, method: "SIGTERM",
                                    window: escalation) {
        case .exited:
            return KillReport(target: target, outcome: .killed(.sigterm))
        case .resolved(let outcome):
            return KillReport(target: target, outcome: outcome)
        case .stillAlive:
            break
        }

        // SIGKILL — re-verify start time again, then a short confirmation window.
        switch signalWithStartCheck(target, signal: SIGKILL, method: "SIGKILL",
                                    window: Self.sigkillWindow) {
        case .exited:
            return KillReport(target: target, outcome: .killed(.sigkill))
        case .resolved(let outcome):
            return KillReport(target: target, outcome: outcome)
        case .stillAlive:
            logger.error("pid \(pid) (\(proc.displayName)) survived SIGKILL")
            return KillReport(target: target, outcome: .failed("survived SIGKILL"))
        }
    }

    // MARK: - Kill-time re-validation (spec §7 requirement 3)

    private enum Revalidation {
        case proceed
        case skip(KillOutcome)
    }

    private func revalidate(_ target: FlaggedProcess, in snapshot: PollSnapshot,
                            phase2: Bool, policy: KillPolicy) -> Revalidation {
        let proc = target.process
        let pid = proc.pid

        // (a) An observation with the SAME pid AND SAME startTimeMicros exists.
        // Holds under EVERY policy — a recycled PID is unkillable (SPEC-UI §6).
        guard let obs = snapshot.daemons.first(where: {
            $0.process.pid == pid && $0.process.identity.startTimeMicros == proc.identity.startTimeMicros
        }) else {
            let extra = phase2 ? " (phase-2 revalidation)" : ""
            logger.info("skipped pid \(pid) (\(proc.displayName)) — gone or PID reused (no matching observation)\(extra)")
            return .skip(.skippedGone)
        }

        // (b) Its argv still contains the matching daemon marker for its kind
        // (exact element match, spec §5.4). Holds under every policy.
        let marker = (proc.kind == .gradle) ? DaemonKind.gradleArgvMarker : DaemonKind.kotlinArgvMarker
        guard obs.process.argv.contains(marker) else {
            logger.info("skipped pid \(pid) (\(proc.displayName)) — argv no longer matches a \(proc.kind.rawValue) (re-execed?)")
            return .skip(.skippedGone)
        }

        // (c) Ownership re-check — the ONLY step `.userForced` bypasses (SPEC-UI
        // §6): user intent already confirmed killing an owned/busy daemon, so a
        // now-owned verdict (or ownershipUnknown fail-safe) does not skip it.
        if policy == .userForced { return .proceed }

        // lsof unknown → fail-safe toward "owned".
        if obs.ownershipUnknown {
            logger.info("skipped pid \(pid) (\(proc.displayName)) — ownership unknown this cycle (fail-safe, not killed)")
            return .skip(.skippedNowOwned)
        }
        if Ownership.isOwned(obs, in: snapshot) {
            if phase2 {
                // A gradle daemon that gained an owner DURING the kotlin phase (spec §7).
                logger.info("skipped pid \(pid) (\(proc.displayName)) — now busy — build attached between phases (phase-2 revalidation)")
            } else {
                logger.info("skipped pid \(pid) (\(proc.displayName)) — now owned (client attached)")
            }
            return .skip(.skippedNowOwned)
        }

        return .proceed
    }

    // MARK: - Marker-file shutdown (spec §7 step 1)

    /// Delete the Kotlin alive-marker (clean self-shutdown) and poll for exit.
    /// DEFENSE: only unlink a path whose last component contains "kotlin" AND ends
    /// in ".alive" (the spec'd marker naming, §5.4) — a hostile/garbled argv must
    /// never make us delete an arbitrary file.
    private func tryMarkerShutdown(_ markerPath: String, pid: Int32, name: String, escalation: Double) -> Bool {
        let lastComponent = (markerPath as NSString).lastPathComponent
        let lower = lastComponent.lowercased()
        guard lower.contains("kotlin") && lower.hasSuffix(".alive") else {
            logger.warn("pid \(pid) (\(name)) — refusing to unlink marker '\(markerPath)' (name must contain 'kotlin' and end in '.alive'); skipping marker step")
            return false
        }

        logger.info("killing pid \(pid) (\(name)) via marker-file shutdown — unlinking \(markerPath)")
        // unlink errors (already gone, permission) are non-fatal: fall through to
        // signal escalation, which is authoritative.
        if deps.unlinkPath(markerPath) != 0 && errno != ENOENT {
            logger.warn("pid \(pid) (\(name)) — unlink of marker failed (errno \(errno)); falling back to signals")
        }

        if pollForExit(pid: pid, within: escalation) {
            logger.info("pid \(pid) (\(name)) exited cleanly after marker deletion")
            return true
        }
        logger.info("pid \(pid) (\(name)) still alive \(Format.duration(escalation)) after marker deletion — escalating to SIGTERM")
        return false
    }

    // MARK: - Signalling with start-time re-verification (spec §7 requirement 5)

    private enum SignalResult {
        case exited                 // confirmed gone within the window
        case stillAlive             // alive after the window → escalate
        case resolved(KillOutcome)  // terminal: skippedGone / failed
    }

    /// Re-verify the live process start time via proc_pidinfo PROC_PIDTBSDINFO
    /// STILL matches first-seen, then send `signal` and poll for exit. Any
    /// start-time mismatch discovered here → stop signalling this pid
    /// immediately and report .skippedGone (PID was recycled mid-escalation).
    private func signalWithStartCheck(_ target: FlaggedProcess,
                                      signal: Int32,
                                      method: String,
                                      window: TimeInterval) -> SignalResult {
        let proc = target.process
        let pid = proc.pid

        // Re-verify start time immediately before signalling (spec §7 #5, §12).
        // Holds under EVERY policy — a recycled PID is never signalled.
        switch deps.liveStartMicros(pid) {
        case .none:
            logger.info("skipped pid \(pid) (\(proc.displayName)) — gone before \(method)")
            return .resolved(.skippedGone)
        case .some(let live) where live != proc.identity.startTimeMicros:
            logger.info("skipped pid \(pid) (\(proc.displayName)) — start time changed before \(method) (PID reused mid-escalation)")
            return .resolved(.skippedGone)
        case .some:
            break
        }

        logger.info("killing pid \(pid) (\(proc.displayName)) via \(method)")
        if deps.sendSignal(pid, signal) != 0 {
            // ESRCH at signal time → it just exited; EPERM → genuine failure.
            switch errno {
            case ESRCH:
                logger.info("skipped pid \(pid) (\(proc.displayName)) — exited just before \(method) (ESRCH)")
                return .resolved(.skippedGone)
            case EPERM:
                logger.error("failed to \(method) pid \(pid) (\(proc.displayName)) — EPERM (not our process?)")
                return .resolved(.failed("\(method): EPERM"))
            default:
                logger.error("failed to \(method) pid \(pid) (\(proc.displayName)) — errno \(errno)")
                return .resolved(.failed("\(method): errno \(errno)"))
            }
        }

        if pollForExit(pid: pid, within: window) {
            logger.info("pid \(pid) (\(proc.displayName)) exited after \(method)")
            return .exited
        }
        return .stillAlive
    }

    // MARK: - Exit detection & start-time probe

    /// Poll `kill(pid, 0)` every 0.25 s up to `within` seconds. Exit is detected
    /// when kill returns -1 with errno == ESRCH (no such process). A surviving
    /// EPERM (process exists but not ours — shouldn't happen for same-user) is
    /// treated as "still alive".
    private func pollForExit(pid: Int32, within: TimeInterval) -> Bool {
        // Liveness probe via signal 0 (no signal sent; only existence/perm checked),
        // routed through the injectable sender so unit tests can model exit.
        func exited() -> Bool { deps.sendSignal(pid, 0) == -1 && errno == ESRCH }
        let deadline = Date().addingTimeInterval(within)
        repeat {
            if exited() { return true }
            // Spin-wait via usleep on this worker thread (off the poll/main path).
            usleep(useconds_t(Self.pollStep * 1_000_000))
        } while Date() < deadline
        // Final check after the loop's last sleep.
        return exited()
    }
}
