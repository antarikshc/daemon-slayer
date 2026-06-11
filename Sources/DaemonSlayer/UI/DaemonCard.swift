import SwiftUI

/// One daemon card (SPEC-UI §10): a rounded-rect row on grouped material, a 2-line
/// dense layout matching the spec mock. Title line: kind glyph + name + verdict
/// chip. Detail line: pid · RSS · CPU · uptime/busy · client, all monospaced-digit
/// so columns don't jitter on the 2 s tick. The Kill button is hover-revealed (see
/// note below). Stays THIN — labels come from already-derived row values; the kill
/// action closure is supplied by the parent, which owns the friction routing.
struct DaemonCard: View {
    let row: DaemonRow
    let killInFlight: Bool
    let onKill: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleLine
            detailLine
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06)))
        .onHover { hovering = $0 }
    }

    private var titleLine: some View {
        HStack(spacing: 8) {
            Text(kindGlyph).font(.system(size: 13))
            Text(row.displayName).font(.system(.body, design: .default)).fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 8)
            VerdictChip(verdict: row.verdict)
        }
    }

    private var detailLine: some View {
        HStack(spacing: 0) {
            Text(metricsLine)
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            killAffordance
        }
    }

    // Hover-reveals the Kill button. DECISION: hover-only keeps the card clean and
    // Activity-Monitor-dense, but discoverability matters for a destructive tool —
    // so the button reserves its space always (no layout jump) and a flagged/orphan
    // row keeps it faintly visible even unhovered (the everyday action shouldn't
    // hide). Owned/busy rows reveal on hover (you must mean it).
    @ViewBuilder
    private var killAffordance: some View {
        let isFlagged = KillPlanner.isFlagged(row)
        let visible = hovering || isFlagged
        Button(action: onKill) {
            Text(killLabel)
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.borderless)
        .tint(.slayerCrimson)
        .disabled(killInFlight)
        .opacity(visible ? 1 : 0)
        .help(killHelp)
    }

    /// "Kill…" when a dialog follows (owned/busy), "Kill" for the one-click path.
    private var killLabel: String {
        KillPlanner.planRow(row).friction == .none ? "Kill" : "Kill…"
    }

    private var killHelp: String {
        switch KillPlanner.planRow(row).friction {
        case .none: return "Kill this daemon"
        case .ownedWarning: return "Owned — confirm before killing"
        case .busyWarning: return "Running a build — confirm before killing"
        }
    }

    /// Disclosure-style kind glyph (§10): ▶ gradle, ▷ kotlin, ⚠ orphaned.
    private var kindGlyph: String {
        if KillPlanner.isFlagged(row) { return "⚠" }
        switch row.kind {
        case .gradle: return "▶"
        case .kotlin: return "▷"
        }
    }

    private var metricsLine: String {
        var parts = ["pid \(row.identity.pid)", Format.bytes(row.rssBytes)]
        parts.append("CPU \(row.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")")
        if row.busyNow, let since = row.busySince {
            parts.append("busy ≥ \(Format.duration(Date().timeIntervalSince(since)))")
        } else {
            parts.append("idle \(Format.duration(row.uptime))")
        }
        if let client = row.attachedClientDescription { parts.append(client) }
        if let agent = divergentAgentStatus { parts.append(agent) }
        return parts.joined(separator: " · ")
    }

    /// Agent state shown ONLY when it diverges from the live verdict (§10), e.g. the
    /// agent has SNOOZED a daemon the live view sees as flagged. Surfaced verbatim
    /// from state.json. We show it when the agent has an explicit non-"healthy",
    /// non-"flagged(...)" opinion (snoozed/ignored/killing) — those are the states
    /// the live verdict can't express on its own.
    private var divergentAgentStatus: String? {
        guard let desc = row.agentStateDescription else { return nil }
        let lower = desc.lowercased()
        if lower.hasPrefix("snoozed") { return "SNOOZED" }
        if lower == "ignored" { return "IGNORED" }
        if lower == "killing" { return "agent: killing" }
        return nil
    }
}

// MARK: - Verdict chip (SPEC-UI §10 / design brief)

/// A rounded capsule for the row's display verdict. Semantic, adaptive colors; the
/// only looping animation in the app is the BUSY dot's breathing (disabled under
/// Reduce Motion). "slayer crimson" is reserved for ORPHAN so red always means
/// "something dies".
struct VerdictChip: View {
    let verdict: DisplayVerdict
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            if case .busy = verdict { busyDot }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundColor(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }

    private var busyDot: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1 : (pulse ? 0.3 : 1))
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                       value: pulse)
            .onAppear { if !reduceMotion { pulse = true } }
    }

    private var label: String {
        switch verdict {
        case .busy: return "BUSY"
        case .owned(let tag): return tag.map { "owned (\($0))" } ?? "owned"
        case .flagged(let rule): return "ORPHAN (\(rule.shortName))"
        case .watching(let n, let m): return "watching \(n)/\(m)"
        case .healthy: return "idle"
        case .unknown: return "unknown"
        }
    }

    private var tint: Color {
        switch verdict {
        case .busy: return .orange
        case .owned: return .green
        case .flagged: return .slayerCrimson
        case .watching: return .secondary
        case .healthy: return .secondary
        case .unknown: return .secondary
        }
    }
}

// MARK: - Shared styling

extension Color {
    /// The signature accent — a deep "slayer crimson" reserved exclusively for kill
    /// affordances and ORPHAN tags (design brief), adaptive for light/dark.
    static let slayerCrimson = Color(
        light: Color(red: 0xC9 / 255, green: 0x2A / 255, blue: 0x2A / 255),
        dark: Color(red: 0xF0 / 255, green: 0x3E / 255, blue: 0x3E / 255))

    /// Build an adaptive color from a light + dark variant (macOS 13 NSColor bridge).
    init(light: Color, dark: Color) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

extension View {
    /// Small-caps, tracking-spaced section header (DAEMONS, SETTINGS) — design brief.
    func sectionHeaderStyle() -> some View {
        self.font(.system(size: 12, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundColor(.secondary)
    }
}
