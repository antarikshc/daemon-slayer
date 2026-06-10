// Integration-test helper: impersonates Gradle/Kotlin daemons end-to-end.
//
// The DaemonSlayer scanner classifies a process as a watched daemon iff its argv
// contains the marker string as an EXACT element (spec §5.4). The harness passes
// those literal marker strings as ordinary argv elements, e.g.
//   fakedaemon --listen org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.13
// so this helper must IGNORE every argument it does not recognise — its job is
// just to be a real, classifiable process that exhibits the network/CPU/marker
// behaviour each scenario needs.
//
// Dependency-free: Foundation + Darwin (BSD sockets) only. No third-party deps.

import Foundation
import Darwin

// MARK: - Argument parsing (tolerant: unknown args are ignored on purpose)

var listen = false
var connectPort: UInt16?
var burnCPU = false
var markerPath: String?
var ignoreSigterm = false
var exitAfter: Double = 600   // safety net (spec: default 600s)

do {
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        let arg = args[i]
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        switch arg {
        case "--listen":
            listen = true
        case "--connect":
            if let v = next(), let p = UInt16(v) { connectPort = p }
        case "--burn-cpu":
            burnCPU = true
        case "--marker":
            if let v = next() { markerPath = v }
        case "--ignore-sigterm":
            ignoreSigterm = true
        case "--exit-after":
            if let v = next(), let d = Double(v) { exitAfter = d }
        default:
            // Unknown argument (daemon-marker strings, version numbers, unique
            // per-scenario tokens, -D… JVM-style flags) — IGNORE by design.
            break
        }
        i += 1
    }
}

// MARK: - Stdout helper (line-buffered, flushed — the harness scrapes "LISTENING <port>")

func emit(_ s: String) {
    FileHandle.standardError.write(Data(("[fakedaemon \(getpid())] " + s + "\n").utf8))
}
func emitStdout(_ s: String) {
    print(s)
    fflush(stdout)
}

// MARK: - Long-lived timer storage (DispatchSourceTimers are cancelled when
// their last strong ref drops; module-level storage keeps them alive).

var liveTimers: [DispatchSourceTimer] = []

// MARK: - Safety net: hard exit after --exit-after seconds no matter what

let exitTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
exitTimer.schedule(deadline: .now() + exitAfter)
exitTimer.setEventHandler {
    emit("exit-after \(exitAfter)s reached — exiting")
    exit(0)
}
exitTimer.resume()
liveTimers.append(exitTimer)

// MARK: - SIGTERM handling (spec §7 step 2; --ignore-sigterm simulates a wedged daemon)

if ignoreSigterm {
    signal(SIGTERM, SIG_IGN)
    emit("SIGTERM ignored (SIG_IGN installed)")
}

// MARK: - --listen: bind 127.0.0.1 on an ephemeral port, accept + hold connections

func startListener() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
        emit("socket() failed: \(String(cString: strerror(errno)))")
        exit(2)
    }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0                                   // 0 → kernel picks an ephemeral port
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")       // loopback only (spec §5.4)

    let bindOK = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindOK == 0 else {
        emit("bind() failed: \(String(cString: strerror(errno)))")
        exit(2)
    }
    guard Darwin.listen(fd, 16) == 0 else {
        emit("listen() failed: \(String(cString: strerror(errno)))")
        exit(2)
    }

    // Read back the actual port the kernel assigned.
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameOK = withUnsafeMutablePointer(to: &bound) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &len)
        }
    }
    guard nameOK == 0 else {
        emit("getsockname() failed: \(String(cString: strerror(errno)))")
        exit(2)
    }
    let port = UInt16(bigEndian: bound.sin_port)

    // Accept loop on a background thread; keep every accepted conn open forever so
    // the daemon shows an ESTABLISHED loopback row for each attached client (O2).
    let acceptThread = Thread {
        var held: [Int32] = []   // keep fds alive (and thus connections ESTABLISHED)
        while true {
            let c = accept(fd, nil, nil)
            if c >= 0 {
                held.append(c)
                emit("accepted connection fd=\(c) (\(held.count) held)")
            } else if errno == EINTR {
                continue
            } else {
                emit("accept() failed: \(String(cString: strerror(errno)))")
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
    acceptThread.stackSize = 1 << 20
    acceptThread.start()

    return port
}

if listen {
    let port = startListener()
    emitStdout("LISTENING \(port)")   // harness scrapes this exact line
    emit("listening on 127.0.0.1:\(port)")
}

// MARK: - --connect: dial 127.0.0.1:<port> and hold the connection open forever
//
// Used both for a plain fake client (O2 attached client) and for a fake
// kotlin→gradle RMI link (peer-daemon connection that must NOT count as a client).

if let port = connectPort {
    let connectThread = Thread {
        // Retry until the listener is up (the harness may spawn us before the
        // listening peer has finished binding).
        var fd: Int32 = -1
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { Thread.sleep(forTimeInterval: 0.2); continue }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if ok == 0 {
                emit("connected to 127.0.0.1:\(port) fd=\(fd)")
                break
            }
            close(fd)
            fd = -1
            Thread.sleep(forTimeInterval: 0.2)
        }
        if fd < 0 {
            emit("could not connect to 127.0.0.1:\(port) within 30s")
            return
        }
        // Hold the connection open forever: park on a blocking read that never
        // returns (peer never sends), keeping the conn ESTABLISHED.
        var byte: UInt8 = 0
        while true {
            let n = recv(fd, &byte, 1, 0)
            if n == 0 { emit("peer closed connection"); break }          // peer gone
            if n < 0 && errno == EINTR { continue }
            if n < 0 { emit("recv error; holding via sleep"); break }
        }
        // If the peer dropped us, just idle so the process stays alive for the test.
        while true { Thread.sleep(forTimeInterval: 3600) }
    }
    connectThread.stackSize = 1 << 20
    connectThread.start()
}

// MARK: - --marker: create the alive-marker, poll it, exit 0 when it disappears
//
// Simulates the Kotlin clean-shutdown contract (spec §7 step 1): DaemonSlayer's
// killer deletes the marker file and the daemon exits on its own.

if let path = markerPath {
    // Create the marker at startup.
    FileManager.default.createFile(atPath: path, contents: Data("alive\n".utf8))
    emit("created marker \(path)")
    let markerTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    markerTimer.schedule(deadline: .now() + 0.2, repeating: 0.2)
    markerTimer.setEventHandler {
        if !FileManager.default.fileExists(atPath: path) {
            emit("marker \(path) gone — clean shutdown, exiting 0")
            exit(0)
        }
    }
    markerTimer.resume()
    liveTimers.append(markerTimer)   // keep a strong ref so the timer keeps firing
}

// MARK: - --burn-cpu: spin one core

if burnCPU {
    let burnThread = Thread {
        var x: Double = 1.0000001
        while true {
            // Tight FP loop — pegs one core. The harness sets cpuThresholdPercent
            // 50, so this comfortably trips R4.
            for _ in 0..<1_000_000 { x = x * 1.0000001 + 0.0000001 }
            if x > 1e300 { x = 1.0000001 }   // keep it from overflowing to inf
        }
    }
    burnThread.stackSize = 1 << 20
    burnThread.start()
}

// MARK: - Park forever (default idle behaviour; threads/timers do the real work)

// All modes keep the main thread parked here; background threads (listener,
// connector, burner) and the dispatch timers (marker, exit-after) keep running.
// Default behaviour with no mode flags is exactly this: a sleep-loop idle daemon.
RunLoop.main.run()
