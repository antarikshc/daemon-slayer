// Finder double-click relay (SPEC-UI §4).
//
// In bundle context the launchd-spawned agent checks in with LaunchServices as
// THE running instance of dev.antariksh.daemonslayer (BackgroundOnly). A Finder/
// Spotlight double-click therefore never spawns a new process — LS just sends a
// reopen Apple Event to the agent. Without this relay that event is silently
// ignored and "double-click → window" (§4, acceptance §14.1) is dead on arrival.
//
// The relay keeps the processes separate exactly as the spec demands: the agent
// never hosts UI; it answers the reopen by activating an already-running UI
// instance, or spawning its own binary with --ui as a detached child. The child
// inherits the agent's config/state paths so both processes watch the same world.
// This is one-way launch plumbing driven by a system event — not agent↔UI IPC.
import AppKit

final class ReopenRelay: NSObject, NSApplicationDelegate {
    private let configPath: String
    private let statePath: String
    private let logger: DSLogger

    init(configPath: String, statePath: String, logger: DSLogger) {
        self.configPath = configPath
        self.statePath = statePath
        self.logger = logger
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // A UI instance of this bundle is any sibling process with a regular
        // activation policy (the agent itself is .prohibited).
        if let bundleID = Bundle.main.bundleIdentifier {
            let existing = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != getpid()
                      && $0.activationPolicy == .regular }
            if let ui = existing {
                logger.info("reopen event: activating running UI (pid \(ui.processIdentifier))")
                ui.activate(options: [.activateIgnoringOtherApps])
                return false
            }
        }
        spawnUI()
        return false // fully handled; the agent has no windows of its own
    }

    private func spawnUI() {
        guard let exe = Bundle.main.executableURL else {
            logger.error("reopen event: no executable URL; cannot spawn UI")
            return
        }
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["--ui", "--config", configPath, "--state-file", statePath]
        do {
            try proc.run()
            logger.info("reopen event: spawned UI (pid \(proc.processIdentifier))")
        } catch {
            logger.error("reopen event: failed to spawn UI: \(error)")
        }
    }
}
