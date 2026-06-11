import Foundation

/// One daemon as the window renders it (SPEC-UI §10): live numbers from the fast
/// lane, ownership facts from the slow lane, agent state from state.json. A plain
/// value type; the merge logic that assembles it is pure and tested.
struct DaemonRow: Equatable, Identifiable {
    var id: ProcessIdentity { identity }

    let identity: ProcessIdentity
    let kind: DaemonKind
    let displayName: String

    // Fast lane (numbers only — refreshed every 2 s, NEVER changes the verdict).
    var rssBytes: UInt64
    var cpuPercent: Double?
    var uptime: TimeInterval
    var busyNow: Bool
    var busySince: Date?

    // Slow lane (ownership facts — refreshed every 10 s / on focus).
    var owned: Bool
    var ownedTag: String?
    var ownershipUnknown: Bool
    var attachedClientDescription: String?

    // Agent lane (state.json — refreshed on file change).
    var agentStateDescription: String?
    var agentFlaggedRule: Rule?
    var pendingSamples: Int
    var pendingRequired: Int

    /// The single precedence-resolved label for this row (SPEC-UI §10).
    var verdict: DisplayVerdict {
        DisplayVerdictDeriver.derive(
            busy: busyNow,
            owned: owned,
            ownedTag: ownedTag,
            ownershipUnknown: ownershipUnknown,
            agentRule: agentFlaggedRule,
            pending: pendingRequired > 0 ? (pendingSamples, pendingRequired) : nil)
    }
}

/// Pure assembly of the daemon row set from the three lanes' latest snapshots.
///
/// CONTRACT (SPEC-UI §5): the fast lane updates NUMBERS only — verdict-bearing
/// facts (owned/ownershipUnknown/client/agent state) persist from the last slow /
/// agent update until that lane refreshes. `merge` enforces this by sourcing each
/// field from its owning lane and never letting a fast tick mutate ownership.
enum DaemonRowMerger {

    /// Latest slow-lane ownership facts for one identity (carried between slow ticks).
    struct SlowFacts: Equatable {
        var owned: Bool
        var ownedTag: String?
        var ownershipUnknown: Bool
        var attachedClientDescription: String?
    }

    /// Latest fast-lane numbers for one identity.
    struct FastFacts: Equatable {
        var rssBytes: UInt64
        var cpuPercent: Double?
        var uptime: TimeInterval
        var busyNow: Bool
        var busySince: Date?
    }

    /// Latest agent-lane state for one identity (from state.json).
    struct AgentFacts: Equatable {
        var stateDescription: String?
        var flaggedRule: Rule?
        var pendingSamples: Int
        var pendingRequired: Int
    }

    /// Build the row set. The fast lane is authoritative for WHICH daemons exist
    /// (appear/disappear is a libproc fact, refreshed every 2 s); slow/agent facts
    /// are looked up by identity and default to "no opinion" when that lane hasn't
    /// seen the daemon yet (a daemon that appeared since the last slow tick shows
    /// live numbers immediately, verdict `.healthy`/`.watching` until the slow lane
    /// catches up ≤ 10 s later — the accepted stale-verdict window, §5).
    static func merge(present: [(identity: ProcessIdentity, kind: DaemonKind, displayName: String)],
                      fast: [ProcessIdentity: FastFacts],
                      slow: [ProcessIdentity: SlowFacts],
                      agent: [ProcessIdentity: AgentFacts]) -> [DaemonRow] {
        present.map { p in
            let f = fast[p.identity]
            let s = slow[p.identity]
            let a = agent[p.identity]
            return DaemonRow(
                identity: p.identity,
                kind: p.kind,
                displayName: p.displayName,
                rssBytes: f?.rssBytes ?? 0,
                cpuPercent: f?.cpuPercent,
                uptime: f?.uptime ?? 0,
                busyNow: f?.busyNow ?? false,
                busySince: f?.busySince,
                owned: s?.owned ?? false,
                ownedTag: s?.ownedTag,
                ownershipUnknown: s?.ownershipUnknown ?? false,
                attachedClientDescription: s?.attachedClientDescription,
                agentStateDescription: a?.stateDescription,
                agentFlaggedRule: a?.flaggedRule,
                pendingSamples: a?.pendingSamples ?? 0,
                pendingRequired: a?.pendingRequired ?? 0)
        }
    }

    /// Display sort (SPEC-UI §10): busy → owned → flagged → watching → healthy →
    /// unknown, ties broken by pid for stability.
    static func sorted(_ rows: [DaemonRow]) -> [DaemonRow] {
        rows.sorted { lhs, rhs in
            let lp = lhs.verdict.precedence, rp = rhs.verdict.precedence
            if lp != rp { return lp < rp }
            return lhs.identity.pid < rhs.identity.pid
        }
    }
}
