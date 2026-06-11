# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

DaemonSlayer — a macOS menu-less LaunchAgent (Swift, zero dependencies, macOS 13+) that detects orphaned Gradle/Kotlin daemon JVMs and notifies/kills them. `SPEC.md` in the repo root is the authoritative design doc for the v1 agent (detection rules, kill semantics, config schema); `SPEC-UI.md` is the v2 spec for the on-demand status/control window. Both are intentionally untracked in git — read them locally, don't commit them.

## Commands

```sh
swift build                                    # debug build (both daemonslayer + fakedaemon)
swift test                                     # unit tests (RuleEngine, ConfigStore)
swift test --filter RuleEngineTests            # one test class
swift test --filter RuleEngineTests/testName   # one test
./scripts/integration_test.sh                  # e2e harness — needs `swift build` first; spawns real
                                               # processes; aborts if real Gradle/Kotlin daemons are live
make build                                     # release build + .app bundle in dist/ + codesign
make install / uninstall                       # deploy to ~/Applications + LaunchAgent bootstrap
make status                                    # run --status against installed (or .build) binary
```

CLI modes of the binary: `--agent` (poll loop, what launchd runs), `--status` (debug view of verdicts), `--scan-once`, `--version`; `--config/--state-file/--log-file` override paths (the integration harness relies on these).

Codesigning uses a stable self-signed Keychain identity `daemonslayer-dev` (not ad-hoc) so TCC notification permission survives rebuilds. `make build` will fail without it.

## Architecture

Single module `daemonslayer` (internal visibility, tests use `@testable`). Data flows one way per poll:

```
ProcessScanner → OwnershipResolver → RuleEngine → NotificationManager / Killer
(libproc/sysctl)  (lsof + IDEMonitor)  (pure)        (side effects)
```

- **ProcessScanner** (`Scanning/ProcessScanner.swift`) — libproc/`KERN_PROCARGS2` process-table scan, classifies daemons by argv marker strings; `ps` fallback.
- **OwnershipResolver** (`Scanning/OwnershipResolver.swift`) — reports *facts only* (parentIsIDE, hasAttachedClient, linkedGradlePid, ownershipUnknown) via a single `lsof` pass; it does NOT decide ownership. Peer-daemon connections (gradle↔kotlin RMI) are excluded so orphans can't vouch for each other.
- **RuleEngine** (`Core/RuleEngine.swift`) — pure and fully unit-testable: clock comes from `snapshot.timestamp`, no I/O. Owns the entire per-PID state machine (HEALTHY→FLAGGED→KILLING, snooze/ignore, re-notify cadence), derives the ownership verdict including O4 Kotlin↔Gradle transitivity, and enforces consecutive-poll hysteresis (counters count polls, not wall-clock — sleep pauses them).
- **AgentRuntime** (`Agent/AgentRuntime.swift`) — wires it all: 30s poll timer with adaptive idle cadence, IDE launch/quit events trigger out-of-band polls, config hot-reload, writes per-poll `state.json` (which `--status` reads to show agent-view vs live divergence).
- **Killer** (`Kill/Killer.swift`) — marker-file delete → SIGTERM → SIGKILL, with fresh-snapshot ownership revalidation per phase (spec §7). Kotlin child dies before its Gradle parent.
- **ConfigStore** — JSONC (`//` comments stripped), every key optional with defaults merged; invalid config keeps last-good. Hot-reloaded via file watch.

`Sources/FakeDaemon` is a test-only helper that masquerades as a Gradle/Kotlin daemon (`--listen`, `--connect <port>`, `--burn-cpu`, marker files, SIGTERM-ignoring) so the integration harness can exercise every detection rule and kill path against real processes.

## Invariants to preserve

- **Fail safe on uncertainty.** `lsof` failure ⇒ `ownershipUnknown=true` ⇒ engine keeps the previous verdict and never flags/kills on that sample. Note: `lsof` exiting 1 with empty output means "no sockets" (valid data), NOT failure — this distinction once masked all detection.
- **ProcessIdentity = pid + startTimeMicros** everywhere (PID-reuse guard). The ps-fallback path has no start times, so kills fail closed there (detection still works).
- **RuleEngine stays pure.** New detection logic goes in the engine with unit tests; new system facts get gathered by the resolver/scanner and passed in via the snapshot.
- **O4 lockstep must not override a Kotlin daemon's own ownership** — it inherits the Gradle verdict only when it has none of its own.
- The integration harness exists because unit tests can't see subprocess-parsing bugs; run it after touching scanning/ownership/kill code.
