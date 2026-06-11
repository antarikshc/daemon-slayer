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
    /// Set when a [Start] kickstart fails (plist not installed) → the banner shows the
    /// `make install` guidance. Cleared on the next successful agent heartbeat.
    @Published private(set) var startFailed: Bool = false
    /// True when the most recent slow tick failed lsof (M3 disables Kill Orphans).
    @Published private(set) var ownershipUnknown: Bool = false

    /// The latest loaded config (defaults merged). The settings form seeds from this
    /// and every save mutates a COPY of it, so hidden keys round-trip (SPEC-UI §9).
    /// Published so an external config edit re-seeds the form.
    @Published private(set) var loadedConfig: Config
    /// Bumped on every config (re)load so the settings form re-seeds. (Config is large;
    /// a counter is a cheaper change trigger than diffing the struct in the view.)
    @Published private(set) var settingsRevision: Int = 0
    /// Latest post-kill toast (SPEC-UI §6); nil when there is nothing to show. The
    /// view drives the auto-dismiss timer and clears it via `dismissToast()`.
    @Published private(set) var toast: KillPlanner.ToastSummary?
    /// True while a kill batch runs — the view disables every kill button so a
    /// second batch can't be queued on top of the first (SPEC-UI §6). Lanes keep
    /// updating regardless.
    @Published private(set) var killInFlight = false

    // MARK: - Lanes

    private let work = DispatchQueue(label: "dev.antariksh.daemonslayer.ui.lanes")
    private let logger: DSLogger
    private let options: CLIOptions
    private let scanner: ProcessScanner
    private let resolver: OwnershipResolver
    private let ideMonitor: IDEMonitor
    private let stateStore: StateStore
    private let configStore: ConfigStore
    private let killCoordinator: KillCoordinator

    private var config: Config

    // Cadences (SPEC-UI §5).
    private static let fastInterval: TimeInterval = 2
    private static let slowInterval: TimeInterval = 10

    private var fastTimer: DispatchSourceTimer?
    private var slowTimer: DispatchSourceTimer?
    private var stateWatch: FileWatcher?
    private var configWatch: FileWatcher?
    /// 1 s display clock that re-derives the banner so "last poll Ns ago" ticks. Armed
    /// only while watching (the fast lane), cancelled on hide with everything else —
    /// no always-on timer (SPEC-UI §7.2).
    private var displayTimer: DispatchSourceTimer?
    /// The agent's plist label (SPEC-UI §7.2): `launchctl kickstart` target.
    private static let agentLabel = "dev.antariksh.daemonslayer"

    // Lane state (mutated on `work`).
    private var sampler: FastLaneSampler
    private var latestFast: [ProcessIdentity: DaemonRowMerger.FastFacts] = [:]
    private var latestSlow: [ProcessIdentity: DaemonRowMerger.SlowFacts] = [:]
    private var latestAgent: [ProcessIdentity: DaemonRowMerger.AgentFacts] = [:]
    private var present: [(identity: ProcessIdentity, kind: DaemonKind, displayName: String)] = []
    /// Last state.json read (work-confined) so the 1 s display timer can re-derive the
    /// banner against a fresh `now` without re-reading the file every second.
    private var lastAgentSnapshot: AgentStateSnapshot?

    private var running = false

    init(options: CLIOptions) {
        self.options = options
        let logger = FileLogger(path: nil, minLevel: .warn)   // stderr; UI never logs to the agent's file
        self.logger = logger
        self.configStore = ConfigStore(path: options.configPath, logger: logger)
        let config = configStore.load()
        self.config = config
        self.loadedConfig = config
        self.scanner = ProcessScanner(logger: logger)
        self.resolver = OwnershipResolver(logger: logger)
        self.ideMonitor = IDEMonitor(bundlePrefixes: config.ownerAppBundlePrefixes, logger: logger)
        self.stateStore = StateStore(path: options.statePath, logger: logger)
        self.sampler = FastLaneSampler(idleCpuSecondsPerPoll: config.idleCpuSecondsPerPoll,
                                       pollIntervalSeconds: config.pollIntervalSeconds)
        self.killCoordinator = KillCoordinator(
            options: options, logger: logger, scanner: scanner,
            resolver: resolver, ideMonitor: ideMonitor, configStore: configStore)
    }

    // MARK: - Kills (SPEC-UI §6)

    /// Run a kill batch against the given rows under `policy`, then surface a toast.
    /// Disables further kills until the batch resolves (no double-batching). The
    /// caller (view) is responsible for routing every `.userForced` request through
    /// a confirmation dialog FIRST — `policy` is whatever `KillPlanner` decided and
    /// the planner only yields `.userForced` for dialog-bearing friction tiers.
    func requestKill(_ rows: [DaemonRow], policy: KillPolicy) {
        guard !killInFlight, !rows.isEmpty else { return }
        killInFlight = true
        let identities = rows.map(\.identity)
        killCoordinator.kill(identities: identities, policy: policy) { [weak self] reports in
            guard let self else { return }
            self.killInFlight = false
            self.toast = KillPlanner.toast(from: reports)
            // Pull a fresh ownership pass so killed daemons drop out promptly rather
            // than waiting up to a full slow tick (the fast lane already drops them
            // within 2 s, this just refreshes verdicts for survivors).
            self.refreshOnFocus()
        }
    }

    /// Clear the toast (the view's auto-dismiss timer fires this after ~4 s).
    func dismissToast() { toast = nil }

    // MARK: - Banner actions: pause / resume / start (SPEC-UI §7)

    /// [Pause] / [Resume] flip the `paused` config key via the whole-file write path.
    /// The agent applies it on its next hot-reload (≤ 1 poll). We mutate ONLY `paused`
    /// on the latest loaded struct, so any pending settings edit is undisturbed.
    func pause() { writeConfig { ConfigWriter.mutated($0, paused: true) } }
    func resume() { writeConfig { ConfigWriter.mutated($0, paused: false) } }

    /// [Start] kickstarts the LaunchAgent (SPEC-UI §7.2). On failure (plist not
    /// installed) we set `startFailed` so the banner instructs `make install` — the
    /// UI never bootstraps the plist itself.
    func startAgent() {
        work.async { [self] in
            let ok = Self.kickstartAgent(logger: logger)
            DispatchQueue.main.async { [weak self] in self?.startFailed = !ok }
            // Re-read state.json shortly: a successful kickstart writes a heartbeat the
            // banner picks up; agentTick clears startFailed when it goes non-dead.
            if ok { agentTick() }
        }
    }

    /// Run `launchctl kickstart gui/$UID/<label>`; returns true on exit code 0.
    private static func kickstartAgent(logger: DSLogger) -> Bool {
        let uid = getuid()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(uid)/\(agentLabel)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                logger.warn("[ui] launchctl kickstart failed (exit \(p.terminationStatus)) — agent likely not installed")
            }
            return p.terminationStatus == 0
        } catch {
            logger.warn("[ui] launchctl kickstart could not run: \(error)")
            return false
        }
    }

    // MARK: - Settings save (SPEC-UI §9)

    /// Commit a settings edit. Mutates ONLY the touched key(s) on the latest loaded
    /// struct (`autoKill.rules` and every hidden key carried through), then writes the
    /// whole file. `nil` args leave that key untouched.
    func saveSettings(autoKillEnabled: Bool?, snoozeMinutes: Double?) {
        writeConfig { ConfigWriter.mutated($0, autoKillEnabled: autoKillEnabled, snoozeMinutes: snoozeMinutes) }
    }

    /// Shared whole-file write: take the latest loaded struct, apply `mutate`, validate
    /// + atomic-write through `ConfigWriter`, and reflect the result so the form +
    /// banner immediately match what's on disk. Runs on `work` (off the main thread).
    private func writeConfig(_ mutate: @escaping (Config) -> Config) {
        work.async { [self] in
            let base = configStore.load()   // freshest on-disk struct (catches external edits)
            let next = mutate(base)
            switch ConfigWriter.save(next, to: options.configPath) {
            case .success:
                config = next
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.loadedConfig = next
                    self.settingsRevision &+= 1
                    // Reflect the paused flip in the banner without waiting for the
                    // 1 s tick (state.json still says the old value until the agent
                    // re-beats; but the config is authoritative for the toggle intent).
                }
            case .failure(let e):
                logger.warn("[ui] config save refused: \(e)")
                // Re-seed the form from the unchanged on-disk struct so a refused edit
                // doesn't leave the control out of sync.
                DispatchQueue.main.async { [weak self] in self?.settingsRevision &+= 1 }
            }
        }
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
        armConfigWatch()
        armDisplayTimer()

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
        configWatch?.cancel(); configWatch = nil
        displayTimer?.cancel(); displayTimer = nil
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
    }

    /// Watch config.json so the settings form refreshes on an external hand-edit
    /// (SPEC-UI §9/§5 edge 5), and the banner staleness math tracks cadence changes.
    private func armConfigWatch() {
        configWatch?.cancel()
        configWatch = FileWatcher(path: options.configPath, queue: work) { [weak self] in
            self?.configTick()
        }
    }

    /// 1 s display clock: re-derives the banner from the last-read state.json so the
    /// "last poll Ns ago" readout ticks. Re-reads nothing heavy — just re-runs the
    /// pure BannerDeriver against `now`. Cancelled on hide with everything else.
    private func armDisplayTimer() {
        displayTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tickBanner() }
        t.resume()
        displayTimer = t
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
        lastAgentSnapshot = snapshot
        latestAgent = AgentFactsDeriver.derive(from: snapshot, config: config)
        let banner = BannerDeriver.derive(snapshot: snapshot, now: Date(), config: config)
        // A fresh heartbeat means the agent is alive again — clear any stale Start error.
        let clearStartFailed = (banner != .dead)
        DispatchQueue.main.async { [weak self] in
            self?.banner = banner
            if clearStartFailed { self?.startFailed = false }
        }
        publish()
    }

    /// 1 s re-derivation of the banner against a fresh `now` (the ticking "last poll
    /// Ns ago"). Pure; touches no I/O. Skips publishing the rows.
    private func tickBanner() {
        let banner = BannerDeriver.derive(snapshot: lastAgentSnapshot, now: Date(), config: config)
        DispatchQueue.main.async { [weak self] in self?.banner = banner }
    }

    /// Config file changed externally (hand-edit) → reload the latest struct so the
    /// settings form re-seeds and the banner uses the new cadence. The agent has its
    /// own ConfigStore + hot-reload; this is purely the UI's read-side refresh.
    private func configTick() {
        let cfg = configStore.load()
        config = cfg
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.loadedConfig = cfg
            self.settingsRevision &+= 1
        }
    }

    /// Merge the three lanes' latest snapshots and push to the main thread.
    private func publish() {
        let merged = DaemonRowMerger.sorted(DaemonRowMerger.merge(
            present: present, fast: latestFast, slow: latestSlow, agent: latestAgent))
        DispatchQueue.main.async { [weak self] in self?.rows = merged }
    }
}
