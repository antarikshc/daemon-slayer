import XCTest
@testable import daemonslayer

/// V2-M4 (SPEC-UI §9): the whole-file config writer. Proves the canonical template is
/// shared with the first-run default writer (cannot drift), that a settings/banner
/// save preserves every hidden hand-tuned key bit-for-bit while flipping ONLY the
/// three exposed keys, that the written text parses through ConfigStore's JSONC
/// reader, and that range-invalid saves are refused with the file untouched.
final class ConfigWriterTests: XCTestCase {
    private var tmpDir: URL!
    private let logger = SilentWriterLogger()

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dswriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }
    private func path() -> String { tmpDir.appendingPathComponent("config.json").path }

    /// A config with EVERY key hand-tuned to a non-default value (the round-trip oracle).
    private func handTunedConfig() -> Config {
        var c = Config()
        c.pollIntervalSeconds = 17
        c.idlePollIntervalSeconds = 240
        c.rules = RulesConfig(
            ownerlessNoIDE: RuleConfig(enabled: false, thresholdMinutes: 5),
            ownerlessWithIDE: RuleConfig(enabled: false, thresholdMinutes: 33),
            idleTooLong: RuleConfig(enabled: false, thresholdMinutes: 90),
            runaway: RuleConfig(enabled: false, thresholdMinutes: 7, cpuThresholdPercent: 88))
        c.idleCpuSecondsPerPoll = 1.25
        c.snoozeMinutes = 42
        c.killEscalationSeconds = 6
        c.autoKill = AutoKillConfig(enabled: true, rules: ["ownerlessNoIDE", "runaway"])
        c.ownerAppBundlePrefixes = ["com.example.weirdide", "org.custom.thing"]
        c.logLevel = "debug"
        c.paused = true
        return c
    }

    // MARK: - Canonical template shared with first-run (no drift)

    func testDefaultConfigTextIsTheWriterSerialization() {
        // The single-source-of-truth guarantee: ConfigStore's first-run text IS
        // ConfigWriter.serialize(.default). They cannot drift.
        XCTAssertEqual(ConfigStore.defaultConfigText, ConfigWriter.serialize(.default))
    }

    func testSerializeDefaultDecodesToDefaultAndHasStockComments() {
        let text = ConfigWriter.serialize(.default)
        // Decodes identically through the real reader.
        let decoded = ConfigWriter.decodeThroughStore(text)
        XCTAssertEqual(decoded, .default)
        // Contains the stock section comments + every rule name (the documentation).
        XCTAssertTrue(text.contains("//"), "canonical text must keep the stock comments")
        for rule in ["ownerlessNoIDE", "ownerlessWithIDE", "idleTooLong", "runaway"] {
            XCTAssertTrue(text.contains(rule), "canonical text must mention rule \(rule)")
        }
        XCTAssertTrue(text.contains("paused"), "canonical text must document the v2 paused key")
    }

    func testSerializeDefaultParsesThroughConfigStoreLoad() {
        // Write serialize(.default) to disk and load it through the REAL ConfigStore.
        let p = path()
        try! Data(ConfigWriter.serialize(.default).utf8).write(to: URL(fileURLWithPath: p))
        let loaded = ConfigStore(path: p, logger: logger).load()
        XCTAssertEqual(loaded, .default)
    }

    // MARK: - Round-trip: only the three exposed keys change, everything else preserved

    func testMutateFlipsAutoKillEnabledKeepsRules() {
        let base = handTunedConfig()   // autoKill.rules = [ownerlessNoIDE, runaway], enabled = true
        let off = ConfigWriter.mutated(base, autoKillEnabled: false)
        XCTAssertFalse(off.autoKill.enabled)
        XCTAssertEqual(off.autoKill.rules, base.autoKill.rules, "autoKill.rules must NEVER be touched")
    }

    func testFullRoundTripPreservesEveryHiddenKey() {
        // Start from a fully hand-tuned config; flip ONLY the three exposed keys via the
        // writer; re-serialize; decode; assert every other field is bit-for-bit equal.
        let base = handTunedConfig()
        let edited = ConfigWriter.mutated(base, autoKillEnabled: false, snoozeMinutes: 99, paused: false)
        let text = ConfigWriter.serialize(edited)
        let back = ConfigWriter.decodeThroughStore(text)
        let r = try! XCTUnwrap(back)

        // The three exposed keys took the new values.
        XCTAssertEqual(r.autoKill.enabled, false)
        XCTAssertEqual(r.snoozeMinutes, 99)
        XCTAssertEqual(r.paused, false)

        // EVERY hidden key preserved bit-for-bit from the hand-tuned base.
        XCTAssertEqual(r.pollIntervalSeconds, base.pollIntervalSeconds)
        XCTAssertEqual(r.idlePollIntervalSeconds, base.idlePollIntervalSeconds)
        XCTAssertEqual(r.rules, base.rules)
        XCTAssertEqual(r.idleCpuSecondsPerPoll, base.idleCpuSecondsPerPoll)
        XCTAssertEqual(r.killEscalationSeconds, base.killEscalationSeconds)
        XCTAssertEqual(r.autoKill.rules, base.autoKill.rules)
        XCTAssertEqual(r.ownerAppBundlePrefixes, base.ownerAppBundlePrefixes)
        XCTAssertEqual(r.logLevel, base.logLevel)
        // And the whole struct equals base with exactly the three edits applied.
        XCTAssertEqual(r, ConfigWriter.mutated(base, autoKillEnabled: false, snoozeMinutes: 99, paused: false))
    }

    func testHandTunedConfigRoundTripsThroughRealConfigStore() {
        // The written text must parse through ConfigStore's JSONC reader to the same
        // struct (the canonical serializer is valid JSONC, not just valid JSON).
        let cfg = handTunedConfig()
        let p = path()
        XCTAssertEqual(try? ConfigWriter.save(cfg, to: p).get() != nil ? true : nil, true)
        let loaded = ConfigStore(path: p, logger: logger).load()
        XCTAssertEqual(loaded, cfg)
    }

    func testPausedFlipPreservesEverythingElse() {
        // Banner pause path: mutate ONLY paused; nothing else moves.
        let base = handTunedConfig()
        let paused = ConfigWriter.mutated(base, paused: false)   // base.paused was true
        XCTAssertEqual(paused, { var c = base; c.paused = false; return c }())
    }

    // MARK: - Save: atomic write + validation refusal

    func testSaveWritesAtomicNoTmpLeft() throws {
        let p = path()
        XCTAssertNoThrow(try ConfigWriter.save(handTunedConfig(), to: p).get())
        XCTAssertTrue(FileManager.default.fileExists(atPath: p))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p + ".tmp"), "no stray .tmp")
    }

    func testInvalidSnoozeRefusedAndFileUntouched() throws {
        let p = path()
        // Seed a known-good file first.
        try ConfigWriter.save(handTunedConfig(), to: p).get()
        let before = try String(contentsOfFile: p, encoding: .utf8)

        // Snooze = 0 → invalidValue, file untouched.
        let bad = ConfigWriter.mutated(handTunedConfig(), snoozeMinutes: 0)
        let result = ConfigWriter.save(bad, to: p)
        guard case .failure(let e) = result else { return XCTFail("save must refuse snooze 0") }
        XCTAssertEqual(e, .invalidValue("snoozeMinutes must be ≥ 1"))

        let after = try String(contentsOfFile: p, encoding: .utf8)
        XCTAssertEqual(before, after, "a refused save must leave the file byte-for-byte untouched")
    }

    func testNegativeSnoozeRefused() {
        let bad = ConfigWriter.mutated(.default, snoozeMinutes: -5)
        guard case .failure = ConfigWriter.validate(bad) else {
            return XCTFail("negative snooze must fail validation")
        }
    }

    func testValidatePassesForSaneSnooze() {
        let ok = ConfigWriter.mutated(.default, snoozeMinutes: 1)
        guard case .success = ConfigWriter.validate(ok) else {
            return XCTFail("snooze == 1 (the floor) must validate")
        }
    }

    // MARK: - Fractional values survive (not just integers)

    func testFractionalIdleCpuSurvivesSerialization() {
        var c = Config()
        c.idleCpuSecondsPerPoll = 0.25   // a genuine fraction must not be truncated
        let back = try! XCTUnwrap(ConfigWriter.decodeThroughStore(ConfigWriter.serialize(c)))
        XCTAssertEqual(back.idleCpuSecondsPerPoll, 0.25)
    }
}

/// No-op logger for the writer tests.
private final class SilentWriterLogger: DSLogger {
    func log(_ level: LogLevel, _ message: String) {}
}
