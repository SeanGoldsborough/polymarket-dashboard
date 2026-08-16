//
//  SettingsSheet.swift
//  PocketTrackpad
//
//  Everything that is not the trackpad, behind one sheet with four tabs.
//
//  A single outer `NavigationStack` wraps the `TabView` rather than each tab
//  carrying its own. That gives one "Done" button and one navigation title bar
//  for the whole sheet — matching the reference design — and it means the push
//  to Diagnostics comes from a stack that is guaranteed to exist regardless of
//  what the individual tab views do internally.
//

import SwiftUI

@MainActor
public struct SettingsSheet: View {

    /// The four tabs, in the order they appear in the tab bar.
    public enum Tab: String, CaseIterable, Identifiable, Hashable {
        case connection, general, remotes, about

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .connection: return "Connection"
            case .general:    return "General"
            case .remotes:    return "Remotes"
            case .about:      return "About"
            }
        }

        /// SF Symbols chosen to read at tab-bar size: the radiowaves glyph is
        /// the standard "this is a wireless link" idiom, and `av.remote` is the
        /// only remote-control symbol that stays legible at 22 pt.
        public var systemImage: String {
            switch self {
            case .connection: return "antenna.radiowaves.left.and.right"
            case .general:    return "gearshape"
            case .remotes:    return "av.remote"
            case .about:      return "info.circle"
            }
        }
    }

    private let runtime: AppRuntime

    @State private var selection: Tab
    @State private var showingDiagnostics: Bool

    @Environment(\.dismiss) private var dismiss

    public init(runtime: AppRuntime, initialTab: Tab = .connection, opensDiagnostics: Bool = false) {
        self.runtime = runtime
        _selection = State(initialValue: initialTab)
        _showingDiagnostics = State(initialValue: opensDiagnostics)
    }

    public var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                tabContent(.connection) {
                    ConnectionView(peripheral: runtime.sender, settings: runtime.settings)
                }
                tabContent(.general) {
                    GeneralSettingsView(settings: runtime.settings)
                }
                tabContent(.remotes) {
                    RemotesListView(
                        store: runtime.remotes,
                        sender: runtime.sender,
                        settings: runtime.settings
                    )
                }
                tabContent(.about) {
                    AboutView()
                }
            }
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selection == .connection {
                        Button {
                            showingDiagnostics = true
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                        .accessibilityLabel("HID diagnostics")
                        .accessibilityHint("Probe which report layouts this iPhone can publish and this Mac accepts.")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            // Attached to the TabView, not to an individual tab: a
            // `navigationDestination` declared inside a tab is only registered
            // while that tab is on screen, which makes programmatic pushes drop
            // silently when the sheet opens on a different tab.
            .navigationDestination(isPresented: $showingDiagnostics) {
                DiagnosticsView(
                    diagnostics: runtime.diagnostics,
                    settings: runtime.settings,
                    isRadioStubbed: runtime.isRadioStubbed
                )
            }
        }
    }

    /// One tab: the sibling-owned screen, on the themed page background, with
    /// the tab-bar item attached.
    private func tabContent<Content: View>(
        _ tab: Tab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .themedPage()
            .tabItem {
                Label(tab.title, systemImage: tab.systemImage)
            }
            .tag(tab)
    }
}

// MARK: - Preview

#Preview("Settings") {
    SettingsSheet(runtime: AppRuntime(settings: AppSettings(defaults: .previewDefaults)))
}

#Preview("Settings — opened at Diagnostics") {
    SettingsSheet(
        runtime: AppRuntime(settings: AppSettings(defaults: .previewDefaults)),
        initialTab: .connection,
        opensDiagnostics: true
    )
}
