import SwiftUI

/// Minimal functional window for M1/M2 (SPEC-UI §10): a placeholder banner row + a
/// plain list of daemon rows. Real visual design lands in M3/M4 — this view stays
/// THIN: every label is computed from the model's already-derived pure values, no
/// logic here.
struct RootView: View {
    @EnvironmentObject private var model: UIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bannerRow
            Divider()
            header
            Divider()
            daemonList
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    // MARK: - Banner (placeholder text; the real banner VIEW is M4)

    private var bannerRow: some View {
        HStack {
            Text(bannerText)
                .font(.system(.body, design: .monospaced))
            Spacer()
        }
        .padding(10)
    }

    private var bannerText: String {
        switch model.banner {
        case .watching(let ago):
            return "● Watching — last poll \(Format.duration(ago)) ago"
        case .paused:
            return "● PAUSED — daemons are not being watched"
        case .dead:
            return "● Agent not running"
        }
    }

    private var header: some View {
        HStack {
            Text("DAEMONS (\(model.rows.count))").font(.headline)
            Spacer()
            if model.ownershipUnknown {
                Text("ownership unknown (lsof failed)").foregroundColor(.secondary).font(.caption)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var daemonList: some View {
        Group {
            if model.rows.isEmpty {
                Spacer()
                Text("No daemons running — nothing to slay 🗡")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(model.rows) { row in
                    DaemonRowView(row: row)
                }
            }
        }
    }
}

/// One plain daemon row (M1/M2: text only). Columns from §10: kind, project, pid,
/// CPU, RSS, uptime, verdict text, client, agent status.
private struct DaemonRowView: View {
    let row: DaemonRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.displayName).bold()
                Spacer()
                Text(verdictText).foregroundColor(.secondary)
            }
            Text(metricsLine).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
            if let client = row.attachedClientDescription {
                Text("client: \(client)").font(.caption).foregroundColor(.secondary)
            }
            if let agent = row.agentStateDescription {
                Text("agent: \(agent)").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var metricsLine: String {
        let cpu = row.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        var line = "pid \(row.identity.pid) · \(Format.bytes(row.rssBytes)) · CPU \(cpu) · up \(Format.duration(row.uptime))"
        if row.busyNow, let since = row.busySince {
            line += " · busy \(Format.duration(Date().timeIntervalSince(since)))"
        }
        return line
    }

    private var verdictText: String {
        switch row.verdict {
        case .busy: return "BUSY"
        case .owned(let tag): return tag.map { "owned (\($0))" } ?? "owned"
        case .flagged(let rule): return "FLAGGED (\(rule.shortName))"
        case .watching(let n, let m): return "watching (\(n)/\(m) polls)"
        case .healthy: return "—"
        case .unknown: return "ownership unknown"
        }
    }
}
