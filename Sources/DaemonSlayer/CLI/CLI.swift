import Foundation

let daemonSlayerVersion = "1.0.0"

enum DSPaths {
    static let home = NSHomeDirectory()
    static let config = home + "/.config/daemonslayer/config.json"
    static let state = home + "/Library/Application Support/daemonslayer/state.json"
    static let log = home + "/Library/Logs/daemonslayer.log"
}

enum CLIMode: Equatable {
    case agent, status, scanOnce, version, help
}

struct CLIError: Error {
    let message: String
}

struct CLIOptions {
    var mode: CLIMode?
    var configPath = DSPaths.config
    var statePath = DSPaths.state
    /// nil → stderr (FileLogger contract)
    var logPath: String? = DSPaths.log

    static func parse(_ args: [String]) -> Result<CLIOptions, CLIError> {
        var opts = CLIOptions()
        var i = 1
        func value(for flag: String) -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--agent": opts.mode = .agent
            case "--status": opts.mode = .status
            case "--scan-once": opts.mode = .scanOnce
            case "--version": opts.mode = .version
            case "--help", "-h": opts.mode = .help
            case "--config":
                guard let v = value(for: arg) else { return .failure(CLIError(message: "--config requires a path")) }
                opts.configPath = v
            case "--state-file":
                guard let v = value(for: arg) else { return .failure(CLIError(message: "--state-file requires a path")) }
                opts.statePath = v
            case "--log-file":
                guard let v = value(for: arg) else { return .failure(CLIError(message: "--log-file requires a path")) }
                opts.logPath = (v == "-") ? nil : v
            default:
                return .failure(CLIError(message: "unknown argument: \(arg)"))
            }
            i += 1
        }
        return .success(opts)
    }
}

let usageText = """
daemonslayer \(daemonSlayerVersion) — Gradle/Kotlin daemon leak watcher (spec: DaemonSlayer v1)

USAGE: daemonslayer <mode> [options]

MODES:
  --agent        run the resident watcher (launchd entry point)
  --status       one-shot scan merged with the resident agent's view (debugging tool)
  --scan-once    one-shot scan, fresh verdicts only
  --version      print version
  --help         this text

OPTIONS:
  --config PATH      config file        (default \(DSPaths.config))
  --state-file PATH  agent state file   (default \(DSPaths.state))
  --log-file PATH    agent log; "-" = stderr (default \(DSPaths.log))
"""
