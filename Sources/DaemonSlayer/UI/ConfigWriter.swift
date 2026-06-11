import Foundation

/// Serializes a `Config` to canonical JSONC and owns the settings/banner write path
/// (SPEC-UI §9). PURE + testable: `serialize` is a deterministic struct→text function
/// and `mutated` produces a new `Config` from the form/banner edits — no I/O. The
/// thin `save(...)` wrapper layers on validation + the atomic tmp+rename write.
///
/// **Single source of truth for the canonical template.** `ConfigStore.defaultConfigText`
/// (the first-run default file) is itself `serialize(.default)`, so the first-run
/// writer and every settings save share ONE template — they cannot drift. The stock
/// `//` section comments live here, in `serialize`.
///
/// **Whole-file write model (SPEC-UI §9):** the form reads the latest loaded `Config`
/// (defaults merged), mutates ONLY the three exposed keys (`autoKill.enabled`,
/// `snoozeMinutes`, `paused`), then re-serializes the ENTIRE struct. Every hidden key
/// (pollIntervalSeconds, rule thresholds, ownerAppBundlePrefixes, autoKill.rules, …)
/// is emitted from the loaded struct, so a save never resets a hand-tuned value to
/// default. Hand-edited comments are clobbered (accepted, grilling decision).
enum ConfigWriter {

    // MARK: - Range sanity (SPEC-UI §9 step 3)

    /// Snooze must be ≥ 1 minute (the form's stepper clamps; this is the hard floor
    /// that refuses a torn/hostile value). Matches the Config decoder's intent while
    /// being stricter for a human-facing control than the decoder's 0.05 melt-guard.
    static let minSnoozeMinutes: Double = 1

    enum WriteError: Error, Equatable {
        /// A mutated value failed range sanity (e.g. snooze ≤ 0).
        case invalidValue(String)
        /// The serialized text did not decode back to an equal Config (round-trip).
        case roundTripMismatch
        /// The atomic write itself failed (I/O).
        case writeFailed(String)
    }

    // MARK: - Mutation (pure)

    /// Apply the form/banner edits to a loaded config, touching ONLY the three exposed
    /// keys. `autoKill.rules` and every other field are carried through untouched.
    /// `nil` arguments leave that key as-is (the banner only sets `paused`; the form
    /// only sets the two settings) — so a banner toggle never disturbs an unsaved
    /// settings edit and vice versa, both serializing from the same latest struct.
    static func mutated(_ base: Config,
                        autoKillEnabled: Bool? = nil,
                        snoozeMinutes: Double? = nil,
                        paused: Bool? = nil) -> Config {
        var c = base
        if let autoKillEnabled { c.autoKill.enabled = autoKillEnabled }   // NEVER touches autoKill.rules
        if let snoozeMinutes { c.snoozeMinutes = snoozeMinutes }
        if let paused { c.paused = paused }
        return c
    }

    // MARK: - Validation (pure)

    /// Range sanity + decode round-trip (SPEC-UI §9 step 3). Returns the config on
    /// success so callers can serialize the validated value.
    static func validate(_ config: Config) -> Result<Config, WriteError> {
        guard config.snoozeMinutes >= minSnoozeMinutes else {
            return .failure(.invalidValue("snoozeMinutes must be ≥ \(Int(minSnoozeMinutes))"))
        }
        // Decode round-trip: serialize, strip comments exactly as ConfigStore does,
        // decode, and require equality. Catches any serializer bug before it touches
        // disk (and proves the written text parses through the real reader).
        let text = serialize(config)
        guard let decoded = decodeThroughStore(text) else {
            return .failure(.roundTripMismatch)
        }
        guard decoded == config else { return .failure(.roundTripMismatch) }
        return .success(config)
    }

