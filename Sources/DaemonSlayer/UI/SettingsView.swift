import SwiftUI

/// The settings section (SPEC-UI §9 / §10): EXACTLY two controls — an "Auto-kill
/// orphans" toggle (`autoKill.enabled`) and a "Snooze duration" minutes stepper
/// (`snoozeMinutes`). Nothing else is exposed. The view is THIN: it binds to local
/// @State seeded from the model's loaded config, and commits each edit through the
/// model's whole-file write path (`ConfigWriter`), which carries every hidden key
/// through untouched. External edits to the file refresh these controls via the
/// model's `settingsRevision` bump.
struct SettingsView: View {
    @EnvironmentObject private var model: UIModel

    // Local editing state, re-seeded whenever the model reloads the config (external
    // edit or post-save). The form never reads/writes the file directly.
    @State private var autoKill = false
    @State private var snoozeMinutes = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").sectionHeaderStyle()

            Toggle(isOn: autoKillBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-kill orphans")
                    Text("Kill flagged orphans without notifying first.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(.slayerCrimson)

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Snooze duration")
                    Text("How long a snoozed daemon stays quiet.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Stepper(value: snoozeBinding, in: snoozeRange) {
                    Text("\(snoozeMinutes) min").monospacedDigit()
                }
                .labelsHidden()
                .fixedSize()
                Text("\(snoozeMinutes) min")
                    .monospacedDigit()
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onAppear(perform: seed)
        // Re-seed on any external/post-save config reload (SPEC-UI §9: form refreshes
        // on external change; saves serialize from the latest loaded struct).
        .onChange(of: model.settingsRevision) { _ in seed() }
    }

    private func seed() {
        let cfg = model.loadedConfig
        autoKill = cfg.autoKill.enabled
        snoozeMinutes = max(Int(ConfigWriter.minSnoozeMinutes), Int(cfg.snoozeMinutes.rounded()))
    }

    // Sane stepper range: ≥ 1 min floor (matches ConfigWriter.minSnoozeMinutes),
    // generous ceiling so a human can't fat-finger past it but never feels boxed in.
    private var snoozeRange: ClosedRange<Int> { Int(ConfigWriter.minSnoozeMinutes)...720 }

    private var autoKillBinding: Binding<Bool> {
        Binding(get: { autoKill },
                set: { autoKill = $0; model.saveSettings(autoKillEnabled: $0, snoozeMinutes: nil) })
    }

    private var snoozeBinding: Binding<Int> {
        Binding(get: { snoozeMinutes },
                set: { snoozeMinutes = $0; model.saveSettings(autoKillEnabled: nil, snoozeMinutes: Double($0)) })
    }
}
