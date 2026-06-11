import Foundation

let daemonSlayerVersion = "1.0.0"

enum DSPaths {
    static let home = NSHomeDirectory()
    static let config = home + "/.config/daemonslayer/config.json"
    static let state = home + "/Library/Application Support/daemonslayer/state.json"
    static let log = home + "/Library/Logs/daemonslayer.log"
}

enum CLIMode: Equatable {
    case agent, status, scanOnce, version, help, ui
    /// Hidden test/debug entry point (NOT shown in --help): one-shot kill of a
    /// single pid under an explicit policy. This is the ONLY place `.userForced`
    /// can originate; the agent poll loop has no path to it. Used by the
    /// integration harness to exercise the KillPolicy split against real fakes.
    case killPid(Int32, KillPolicy)
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
        // Hidden test/debug kill hook (see CLIMode.killPid). Collected here, folded
        // into the mode after the full arg scan so flag order doesn't matter.
        var killPidArg: Int32?
        var policyArg: KillPolicy?
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
            case "--ui": opts.mode = .ui
            case "--help", "-h": opts.mode = .help
            case "--kill-pid":
                guard let v = value(for: arg), let pid = Int32(v) else {
                    return .failure(CLIError(message: "--kill-pid requires a numeric pid"))
                }
                killPidArg = pid
            case "--policy":
                guard let v = value(for: arg) else {
                    return .failure(CLIError(message: "--policy requires a value (respectOwnership|userForced)"))
                }
                switch v {
                case "respectOwnership": policyArg = .respectOwnership
                case "userForced": policyArg = .userForced
                default: return .failure(CLIError(message: "--policy must be respectOwnership or userForced"))
                }
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
        // Fold the hidden kill hook into the mode (requires both flags).
        if let pid = killPidArg {
            guard let policy = policyArg else {
                return .failure(CLIError(message: "--kill-pid requires --policy <respectOwnership|userForced>"))
            }
            opts.mode = .killPid(pid, policy)
        } else if policyArg != nil {
            return .failure(CLIError(message: "--policy is only valid with --kill-pid"))
        }
        return .success(opts)
    }
}

let usageText = """
daemonslayer \(daemonSlayerVersion) — Gradle/Kotlin daemon leak watcher (spec: DaemonSlayer v1)

USAGE: daemonslayer <mode> [options]

MODES:
  --agent        run the resident watcher (launchd entry point)
  --ui           open the status & control window (also the default with no args)
  --status       one-shot scan merged with the resident agent's view (debugging tool)
  --scan-once    one-shot scan, fresh verdicts only
  --version      print version
  --help         this text

OPTIONS:
  --config PATH      config file        (default \(DSPaths.config))
  --state-file PATH  agent state file   (default \(DSPaths.state))
  --log-file PATH    agent log; "-" = stderr (default \(DSPaths.log))
"""
