import Foundation

// MARK: - Configuration (spec §10)
// Every field is optional in the JSON; missing fields fall back to defaults so a
// partial config file is always valid. Unknown keys are ignored.

struct RuleConfig: Codable, Equatable {
    var enabled: Bool
    var thresholdMinutes: Double
    /// R4 only: sustained CPU (percent of one core) that counts as runaway.
    var cpuThresholdPercent: Double?

    var thresholdSeconds: Double { thresholdMinutes * 60 }

    init(enabled: Bool, thresholdMinutes: Double, cpuThresholdPercent: Double? = nil) {
        self.enabled = enabled
        self.thresholdMinutes = thresholdMinutes
        self.cpuThresholdPercent = cpuThresholdPercent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        thresholdMinutes = try c.decodeIfPresent(Double.self, forKey: .thresholdMinutes) ?? 0
        cpuThresholdPercent = try c.decodeIfPresent(Double.self, forKey: .cpuThresholdPercent)
    }
}

struct RulesConfig: Codable, Equatable {
    var ownerlessNoIDE: RuleConfig
    var ownerlessWithIDE: RuleConfig
    var idleTooLong: RuleConfig
    var runaway: RuleConfig

    static let `default` = RulesConfig(
        ownerlessNoIDE: RuleConfig(enabled: true, thresholdMinutes: 2),
        ownerlessWithIDE: RuleConfig(enabled: true, thresholdMinutes: 15),
        idleTooLong: RuleConfig(enabled: true, thresholdMinutes: 120),
        runaway: RuleConfig(enabled: true, thresholdMinutes: 2, cpuThresholdPercent: 50)
    )

    init(ownerlessNoIDE: RuleConfig, ownerlessWithIDE: RuleConfig,
         idleTooLong: RuleConfig, runaway: RuleConfig) {
        self.ownerlessNoIDE = ownerlessNoIDE
        self.ownerlessWithIDE = ownerlessWithIDE
        self.idleTooLong = idleTooLong
        self.runaway = runaway
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RulesConfig.default
        ownerlessNoIDE = try c.decodeIfPresent(RuleConfig.self, forKey: .ownerlessNoIDE) ?? d.ownerlessNoIDE
        ownerlessWithIDE = try c.decodeIfPresent(RuleConfig.self, forKey: .ownerlessWithIDE) ?? d.ownerlessWithIDE
        idleTooLong = try c.decodeIfPresent(RuleConfig.self, forKey: .idleTooLong) ?? d.idleTooLong
        runaway = try c.decodeIfPresent(RuleConfig.self, forKey: .runaway) ?? d.runaway
    }

    subscript(rule: Rule) -> RuleConfig {
        switch rule {
        case .ownerlessNoIDE: return ownerlessNoIDE
        case .ownerlessWithIDE: return ownerlessWithIDE
        case .idleTooLong: return idleTooLong
        case .runaway: return runaway
        }
    }
}

struct AutoKillConfig: Codable, Equatable {
    var enabled: Bool
    /// Rule rawValues (config rule names, e.g. "ownerlessNoIDE").
    var rules: [String]

    static let `default` = AutoKillConfig(enabled: false, rules: [Rule.ownerlessNoIDE.rawValue])

    var enabledRules: Set<Rule> {
        guard enabled else { return [] }
        return Set(rules.compactMap(Rule.init(rawValue:)))
    }

    init(enabled: Bool, rules: [String]) {
        self.enabled = enabled
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? AutoKillConfig.default.enabled
        rules = try c.decodeIfPresent([String].self, forKey: .rules) ?? AutoKillConfig.default.rules
    }
}

struct Config: Codable, Equatable {
    var pollIntervalSeconds: Double = 30
    var idlePollIntervalSeconds: Double = 120
    var rules: RulesConfig = .default
    var idleCpuSecondsPerPoll: Double = 0.5
    var snoozeMinutes: Double = 60
    var killEscalationSeconds: Double = 10
    var autoKill: AutoKillConfig = .default
    var ownerAppBundlePrefixes: [String] = [
        "com.google.android.studio",
        "com.jetbrains.intellij",
    ]
    var logLevel: String = "info"

    static let `default` = Config()

    var logLevelValue: LogLevel { LogLevel(configString: logLevel) ?? .info }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        pollIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? d.pollIntervalSeconds
        idlePollIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .idlePollIntervalSeconds) ?? d.idlePollIntervalSeconds
        rules = try c.decodeIfPresent(RulesConfig.self, forKey: .rules) ?? d.rules
        idleCpuSecondsPerPoll = try c.decodeIfPresent(Double.self, forKey: .idleCpuSecondsPerPoll) ?? d.idleCpuSecondsPerPoll
        snoozeMinutes = try c.decodeIfPresent(Double.self, forKey: .snoozeMinutes) ?? d.snoozeMinutes
        killEscalationSeconds = try c.decodeIfPresent(Double.self, forKey: .killEscalationSeconds) ?? d.killEscalationSeconds
        autoKill = try c.decodeIfPresent(AutoKillConfig.self, forKey: .autoKill) ?? d.autoKill
        ownerAppBundlePrefixes = try c.decodeIfPresent([String].self, forKey: .ownerAppBundlePrefixes) ?? d.ownerAppBundlePrefixes
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? d.logLevel

        // Sanity clamps — a hostile/typo'd config must not melt the machine.
        pollIntervalSeconds = max(1, pollIntervalSeconds)
        idlePollIntervalSeconds = max(pollIntervalSeconds, idlePollIntervalSeconds)
        killEscalationSeconds = max(0.1, killEscalationSeconds)
        snoozeMinutes = max(0.05, snoozeMinutes)
    }

    /// Consecutive matching samples required before a rule fires (spec §5.3).
    func requiredConsecutiveSamples(for rule: Rule) -> Int {
        max(1, Int(ceil(rules[rule].thresholdSeconds / pollIntervalSeconds)))
    }
}
