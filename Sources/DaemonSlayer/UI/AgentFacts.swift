import Foundation

/// Pure bridge from the agent's `state.json` records (agent lane) to per-identity
/// display facts. The UI surfaces the agent's OWN state-machine view (FLAGGED,
/// SNOOZED, counters) verbatim — it does not recompute hysteresis (SPEC-UI §5).
enum AgentFactsDeriver {

    static func derive(from snapshot: AgentStateSnapshot?, config: Config)
        -> [ProcessIdentity: DaemonRowMerger.AgentFacts] {
        guard let snapshot else { return [:] }
        var out: [ProcessIdentity: DaemonRowMerger.AgentFacts] = [:]
        out.reserveCapacity(snapshot.records.count)
        for record in snapshot.records {
            let pending = highestPending(record, config: config)
            out[record.identity] = DaemonRowMerger.AgentFacts(
                stateDescription: record.stateDescription,
                flaggedRule: record.flaggedRule,
                pendingSamples: pending?.samples ?? 0,
                pendingRequired: pending?.required ?? 0)
        }
        return out
    }

    /// The rule with the highest hysteresis progress (samples/required), for the
    /// "watching (n/m polls)" label. Honors the agent's own per-rule counters from
    /// state.json against the config's required-sample math (SPEC §5.3).
    private static func highestPending(_ record: ProcessStateRecord, config: Config)
        -> (samples: Int, required: Int)? {
        var best: (samples: Int, required: Int, ratio: Double)?
        for (raw, samples) in record.ruleCounters {
            guard samples > 0, let rule = Rule(rawValue: raw) else { continue }
            let required = config.requiredConsecutiveSamples(for: rule)
            guard required > 0 else { continue }
            let ratio = Double(samples) / Double(required)
            if best == nil || ratio > best!.ratio {
                best = (samples, required, ratio)
            }
        }
        guard let b = best else { return nil }
        return (b.samples, b.required)
    }
}
