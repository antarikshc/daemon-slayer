import Foundation
import Combine

/// The observable model behind the status window (SPEC-UI §5). Owns the three data
/// lanes (fast / slow / agent), merges their latest snapshots into the published
/// `rows` + `banner`, and starts/stops all of them on window visibility. macOS 13
/// floor → `ObservableObject` + `@Published`, not the `@Observable` macro.
///
/// THREADING: every lane tick (I/O + lane-state mutation) runs on the private
/// serial `work` queue; the present-set / latest-fast/slow/agent dictionaries are
/// `work`-confined. All `@Published` mutations hop to the main queue via `publish`.
/// `start`/`stop`/`refreshOnFocus` are the only cross-thread entry points and are
/// called from the main thread by the window delegate; they only touch the timer
/// handles and dispatch real work onto `work`.
final class UIModel: ObservableObject {

    // MARK: - Published view state

    @Published private(set) var rows: [DaemonRow] = []
    @Published private(set) var banner: BannerState = .dead
    /// True when the most recent slow tick failed lsof (M3 disables Kill Orphans).
    @Published private(set) var ownershipUnknown: Bool = false

    // MARK: - Lanes

    private let work = DispatchQueue(label: "dev.antariksh.daemonslayer.ui.lanes")
    private let logger: DSLogger
    private let options: CLIOptions
    private let scanner: ProcessScanner
    private let resolver: OwnershipResolver
    private let ideMonitor: IDEMonitor
    private let stateStore: StateStore
    private let configStore: ConfigStore

    private var config: Config

    // Cadences (SPEC-UI §5).
    private static let fastInterval: TimeInterval = 2
    private static let slowInterval: TimeInterval = 10

    private var fastTimer: DispatchSourceTimer?
    private var slowTimer: DispatchSourceTimer?
    private var stateWatch: FileWatcher?

    // Lane state (mutated on `work`).
    private var sampler: FastLaneSampler
    private var latestFast: [ProcessIdentity: DaemonRowMerger.FastFacts] = [:]
    private var latestSlow: [ProcessIdentity: DaemonRowMerger.SlowFacts] = [:]
    private var latestAgent: [ProcessIdentity: DaemonRowMerger.AgentFacts] = [:]
    private var present: [(identity: ProcessIdentity, kind: DaemonKind, displayName: String)] = []

    private var running = false

    init(options: CLIOptions) {
        self.options = options
        let logger = FileLogger(path: nil, minLevel: .warn)   // stderr; UI never logs to the agent's file
        self.logger = logger
        self.configStore = ConfigStore(path: options.configPath, logger: logger)
        let config = configStore.load()
        self.config = config
        self.scanner = ProcessScanner(logger: logger)
        self.resolver = OwnershipResolver(logger: logger)
        self.ideMonitor = IDEMonitor(bundlePrefixes: config.ownerAppBundlePrefixes, logger: logger)
        self.stateStore = StateStore(path: options.statePath, logger: logger)
        self.sampler = FastLaneSampler(idleCpuSecondsPerPoll: config.idleCpuSecondsPerPoll,
                                       pollIntervalSeconds: config.pollIntervalSeconds)
    }

    // MARK: - Lifecycle (cancel-on-hide, SPEC-UI §5/§11)

    /// Window became visible → arm every lane. Idempotent.
    func start() {
        guard !running else { return }
        running = true
        ideMonitor.start()

        // Fresh-session busy tracking (§5: busy-since resets on reopen).
        work.async { [self] in
            sampler = FastLaneSampler(idleCpuSecondsPerPoll: config.idleCpuSecondsPerPoll,
                                      pollIntervalSeconds: config.pollIntervalSeconds)
        }

        armFastTimer()
        armSlowTimer()
        armStateWatch()

        // Immediate first pass so the window isn't blank for 2 s / 10 s.
        work.async { [self] in
            fastTick()
            slowTick()
            agentTick()
        }
    }

    /// Window hidden / minimized / closed → cancel ALL lanes dead (SPEC-UI §5: the
    /// v1 footprint promise). Not "skip a tick" — the timers are torn down so a
    /// hidden window costs nothing. Re-armed by `start()` on re-show.
    func stop() {
        guard running else { return }
        running = false
        fastTimer?.cancel(); fastTimer = nil
        slowTimer?.cancel(); slowTimer = nil
        stateWatch?.cancel(); stateWatch = nil
        ideMonitor.stop()
    }

