import Foundation

// MARK: - Daemon classification

enum DaemonKind: String, Codable, CaseIterable {
    case gradle = "GradleDaemon"
    case kotlin = "KotlinCompileDaemon"

    /// argv substrings that classify a JVM as a watched daemon (spec §5.4).
    static let gradleArgvMarker = "org.gradle.launcher.daemon.bootstrap.GradleDaemon"
    static let kotlinArgvMarker = "org.jetbrains.kotlin.daemon.KotlinCompileDaemon"
}

// MARK: - Process identity (PID-reuse guard, spec §5.4 / §12)

/// A PID is only meaningful together with the process start time. Start time is
/// stored as integer microseconds since epoch (from pbi_start_tvsec/usec) so that
/// equality across polls is exact.
struct ProcessIdentity: Hashable, Codable {
    let pid: Int32
    let startTimeMicros: Int64

    var startDate: Date { Date(timeIntervalSince1970: Double(startTimeMicros) / 1_000_000) }
}

// MARK: - Scanner output

/// One row of the same-user process table. Produced by ProcessScanner, consumed
/// by OwnershipResolver (parent-chain walks, peer classification).
struct RawProcess {
    let pid: Int32
    let ppid: Int32
    let startTimeMicros: Int64
    let rssBytes: UInt64
    /// Cumulative user+system CPU seconds since process start.
    let cpuTimeSeconds: Double
    let argv: [String]
}

/// One watched daemon process as seen in a single scan. Stateless snapshot —
/// cumulative CPU time deltas are computed by the RuleEngine across snapshots.
struct DaemonProcess: Codable {
    let identity: ProcessIdentity
    let kind: DaemonKind
    let ppid: Int32
    let rssBytes: UInt64
    /// Cumulative user+system CPU seconds since process start.
    let cpuTimeSeconds: Double
    let argv: [String]
    /// Parsed from argv, e.g. "8.13" from "... GradleDaemon 8.13".
    let gradleVersion: String?
    /// Best-effort project name (Kotlin alive-marker filename, classpath hints).
    let projectHint: String?
    /// Kotlin only: -Dkotlin.daemon.initiator.marker.file=… (kill step 1, spec §7).
    let kotlinAliveMarkerPath: String?

    var pid: Int32 { identity.pid }
    /// Detached = re-parented to launchd (spec §4).
    var isDetached: Bool { ppid == 1 }

    /// Human-readable name for notifications and --status, e.g.
    /// "Gradle 8.13 (mojmultiproject)" or "Kotlin daemon (androidcommon)".
    var displayName: String {
        let base: String
        switch kind {
        case .gradle: base = "Gradle" + (gradleVersion.map { " \($0)" } ?? " daemon")
        case .kotlin: base = "Kotlin daemon"
        }
        if let project = projectHint, !project.isEmpty { return "\(base) (\(project))" }
        return base
    }
}

// MARK: - Ownership (spec §5.1)

/// Scanner + OwnershipResolver output for one daemon, input to the RuleEngine.
struct DaemonObservation: Codable {
    var process: DaemonProcess
    /// O1 — ppid chain reaches a running configured IDE.
    var parentIsIDE: Bool
    /// O2 — ESTABLISHED loopback connection to one of its LISTEN ports from a
    /// peer that is not itself a watched daemon.
    var hasAttachedClient: Bool
    /// Diagnostic: the daemon's loopback LISTEN ports.
    var listenPorts: [Int]
    /// Kotlin only: PID of the Gradle daemon it serves (PPID match, falling back
    /// to RMI peer). Drives O4 transitivity in the RuleEngine.
    var linkedGradlePid: Int32?
    /// lsof timed out/failed for this daemon this cycle → RuleEngine keeps the
    /// previous verdict (fail-safe toward NOT flagging, spec edge case 8).
    var ownershipUnknown: Bool
    /// v2 (SPEC-UI §5.1): display-only description of the attached client (the
    /// non-peer ESTABLISHED loopback peer process, e.g. "Android Studio", "java
    /// (pid 1234)"). Facts only — the RuleEngine IGNORES this. nil when there is
    /// no client (or only peer-daemon links, which are not clients).
    var attachedClientDescription: String?

    init(process: DaemonProcess,
         parentIsIDE: Bool = false,
         hasAttachedClient: Bool = false,
         listenPorts: [Int] = [],
         linkedGradlePid: Int32? = nil,
         ownershipUnknown: Bool = false,
         attachedClientDescription: String? = nil) {
        self.process = process
        self.parentIsIDE = parentIsIDE
        self.hasAttachedClient = hasAttachedClient
        self.listenPorts = listenPorts
        self.linkedGradlePid = linkedGradlePid
        self.ownershipUnknown = ownershipUnknown
        self.attachedClientDescription = attachedClientDescription
    }
}

/// Everything the RuleEngine needs about one poll. `timestamp` is the engine's
/// clock — tests drive time by fabricating timestamps.
struct PollSnapshot: Codable {
    var timestamp: Date
    var daemons: [DaemonObservation]
    /// True iff any configured owner app (IDE) is currently running.
    var ideRunning: Bool
}

// MARK: - Ownership predicate (spec §5.1)

