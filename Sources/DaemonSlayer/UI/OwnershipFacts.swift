import Foundation

/// Pure bridge from a resolved `PollSnapshot` (slow lane) to per-identity display
/// ownership facts. Reuses the engine's existing `Ownership.isOwned` verbatim —
/// the UI never re-implements the ownership predicate (CLAUDE.md invariant). This
/// only ADDS a cosmetic rule tag (O1/O2/O4) for display; the boolean is the
/// engine's.
enum OwnershipFacts {

    /// Map every daemon in the snapshot to its slow-lane facts.
    static func derive(from snapshot: PollSnapshot) -> [ProcessIdentity: DaemonRowMerger.SlowFacts] {
        var out: [ProcessIdentity: DaemonRowMerger.SlowFacts] = [:]
        out.reserveCapacity(snapshot.daemons.count)
        for obs in snapshot.daemons {
            // lsof failure (§8): report unknown; the model keeps the previous verdict
            // and the deriver never flags on unknown.
            if obs.ownershipUnknown {
                out[obs.process.identity] = DaemonRowMerger.SlowFacts(
                    owned: false, ownedTag: nil, ownershipUnknown: true,
                    attachedClientDescription: obs.attachedClientDescription)
                continue
            }
            let owned = Ownership.isOwned(obs, in: snapshot)
            out[obs.process.identity] = DaemonRowMerger.SlowFacts(
                owned: owned, ownedTag: owned ? tag(for: obs, in: snapshot) : nil,
                ownershipUnknown: false,
                attachedClientDescription: obs.attachedClientDescription)
        }
        return out
    }

    /// Display-only rule tag for an OWNED daemon: O1 (IDE parent), O2 (attached
    /// client), O4 (Kotlin inheriting its Gradle's verdict). Mirrors the branches in
    /// `Ownership.isOwned` for labelling; it decides nothing.
    private static func tag(for d: DaemonObservation, in snapshot: PollSnapshot) -> String? {
        if d.parentIsIDE { return "O1" }
        if d.hasAttachedClient { return "O2" }
        if d.process.kind == .kotlin, d.linkedGradlePid != nil { return "O4" }
        return nil
    }
}
