//
//  GeneralSettingsView.swift
//  PocketTrackpad
//
//  The General tab: three sensitivity cards, the natural-scrolling switch, the
//  appearance control, and an Advanced disclosure holding the advertised name
//  and the route to Diagnostics.
//
//  Sliders are normalised 0...1 — `PointerEngine` and `ScrollEngine` own the
//  mapping onto real gain, so this screen never talks in device units.
//

import SwiftUI

public struct GeneralSettingsView: View {
    @Bindable private var settings: AppSettings

    @State private var isAdvancedExpanded = false
    @FocusState private var isNameFieldFocused: Bool

    public init(settings: AppSettings) {
        _settings = Bindable(settings)
    }

    public var body: some View {
        List {
            Section {
                SensitivitySlider(
                    value: $settings.tracking,
                    accessibilityLabel: "Tracking speed",
                    slowestHint: "Slower pointer",
                    fastestHint: "Faster pointer"
                )
            } header: {
                SectionHeader("Tracking")
            } footer: {
                Text("How far the pointer travels for a given finger movement.")
            }

            Section {
                SensitivitySlider(
                    value: $settings.motion,
                    accessibilityLabel: "Motion acceleration",
                    slowestHint: "Less acceleration",
                    fastestHint: "More acceleration"
                )
            } header: {
                SectionHeader("Motion")
            } footer: {
                Text("How strongly a fast flick is amplified beyond a slow drag.")
            }

            Section {
                SensitivitySlider(
                    value: $settings.scrolling,
                    accessibilityLabel: "Scrolling speed",
                    slowestHint: "Slower scrolling",
                    fastestHint: "Faster scrolling"
                )

                Toggle(isOn: $settings.naturalScrolling) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Natural Scrolling")
                        Text("Content tracks finger movement")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Natural scrolling")
                .accessibilityValue(settings.naturalScrolling
                                    ? "On, content tracks finger movement"
                                    : "Off, content moves opposite the finger")
            } header: {
                SectionHeader("Scrolling")
            }

            Section {
                Picker(selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Appearance")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Appearance")
                .accessibilityValue(settings.appearance.title)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                SectionHeader("Appearance")
            }

            Section {
                Toggle(isOn: $settings.hapticsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Haptic Feedback")
                        Text("A tap on every button press")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Haptic feedback")
                .accessibilityValue(settings.hapticsEnabled ? "On" : "Off")
            } header: {
                SectionHeader("Feedback")
            }

            Section {
                DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Device Name")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        TextField("Device Name", text: $settings.advertisedName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($isNameFieldFocused)
                            .onSubmit { isNameFieldFocused = false }
                            .accessibilityLabel("Advertised device name")
                            .accessibilityValue(settings.advertisedName.isEmpty
                                                ? "Not set"
                                                : settings.advertisedName)

                        Text("The name your Mac shows in its Bluetooth list.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if settings.advertisedName != AppSettings.defaultAdvertisedName {
                            Button("Use Device Name") {
                                settings.advertisedName = AppSettings.defaultAdvertisedName
                                isNameFieldFocused = false
                            }
                            .font(.footnote)
                            .accessibilityHint("Resets the advertised name to \(AppSettings.defaultAdvertisedName)")
                        }
                    }
                    .padding(.vertical, 4)

                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                    .accessibilityHint("Probes which Bluetooth report layout this Mac accepts")
                } label: {
                    Label("Advanced", systemImage: "gearshape.2")
                        .accessibilityLabel("Advanced")
                        .accessibilityHint(isAdvancedExpanded ? "Expanded" : "Collapsed")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    private let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .textCase(.uppercase)
    }
}

// MARK: - Sensitivity slider

/// Tortoise-to-hare slider. The glyphs are decoration — they are hidden from
/// VoiceOver, which instead hears the control's purpose and a word for where
/// it currently sits, because "50 percent" of an unnamed scale says nothing.
///
/// No numeric read-out is drawn: the reference layout has none, and a value
/// label would push the row past the card's height at large Dynamic Type
/// sizes for no gain. The word is carried in the accessibility value instead.
private struct SensitivitySlider: View {
    @Binding var value: Double
    let accessibilityLabel: String
    let slowestHint: String
    let fastestHint: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var descriptor: String {
        switch value {
        case ..<0.15:  return "Slowest"
        case ..<0.40:  return "Slow"
        case ..<0.60:  return "Medium"
        case ..<0.85:  return "Fast"
        default:       return "Fastest"
        }
    }

    private var slider: some View {
        Slider(value: $value, in: 0...1)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(descriptor)
            .accessibilityHint("Swipe up for \(fastestHint.lowercased()), down for \(slowestHint.lowercased()).")
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // At accessibility sizes the glyphs and the track no longer fit
                // on one line without shrinking the track to uselessness.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        glyph("tortoise")
                        Spacer()
                        glyph("hare")
                    }
                    slider
                }
            } else {
                HStack(spacing: 14) {
                    glyph("tortoise")
                    slider
                    glyph("hare")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .imageScale(.large)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview("General") {
    NavigationStack {
        GeneralSettingsView(settings: AppSettings(defaults: UserDefaults(suiteName: "preview.general") ?? .standard))
    }
}

#Preview("General — Accessibility Sizes") {
    NavigationStack {
        GeneralSettingsView(settings: AppSettings(defaults: UserDefaults(suiteName: "preview.general.ax") ?? .standard))
    }
    .environment(\.dynamicTypeSize, .accessibility2)
}
