import Foundation

// MARK: - ProcessScanner (spec §5.4 — "Data sources per poll")
//
// Native same-user process table scan with no subprocess spawns in the fast
// path. Primary source is libproc (proc_listallpids + proc_pidinfo) and sysctl
// KERN_PROCARGS2 for argv. A `ps` fallback exists only for the case where
// proc_listallpids itself refuses to enumerate at all.
//
// Everything here is best-effort per PID: processes race-exit, become zombies,
// or belong to other users mid-scan. Any per-PID failure is skipped (debug log)
// rather than aborting the scan.

final class ProcessScanner {
    private let logger: DSLogger

    // mach time base is constant for the life of the process; query it once.
    // ri_user_time / ri_system_time (proc_pid_rusage) are in mach ticks, which
    // must be scaled by numer/denom to get nanoseconds. On Apple Silicon this
    // ratio is not 1:1, so the conversion is mandatory (not a no-op like x86).
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        if tb.denom == 0 { tb.numer = 1; tb.denom = 1 }
        return tb
    }()

    init(logger: DSLogger) {
        self.logger = logger
    }

    // MARK: Public surface

    /// Scan the full same-user process table. Failures for individual PIDs
    /// (raced exits, zombies, EPERM) are skipped silently.
    func allProcesses() -> [RawProcess] {
        guard let pids = listAllPIDs() else {
            // proc_listallpids gave up entirely (returned <= 0 twice). This
            // should essentially never happen for a same-user enumeration;
            // degrade to the `ps` fallback rather than returning nothing.
            logger.warn("proc_listallpids failed; falling back to /bin/ps (startTime-based PID-reuse guard degraded)")
            return fallbackPSScan()
        }

        let myUID = getuid()
        var result: [RawProcess] = []
        result.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let bsd = bsdInfo(pid) else { continue }   // dead/zombie/raced
            guard bsd.pbi_uid == myUID else { continue }     // other user → ignore

            let startMicros = Int64(bsd.pbi_start_tvsec) * 1_000_000 + Int64(bsd.pbi_start_tvusec)
            let (rss, cpu) = rusage(pid)
            let argv = readArgv(pid)   // may be empty; row still kept (ppid node)

            result.append(RawProcess(
                pid: pid,
                ppid: Int32(bitPattern: bsd.pbi_ppid),
                startTimeMicros: startMicros,
                rssBytes: rss,
                cpuTimeSeconds: cpu,
                argv: argv
            ))
        }
        return result
    }

    /// Extract + classify watched daemons from a raw table, parsing
    /// gradleVersion / projectHint / kotlinAliveMarkerPath from argv.
    static func daemons(in processes: [RawProcess]) -> [DaemonProcess] {
        var out: [DaemonProcess] = []
        for p in processes {
            guard !p.argv.isEmpty else { continue }

            // Cheap insurance against `grep GradleDaemon …` self-matches: the
            // marker would be an exact argv element of grep too.
            if let arg0 = p.argv.first {
                let base = (arg0 as NSString).lastPathComponent
                if base == "grep" { continue }
            }

            let kind: DaemonKind
            let markerIndex: Int
            if let i = p.argv.firstIndex(of: DaemonKind.gradleArgvMarker) {
                kind = .gradle; markerIndex = i
            } else if let i = p.argv.firstIndex(of: DaemonKind.kotlinArgvMarker) {
                kind = .kotlin; markerIndex = i
            } else {
                continue
            }

            let gradleVersion = (kind == .gradle) ? parseGradleVersion(p.argv, after: markerIndex) : nil
            let alivePath = parseKotlinMarkerPath(p.argv)
            let project = (kind == .kotlin)
                ? alivePath.flatMap(parseProjectFromMarker)
                : parseGradleProjectHint(p.argv)

            out.append(DaemonProcess(
                identity: ProcessIdentity(pid: p.pid, startTimeMicros: p.startTimeMicros),
                kind: kind,
                ppid: p.ppid,
                rssBytes: p.rssBytes,
                cpuTimeSeconds: p.cpuTimeSeconds,
                argv: p.argv,
                gradleVersion: gradleVersion,
                projectHint: project,
                kotlinAliveMarkerPath: alivePath
            ))
        }
        return out
    }

    // MARK: - libproc: PID enumeration

    /// proc_listallpids with the standard two-call sizing pattern: the first
    /// call (nil buffer) returns the byte size needed; we add headroom because
    /// processes can spawn between the sizing and the fill call. Returns nil
    /// only if the kernel refuses twice — the caller then uses the `ps` path.
    private func listAllPIDs() -> [Int32]? {
        let sizeBytes = proc_listallpids(nil, 0)
        guard sizeBytes > 0 else { return nil }

        // Headroom: +64 slots over the kernel's count, in case of races.
        var capacity = Int(sizeBytes) / MemoryLayout<Int32>.stride + 64
        var pids = [Int32](repeating: 0, count: capacity)

        let written = pids.withUnsafeMutableBytes { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard written > 0 else { return nil }

        capacity = min(Int(written), pids.count)
        return Array(pids[0..<capacity])
    }

    // MARK: - libproc: BSD info (uid, ppid, start time)

    private func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        // A short read means the PID died or we lack visibility — skip it.
        guard n == size else { return nil }
        return info
    }

    // MARK: - libproc: RSS + CPU

    /// proc_pid_rusage with RUSAGE_INFO_V4, falling back to V2 (both expose the
    /// same three fields at the same offsets — V4 only appends fields). CPU
    /// times are mach ticks → scaled to seconds via the static timebase.
    private func rusage(_ pid: Int32) -> (rss: UInt64, cpuSeconds: Double) {
        func toSeconds(_ machTicks: UInt64) -> Double {
            let nanos = Double(machTicks) * Double(Self.timebase.numer) / Double(Self.timebase.denom)
            return nanos / 1_000_000_000
        }

        var v4 = rusage_info_v4()
        let okV4 = withUnsafeMutablePointer(to: &v4) { ptr -> Bool in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rip in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rip) == 0
            }
        }
        if okV4 {
            return (v4.ri_resident_size, toSeconds(v4.ri_user_time + v4.ri_system_time))
        }

        var v2 = rusage_info_v2()
        let okV2 = withUnsafeMutablePointer(to: &v2) { ptr -> Bool in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rip in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rip) == 0
            }
        }
        if okV2 {
            return (v2.ri_resident_size, toSeconds(v2.ri_user_time + v2.ri_system_time))
        }

        // Zombie/raced/EPERM — keep the row (it's a valid ppid node), 0 metrics.
        return (0, 0)
    }

    // MARK: - sysctl KERN_PROCARGS2: argv

    /// Layout of the KERN_PROCARGS2 blob:
    ///   [Int32 argc][exec_path NUL-terminated][NUL padding]
    ///   [argv[0] NUL]…[argv[argc-1] NUL][env…]
    /// We parse only argc + the argv strings, defensively. Any malformation,
    /// truncation, or EPERM/EINVAL (other-user processes, zombies) → empty argv.
    private func readArgv(_ pid: Int32) -> [String] {
        // Generous fixed buffer: ARG_MAX on macOS is ~256 KB and argv+env must
        // fit under it, so this never truncates a real argv. Querying the exact
        // size is an extra syscall per PID for no benefit here.
        var size = Int(262_144) // 256 KB
        var buf = [UInt8](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]

        let rc = buf.withUnsafeMutableBytes { raw in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
        }
        guard rc == 0, size >= MemoryLayout<Int32>.size else { return [] }

        return parseProcArgs2(Array(buf[0..<size]))
    }

    /// Pure parser, isolated for testability. `blob` is the bytes actually
    /// returned by sysctl (length == returned `size`).
    private func parseProcArgs2(_ blob: [UInt8]) -> [String] {
        let count = blob.count
        guard count > MemoryLayout<Int32>.size else { return [] }

        // argc: first 4 bytes, host byte order.
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            blob.withUnsafeBytes { src in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: src[0..<4]))
            }
        }
        guard argc > 0, argc < 8192 else { return [] }   // sanity bound

        var idx = MemoryLayout<Int32>.size

        // exec_path: NUL-terminated string immediately after argc.
        while idx < count && blob[idx] != 0 { idx += 1 }
        // Skip the NUL padding between exec_path and argv[0].
        while idx < count && blob[idx] == 0 { idx += 1 }

        var argv: [String] = []
        argv.reserveCapacity(Int(argc))
        var collected: Int32 = 0
        while collected < argc && idx < count {
            let start = idx
            while idx < count && blob[idx] != 0 { idx += 1 }
            // A trailing string with no NUL = truncation; take what we have.
            let slice = blob[start..<idx]
            if let s = String(bytes: slice, encoding: .utf8) {
                argv.append(s)
            } else {
                argv.append(String(decoding: slice, as: UTF8.self))
            }
            collected += 1
            idx += 1 // step over the NUL
        }
        return argv
    }

    // MARK: - Fallback: /bin/ps (spec §5.4) — only when libproc enumeration fails

    /// Minimal, obviously-correct fallback. startTimeMicros is unavailable from
    /// this format, so it's 0 — the PID-reuse guard is degraded for this path
    /// (warned by the caller). This path should basically never execute.
    private func fallbackPSScan() -> [RawProcess] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid=,rss=,time=,args="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            logger.error("fallback /bin/ps failed to launch: \(error)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let myUID = getuid()  // ps -ax shows all users; we filter below is impossible
                              // without -o uid, but the table is only used as a
                              // last resort, so we keep every row (ownership
                              // resolver walks arbitrary ppid nodes anyway).
        _ = myUID

        var rows: [RawProcess] = []
        for line in text.split(separator: "\n") {
            // Split into at most 5 fields; args (may contain spaces) is the rest.
            let trimmed = line.drop(while: { $0 == " " })
            let parts = splitPSLine(String(trimmed))
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let rssKB = UInt64(parts[2]) else { continue }
            let cpu = parsePSTime(parts[3])
            let argv = parts[4].split(separator: " ").map(String.init)
            rows.append(RawProcess(
                pid: pid,
                ppid: ppid,
                startTimeMicros: 0,                 // unavailable in this format
                rssBytes: rssKB * 1024,             // ps rss is KB
                cpuTimeSeconds: cpu,
                argv: argv
            ))
        }
        return rows
    }

    /// Splits a `ps` line of `pid ppid rss time args…` where the first four
    /// fields are whitespace-delimited and `args` is everything after.
    private func splitPSLine(_ line: String) -> [String] {
        var fields: [String] = []
        var rest = Substring(line)
        for _ in 0..<4 {
            rest = rest.drop(while: { $0 == " " })
            guard let sp = rest.firstIndex(of: " ") else {
                fields.append(String(rest)); rest = ""; break
            }
            fields.append(String(rest[rest.startIndex..<sp]))
            rest = rest[rest.index(after: sp)...]
        }
        fields.append(String(rest.drop(while: { $0 == " " })))
        return fields
    }

    /// cumulative cpu `time` as `[[dd-]hh:]mm:ss[.ff]` → seconds.
    private func parsePSTime(_ s: String) -> Double {
        var days = 0.0
        var rest = s
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[rest.startIndex..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let comps = rest.split(separator: ":").map { Double($0) ?? 0 }
        var seconds = 0.0
        for c in comps { seconds = seconds * 60 + c }
        return days * 86_400 + seconds
    }

    // MARK: - argv parsing helpers (daemon classification, spec §5.4)

    // Spec §5.4 gives `^[0-9]+(\.[0-9]+)*([-.][A-Za-z0-9]+)?$` but lists
    // "9.0.0-rc-1" as a valid example — which that pattern rejects (two trailing
    // `-segment`s). The trailing group is repeated here so the spec's own
    // example matches; plain words ("main") are still rejected (digit-led core).
    private static let versionRegex = try! NSRegularExpression(
        pattern: "^[0-9]+(\\.[0-9]+)*([-.][A-Za-z0-9]+)*$"
    )

    /// gradleVersion: the argv element immediately AFTER the gradle marker, iff
    /// it looks like a version (e.g. "8.13", "8.7", "9.0.0-rc-1").
    private static func parseGradleVersion(_ argv: [String], after markerIndex: Int) -> String? {
        let next = markerIndex + 1
        guard next < argv.count else { return nil }
        let candidate = argv[next]
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard versionRegex.firstMatch(in: candidate, range: range) != nil else { return nil }
        return candidate
    }

    /// kotlinAliveMarkerPath: from `-Dkotlin.daemon.initiator.marker.file=<path>`.
    private static let kotlinMarkerPrefix = "-Dkotlin.daemon.initiator.marker.file="
    private static func parseKotlinMarkerPath(_ argv: [String]) -> String? {
        for a in argv where a.hasPrefix(kotlinMarkerPrefix) {
            return String(a.dropFirst(kotlinMarkerPrefix.count))
        }
        return nil
    }

    /// projectHint for Kotlin: marker filename is
    /// `kotlin-compiler-in-<project>-<suffix>.alive`. Strip the prefix, the
    /// ".alive" extension, then a single trailing "-<suffix>" if present.
    private static func parseProjectFromMarker(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let prefix = "kotlin-compiler-in-"
        guard name.hasPrefix(prefix) else { return nil }
        var core = String(name.dropFirst(prefix.count))
        if core.hasSuffix(".alive") { core = String(core.dropLast(".alive".count)) }
        // Strip the final "-<suffix>" (random id) if there is one.
        if let dash = core.lastIndex(of: "-") {
            core = String(core[core.startIndex..<dash])
        }
        return core.isEmpty ? nil : core
    }

    /// projectHint for Gradle: best-effort from `-Dorg.gradle.projectDir=…` (or
    /// the older `-Dorg.gradle.project.dir=`), taking the last path component.
    private static func parseGradleProjectHint(_ argv: [String]) -> String? {
        let prefixes = ["-Dorg.gradle.projectDir=", "-Dorg.gradle.project.dir="]
        for a in argv {
            for p in prefixes where a.hasPrefix(p) {
                let dir = String(a.dropFirst(p.count))
                let leaf = (dir as NSString).lastPathComponent
                return leaf.isEmpty ? nil : leaf
            }
        }
        return nil
    }
}