    /// Decode JSONC text through the SAME path ConfigStore uses (whole-line `//`
    /// strip → tolerant Config decoder). Exposed for the round-trip check + tests.
    static func decodeThroughStore(_ text: String) -> Config? {
        let stripped = ConfigStore.stripCommentLines(text)
        guard let data = stripped.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    // MARK: - Save (validation + atomic write)

    /// Validate then atomically write `config` to `path` (tmp + rename, the StateStore
    /// pattern). Refuses to write on any validation failure — the file is untouched.
    @discardableResult
    static func save(_ config: Config, to path: String) -> Result<Void, WriteError> {
        switch validate(config) {
        case .failure(let e): return .failure(e)
        case .success(let valid):
            return atomicWrite(serialize(valid), to: path)
        }
    }

    /// tmp + rename, identical guarantees to StateStore.write: never leaves a torn
    /// file; an atomic rename means a concurrent reader sees old-or-new, never partial.
    private static func atomicWrite(_ text: String, to path: String) -> Result<Void, WriteError> {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let url = URL(fileURLWithPath: path)
        let tmpURL = URL(fileURLWithPath: path + ".tmp")
        do {
            try Data(text.utf8).write(to: tmpURL, options: .atomic)
            if fm.fileExists(atPath: path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: url)
            }
            return .success(())
        } catch {
            try? fm.removeItem(at: tmpURL)
            return .failure(.writeFailed("\(error)"))
        }
    }

    // MARK: - Canonical serializer (the ONE template, SPEC-UI §9 / §10)

    /// Render the ENTIRE config as canonical JSONC with the stock section comments.
    /// Every value comes from `config` (hidden keys round-trip untouched); the comment
    /// text is fixed. `serialize(.default)` IS the first-run default file.
    static func serialize(_ config: Config) -> String {
        let r = config.rules
        func num(_ d: Double) -> String {
            // Integer-valued doubles render without a trailing ".0" so the canonical
            // default matches the hand-written template (30, not 30.0); genuine
            // fractions (0.5) keep their decimals.
            d == d.rounded() ? String(Int(d)) : String(d)
        }
        func ruleLine(_ name: String, _ rc: RuleConfig, pad: Int) -> String {
            let key = "\"\(name)\":".padding(toLength: pad, withPad: " ", startingAt: 0)
            var body = "{ \"enabled\": \(rc.enabled), \"thresholdMinutes\": \(num(rc.thresholdMinutes))"
            if let cpu = rc.cpuThresholdPercent {
                body += ", \"cpuThresholdPercent\": \(num(cpu))"
            }
            body += " }"
            return "    \(key) \(body)"
        }
        let prefixes = config.ownerAppBundlePrefixes
            .map { "    \"\($0)\"" }
            .joined(separator: ",\n")
        let rulePad = 19   // aligns the four rule bodies (longest key + colon)

        return """
        {
          // How often to scan the process table, in seconds (default 30).
          "pollIntervalSeconds": \(num(config.pollIntervalSeconds)),
          // Slower cadence used when no daemons are present (default 120).
          "idlePollIntervalSeconds": \(num(config.idlePollIntervalSeconds)),
          "rules": {
            // R1 — ownerless daemon with no IDE running at all (the headline leak).
        \(ruleLine("ownerlessNoIDE", r.ownerlessNoIDE, pad: rulePad)),
            // R2 — ownerless daemon while an IDE is running (CLI-spawned leak).
        \(ruleLine("ownerlessWithIDE", r.ownerlessWithIDE, pad: rulePad)),
            // R3 — owned but idle (≈ zero CPU) for the whole window.
        \(ruleLine("idleTooLong", r.idleTooLong, pad: rulePad)),
            // R4 — runaway: no client attached but burning CPU above the threshold.
        \(ruleLine("runaway", r.runaway, pad: rulePad))
          },
          // CPU-seconds per poll below which a daemon counts as "idle" (default 0.5).
          "idleCpuSecondsPerPoll": \(num(config.idleCpuSecondsPerPoll)),
          // Minutes to suppress re-notification after Snooze / no response (default 60).
          "snoozeMinutes": \(num(config.snoozeMinutes)),
          // Seconds to wait between kill escalation steps: marker → TERM → KILL (default 10).
          "killEscalationSeconds": \(num(config.killEscalationSeconds)),
          // Opt-in auto-kill: only the listed rules kill without notifying first.
          "autoKill": { "enabled": \(config.autoKill.enabled), "rules": [\(config.autoKill.rules.map { "\"\($0)\"" }.joined(separator: ", "))] },
          // Bundle-ID prefixes of apps that count as an IDE / owner.
          "ownerAppBundlePrefixes": [
        \(prefixes)
          ],
          // Log verbosity: debug | info | warn | error.
          "logLevel": "\(config.logLevel)",
          // v2: when true the agent suspends all watching/notifying/killing (the v2 UI
          // toggles this; it stays paused until flipped back).
          "paused": \(config.paused)
        }
        """
    }
}
