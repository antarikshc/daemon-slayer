import XCTest
@testable import daemonslayer

/// Covers ConfigStore load/reload semantics, StateStore round-trip + atomicity, and
/// FileLogger rotation. Watching is NOT tested via DispatchSource + sleeps (flaky);
/// reload semantics are driven through `reloadNow()` after rewriting the file.
final class ConfigStoreTests: XCTestCase {
    private var tmpDir: URL!
    private let logger = SilentLogger()

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dstest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    private func configPath() -> String {
        tmpDir.appendingPathComponent("config.json").path
    }

    private func write(_ text: String, to path: String) {
        try! text.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - load()

    func testMissingFileWritesCommentedDefaultAndReturnsDefaults() {
        let path = configPath()
        let store = ConfigStore(path: path, logger: logger)
        let cfg = store.load()

        XCTAssertEqual(cfg, Config.default)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "default config file should be written")

        let written = try! String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        XCTAssertTrue(written.contains("//"), "written default should contain // comments")
        // Documents each of the four rule names.
        for rule in ["ownerlessNoIDE", "ownerlessWithIDE", "idleTooLong", "runaway"] {
            XCTAssertTrue(written.contains(rule), "default should mention rule \(rule)")
        }
    }

    func testWrittenDefaultRoundTripsThroughLoad() {
        let path = configPath()
        // First run writes the commented default.
        _ = ConfigStore(path: path, logger: logger).load()
        // A fresh store loading that same on-disk file must parse to defaults.
        let reloaded = ConfigStore(path: path, logger: logger).load()
        XCTAssertEqual(reloaded, Config.default)
    }

