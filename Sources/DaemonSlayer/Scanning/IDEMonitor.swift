import Foundation
import AppKit

// MARK: - IDEMonitor (spec §5.3 event-driven IDE tracking, §5.4 NSWorkspace)
//
// IDE presence is push-based: we subscribe to NSWorkspace launch/terminate
// notifications instead of scanning the process table every poll. An IDE
// quitting must reach the Poller immediately so R1's clock starts on the quit
// event (spec §5.3) rather than the next tick — hence onChange fires on EVERY
// launch/terminate, even when the ideRunning boolean is unchanged (a second
// IDE instance launching/quitting still warrants an out-of-band poll).
//
// `runningApplications` is an in-memory list maintained by AppKit, so the
// per-event re-filter is cheap (spec §5.4 explicitly allows this — "no polling
// cost").

final class IDEMonitor {
    private let logger: DSLogger

    // Notifications arrive on arbitrary queues; `prefixes` is the only mutable
    // state shared across them and the config hot-reload, so it is guarded by a
    // serial queue. ideRunning/runningIDEPids re-filter NSWorkspace live under
    // the same lock so a concurrent updatePrefixes() can't tear the read.
    private let stateQueue = DispatchQueue(label: "dev.antariksh.daemonslayer.idemonitor")
    private var prefixes: [String]

    private var observers: [NSObjectProtocol] = []
    private var started = false

    /// Invoked with the freshly computed `ideRunning` value on every IDE
    /// launch/terminate. MAY be called from an arbitrary thread — the caller
    /// (Poller) is responsible for re-dispatching onto its own serial queue.
    var onChange: ((Bool) -> Void)?

    init(bundlePrefixes: [String], logger: DSLogger) {
        self.prefixes = bundlePrefixes
        self.logger = logger
    }

    func start() {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        let handler: (Notification) -> Void = { [weak self] note in
            self?.handleWorkspaceEvent(note)
        }
        // Pass a concrete queue (nil = posting thread) — we re-filter under our
        // own lock anyway, so any queue is fine; use the main queue so AppKit's
        // userInfo app object is touched on a sane thread.
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: nil, using: handler))
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                        object: nil, queue: nil, using: handler))
        logger.info("IDEMonitor started; watching prefixes \(prefixesSnapshot())")
    }

    func stop() {
        guard started else { return }
        started = false
        let nc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o) }
        observers.removeAll()
        logger.info("IDEMonitor stopped")
    }

    /// Config hot-reload (spec §10). Replaces the watched prefix list; does not
    /// fire onChange (the next poll picks up the new ideRunning, and a prefix
    /// change with no IDE running is a no-op for ownership).
    func updatePrefixes(_ prefixes: [String]) {
        stateQueue.sync { self.prefixes = prefixes }
        logger.debug("IDEMonitor prefixes updated to \(prefixesSnapshot())")
    }

    /// True iff any running app's bundle ID has one of the configured prefixes.
    var ideRunning: Bool {
        !matchingApps().isEmpty
    }

    /// PIDs of all currently-running IDE apps (input to OwnershipResolver O1).
    func runningIDEPids() -> Set<Int32> {
        Set(matchingApps().map { $0.processIdentifier })
    }

    // MARK: - Internals

    private func handleWorkspaceEvent(_ note: Notification) {
        let running = ideRunning
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            let verb = note.name == NSWorkspace.didTerminateApplicationNotification ? "terminated" : "launched"
            let bundle = app.bundleIdentifier ?? "?"
            logger.debug("IDEMonitor: app \(verb) bundle=\(bundle) pid=\(app.processIdentifier); ideRunning=\(running)")
        }
        // Fire on EVERY event (spec §5.3) so the Poller runs an out-of-band poll;
        // a different IDE instance toggling must still kick R1's clock.
        onChange?(running)
    }

    /// Live re-filter of NSWorkspace.runningApplications under the prefix lock.
    private func matchingApps() -> [NSRunningApplication] {
        let prefixes = stateQueue.sync { self.prefixes }
        guard !prefixes.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let bundle = app.bundleIdentifier else { return false }
            return prefixes.contains { bundle.hasPrefix($0) }
        }
    }

    private func prefixesSnapshot() -> [String] {
        stateQueue.sync { prefixes }
    }
}
