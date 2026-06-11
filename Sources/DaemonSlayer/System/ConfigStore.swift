import Foundation

/// Loads, watches, and hot-reloads the JSONC-lite config (spec §10).
///
/// "JSONC-lite": whole-line `//` comments are stripped before decoding. Trailing
/// same-line comments are deliberately NOT stripped — doing so safely would require
/// a real tokenizer (a `//` inside a string value would be mangled), and the spec's
/// default file uses only whole-line and trailing comments on simple lines anyway.
final class ConfigStore {
    let path: String
    private let logger: DSLogger

    private let queue = DispatchQueue(label: "dev.antariksh.daemonslayer.configstore")

    private var _current: Config = .default
    /// The last successfully-parsed config. Reads are queue-confined for safety.
    private(set) var current: Config {
        get { queue.sync { _current } }
        set { queue.sync { _current = newValue } }
    }

    /// Fired (on the internal queue) when a reload produces a config != the current one.
    private var onChange: ((Config) -> Void)?
    /// Fired at most once per distinct bad file state (spec §10: one-time error).
    var onInvalidConfig: ((String) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var debounceWork: DispatchWorkItem?
    /// Hash of the last invalid content we already complained about; avoids repeat
    /// notifications until the file actually changes again (spec §10).
    private var lastBadContentHash: Int?

    /// ~250 ms debounce so an editor's multi-step atomic save fires one reload.
    private static let debounceMillis = 250
    /// Re-open retry when the path is momentarily absent mid-atomic-rename.
    private static let reopenRetryMillis = 80

    init(path: String, logger: DSLogger) {
        self.path = path
        self.logger = logger
    }

    deinit { stopWatching() }

    // MARK: - Initial load

    /// Missing file → write a commented default config (spec §10) + return defaults.
    /// Unparseable → defaults + warning.
    @discardableResult
    func load() -> Config {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            writeDefaultConfig()
            current = .default
            return .default
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            logger.warn("ConfigStore: could not read \(path); using defaults")
            current = .default
            return .default
        }
        switch Self.decode(data) {
        case .success(let config):
            current = config
            return config
        case .failure(let message):
            logger.warn("ConfigStore: invalid config at \(path) (\(message)); using defaults")
            current = .default
            return .default
        }
    }

    // MARK: - Watching (spec §10 hot reload, §9.2)

