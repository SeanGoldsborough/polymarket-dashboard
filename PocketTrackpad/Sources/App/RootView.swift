//
//  RootView.swift
//  PocketTrackpad
//
//  The app is a single surface — the trackpad — with everything else behind a
//  settings sheet. That is deliberate: this is a device you use while looking
//  at another screen, so the primary view must never be one tap deep, and
//  chrome must never steal vertical space from the touch surface.
//

import SwiftUI

@MainActor
public struct RootView: View {

    private let runtime: AppRuntime

    /// Non-nil while the settings sheet is up. Modelled as an item rather than
    /// a bool so callers can open the sheet *at* a particular tab (and, for the
    /// start-failure banner, straight through to Diagnostics).
    @State private var settingsPresentation: SettingsPresentation?

    public init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    public var body: some View {
        VStack(spacing: 0) {
            // A strip rather than an overlay: `TrackpadView` puts its menu
            // button in the top-left corner, and floating a banner over it
            // would make the only route into settings untappable.
            if hasStatusToShow {
                statusStrip
            }

            TrackpadView(
                sender: runtime.sender,
                settings: runtime.settings,
                onOpenMenu: {
                    settingsPresentation = SettingsPresentation(tab: .connection, opensDiagnostics: false)
                }
            )
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .tint(Theme.accent)
        .sheet(item: $settingsPresentation) { presentation in
            SettingsSheet(
                runtime: runtime,
                initialTab: presentation.tab,
                opensDiagnostics: presentation.opensDiagnostics
            )
        }
    }

    // MARK: Status strip

    private var hasStatusToShow: Bool {
        runtime.isRadioStubbed || runtime.lastStartError != nil
    }

    /// Status that must be visible without opening settings: the Simulator
    /// substitution, and a radio that refused to publish.
    private var statusStrip: some View {
        VStack(spacing: 10) {
            if runtime.isRadioStubbed {
                StubbedRadioBadge()
            }
            if let error = runtime.lastStartError {
                startFailureBanner(error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func startFailureBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(Theme.danger)
                Text("The radio could not publish its HID service")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
            }

            // Verbatim. A friendly paraphrase of this string would destroy the
            // only evidence of which layout iOS rejected and why.
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button("Open Diagnostics") {
                    settingsPresentation = SettingsPresentation(tab: .connection, opensDiagnostics: true)
                }
                .buttonStyle(.secondaryCapsule)

                Button("Dismiss") {
                    runtime.clearStartError()
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(14)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Theme.cardShadow, radius: Theme.cardShadowRadius, y: Theme.cardShadowOffsetY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Radio error")
        .accessibilityHint("The HID service was rejected. Open Diagnostics to find a layout that works.")
    }
}

// MARK: - Sheet routing

/// Which tab the settings sheet should open on, and whether it should push
/// straight through to Diagnostics.
struct SettingsPresentation: Identifiable {
    let id = UUID()
    var tab: SettingsSheet.Tab
    var opensDiagnostics: Bool
}

// MARK: - Preview

#Preview("Root") {
    RootView(runtime: AppRuntime(settings: AppSettings(defaults: .previewDefaults)))
}

// MARK: - Preview support

extension UserDefaults {
    /// A throwaway defaults domain so previews never write into the real app's
    /// preferences (and so two previews cannot fight over the same keys).
    static var previewDefaults: UserDefaults {
        UserDefaults(suiteName: "PocketTrackpad.preview.\(UUID().uuidString)") ?? .standard
    }
}
