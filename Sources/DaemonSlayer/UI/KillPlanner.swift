import Foundation

/// The pure decision core for every kill affordance in the window (SPEC-UI §6.2).
/// Views are thin: they ask the planner what to render, how much friction to apply,
/// and which `KillPolicy` to use — they never decide policy themselves. This keeps
/// the entire friction ladder exhaustively unit-testable and, critically, lets us
/// PROVE that no one-click path can ever produce `.userForced` (CLAUDE.md / §6).
///
/// THE `.userForced` FENCE: `planRow` returns `.userForced` ONLY for friction tiers
/// that carry dialog text (`.ownedWarning` / `.busyWarning`); the one-click tier
/// (`.none`) is hard-wired to `.respectOwnership`. The view contract is that any
/// plan whose `friction != .none` MUST be routed through a confirmation dialog
/// before its `policy` reaches the Killer — there is no plan that is simultaneously
/// dialog-free and `.userForced`. A unit test asserts this invariant directly.
enum KillPlanner {

    // MARK: - Friction tiers (SPEC-UI §6.2)

    /// How much ceremony a kill needs before the signal flies.
    enum Friction: Equatable {
        /// One click, no dialog. ALWAYS paired with `.respectOwnership`.
        case none
        /// Warn that the target is owned and will likely respawn. `.userForced`.
        case ownedWarning
        /// Scary build-loss warning. `.userForced`.
        case busyWarning
    }

    /// The full plan for a single row's Kill button.
    struct RowPlan: Equatable {
        /// The policy the Killer must run under. `.respectOwnership` iff `friction == .none`.
        let policy: KillPolicy
        let friction: Friction
        /// nil for the one-click tier; the dialog body otherwise.
        let dialogMessage: String?
    }

    // MARK: - Per-row Kill (SPEC-UI §6.2 rows 1–3)

    /// Decide the per-row Kill affordance from the row's already-derived display
    /// verdict (and the slow lane's ownership facts it carries).
    ///
    /// - busy row              → scary build warning, `.userForced`.
    /// - owned idle row         → owned/respawn warning, `.userForced`.
    /// - ownershipUnknown row   → owned-class fail-safe (can't trust it's unowned),
    ///                            warning + `.userForced` — §8 keeps owned-class
    ///                            actions warned when lsof failed.
    /// - everything else        → one click, `.respectOwnership` (flagged/orphaned,
    ///   watching, healthy: all unowned-or-flagged, the Killer's own revalidation
    ///   gates the rest).
    static func planRow(_ row: DaemonRow) -> RowPlan {
        if row.busyNow {
            return RowPlan(
                policy: .userForced,
                friction: .busyWarning,
                dialogMessage: busyMessage(pid: row.identity.pid, project: projectName(row)))
        }
        if row.owned {
            return RowPlan(
                policy: .userForced,
                friction: .ownedWarning,
                dialogMessage: ownedMessage(client: row.attachedClientDescription))
        }
        if row.ownershipUnknown {
            // lsof failed this cycle (§8): treat as owned-class — warn, don't one-click.
            return RowPlan(
                policy: .userForced,
                friction: .ownedWarning,
                dialogMessage: "Ownership couldn't be verified (lsof failed this cycle). "
                    + "It may belong to a running build and could respawn.")
        }
        // Flagged / watching / healthy → unowned or agent-flagged. One click; the
        // Killer's own ownership revalidation still gates against a last-second owner.
        return RowPlan(policy: .respectOwnership, friction: .none, dialogMessage: nil)
    }

    // MARK: - Dialog copy (SPEC-UI §6.2)

    static func busyMessage(pid: Int32, project: String) -> String {
        "PID \(pid) is running a build for \(project) right now. "
            + "Killing it will fail that build."
    }

    static func ownedMessage(client: String?) -> String {
        let who = client ?? "a client"
        return "Owned by \(who) — it will likely respawn this daemon."
    }

    /// Project label used in the busy warning; falls back to the display name.
    static func projectName(_ row: DaemonRow) -> String {
        row.displayName
    }

