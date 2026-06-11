import SwiftUI

/// The pinned health banner (SPEC-UI §7.2 / §10): a status lamp + message + the one
/// contextual action (Pause / Resume / Start). Derivation lives in `BannerDeriver`
/// (pure, M2-tested); this view only renders the derived `BannerState` and routes the
/// three actions back to the model. The "last poll Ns ago" readout ticks off the
/// model's 1 s display clock (armed only while watching, cancelled on hide).
///
/// Design: a status lamp dot (green breathing while watching — Reduce-Motion aware;
/// solid amber paused; solid red dead), material background, consistent with the M3
/// crimson/chip language. The PAUSED banner is deliberately LOUD — it's the nudge to
/// resume — rendered on a filled amber bar rather than the quiet default material.
struct BannerView: View {
    let state: BannerState
    /// nil unless a [Start] kickstart just failed → show the "not installed" guidance.
    let startFailed: Bool
    let busy: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onStart: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusLamp(state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(message)
                    .font(.system(.body, weight: isPaused ? .semibold : .regular))
                    .foregroundColor(messageColor)
                if startFailed, case .dead = state {
                    Text("Agent isn’t installed — run `make install` in the repo to set it up.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            actionButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isPaused ? 11 : 10)
        .background(banner)
    }

    private var isPaused: Bool { state == .paused }

    @ViewBuilder
    private var banner: some View {
        if isPaused {
            // Loud: filled amber bar with a hairline rule beneath.
            Color.slayerAmber.opacity(0.18)
                .overlay(Rectangle().fill(Color.slayerAmber.opacity(0.55)).frame(height: 2),
                         alignment: .bottom)
        } else {
            Color.clear.background(.bar)
        }
    }

    private var message: String {
        switch state {
        case .watching(let ago): return "Watching — last poll \(Format.duration(ago)) ago"
        case .paused: return "PAUSED — daemons are not being watched"
        case .dead: return "Agent not running"
        }
    }

    private var messageColor: Color {
        switch state {
        case .watching: return .primary
        case .paused: return .slayerAmber
        case .dead: return .slayerCrimson
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .watching:
            Button("Pause", action: onPause).disabled(busy)
        case .paused:
            Button("Resume", action: onResume)
                .buttonStyle(.borderedProminent)
                .tint(.slayerAmber)
                .disabled(busy)
        case .dead:
            Button("Start", action: onStart).disabled(busy)
        }
    }
}

// MARK: - Status lamp (SPEC-UI §7.2 design)

/// The lamp dot: green breathing while watching (Reduce-Motion aware), solid amber
/// when paused, solid red when dead. Mirrors the BUSY-dot breathing idiom from M3 so
/// the two "live" animations read as the same language.
private struct StatusLamp: View {
    let state: BannerState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .opacity(breathing && !reduceMotion ? (breathe ? 0.35 : 1) : 1)
            .shadow(color: color.opacity(0.6), radius: breathing ? 3 : 0)
            .animation(breathing && !reduceMotion
                       ? .easeInOut(duration: 2).repeatForever(autoreverses: true) : nil,
                       value: breathe)
            .onAppear { if breathing && !reduceMotion { breathe = true } }
            .onChange(of: breathing) { on in breathe = on && !reduceMotion }
    }

    /// Only the watching (green) lamp breathes; amber/red are solid.
    private var breathing: Bool { if case .watching = state { return true }; return false }

    private var color: Color {
        switch state {
        case .watching: return .green
        case .paused: return .slayerAmber
        case .dead: return .slayerCrimson
        }
    }
}

// MARK: - Shared amber (paused signal)

extension Color {
    /// The paused/warning amber — loud enough to nag, adaptive for light/dark. Sits
    /// alongside `slayerCrimson` (kills) and green (healthy) in the lamp vocabulary.
    static let slayerAmber = Color(
        light: Color(red: 0xB7 / 255, green: 0x7A / 255, blue: 0x00 / 255),
        dark: Color(red: 0xF5 / 255, green: 0xB3 / 255, blue: 0x1F / 255))
}