/// Shared by RuleEngine (per-poll evaluation) and Killer (kill-time
/// re-validation, spec §7). Pure function of one snapshot. `ownershipUnknown`
/// handling is NOT done here — callers decide (engine keeps previous verdict,
/// killer fails safe toward "owned").
enum Ownership {
    static func isOwned(_ d: DaemonObservation, in snapshot: PollSnapshot) -> Bool {
        if d.parentIsIDE || d.hasAttachedClient { return true }
        // O4 — a Kotlin daemon inherits the verdict of the Gradle daemon it
        // serves (the gradle's own O1/O2, not another transitive hop).
        if d.process.kind == .kotlin, let gpid = d.linkedGradlePid,
           let gradle = snapshot.daemons.first(where: { $0.process.pid == gpid && $0.process.kind == .gradle }) {
            return gradle.parentIsIDE || gradle.hasAttachedClient
        }
        return false
    }
}

// MARK: - Rules (spec §5.2)

enum Rule: String, Codable, CaseIterable {
    case ownerlessNoIDE      // R1
    case ownerlessWithIDE    // R2
    case idleTooLong         // R3
    case runaway             // R4

    var shortName: String {
        switch self {
        case .ownerlessNoIDE: return "R1"
        case .ownerlessWithIDE: return "R2"
        case .idleTooLong: return "R3"
        case .runaway: return "R4"
        }
    }
}

// MARK: - RuleEngine output

struct FlaggedProcess: Codable {
    let process: DaemonProcess
    let rule: Rule
    /// When this daemon first started matching the rule (start of the
    /// hysteresis window that ultimately fired).
    let candidateSince: Date
    /// Seconds with ~zero CPU delta (for notification copy), where applicable.
    let idleSeconds: Double?
    /// Sustained CPU percent of one core (R4 copy), where applicable.
    let cpuPercent: Double?
}

enum NotificationCategory: String, Codable {
    case orphanFound = "ORPHAN_FOUND"
    case runawayFound = "RUNAWAY_FOUND"
}

/// One notification to post: all newly-flagged (or re-notify-due) processes of a
/// category in this poll cycle, batched (spec §6).
struct NotificationBatch {
    let category: NotificationCategory
    let processes: [FlaggedProcess]
    /// Stable per process-set so re-notifications replace, not pile up.
    let identifier: String
}

struct RuleEngineOutput {
    /// 0–2 batches per poll (orphans and runaways batch separately).
    var notifications: [NotificationBatch] = []
    /// Processes to kill immediately without notifying (auto-kill policy, §8).
    var autoKill: [FlaggedProcess] = []
}

// MARK: - Per-process state (state.json + --status, spec §11)

struct ProcessStateRecord: Codable {
    var identity: ProcessIdentity
    var kind: DaemonKind
    var displayName: String
    /// "healthy" | "flagged(R1)" | "snoozed until <ISO8601>" | "ignored" | "killing"
    var stateDescription: String
    /// Rule rawValue → consecutive matching samples so far.
    var ruleCounters: [String: Int]
    var owned: Bool
    var flaggedRule: Rule?
    var snoozedUntil: Date?
    var lastSeen: Date
    var rssBytes: UInt64
}

// MARK: - Kill policy (SPEC-UI §6)

/// Whether a kill batch honors the kill-time ownership re-check (v1 default) or
/// bypasses ONLY that one check on explicit user intent. Identity, argv, and
/// per-phase start-time re-verification are non-negotiable under both policies —
/// a recycled PID is unkillable regardless. The parameter has NO default so every
/// call site states its policy; no agent path may ever construct `.userForced`.
enum KillPolicy: Equatable {
    case respectOwnership   // v1 behaviour — the ONLY policy the agent may use.
    case userForced         // UI-only, behind an explicit confirmation dialog.
}

// MARK: - Kill reporting (spec §7)

enum KillMethod: String, Codable {
    case markerFile   // Kotlin alive-marker deleted, daemon exited on its own
    case sigterm
    case sigkill
}

enum KillOutcome {
    case killed(KillMethod)
    case skippedNowOwned      // re-validation: picked up a client/owner since flagging
    case skippedGone          // already dead or PID reused
    case failed(String)
}

struct KillReport {
    let target: FlaggedProcess
    let outcome: KillOutcome
    /// RSS at kill time, summed for the "freed ~X GB" confirmation.
    var freedBytes: UInt64 {
        if case .killed = outcome { return target.process.rssBytes }
        return 0
    }
}

// MARK: - Logging

enum LogLevel: Int, Codable, Comparable {
    case debug = 0, info = 1, warn = 2, error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }

    init?(configString: String) {
        switch configString.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        case "warn", "warning": self = .warn
        case "error": self = .error
        default: return nil
        }
    }
}

protocol DSLogger {
    func log(_ level: LogLevel, _ message: String)
}

extension DSLogger {
    func debug(_ message: String) { log(.debug, message) }
    func info(_ message: String) { log(.info, message) }
    func warn(_ message: String) { log(.warn, message) }
    func error(_ message: String) { log(.error, message) }
}

// MARK: - Formatting helpers (notifications + --status)

enum Format {
    /// "7.2 GB", "830 MB", "53 MB"
    static func bytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    /// "1h32m", "22 min", "45 s"
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m"
    }
}
