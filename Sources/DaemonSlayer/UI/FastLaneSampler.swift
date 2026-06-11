import Foundation

/// Pure fast-lane state: turns consecutive libproc samples (cumulative CPU seconds
/// + wall timestamps) into a live CPU% per daemon, and tracks session-local
/// "busy since" (SPEC-UI §5). No I/O — the lane controller feeds it samples; this
/// type owns only the math so it can be unit-tested deterministically.
///
/// CPU% is the SAME cumulative-cputime-delta method the engine uses (SPEC §5.3):
/// `(cpuSeconds − prevCpuSeconds) / wallDelta × 100`. First sample for an identity
/// has no prior, so CPU% is nil until the second tick.
struct FastLaneSampler {

    /// What the fast lane knows about one daemon after a sample.
    struct Sample: Equatable {
        /// nil on the very first observation of this identity (no delta yet).
        var cpuPercent: Double?
        /// True iff cpuPercent is known AND above the idle threshold (busy now).
        var busyNow: Bool
        /// When this UI session FIRST observed the busy condition for this identity;
        /// nil while not busy. Session-local: never persisted, resets on reopen.
        var busySince: Date?
    }

    /// Per-identity carry-over between ticks.
    private struct Prior {
        var cpuSeconds: Double
        var timestamp: Date
        var busySince: Date?
    }

    /// CPU-seconds-per-poll equivalent reused as the busy floor: a daemon is "busy"
    /// when its CPU delta exceeds the idle threshold over the sample gap, mirroring
    /// the engine's `idleThisSample` (cpuDelta < idleCpuSecondsPerPoll ⇒ idle).
    /// We compare on the per-second rate so a 2 s fast tick and a 30 s engine poll
    /// agree on the same daemon.
    private let idleCpuSecondsPerSecond: Double

    private var priors: [ProcessIdentity: Prior] = [:]

    /// - `idleCpuSecondsPerPoll`/`pollIntervalSeconds`: the engine's idle definition,
    ///   converted to a per-second rate so the fast lane's 2 s gap uses the SAME
    ///   threshold as a 30 s poll (match the spec's busy/idle line, SPEC-UI §5).
    init(idleCpuSecondsPerPoll: Double, pollIntervalSeconds: Double) {
        let interval = max(0.001, pollIntervalSeconds)
        self.idleCpuSecondsPerSecond = idleCpuSecondsPerPoll / interval
    }

    /// Ingest one fast tick: a set of (identity, cumulative cpu seconds) at `now`.
    /// Returns the per-identity Sample. Identities absent from this tick are dropped
    /// from the carry-over (the daemon disappeared — its busy session ends).
    mutating func ingest(_ observations: [(identity: ProcessIdentity, cpuSeconds: Double)],
                         now: Date) -> [ProcessIdentity: Sample] {
        var out: [ProcessIdentity: Sample] = [:]
        var nextPriors: [ProcessIdentity: Prior] = [:]
        out.reserveCapacity(observations.count)
        nextPriors.reserveCapacity(observations.count)

        for obs in observations {
            let id = obs.identity
            var cpuPercent: Double?
            var busyNow = false

            if let prior = priors[id] {
                let cpuDelta = obs.cpuSeconds - prior.cpuSeconds
                let wallDelta = now.timeIntervalSince(prior.timestamp)
                if wallDelta > 0 {
                    cpuPercent = max(0, cpuDelta / wallDelta * 100)
                    // Busy iff the per-second CPU rate exceeds the idle floor.
                    busyNow = (cpuDelta / wallDelta) > idleCpuSecondsPerSecond
                }
            }

            // Session-local busy-since: set on the busy edge, cleared when not busy.
            let priorBusySince = priors[id]?.busySince
            let busySince: Date?
            if busyNow {
                busySince = priorBusySince ?? now
            } else {
                busySince = nil
            }

            out[id] = Sample(cpuPercent: cpuPercent, busyNow: busyNow, busySince: busySince)
            nextPriors[id] = Prior(cpuSeconds: obs.cpuSeconds, timestamp: now, busySince: busySince)
        }

        priors = nextPriors
        return out
    }
}
