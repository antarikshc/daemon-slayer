import SwiftUI

/// The status & control window (SPEC-UI §10). M3 lands the daemon cards + kill UX:
/// a scrollable card list, the friction-laddered kill controls (per-row, Kill
/// Orphans, Kill All), and the post-kill toast. The banner + settings rows are
/// still placeholders (M4). Views stay THIN — every kill decision comes from the
/// pure `KillPlanner`; this file only renders plans and routes confirmations.
struct RootView: View {
    @EnvironmentObject private var model: UIModel

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                bannerRow
                Divider()
                DaemonSection(rows: model.rows, ownershipUnknown: model.ownershipUnknown,
                              killInFlight: model.killInFlight, model: model)
                Divider()
                settingsPlaceholder
            }
            .frame(minWidth: 480, minHeight: 360)

            if let toast = model.toast {
                ToastView(summary: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        // Auto-dismiss the toast after 4 s (SPEC-UI §6).
        .onChange(of: model.toast) { newValue in
            guard newValue != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { model.dismissToast() }
        }
    }

    // MARK: - Banner (placeholder text; the real banner VIEW is M4)

    private var bannerRow: some View {
        HStack {
            Text(bannerText).font(.system(.body, design: .monospaced))
            Spacer()
        }
        .padding(10)
    }

    private var bannerText: String {
        switch model.banner {
        case .watching(let ago): return "● Watching — last poll \(Format.duration(ago)) ago"
        case .paused: return "● PAUSED — daemons are not being watched"
        case .dead: return "● Agent not running"
        }
    }

    private var settingsPlaceholder: some View {
        HStack {
            Text("SETTINGS").sectionHeaderStyle()
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - Daemon section (header + toolbar + scrolling card box)

private struct DaemonSection: View {
    let rows: [DaemonRow]
    let ownershipUnknown: Bool
    let killInFlight: Bool
    let model: UIModel

    // Kill All confirmation (§6.2 row 5).
    @State private var showKillAll = false
    // Per-row owned/busy confirmation (§6.2 rows 2–3).
    @State private var pendingRow: DaemonRow?
    @State private var pendingPlan: KillPlanner.RowPlan?

    private var orphansButton: KillPlanner.OrphansButton {
        KillPlanner.orphansButton(rows: rows, ownershipUnknown: ownershipUnknown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            cardBox
        }
        // Kill All confirmation lists every casualty; busy ones painted crimson.
        .confirmationDialog("Kill all \(rows.count) daemon\(rows.count == 1 ? "" : "s")?",
                            isPresented: $showKillAll, titleVisibility: .visible) {
            Button("Kill all", role: .destructive) {
                model.requestKill(KillPlanner.allTargets(rows), policy: .userForced)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(killAllMessage)
        }
        // Per-row owned/busy warning. `.userForced` is constructed ONLY here, inside
        // the confirm action — never on a one-click path.
        .confirmationDialog(perRowTitle, isPresented: perRowBinding, titleVisibility: .visible) {
            Button(perRowConfirmLabel, role: .destructive) {
                if let row = pendingRow { model.requestKill([row], policy: .userForced) }
                clearPending()
            }
            Button("Cancel", role: .cancel) { clearPending() }
        } message: {
            Text(pendingPlan?.dialogMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("DAEMONS (\(rows.count))").sectionHeaderStyle()
            if ownershipUnknown {
                Text("ownership unknown").foregroundColor(.secondary).font(.caption)
            }
            Spacer()
            // Kill Orphans: rendered only with ≥1 orphan, disabled under ownershipUnknown.
            if orphansButton.isVisible {
                Button("Kill Orphans") {
                    model.requestKill(KillPlanner.orphanTargets(rows), policy: .respectOwnership)
                }
                .disabled(!orphansButton.isEnabled || killInFlight)
                .help(orphansButton.isEnabled
                      ? "Kill every orphaned daemon (respects ownership)"
                      : "Ownership couldn't be verified this cycle")
            }
            // Kill All: always present.
            Button("Kill All") { showKillAll = true }
                .tint(.slayerCrimson)
                .disabled(rows.isEmpty || killInFlight)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder
    private var cardBox: some View {
        if rows.isEmpty {
            EmptyDaemonsView()
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        DaemonCard(row: row, killInFlight: killInFlight) {
                            handleRowKill(row)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 340)   // fixed-max-height scroll box (§10)
            .animation(.easeOut(duration: 0.2), value: rows.map(\.id))
        }
    }

    // MARK: - Per-row kill routing (the `.userForced` fence)

    /// One-click rows (friction `.none`) kill immediately under `.respectOwnership`.
    /// Owned/busy/unknown rows raise a confirmation; their `.userForced` policy only
    /// reaches the Killer through the dialog's confirm button.
    private func handleRowKill(_ row: DaemonRow) {
        let plan = KillPlanner.planRow(row)
        switch plan.friction {
        case .none:
            model.requestKill([row], policy: plan.policy)   // .respectOwnership by construction
        case .ownedWarning, .busyWarning:
            pendingRow = row
            pendingPlan = plan
        }
    }

    private func clearPending() { pendingRow = nil; pendingPlan = nil }

    private var perRowBinding: Binding<Bool> {
        Binding(get: { pendingRow != nil }, set: { if !$0 { clearPending() } })
    }

    private var perRowTitle: String {
        guard let plan = pendingPlan else { return "" }
        switch plan.friction {
        case .busyWarning: return "Kill a running build?"
        case .ownedWarning: return "Kill an owned daemon?"
        case .none: return ""
        }
    }

    private var perRowConfirmLabel: String {
        pendingPlan?.friction == .busyWarning ? "Kill build" : "Kill"
    }

    private var killAllMessage: String {
        var lines = ["This signals every daemon below. Identity checks still apply."]
        for row in rows {
            let prefix = KillPlanner.isBusyCasualty(row) ? "⚠︎ " : "• "
            var line = prefix + row.displayName + " (pid \(row.identity.pid))"
            if KillPlanner.isBusyCasualty(row) { line += " — running a build; killing fails it" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Empty state (SPEC-UI §10 — the one memorable moment)

private struct EmptyDaemonsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 10) {
            Text("🗡")
                .font(.system(size: 44))
                .offset(y: breathe ? -4 : 4)
                .animation(reduceMotion ? nil
                           : .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                           value: breathe)
            Text("No daemons running")
                .font(.title3.weight(.semibold))
            Text("nothing to slay")
                .font(.callout).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !reduceMotion { breathe = true } }
    }
}

// MARK: - Toast (SPEC-UI §6)

private struct ToastView: View {
    let summary: KillPlanner.ToastSummary

    var body: some View {
        VStack(spacing: 2) {
            Text(summary.headline)
                .font(.headline)
                .monospacedDigit()
            if let detail = summary.detail {
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(radius: 8, y: 2)
    }
}