    /// Window focus / appear → an out-of-band slow pass (SPEC-UI §5: slow lane also
    /// runs on focus so verdicts are fresh the moment the user looks).
    func refreshOnFocus() {
        guard running else { return }
        work.async { [self] in slowTick(); agentTick() }
    }

    // MARK: - Timers

    private func armFastTimer() {
        fastTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + Self.fastInterval, repeating: Self.fastInterval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.fastTick() }
        t.resume()
        fastTimer = t
    }

    private func armSlowTimer() {
        slowTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + Self.slowInterval, repeating: Self.slowInterval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.slowTick() }
        t.resume()
        slowTimer = t
    }

    private func armStateWatch() {
        stateWatch?.cancel()
        // state.json is replaced by atomic rename (StateStore), so the watcher must
        // re-arm on vnode delete/rename (same pattern as ConfigStore). FileWatcher
        // handles that; we just react.
        stateWatch = FileWatcher(path: options.statePath, queue: work) { [weak self] in
            self?.agentTick()
        }
        // Also reflect the agent's config (for cadence/staleness math) if it changes.
    }

    // MARK: - Lane ticks (run on `work`)

    /// Fast lane: ONE libproc table scan, no lsof (SPEC-UI §5). Updates numbers and
    /// the present-daemon set; never touches ownership/agent facts.
    private func fastTick() {
        let now = Date()
        let raw = scanner.allProcesses()
        let daemons = ProcessScanner.daemons(in: raw)

        let samples = sampler.ingest(daemons.map { ($0.identity, $0.cpuTimeSeconds) }, now: now)

        var fast: [ProcessIdentity: DaemonRowMerger.FastFacts] = [:]
        var present: [(identity: ProcessIdentity, kind: DaemonKind, displayName: String)] = []
        for d in daemons {
            let s = samples[d.identity]
            fast[d.identity] = DaemonRowMerger.FastFacts(
                rssBytes: d.rssBytes,
                cpuPercent: s?.cpuPercent,
                uptime: now.timeIntervalSince(d.identity.startDate),
                busyNow: s?.busyNow ?? false,
                busySince: s?.busySince)
            present.append((d.identity, d.kind, d.displayName))
        }
        self.latestFast = fast
        self.present = present
        // Drop slow/agent facts for daemons that disappeared so they don't linger.
        let live = Set(present.map { $0.identity })
        latestSlow = latestSlow.filter { live.contains($0.key) }
        latestAgent = latestAgent.filter { live.contains($0.key) }
        publish()
    }

    /// Slow lane: full scan + OwnershipResolver with client descriptions (SPEC-UI
    /// §5). Produces ownership verdicts; on lsof failure keeps previous verdicts and
    /// flags `ownershipUnknown` (M3 disables Kill Orphans). ≤ 4 lsof / 10 s (§11).
    private func slowTick() {
        let raw = scanner.allProcesses()
        let daemons = ProcessScanner.daemons(in: raw)
        let snapshot = resolver.resolve(
            daemons: daemons, allProcesses: raw,
            idePids: ideMonitor.runningIDEPids(), ideRunning: ideMonitor.ideRunning,
            timestamp: Date(), resolveClientDescriptions: true)

        let facts = OwnershipFacts.derive(from: snapshot)
        // Carry-over per identity: a daemon present this slow tick gets its fresh
        // facts; one NOT in this snapshot (e.g. raced) keeps its previous facts
        // until the fast lane drops it. Verdicts persist between slow ticks (§5).
        for (id, f) in facts { latestSlow[id] = f }
        let anyUnknown = snapshot.daemons.contains { $0.ownershipUnknown }
        DispatchQueue.main.async { [weak self] in self?.ownershipUnknown = anyUnknown }
        publish()
    }

    /// Agent lane: read state.json (on change + on focus). Feeds banner + per-PID
    /// agent state-machine status. Pure derivation from the file (SPEC-UI §5/§7.2).
    private func agentTick() {
        let snapshot = stateStore.read()
        latestAgent = AgentFactsDeriver.derive(from: snapshot, config: config)
        let banner = BannerDeriver.derive(snapshot: snapshot, now: Date(), config: config)
        DispatchQueue.main.async { [weak self] in self?.banner = banner }
        publish()
    }

    /// Merge the three lanes' latest snapshots and push to the main thread.
    private func publish() {
        let merged = DaemonRowMerger.sorted(DaemonRowMerger.merge(
            present: present, fast: latestFast, slow: latestSlow, agent: latestAgent))
        DispatchQueue.main.async { [weak self] in self?.rows = merged }
    }
}
