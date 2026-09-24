# Installing DaemonSlayer

DaemonSlayer isn't distributed as a signed/notarized app. You build it from source and sign it with your own Apple Development certificate. It installs as a per-user LaunchAgent, and no `sudo` is needed.

> **AI agents:** run the steps in order and check each step's result before moving on. Step 2 may need the human: creating a certificate happens in the Xcode GUI, and the first codesign can show a Keychain prompt. Never commit `Makefile.local`.

## Requirements

- macOS 13 or later
- Swift 5.9+ (Xcode 15+ or the Command Line Tools). Check with `swift --version`.
- Optional but recommended: an **Apple Development** signing certificate. A free Apple ID works.

## Install

**1. Clone**

```sh
git clone <repo-url> daemon-slayer && cd daemon-slayer
```

**2. Choose a signing identity**

List the identities you have:

```sh
security find-identity -v -p codesigning
```

If there's no `Apple Development: …` entry, create one: Xcode → Settings → Accounts → add your Apple ID → Manage Certificates → **+** → Apple Development.

Write your identity to `Makefile.local`. It's gitignored and read by the Makefile. This command takes the first Apple Development identity; edit the file if you have several.

```sh
security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' | sed 's/^/SIGN_IDENTITY = /' > Makefile.local
```

You can skip this step: without `Makefile.local` the build is signed ad-hoc. That works, but macOS may ask for notification permission again after each rebuild.

**3. Build and install**

```sh
make install
```

This builds a release `.app`, signs it, copies it to `~/Applications/DaemonSlayer.app`, and loads the LaunchAgent. The agent starts now and at every login. If the Keychain asks to let `codesign` use your key, choose **Always Allow**.

**4. Allow notifications**

When prompted, allow notifications. Then go to System Settings → Notifications → DaemonSlayer and set the style to **Alerts**. Banners auto-dismiss, while Alerts keep the Kill button on screen.

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

**`<identity>: no identity found` during `make install`**
The name in `Makefile.local` doesn't exactly match a Keychain identity. Re-run step 2, or delete `Makefile.local` to sign ad-hoc.

**`make status` says the agent isn't running**
Check System Settings → General → Login Items & Extensions: DaemonSlayer must be enabled under *App Background Activity*. Then run `make install` again and look at the logs listed above. To inspect launchd directly: `launchctl print gui/$(id -u)/dev.antariksh.daemonslayer`.

**No notifications appear**
`make status` shows the permission state. If it's `denied`, enable DaemonSlayer in System Settings → Notifications. Also check that Focus / Do Not Disturb isn't hiding them.

**"App is damaged" / "unidentified developer"**
This happens with an app someone else built and sent you, because macOS quarantines downloaded apps. Build it yourself with the steps above. Locally built apps aren't quarantined.

**Will it kill my running builds?**
Not automatically. Auto-kill is off by default, so the agent only notifies. A daemon with an attached client (a running build, or an IDE that owns it) counts as owned and is never flagged. Everything is configurable in `config.json`.

**Is a `daemonslayer` command on my PATH?**
Only if `/usr/local/bin` is writable; `make install` symlinks it there. Otherwise run `~/Applications/DaemonSlayer.app/Contents/MacOS/daemonslayer --help`.
