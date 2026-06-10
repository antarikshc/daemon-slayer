import Foundation
import os

/// os_log + rotating plaintext file logger (spec §9.2, §14).
///
/// Line format: `2026-06-10T22:31:04+0530 [INFO] message` — ISO8601 with timezone,
/// fixed-format via ISO8601DateFormatter (never DateFormatter with a user locale,
/// so logs are stable regardless of who's reading them).
///
/// Rotation (spec §14): when the file exceeds 5 MB on a write, rename it to
/// "<path>.1" (replacing any existing .1) and start fresh. Keep 2 files total.
/// All sinks are serialized on a private queue for thread-safety.
final class FileLogger: DSLogger {
    /// Spec §14: rotate at 5 MB.
    private static let maxFileBytes: UInt64 = 5 * 1_024 * 1_024

    private let path: String?
    private let queue = DispatchQueue(label: "dev.antariksh.daemonslayer.logger")
    private let osLog = OSLog(subsystem: "dev.antariksh.daemonslayer", category: "agent")
    private let dateFormatter: ISO8601DateFormatter

    /// File sink. nil when `path` is nil (writes go to stderr instead — CLI/integration mode).
    private var handle: FileHandle?

    private var _minLevel: LogLevel
    /// Hot-reloaded from config (spec §10 logLevel); applies to both sinks.
    var minLevel: LogLevel {
        get { queue.sync { _minLevel } }
        set { queue.sync { _minLevel = newValue } }
    }

    init(path: String?, minLevel: LogLevel) {
        self.path = path
        self._minLevel = minLevel

        let fmt = ISO8601DateFormatter()
        // withTimeZone => "+0530" suffix; without colon to match the spec's sample line.
        fmt.formatOptions = [.withInternetDateTime]
        // Local time, not the default UTC, so agent-log lines line up with --status
        // output (which prints in local time).
        fmt.timeZone = TimeZone.current
        self.dateFormatter = fmt

        if let path { handle = FileLogger.openHandle(at: path) }
    }

    deinit { try? handle?.close() }

    func log(_ level: LogLevel, _ message: String) {
        queue.async { [self] in
            guard level >= _minLevel else { return }

            // os_log mirror (skipped for stderr-only mode; harmless to keep anyway).
            os_log("%{public}@", log: osLog, type: FileLogger.osType(for: level), message)

            let line = "\(dateFormatter.string(from: Date())) [\(level.label)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            guard path != nil, let h = handle else {
                FileHandle.standardError.write(data)
                return
            }
            h.write(data)
            rotateIfNeeded()
        }
    }

    // MARK: - File handling (queue-confined)

    private static func osType(for level: LogLevel) -> OSLogType {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warn: return .default   // os_log has no "warn"; .default is the closest tier.
        case .error: return .error
        }
    }

    private static func openHandle(at path: String) -> FileHandle? {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        h.seekToEndOfFile()
        return h
    }

    /// Checked on every write (spec §14). Renames "<path>" → "<path>.1" and reopens.
    private func rotateIfNeeded() {
        guard let path, let h = handle else { return }
        let size = (try? h.offset()) ?? 0
        guard size > FileLogger.maxFileBytes else { return }

        try? h.close()
        handle = nil

        let fm = FileManager.default
        let rotated = path + ".1"
        try? fm.removeItem(atPath: rotated)         // keep only one prior file (.1)
        try? fm.moveItem(atPath: path, toPath: rotated)

        handle = FileLogger.openHandle(at: path)    // reopen fresh, empty file
    }
}
