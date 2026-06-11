// Entry point — flag-dispatched: one binary serves as launchd agent and
// debugging CLI (spec §11).
import Foundation

switch CLIOptions.parse(CommandLine.arguments) {
case .failure(let err):
    FileHandle.standardError.write(Data("error: \(err.message)\n\n\(usageText)\n".utf8))
    exit(64)
case .success(let options):
    switch options.mode {
    case .none, .help:
        print(usageText)
        exit(options.mode == .help ? 0 : 64)
    case .version:
        print(daemonSlayerVersion)
        exit(0)
    case .scanOnce:
        exit(StatusCommand.run(options: options, includeAgentView: false))
    case .status:
        exit(StatusCommand.run(options: options, includeAgentView: true))
    case .killPid(let pid, let policy):
        exit(KillCommand.run(pid: pid, policy: policy, options: options))
    case .agent:
        AgentRuntime(configPath: options.configPath,
                     statePath: options.statePath,
                     logPath: options.logPath).run()
    }
}
