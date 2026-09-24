# Installing DaemonSlayer

DaemonSlayer isn't distributed as a signed/notarized app. You build it from source and it installs as a per-user LaunchAgent: no Xcode, no Apple Developer account, no `sudo`.

> **AI agents:** run the steps in order and check each step's result before moving on. Step 1 opens a GUI installer if the Command Line Tools are missing, and step 4 needs the human to click **Allow**. Never commit `Makefile.local`.

## Requirements

- macOS 13 or later
- Apple Command Line Tools (Swift 5.9+). This is **not** Xcode: it's a small download that installs the compiler on its own.

## Install

**1. Install the Command Line Tools (skip if `swift --version` already works)**

```sh
xcode-select --install
```

Finish the installer dialog, then confirm with `swift --version`.

**2. Clone**

```sh
git clone <repo-url> daemon-slayer && cd daemon-slayer
```

**3. Build and install**

```sh
make install
```

This builds a release `.app`, signs it ad-hoc (a local signature that needs no certificate), copies it to `~/Applications/DaemonSlayer.app`, and loads the LaunchAgent. The agent starts now and at every login.

**4. Allow notifications**

When prompted, allow notifications. Then go to System Settings → Notifications → DaemonSlayer and set the style to **Alerts**. Banners auto-dismiss, while Alerts keep the Kill button on screen.

**Optional: sign with your own certificate.** Ad-hoc works fine. If you already have a code-signing identity (`security find-identity -v -p codesigning`), you can use it instead: put `SIGN_IDENTITY = <identity name>` in `Makefile.local` (gitignored) and re-run `make install`.

## Verify

```sh
make status
```

Expected: `Agent: pid <n> running, last poll <n> s ago | notifications: authorized`.

Open `~/Applications/DaemonSlayer.app` (double-click, or `open ~/Applications/DaemonSlayer.app`) for the status/control window.

## Update / uninstall

```sh
git pull && make install   # rebuild and restart the agent (safe to re-run)
make uninstall             # removes app, LaunchAgent, config, state, logs
```

## Files

| What | Path |
|---|---|
| App | `~/Applications/DaemonSlayer.app` |
| LaunchAgent | `~/Library/LaunchAgents/dev.antariksh.daemonslayer.plist` |
| Config (JSON with `//` comments, created on first run, hot-reloaded) | `~/.config/daemonslayer/config.json` |
| Agent state | `~/Library/Application Support/daemonslayer/state.json` |
| Logs | `~/Library/Logs/daemonslayer.log`, `~/Library/Logs/daemonslayer.stdio.log` |

## Troubleshooting / FAQ

**`xcrun: error: invalid active developer path` or `swift: command not found`**
The Command Line Tools are missing or broken. Run `xcode-select --install` (step 1).

**`<identity>: no identity found` during `make install`**
The name in `Makefile.local` doesn't exactly match a Keychain identity. Fix it, or delete `Makefile.local` to go back to ad-hoc.

**`make status` says the agent isn't running**
Check System Settings → General → Login Items & Extensions: DaemonSlayer must be enabled under *App Background Activity*. Then run `make install` again and look at the logs listed above. To inspect launchd directly: `launchctl print gui/$(id -u)/dev.antariksh.daemonslayer`.

**No notifications appear**
`make status` shows the permission state. If it's `denied`, enable DaemonSlayer in System Settings → Notifications. Also check that Focus / Do Not Disturb isn't hiding them.

**"App is damaged" / "unidentified developer"**
This happens with an app someone else built and sent you, because macOS quarantines downloaded apps. Build it yourself with the steps above. Locally built apps aren't quarantined.

**Will it kill my running builds?**
Not automatically. Auto-kill is off by default, so the agent only notifies. A daemon with an attached client (a running build, or an IDE that owns it) counts as owned. It's only flagged after 2 h of idleness, never while it's busy. Everything is configurable in `config.json`.

**Is a `daemonslayer` command on my PATH?**
Only if `/usr/local/bin` is writable; `make install` symlinks it there. Otherwise run `~/Applications/DaemonSlayer.app/Contents/MacOS/daemonslayer --help`.
