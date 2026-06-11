import AppKit
import SwiftUI

/// Manual AppKit bootstrap for UI mode (SPEC-UI §4). This is a SwiftPM executable
/// with a main.swift dispatcher, so there is no `@main App` — we build the process
/// by hand: NSApplication + delegate + an NSWindow hosting the SwiftUI root.
///
/// The bundle keeps `LSUIElement = true` (no dock icon for the headless agent); UI
/// mode flips `setActivationPolicy(.regular)` at runtime so the dock icon appears
/// ONLY while the window is open. Closing the window (or Cmd-Q) terminates the UI
/// process entirely (§11) — it never touches the agent process.
enum UIApp {
    /// Never returns: runs the AppKit event loop until the window closes.
    static func run(options: CLIOptions) -> Never {
        let app = NSApplication.shared
        // Regular so the dock icon + menu appear while the window is open, despite
        // the bundle's LSUIElement (which governs the headless agent process).
        app.setActivationPolicy(.regular)

        let delegate = UIAppDelegate(options: options)
        app.delegate = delegate
        app.run()
        // app.run() only returns after terminate; exit cleanly for good measure.
        exit(0)
    }
}

/// Owns the window and the model; bridges NSWindow visibility → lane start/stop and
/// last-window-close → process quit.
final class UIAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: CLIOptions
    private var window: NSWindow!
    private var model: UIModel!

    init(options: CLIOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = UIModel(options: options)
        self.model = model

        let root = RootView().environmentObject(model)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "DaemonSlayer"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 620))
        window.center()
        window.delegate = self
        // Occlusion notifications let us cancel lanes when the window is fully hidden
        // behind others, not just minimized/closed (SPEC-UI §5 cancel-on-hide).
        window.isReleasedWhenClosed = false
        self.window = window

        // Finder double-click must land focused (§4): activate + front.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        model.start()
    }

    // MARK: - Quit on last window close (SPEC-UI §11)

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        // Last (only) window closing → terminate the whole UI process (§11): no
        // lingering invisible UI process. Reopening is a Finder double-click away.
        NSApp.terminate(nil)
    }

    // MARK: - Cancel-on-hide / re-arm (SPEC-UI §5)

    func windowDidMiniaturize(_ notification: Notification) {
        model.stop()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model.start()
        model.refreshOnFocus()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.occlusionState.contains(.visible) {
            model.start()
            model.refreshOnFocus()
        } else {
            // Fully occluded (covered by other windows) → stop scanning dead.
            model.stop()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshOnFocus()
    }
}