    // MARK: - Toolbar buttons (SPEC-UI §6.2 rows 4–5)

    /// The "Kill Orphans" toolbar button's state. Rendered ONLY when ≥ 1 daemon is
    /// currently flagged/orphaned, and DISABLED (but still shown) when ownership is
    /// unknown this cycle (§8: can't trust the orphan set). Always `.respectOwnership`.
    struct OrphansButton: Equatable {
        let isVisible: Bool
        let isEnabled: Bool
    }

    static func orphansButton(rows: [DaemonRow], ownershipUnknown: Bool) -> OrphansButton {
        let anyFlagged = rows.contains { isFlagged($0) }
        return OrphansButton(isVisible: anyFlagged, isEnabled: anyFlagged && !ownershipUnknown)
    }

    // MARK: - Target-set derivation

    /// Kill Orphans target set: flagged/orphaned daemons only (SPEC-UI §6.2). Always
    /// killed under `.respectOwnership` — the Killer skips any that gained an owner.
    static func orphanTargets(_ rows: [DaemonRow]) -> [DaemonRow] {
        rows.filter { isFlagged($0) }
    }

    /// Kill All target set: every live daemon (SPEC-UI §6.2). Run under `.userForced`
    /// behind the confirmation dialog; the Killer's identity gates still apply.
    static func allTargets(_ rows: [DaemonRow]) -> [DaemonRow] {
        rows
    }

    /// A daemon counts as "flagged/orphaned" for the orphan button/target set iff its
    /// display verdict is `.flagged` (the agent's state machine fired). Busy/owned are
    /// explicitly excluded — Kill Orphans must never touch them.
    static func isFlagged(_ row: DaemonRow) -> Bool {
        if case .flagged = row.verdict { return true }
        return false
    }

    /// A row that the Kill All confirmation must paint in crimson with a build
    /// warning (SPEC-UI §6.2): the busy ones.
    static func isBusyCasualty(_ row: DaemonRow) -> Bool { row.busyNow }

    // MARK: - Post-kill toast (SPEC-UI §6 / §6.2)

    /// A formatted summary of a finished kill batch for the in-window toast. Freed
    /// RSS = sum of last-observed RSS of confirmed-killed targets; skips are honest.
    struct ToastSummary: Equatable {
        /// e.g. "Reclaimed 2.3 GB" — nil when nothing was actually killed.
        let headline: String
        /// e.g. "Killed 3 · 1 already gone · skipped 1 — now busy" — nil when there
        /// is nothing worth a second line.
        let detail: String?
    }

    static func toast(from reports: [KillReport]) -> ToastSummary {
        var killed = 0
        var skippedGone = 0
        var skippedNowOwned = 0
        var failed = 0
        var freedBytes: UInt64 = 0

        for r in reports {
            switch r.outcome {
            case .killed:
                killed += 1
                freedBytes += r.freedBytes
            case .skippedGone:
                skippedGone += 1
            case .skippedNowOwned:
                skippedNowOwned += 1
            case .failed:
                failed += 1
            }
        }

        let headline: String
        if killed > 0 {
            headline = "Reclaimed \(Format.bytes(freedBytes))"
        } else if reports.isEmpty {
            headline = "Nothing to kill"
        } else {
            headline = "Killed 0"
        }

        // Detail line: lead with the kill count, then honest skips/failures.
        var parts: [String] = []
        if killed > 0 { parts.append("Killed \(killed)") }
        if skippedGone > 0 { parts.append("\(skippedGone) already gone") }
        if skippedNowOwned > 0 { parts.append("skipped \(skippedNowOwned) — now busy") }
        if failed > 0 { parts.append("\(failed) failed") }
        // Suppress a redundant single "Killed n" detail when the headline already
        // carries the only news (a clean batch needs no second line).
        let detail: String?
        if parts.isEmpty {
            detail = nil
        } else if parts.count == 1, killed > 0 {
            detail = nil
        } else {
            detail = parts.joined(separator: " · ")
        }
        return ToastSummary(headline: headline, detail: detail)
    }
}
