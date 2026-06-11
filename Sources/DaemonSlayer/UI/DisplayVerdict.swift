import Foundation

/// The single verdict label shown on a daemon card, with a strict display
/// precedence (SPEC-UI §10): busy > owned > flagged(rule) > healthy-unowned-pending.
///
/// This is a DISPLAY derivation, not detection: it never runs hysteresis. Ownership
/// comes from the slow lane's facts (via the engine's pure `Ownership.isOwned`);
/// "busy" comes from the fast lane's live CPU; flagged/pending come from the agent's
/// state.json. The UI is a viewer, not a second brain (CLAUDE.md invariant).
enum DisplayVerdict: Equatable {
    /// Live CPU above the idle threshold — running a build right now. Highest
    /// precedence: a busy daemon is a busy daemon whatever the agent thinks.
    case busy
    /// Ownership facts (O1/O2/O4) say owned. `ruleTag` e.g. "O4" for a Kotlin daemon
    /// inheriting its Gradle's verdict; nil for a directly-owned daemon.
    case owned(ruleTag: String?)
    /// The agent's state machine has FLAGGED this daemon. `rule` is its short tag.
    case flagged(rule: Rule)
    /// Unowned and the agent's hysteresis is still counting toward a fire.
    /// Shown as "watching (n/m polls)".
    case watching(samples: Int, required: Int)
    /// Unowned, not busy, not flagged, no counter progress — nothing to say yet.
    case healthy
    /// Slow lane couldn't resolve ownership this cycle (lsof failure). The last
    /// good verdict is shown by the model; this is the explicit unknown fallback.
    case unknown

    var precedence: Int {
        switch self {
        case .busy:     return 0
        case .owned:    return 1
        case .flagged:  return 2
        case .watching: return 3
        case .healthy:  return 4
        case .unknown:  return 5
        }
    }
}

enum DisplayVerdictDeriver {
    /// Inputs are already-computed facts from the three lanes — this stays a pure
    /// mapping with no I/O, so the precedence ordering is exhaustively testable.
    ///
    /// - `busy`: fast lane — live CPU > idle threshold this session.
    /// - `owned`: slow lane — `Ownership.isOwned` over the latest resolved snapshot.
    /// - `ownedTag`: optional rule tag for the owned case (e.g. "O4").
    /// - `ownershipUnknown`: slow lane — lsof failed this cycle.
    /// - `agentRule`: state.json — the rule the agent has this daemon FLAGGED under.
    /// - `pending`: state.json — (samples, required) for the highest-progress rule
    ///   when unowned and not yet flagged; nil when there is no progress to show.
    static func derive(busy: Bool,
                       owned: Bool,
                       ownedTag: String?,
                       ownershipUnknown: Bool,
                       agentRule: Rule?,
                       pending: (samples: Int, required: Int)?) -> DisplayVerdict {
        // Busy wins unconditionally (§10): a running build is the loudest fact.
        if busy { return .busy }
        if owned { return .owned(ruleTag: ownedTag) }
        if let rule = agentRule { return .flagged(rule: rule) }
        if ownershipUnknown { return .unknown }
        if let p = pending, p.samples > 0, p.required > 0 {
            return .watching(samples: p.samples, required: p.required)
        }
        return .healthy
    }
}
