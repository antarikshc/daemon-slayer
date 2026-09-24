# DaemonSlayer

A tiny macOS agent that finds orphaned Gradle and Kotlin daemons and helps you get rid of them.

Gradle and Kotlin daemons are JVMs that often outlive the IDE or terminal session that started them, each holding on to gigabytes of RAM. DaemonSlayer watches for them in the background, notifies you with a one-click **Kill** action, and gives you a small window to see and clean up every daemon on your Mac.

## What it flags

| Rule | Condition (defaults) |
|---|---|
| Ownerless, no IDE | no attached client and no IDE running, for 2 min |
| Ownerless, IDE open | no attached client while an IDE is running, for 15 min |
| Idle too long | owned but idle for 2 h |
| Runaway | no attached client and burning >50% CPU for 2 min |

Nothing is killed unless you say so: auto-kill is off by default. Kills are graceful (SIGTERM, then SIGKILL), and before each step the daemon is re-checked, so one that picked up a build in the meantime is left alone, unless you explicitly force-kill it from the window.

## Install

Build from source and sign with your own Apple Development certificate. See **[INSTALL.md](INSTALL.md)**.

```sh
make install
```

## Usage

- **Background agent**: starts at login and notifies you when it finds a daemon to kill.
- **Window**: open `~/Applications/DaemonSlayer.app` to see every daemon, kill orphans, pause the agent, or change settings.
- **CLI**: `daemonslayer --status` for a one-shot debug view; `--help` for all modes.
- **Config**: `~/.config/daemonslayer/config.json` (JSON with comments, hot-reloaded).

## Development

Swift, no dependencies, macOS 13+.

```sh
swift build
swift test
./scripts/integration_test.sh   # end-to-end, against fake daemons
```
