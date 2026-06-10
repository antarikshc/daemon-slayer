import Foundation

/// The resident agent's view of the world, written after each poll (spec §11).
/// `--status` merges this with a fresh scan so a human sees both what's true now
/// and what the agent believes — divergence is itself diagnostic.
struct AgentStateSnapshot: Codable {
    var writtenAt: Date
    var agentPid: Int32
    var lastPollAt: Date
    var ideRunning: Bool
    /// nil = undetermined / process not bundled (notification auth unknowable).
    var notificationsAuthorized: Bool?
    var configPath: String
    var records: [ProcessStateRecord]
}

/// Atomic reader/writer for state.json (spec §11). The file is pretty-printed with
/// sorted keys because humans read it while debugging.
final class StateStore {
    private let path: String
    private let logger: DSLogger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(path: String, logger: DSLogger) {
        self.path = path
        self.logger = logger

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Atomic write: encode to "<path>.tmp", then replace the live file. One small
    /// write per poll (spec §11). Never leaves a partial/torn file behind.
    func write(_ snapshot: AgentStateSnapshot) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let url = URL(fileURLWithPath: path)
        let tmpURL = URL(fileURLWithPath: path + ".tmp")
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: tmpURL, options: .atomic)
            // replaceItem performs an atomic rename(2) onto the destination; if the
            // destination doesn't exist yet, fall back to a plain move.
            if fm.fileExists(atPath: path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmpURL)
            logger.warn("StateStore: failed to write \(path): \(error)")
        }
    }

    /// Missing file → nil silently (normal before the first poll). Corrupt → warn + nil.
    func read() -> AgentStateSnapshot? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try decoder.decode(AgentStateSnapshot.self, from: data)
        } catch {
            logger.warn("StateStore: corrupt state file \(path): \(error)")
            return nil
        }
    }
}