    func testPartialJSONAppliesOnlyThatKey() {
        let path = configPath()
        write(#"{ "pollIntervalSeconds": 7 }"#, to: path)
        let cfg = ConfigStore(path: path, logger: logger).load()

        XCTAssertEqual(cfg.pollIntervalSeconds, 7)
        // Everything else stays default.
        XCTAssertEqual(cfg.idlePollIntervalSeconds, Config.default.idlePollIntervalSeconds)
        XCTAssertEqual(cfg.rules, Config.default.rules)
        XCTAssertEqual(cfg.snoozeMinutes, Config.default.snoozeMinutes)
        XCTAssertEqual(cfg.ownerAppBundlePrefixes, Config.default.ownerAppBundlePrefixes)
    }

    func testCommentLinesAreStripped() {
        let path = configPath()
        write(
            """
            {
              // a leading comment line
              "pollIntervalSeconds": 45,
                // indented comment line
              "snoozeMinutes": 5
            }
            """,
            to: path
        )
        let cfg = ConfigStore(path: path, logger: logger).load()
        XCTAssertEqual(cfg.pollIntervalSeconds, 45)
        XCTAssertEqual(cfg.snoozeMinutes, 5)
    }

    func testCommentStrippingHelperLeavesTrailingCommentsAlone() {
        // Whole-line comments removed; trailing same-line text untouched (string-safety).
        let input = "// gone\nkeep // trailing stays\n  // also gone"
        XCTAssertEqual(ConfigStore.stripCommentLines(input), "\nkeep // trailing stays\n")
    }

    func testInvalidJSONReturnsDefaultsOnFirstLoad() {
        let path = configPath()
        write("{ this is not json", to: path)
        let cfg = ConfigStore(path: path, logger: logger).load()
        XCTAssertEqual(cfg, Config.default)
    }

    func testPollIntervalClampedToAtLeastOne() {
        let path = configPath()
        write(#"{ "pollIntervalSeconds": 0 }"#, to: path)
        let cfg = ConfigStore(path: path, logger: logger).load()
        XCTAssertEqual(cfg.pollIntervalSeconds, 1)
    }

    func testUnknownKeysIgnored() {
        let path = configPath()
        write(#"{ "pollIntervalSeconds": 12, "totallyMadeUpKey": 99, "nested": { "x": 1 } }"#, to: path)
        let cfg = ConfigStore(path: path, logger: logger).load()
        XCTAssertEqual(cfg.pollIntervalSeconds, 12)
        XCTAssertEqual(cfg.snoozeMinutes, Config.default.snoozeMinutes)
    }

    // MARK: - reloadNow() semantics

    func testReloadNowAdoptsChangedConfigAndFiresOnChange() {
        let path = configPath()
        let store = ConfigStore(path: path, logger: logger)
        _ = store.load() // writes default

        var changes: [Config] = []
        store.startWatching { changes.append($0) }

        write(#"{ "pollIntervalSeconds": 99 }"#, to: path)
        store.reloadNow()

        XCTAssertEqual(store.current.pollIntervalSeconds, 99)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.pollIntervalSeconds, 99)

        store.stopWatching()
    }

    func testReloadNowDoesNotFireWhenEffectiveConfigUnchanged() {
        let path = configPath()
        let store = ConfigStore(path: path, logger: logger)
        _ = store.load()

        var changeCount = 0
        store.startWatching { _ in changeCount += 1 }

        // Rewrite with a comment added but the same effective values.
        write("// just a comment\n" + ConfigStore.defaultConfigText, to: path)
        store.reloadNow()

        XCTAssertEqual(changeCount, 0, "onChange must not fire when the effective config is identical")
        store.stopWatching()
    }

    func testReloadNowKeepsLastGoodConfigAndFiresInvalidOnce() {
        let path = configPath()
        let store = ConfigStore(path: path, logger: logger)
        write(#"{ "pollIntervalSeconds": 50 }"#, to: path)
        _ = store.load()
        XCTAssertEqual(store.current.pollIntervalSeconds, 50)

        var invalidMessages: [String] = []
        store.onInvalidConfig = { invalidMessages.append($0) }
        store.startWatching { _ in }

        // Break the file.
        write("{ broken", to: path)
        store.reloadNow()
        store.reloadNow() // same bad content → must NOT re-fire

        XCTAssertEqual(store.current.pollIntervalSeconds, 50, "should keep last good config")
        XCTAssertEqual(invalidMessages.count, 1, "onInvalidConfig fires once per distinct bad state")

        // A different bad state fires again.
        write("{ also broken differently", to: path)
        store.reloadNow()
        XCTAssertEqual(invalidMessages.count, 2)

        store.stopWatching()
    }

    // MARK: - StateStore round-trip + atomicity

    func testStateSnapshotRoundTripAndNoTmpLeft() throws {
        let statePath = tmpDir.appendingPathComponent("state.json").path
        let store = StateStore(path: statePath, logger: logger)

        let record = ProcessStateRecord(
            identity: ProcessIdentity(pid: 4242, startTimeMicros: 1_700_000_000_000_000),
            kind: .gradle,
            displayName: "Gradle 8.13 (myproject)",
            stateDescription: "flagged(R1)",
            ruleCounters: ["ownerlessNoIDE": 3],
            owned: false,
            flaggedRule: .ownerlessNoIDE,
            snoozedUntil: nil,
            lastSeen: Date(timeIntervalSince1970: 1_700_000_100),
            rssBytes: 87 * 1_048_576
        )
        let snapshot = AgentStateSnapshot(
            writtenAt: Date(timeIntervalSince1970: 1_700_000_200),
            agentPid: 555,
            lastPollAt: Date(timeIntervalSince1970: 1_700_000_150),
            ideRunning: true,
            notificationsAuthorized: nil,
            configPath: configPath(),
            records: [record]
        )

        store.write(snapshot)
        // Atomicity: no stray .tmp left behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: statePath + ".tmp"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: statePath))

        let readBack = store.read()
        XCTAssertNotNil(readBack)
        XCTAssertEqual(readBack?.agentPid, 555)
        XCTAssertEqual(readBack?.ideRunning, true)
        // notificationsAuthorized was nil → must survive the round-trip as nil.
        let auth: Bool? = readBack.flatMap { $0.notificationsAuthorized }
        XCTAssertNil(auth)
        XCTAssertEqual(readBack?.records.count, 1)
        XCTAssertEqual(readBack?.records.first?.identity.pid, 4242)
        XCTAssertEqual(readBack?.records.first?.flaggedRule, .ownerlessNoIDE)
        let writtenAt = try XCTUnwrap(readBack).writtenAt.timeIntervalSince1970
        XCTAssertEqual(writtenAt, snapshot.writtenAt.timeIntervalSince1970, accuracy: 1)
    }

    func testStateStoreMissingFileReturnsNil() {
        let store = StateStore(path: tmpDir.appendingPathComponent("absent.json").path, logger: logger)
        XCTAssertNil(store.read())
    }

    func testStateStoreCorruptFileReturnsNil() {
        let statePath = tmpDir.appendingPathComponent("corrupt.json").path
        write("not json at all", to: statePath)
        let store = StateStore(path: statePath, logger: logger)
        XCTAssertNil(store.read())
    }

    // MARK: - FileLogger rotation (spec §14)

    func testFileLoggerRotatesPastFiveMegabytesWithLevelFilter() {
        let logPath = tmpDir.appendingPathComponent("daemonslayer.log").path
        let logger = FileLogger(path: logPath, minLevel: .info)

        // debug lines must be filtered out (below minLevel) and never hit disk.
        for _ in 0..<100 { logger.debug("this debug line should be dropped entirely") }

        // ~6 MB of info lines forces at least one rotation.
        let chunk = String(repeating: "x", count: 1_000)
        for _ in 0..<6_500 { logger.info(chunk) }

        // Flush the serial queue by enqueuing a barrier read.
        let drained = expectation(description: "logger queue drained")
        logger.info("final marker")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        let rotated = logPath + ".1"
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated), "rotated .1 file should exist")

        let mainSize = fileSize(logPath)
        XCTAssertLessThanOrEqual(mainSize, 5 * 1_024 * 1_024,
                                 "active log file should be reset below the 5 MB rotation budget")

        // No DEBUG lines should appear in either file.
        let mainText = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        XCTAssertFalse(mainText.contains("[DEBUG]"), "debug lines below minLevel must be filtered")
    }

    private func fileSize(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? UInt64) ?? 0
    }
}

/// No-op logger so tests don't spew to disk/os_log.
private final class SilentLogger: DSLogger {
    func log(_ level: LogLevel, _ message: String) {}
}
