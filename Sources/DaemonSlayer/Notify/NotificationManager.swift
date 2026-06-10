import Foundation
import UserNotifications

// MARK: - Action wiring (spec §6)

/// Closures the wiring layer supplies to react to notification button taps.
/// May be invoked on ANY thread (the UNUserNotificationCenter delegate callback
/// thread) — the wiring layer is responsible for re-dispatching to its serial
/// queue, so this file just calls them directly.
struct NotificationActions {
    var killAll: ([FlaggedProcess]) -> Void
    var snooze: ([ProcessIdentity]) -> Void
    var ignore: ([ProcessIdentity]) -> Void
}

/// All UNUserNotificationCenter use lives here (spec §6).
///
/// CRITICAL: UNUserNotificationCenter.current() crashes when the process is not
/// running from an .app bundle (Bundle.main.bundleIdentifier == nil — the
/// integration harness and `--status`/`--scan-once` CLI runs). In that case
/// every method becomes a no-op that instead logs the would-be notification at
/// info level prefixed "[notify-dryrun]" (title + body + identifier), which the
/// harness greps for.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    // MARK: Action identifiers (spec §6)

    private enum ActionID {
        static let killAll = "KILL_ALL"
        static let snooze = "SNOOZE"
        static let ignore = "IGNORE"
    }

    /// userInfo key carrying the base64'd JSON of the [FlaggedProcess] batch.
    private static let payloadKey = "payload"

    private let logger: DSLogger
    private let actions: NotificationActions

    /// true outside an .app bundle — UNUserNotificationCenter must not be touched.
    private(set) var dryRun: Bool

    /// nil until determined (and always nil in dryRun); the wiring layer reads
    /// this for state.json / `--status` permission reporting (spec §11, §13/11).
    private(set) var authorized: Bool?

    init(logger: DSLogger, actions: NotificationActions) {
        self.logger = logger
        self.actions = actions
        // Bundle identifier is the canonical "are we in a bundle?" probe; it is
        // exactly what UNUserNotificationCenter checks before it traps.
        self.dryRun = Bundle.main.bundleIdentifier == nil
        super.init()
    }

    /// nil in dryRun, else the live notification center.
    private var center: UNUserNotificationCenter? {
        dryRun ? nil : UNUserNotificationCenter.current()
    }

    // MARK: - Bootstrap (spec §6, §11, §13 row 11)

    /// requestAuthorization([.alert]) + category registration + delegate
    /// assignment. Permission denied → log loudly and keep running (auto-kill
    /// mode still functions; spec §13 row 11). `completion` receives the granted
    /// flag (false in dryRun).
    func bootstrap(completion: ((Bool) -> Void)?) {
        guard let center = center else {
            logger.info("[notify-dryrun] bootstrap skipped — not running in an .app bundle; notifications will be logged, not posted")
            authorized = nil
            completion?(false)
            return
        }

        center.delegate = self
        registerCategories(on: center)

        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            guard let self = self else { completion?(granted); return }
            if let error = error {
                self.logger.error("notification authorization request failed: \(error.localizedDescription)")
            }
            if granted {
                self.logger.info("notification authorization granted")
            } else {
                // spec §13 row 11: denied → log loudly, keep running.
                self.logger.error("notification permission DENIED — open System Settings ▸ Notifications ▸ DaemonSlayer to enable. The watcher keeps running; auto-kill (if enabled) still works, but you will not see kill prompts.")
            }
            self.refreshAuthorization { _ in completion?(granted) }
        }
    }

    /// Both categories share the same three actions (spec §6 / requirement 1).
    private func registerCategories(on center: UNUserNotificationCenter) {
        let killAll = UNNotificationAction(identifier: ActionID.killAll, title: "Kill All", options: [.destructive])
        let snooze = UNNotificationAction(identifier: ActionID.snooze, title: "Snooze 1h", options: [])
        let ignore = UNNotificationAction(identifier: ActionID.ignore, title: "Ignore", options: [])
        let actionList = [killAll, snooze, ignore]

        let orphan = UNNotificationCategory(
            identifier: NotificationCategory.orphanFound.rawValue,
            actions: actionList, intentIdentifiers: [], options: [])
        let runaway = UNNotificationCategory(
            identifier: NotificationCategory.runawayFound.rawValue,
            actions: actionList, intentIdentifiers: [], options: [])

        center.setNotificationCategories([orphan, runaway])
    }

    /// Re-queries the live authorization state (cheap; spec requirement 7).
    private func refreshAuthorization(_ done: ((Bool) -> Void)? = nil) {
        guard let center = center else { authorized = nil; done?(false); return }
        center.getNotificationSettings { [weak self] settings in
            let ok = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            self?.authorized = ok
            done?(ok)
        }
    }

    // MARK: - Posting (spec §6)

    /// Post a batch of newly-flagged (or re-notify-due) processes. The identifier
    /// is stable per process-set so re-notifications REPLACE the prior entry in
    /// Notification Center rather than piling up (spec §6).
    func post(_ batch: NotificationBatch) {
        let title = title(for: batch)
        let body = body(for: batch)

        guard let center = center else {
            logDryRun(title: title, body: body, identifier: batch.identifier)
            return
        }
        refreshAuthorization()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = batch.category.rawValue
        // Best-effort: time-sensitive interruption works for local notifications
        // without a special entitlement in most cases (spec §6).
        content.interruptionLevel = .timeSensitive
        // No sound (spec requirement 3).
        // Carry the full batch payload so the delegate can act on the exact set
        // even when tapped hours later. userInfo must be plist-safe → JSON +
        // base64 string (spec requirement 3).
        if let encoded = encodePayload(batch.processes) {
            content.userInfo = [Self.payloadKey: encoded]
        }

        let request = UNNotificationRequest(identifier: batch.identifier, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("failed to post notification \(batch.identifier): \(error.localizedDescription)")
            }
        }
    }

    /// Passive post-kill confirmation (no category, no actions). Honest
    /// accounting from the KillReports (spec §6 / §7).
    func postKillSummary(_ reports: [KillReport]) {
        guard !reports.isEmpty else { return }

        let killed = reports.filter { if case .killed = $0.outcome { return true }; return false }
        let sigkilled = reports.filter { if case .killed(.sigkill) = $0.outcome { return true }; return false }
        let nowOwned = reports.filter { if case .skippedNowOwned = $0.outcome { return true }; return false }
        let failedPIDs = reports.compactMap { r -> Int32? in
            if case .failed = r.outcome { return r.target.process.pid }
            return nil
        }
        // .skippedGone is silent in the summary: it died on its own / PID reuse —
        // nothing to report and nothing to apologise for.

        let freed = killed.reduce(UInt64(0)) { $0 + $1.freedBytes }
        var parts: [String] = []
        parts.append("Killed \(killed.count) JVM\(killed.count == 1 ? "" : "s"), freed ~\(Format.bytes(freed))")
        if !sigkilled.isEmpty {
            parts.append("\(sigkilled.count) required SIGKILL")
        }
        if !nowOwned.isEmpty {
            parts.append("skipped \(nowOwned.count) — now busy")
        }
        for pid in failedPIDs {
            parts.append("failed to kill PID \(pid)")
        }
        let body = parts.joined(separator: ", ")

        postPassive(title: "DaemonSlayer", body: body, identifier: "kill-summary")
    }

    /// Passive one-time config-error notification (spec §10, §6 honesty).
    func postConfigError(_ message: String) {
        let body = "config.json invalid — keeping last good config\n\(message)"
        postPassive(title: "DaemonSlayer", body: body, identifier: "config-error")
    }

    /// First-install verification notification (spec §11).
    func postTest() {
        postPassive(title: "DaemonSlayer is watching",
                    body: "Notifications are working. You'll see one here when a leaked Gradle or Kotlin daemon shows up.",
                    identifier: "test-notification")
    }

    /// Shared path for the three passive (no category, no actions) notifications.
    private func postPassive(title: String, body: String, identifier: String) {
        guard let center = center else {
            logDryRun(title: title, body: body, identifier: identifier)
            return
        }
        refreshAuthorization()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // No category → no buttons. No sound.

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("failed to post notification \(identifier): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Copy (spec §6 — examples are normative)

    /// Orphan: "<n> orphaned Gradle JVMs — ~<RSS sum>".
    /// Singular: "Orphaned Gradle JVM — ~830 MB".
    /// Runaway: "Gradle daemon burning 140% CPU with no build attached — 22 min".
    private func title(for batch: NotificationBatch) -> String {
        switch batch.category {
        case .orphanFound:
            let n = batch.processes.count
            let rss = batch.processes.reduce(UInt64(0)) { $0 + $1.process.rssBytes }
            if n == 1 {
                return "Orphaned Gradle JVM — ~\(Format.bytes(rss))"
            }
            return "\(n) orphaned Gradle JVMs — ~\(Format.bytes(rss))"
        case .runawayFound:
            // The runaway batch is usually a single daemon; lead with it.
            guard let first = batch.processes.first else {
                return "Runaway Gradle daemon"
            }
            let cpu = first.cpuPercent.map { Int($0.rounded()) }
            let age = Format.duration(Date().timeIntervalSince(first.candidateSince))
            let cpuStr = cpu.map { "\($0)% CPU" } ?? "high CPU"
            if batch.processes.count > 1 {
                return "\(batch.processes.count) Gradle daemons burning \(cpuStr) with no build attached — \(age)"
            }
            return "Gradle daemon burning \(cpuStr) with no build attached — \(age)"
        }
    }

    /// Orphan body: comma/+ joined per-process lines like
    /// "Gradle 8.7 (androidcommon, idle 1h32m) + Kotlin daemon, Gradle 8.10 (idle 2h05m)".
    /// We render each as "<displayName> (idle <dur>)" using idleSeconds where
    /// present; "+" joins a Gradle/Kotlin pair feel and "," separates entries —
    /// spec says match the spirit, keep it informative.
    private func body(for batch: NotificationBatch) -> String {
        switch batch.category {
        case .orphanFound:
            return batch.processes.map { line(for: $0) }.joined(separator: ", ")
        case .runawayFound:
            // Title already carries the headline; body lists the daemon(s).
            return batch.processes.map { line(for: $0) }.joined(separator: ", ")
        }
    }

    /// One process descriptor for the body. Uses displayName + the most relevant
    /// metric: idle duration for orphan/idle rules, CPU% for runaway.
    private func line(for f: FlaggedProcess) -> String {
        let name = f.process.displayName
        if f.rule == .runaway, let cpu = f.cpuPercent {
            return "\(name) (\(Int(cpu.rounded()))% CPU)"
        }
        if let idle = f.idleSeconds {
            return "\(name) (idle \(Format.duration(idle)))"
        }
        return name
    }

    // MARK: - Payload (plist-safe userInfo, spec requirement 3)

    private func encodePayload(_ processes: [FlaggedProcess]) -> String? {
        do {
            let data = try JSONEncoder().encode(processes)
            return data.base64EncodedString()
        } catch {
            logger.error("failed to encode notification payload: \(error.localizedDescription)")
            return nil
        }
    }

    private func decodePayload(_ userInfo: [AnyHashable: Any]) -> [FlaggedProcess]? {
        guard let encoded = userInfo[Self.payloadKey] as? String,
              let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode([FlaggedProcess].self, from: data)
    }

    // MARK: - Dry-run logging (spec CRITICAL note — harness greps these lines)

    private func logDryRun(title: String, body: String, identifier: String) {
        // Single-line so a grep over the log captures the whole event.
        let flatBody = body.replacingOccurrences(of: "\n", with: " / ")
        logger.info("[notify-dryrun] id=\(identifier) title=\"\(title)\" body=\"\(flatBody)\"")
    }

    // MARK: - UNUserNotificationCenterDelegate (spec requirement 4)

    /// Show banners even when the app is "frontmost" (LSUIElement has no
    /// frontmost state, but be explicit). [.banner, .list].
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// Button taps. Action closures may run on any thread — the wiring layer
    /// re-dispatches, so we just call them. The default action (tap on the body)
    /// and the dismiss action are intentional no-ops: implicit-snooze is handled
    /// by the engine's re-notify cadence (spec §6).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        guard let processes = decodePayload(userInfo) else {
            // Passive notifications (kill summary / config error / test) carry no
            // payload — nothing to do beyond acknowledging.
            if response.actionIdentifier != UNNotificationDefaultActionIdentifier,
               response.actionIdentifier != UNNotificationDismissActionIdentifier {
                logger.warn("notification action \(response.actionIdentifier) received with no decodable payload")
            }
            return
        }
        let identities = processes.map { $0.process.identity }

        switch response.actionIdentifier {
        case ActionID.killAll:
            logger.info("user tapped Kill All on \(processes.count) process(es)")
            actions.killAll(processes)
        case ActionID.snooze:
            logger.info("user tapped Snooze on \(identities.count) process(es)")
            actions.snooze(identities)
        case ActionID.ignore:
            logger.info("user tapped Ignore on \(identities.count) process(es)")
            actions.ignore(identities)
        case UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier:
            // No-op by design (spec §6): dismiss = implicit snooze via re-notify
            // cadence; body-tap opens nothing.
            break
        default:
            break
        }
    }
}