    /// Hot-reload via DispatchSource file watch. `onChange` fires only when the
    /// effective Config actually changed, and always on the internal serial queue
    /// (the caller is expected to re-dispatch).
    func startWatching(onChange: @escaping (Config) -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            armSource()
        }
    }

    func stopWatching() {
        queue.sync { [self] in
            debounceWork?.cancel()
            debounceWork = nil
            cancelSource()
            onChange = nil
        }
    }

    /// Parse the file now and apply reload semantics. Used by the watcher AND by
    /// tests (drives reload deterministically without sleeping on DispatchSource).
    /// MUST be called on `queue` by the watcher; tests call it directly (sync hop).
    func reloadNow() {
        queue.sync { [self] in performReload() }
    }

    // MARK: - Internals (queue-confined)

    private func performReload() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            // File momentarily gone (atomic rename in flight) — keep last good config.
            return
        }
        switch Self.decode(data) {
        case .success(let config):
            lastBadContentHash = nil
            if config != _current {
                _current = config
                logger.info("ConfigStore: reloaded config from \(path)")
                onChange?(config)
            }
        case .failure(let message):
            // Keep last good config; warn always, but only notify once per distinct
            // bad content (spec §10).
            logger.warn("ConfigStore: invalid config on reload (\(message)); keeping last good config")
            let hash = String(data: data, encoding: .utf8)?.hashValue ?? data.count
            if lastBadContentHash != hash {
                lastBadContentHash = hash
                onInvalidConfig?(message)
            }
        }
    }

    /// (Re)create the DispatchSource on a fresh O_EVTONLY fd. Editors save atomically
    /// (write tmp + rename), so a .rename/.delete means our fd points at the old inode —
    /// we close, re-open the path (with a short retry if absent), and re-arm.
    private func armSource() {
        cancelSource()

        let fd = open(path, O_EVTONLY)
        if fd < 0 {
            // File may be absent (e.g. just deleted). Retry shortly, then give up
            // until the next event re-arm naturally; watchers self-heal on save.
            queue.asyncAfter(deadline: .now() + .milliseconds(Self.reopenRetryMillis)) { [self] in
                if open(path, O_EVTONLY) >= 0 { armSource() }
            }
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Inode swapped out from under us — re-open the path and re-arm.
                self.armSource()
                self.scheduleReload()
            } else {
                self.scheduleReload()
            }
        }
        src.setCancelHandler { close(fd) }
        watchedFD = fd
        source = src
        src.resume()
    }

    private func cancelSource() {
        source?.cancel()   // cancel handler closes the fd
        source = nil
        watchedFD = -1
    }

    /// Debounce coalesces an editor's burst of events into one reload (~250 ms).
    private func scheduleReload() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performReload() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(Self.debounceMillis), execute: work)
    }

    // MARK: - Decoding (JSONC-lite)

    private enum DecodeResult { case success(Config); case failure(String) }

    /// Strip whole-line `//` comments, then decode. Config's own tolerant decoder
    /// handles missing keys, unknown keys, and clamps (see Core/Config.swift).
    private static func decode(_ data: Data) -> DecodeResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure("not valid UTF-8")
        }
        let stripped = stripCommentLines(text)
        guard let jsonData = stripped.data(using: .utf8) else {
            return .failure("re-encode failed")
        }
        do {
            let config = try JSONDecoder().decode(Config.self, from: jsonData)
            return .success(config)
        } catch {
            return .failure("\(error)")
        }
    }

    /// Blanks lines whose first non-whitespace characters are "//" (replacing them
    /// with empty lines, preserving line structure). Does NOT touch trailing
    /// same-line comments (string-safety, see type doc).
    static func stripCommentLines(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
            .joined(separator: "\n")
    }

    // MARK: - Default config (spec §10)

    private func writeDefaultConfig() {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        do {
            try Self.defaultConfigText.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
            logger.info("ConfigStore: wrote default config to \(path)")
        } catch {
            logger.warn("ConfigStore: failed to write default config to \(path): \(error)")
        }
    }

    /// The commented default written on first run (spec §10). Key names + defaults
    /// match the spec schema EXACTLY; whole-line `//` comments document each field
    /// and the four rule names. This text must round-trip through `load()`.
    static let defaultConfigText = """
    {
      // How often to scan the process table, in seconds (default 30).
      "pollIntervalSeconds": 30,
      // Slower cadence used when no daemons are present (default 120).
      "idlePollIntervalSeconds": 120,
      "rules": {
        // R1 — ownerless daemon with no IDE running at all (the headline leak).
        "ownerlessNoIDE":   { "enabled": true, "thresholdMinutes": 2 },
        // R2 — ownerless daemon while an IDE is running (CLI-spawned leak).
        "ownerlessWithIDE": { "enabled": true, "thresholdMinutes": 15 },
        // R3 — owned but idle (≈ zero CPU) for the whole window.
        "idleTooLong":      { "enabled": true, "thresholdMinutes": 120 },
        // R4 — runaway: no client attached but burning CPU above the threshold.
        "runaway":          { "enabled": true, "thresholdMinutes": 2,
                              "cpuThresholdPercent": 50 }
      },
      // CPU-seconds per poll below which a daemon counts as "idle" (default 0.5).
      "idleCpuSecondsPerPoll": 0.5,
      // Minutes to suppress re-notification after Snooze / no response (default 60).
      "snoozeMinutes": 60,
      // Seconds to wait between kill escalation steps: marker → TERM → KILL (default 10).
      "killEscalationSeconds": 10,
      // Opt-in auto-kill: only the listed rules kill without notifying first.
      "autoKill": { "enabled": false, "rules": ["ownerlessNoIDE"] },
      // Bundle-ID prefixes of apps that count as an IDE / owner.
      "ownerAppBundlePrefixes": [
        "com.google.android.studio",
        "com.jetbrains.intellij"
      ],
      // Log verbosity: debug | info | warn | error.
      "logLevel": "info",
      // v2: when true the agent suspends all watching/notifying/killing (the v2 UI
      // toggles this; it stays paused until flipped back).
      "paused": false
    }
    """
}
