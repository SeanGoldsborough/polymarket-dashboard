//
//  KeyboardAccessoryView.swift
//  PocketTrackpad
//
//  The modifier and utility rows that sit between the mouse buttons and the
//  system keyboard: sticky modifiers, caps lock, secure-entry toggle, paste,
//  and an Aa / Fn / ▶ switcher.
//
//  The latched modifier set lives on `KeyboardBridge`, which `HiddenKeyboardField`
//  reads when it builds an outgoing report — this view never talks to the radio
//  for ordinary keystrokes, it only changes what the next keystroke carries.
//

import SwiftUI
import UIKit

// MARK: - Mode

/// Which extra key bank is showing under the utility rows.
enum KeyboardAccessoryMode: String, CaseIterable, Identifiable {
    case letters
    case function
    case media

    var id: String { rawValue }

    /// Compact label, matching the reference app's segmented control.
    var shortTitle: String {
        switch self {
        case .letters:  return "Aa"
        case .function: return "Fn"
        case .media:    return "▶"
        }
    }

    /// Spelled out for VoiceOver, where "Aa" and "▶" are useless.
    var accessibilityTitle: String {
        switch self {
        case .letters:  return "Letters"
        case .function: return "Function keys"
        case .media:    return "Media controls"
        }
    }
}

// MARK: - Key descriptors

private struct ModifierKeySpec: Identifiable {
    let modifier: KeyModifiers
    let title: String
    let symbol: String

    var id: UInt8 { modifier.rawValue }

    static let all: [ModifierKeySpec] = [
        ModifierKeySpec(modifier: .leftShift,   title: "shift",   symbol: "shift"),
        ModifierKeySpec(modifier: .leftControl, title: "control", symbol: "control"),
        ModifierKeySpec(modifier: .leftOption,  title: "option",  symbol: "option"),
        ModifierKeySpec(modifier: .leftCommand, title: "command", symbol: "command")
    ]
}

private struct MediaKeySpec: Identifiable {
    let usage: ConsumerUsage
    let symbol: String
    let label: String

    var id: UInt16 { usage.rawValue }

    static let all: [MediaKeySpec] = [
        MediaKeySpec(usage: .scanPrevious,     symbol: "backward.end.fill",  label: "Previous track"),
        MediaKeySpec(usage: .playPause,        symbol: "playpause.fill",     label: "Play or pause"),
        MediaKeySpec(usage: .scanNext,         symbol: "forward.end.fill",   label: "Next track"),
        MediaKeySpec(usage: .mute,             symbol: "speaker.slash.fill", label: "Mute"),
        MediaKeySpec(usage: .volumeDown,       symbol: "speaker.wave.1.fill", label: "Volume down"),
        MediaKeySpec(usage: .volumeUp,         symbol: "speaker.wave.3.fill", label: "Volume up"),
        MediaKeySpec(usage: .brightnessDown,   symbol: "sun.min.fill",       label: "Brightness down"),
        MediaKeySpec(usage: .brightnessUp,     symbol: "sun.max.fill",       label: "Brightness up"),
        MediaKeySpec(usage: .acDesktopShowAll, symbol: "square.grid.2x2",    label: "Mission Control")
    ]
}

private struct NavigationKeySpec: Identifiable {
    let usage: UInt8
    let symbol: String?
    let title: String?
    let label: String

    var id: UInt8 { usage }

    static let all: [NavigationKeySpec] = [
        NavigationKeySpec(usage: TrackpadKeyUsage.escape,     symbol: nil, title: "esc", label: "Escape"),
        NavigationKeySpec(usage: TrackpadKeyUsage.tab,        symbol: "arrow.right.to.line", title: nil, label: "Tab"),
        NavigationKeySpec(usage: TrackpadKeyUsage.leftArrow,  symbol: "arrow.left",  title: nil, label: "Left arrow"),
        NavigationKeySpec(usage: TrackpadKeyUsage.downArrow,  symbol: "arrow.down",  title: nil, label: "Down arrow"),
        NavigationKeySpec(usage: TrackpadKeyUsage.upArrow,    symbol: "arrow.up",    title: nil, label: "Up arrow"),
        NavigationKeySpec(usage: TrackpadKeyUsage.rightArrow, symbol: "arrow.right", title: nil, label: "Right arrow")
    ]
}

// MARK: - Key style

/// Shared look for every key in the accessory: a white card that darkens on
/// press and turns blue once latched.
private struct AccessoryKeyStyle: ButtonStyle {
    var isLatched: Bool = false
    var isLocked: Bool = false
    var isEnabled: Bool = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .frame(minHeight: 42)
            .foregroundStyle(isLatched ? Color.white : Color.primary)
            .background(shape.fill(fill(pressed: configuration.isPressed)))
            .overlay(shape.strokeBorder(isLocked ? Color.accentColor : Color.clear, lineWidth: 2))
            .shadow(color: .black.opacity(configuration.isPressed ? 0.03 : 0.10),
                    radius: 1, x: 0, y: 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isLatched)
    }

    private func fill(pressed: Bool) -> Color {
        if isLatched {
            return Color.accentColor.opacity(pressed ? 0.75 : 1)
        }
        return pressed
            ? Color(.systemFill)
            : Color(.secondarySystemGroupedBackground)
    }
}

// MARK: - Accessory

/// Modifier and utility rows shown above the system keyboard.
@MainActor
struct KeyboardAccessoryView: View {

    @Bindable var bridge: KeyboardBridge
    let settings: AppSettings

    @State private var mode: KeyboardAccessoryMode = .letters
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(bridge: KeyboardBridge, settings: AppSettings) {
        self.bridge = bridge
        self.settings = settings
    }

    var body: some View {
        VStack(spacing: 8) {
            modifierRow
            utilityRow
            modeSwitcher
            modeContent
            if let progress = bridge.pasteProgress {
                pasteIndicator(progress)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
        .disabled(!bridge.isConnected)
    }

    // MARK: Rows

    private var modifierRow: some View {
        HStack(spacing: 6) {
            ForEach(ModifierKeySpec.all) { spec in
                let state = bridge.latchState(for: spec.modifier)
                Button {
                    bridge.cycleLatch(for: spec.modifier)
                } label: {
                    Label(spec.title, systemImage: spec.symbol)
                        .labelStyle(.keyLabel)
                }
                .buttonStyle(AccessoryKeyStyle(isLatched: state != .off,
                                               isLocked: state == .locked,
                                               isEnabled: bridge.isConnected))
                .accessibilityLabel(spec.title)
                .accessibilityValue(accessibilityValue(for: state))
                .accessibilityHint("Applies to the next key you type. Tap again to lock.")
                .accessibilityAddTraits(state != .off ? .isSelected : [])
            }
        }
    }

    private var utilityRow: some View {
        HStack(spacing: 6) {
            Button {
                bridge.toggleCapsLock()
            } label: {
                Label("caps", systemImage: "capslock")
                    .labelStyle(.keyLabel)
            }
            .buttonStyle(AccessoryKeyStyle(isLatched: bridge.isCapsLockEngaged,
                                           isEnabled: bridge.isConnected))
            .accessibilityLabel("Caps lock")
            .accessibilityValue(bridge.isCapsLockEngaged ? "On" : "Off")
            .accessibilityAddTraits(bridge.isCapsLockEngaged ? .isSelected : [])

            Button {
                bridge.masksTypedText.toggle()
                bridge.impact(.light)
            } label: {
                Label(bridge.masksTypedText ? "hidden" : "visible",
                      systemImage: bridge.masksTypedText ? "eye.slash" : "eye")
                    .labelStyle(.keyLabel)
            }
            .buttonStyle(AccessoryKeyStyle(isLatched: bridge.masksTypedText,
                                           isEnabled: bridge.isConnected))
            .accessibilityLabel("Hide what you type")
            .accessibilityValue(bridge.masksTypedText ? "On" : "Off")
            .accessibilityHint("Turns off predictions and autocorrect for passwords.")
            .accessibilityAddTraits(bridge.masksTypedText ? .isSelected : [])

            Button {
                bridge.pasteClipboard()
                bridge.impact(.medium)
            } label: {
                Label("paste", systemImage: "doc.on.clipboard")
                    .labelStyle(.keyLabel)
            }
            .buttonStyle(AccessoryKeyStyle(isEnabled: bridge.isConnected))
            .accessibilityLabel("Paste clipboard")
            .accessibilityHint("Types the contents of this iPhone's clipboard on the Mac.")
        }
    }

    private var modeSwitcher: some View {
        Picker("Key bank", selection: $mode) {
            ForEach(KeyboardAccessoryMode.allCases) { candidate in
                Text(candidate.shortTitle)
                    .accessibilityLabel(candidate.accessibilityTitle)
                    .tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Key bank")
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .letters:  navigationStrip
        case .function: functionKeys
        case .media:    mediaStrip
        }
    }

    private var navigationStrip: some View {
        HStack(spacing: 6) {
            ForEach(NavigationKeySpec.all) { spec in
                Button {
                    bridge.send(usage: spec.usage)
                    bridge.impact(.light)
                } label: {
                    if let symbol = spec.symbol {
                        Image(systemName: symbol)
                    } else if let title = spec.title {
                        Text(title)
                    }
                }
                .buttonStyle(AccessoryKeyStyle(isEnabled: bridge.isConnected))
                .accessibilityLabel(spec.label)
            }
        }
    }

    private var functionKeys: some View {
        LazyVGrid(columns: functionColumns, spacing: 6) {
            ForEach(1...12, id: \.self) { number in
                Button {
                    guard let usage = TrackpadKeyUsage.function(number) else { return }
                    bridge.send(usage: usage)
                    bridge.impact(.light)
                } label: {
                    Text(verbatim: "F\(number)")
                }
                .buttonStyle(AccessoryKeyStyle(isEnabled: bridge.isConnected))
                .accessibilityLabel("Function \(number)")
            }
        }
    }

    private var mediaStrip: some View {
        LazyVGrid(columns: mediaColumns, spacing: 6) {
            ForEach(MediaKeySpec.all) { spec in
                Button {
                    bridge.tapConsumer(spec.usage)
                } label: {
                    Image(systemName: spec.symbol)
                }
                .buttonStyle(AccessoryKeyStyle(isEnabled: bridge.isConnected))
                .accessibilityLabel(spec.label)
            }
        }
    }

    private func pasteIndicator(_ progress: Double) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Button("Stop") { bridge.cancelTyping() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pasting")
        .accessibilityValue("\(Int(progress * 100)) percent complete")
    }

    // MARK: Layout helpers

    /// Six across normally; three across once the user has asked for large
    /// text, so "F10" never has to shrink to fit.
    private var functionColumns: [GridItem] {
        let count = dynamicTypeSize >= .accessibility1 ? 3 : 6
        return Array(repeating: GridItem(.flexible(), spacing: 6), count: count)
    }

    private var mediaColumns: [GridItem] {
        let count = dynamicTypeSize >= .accessibility1 ? 3 : 5
        return Array(repeating: GridItem(.flexible(), spacing: 6), count: count)
    }

    private func accessibilityValue(for state: KeyboardBridge.LatchState) -> String {
        switch state {
        case .off:     return "Off"
        case .oneShot: return "Armed for the next key"
        case .locked:  return "Locked on"
        }
    }
}

// MARK: - Label style

/// Symbol over caption, so a key reads at a glance but still carries its name.
private struct KeyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 2) {
            configuration.icon
                .imageScale(.medium)
            configuration.title
                .font(.system(.caption2, design: .rounded, weight: .medium))
        }
    }
}

private extension LabelStyle where Self == KeyLabelStyle {
    static var keyLabel: KeyLabelStyle { KeyLabelStyle() }
}

// MARK: - Preview

@MainActor
private struct KeyboardAccessoryHarness: View {
    @State private var bridge: KeyboardBridge

    init(connected: Bool) {
        let sender = StubHIDSender(
            connectionState: connected ? .connected(centralName: "Sean's Mac mini") : .idle
        )
        _bridge = State(initialValue: KeyboardBridge(sender: sender, settings: AppSettings()))
    }

    var body: some View {
        VStack {
            Spacer()
            KeyboardAccessoryView(bridge: bridge, settings: AppSettings())
        }
        .background(Color(.systemGroupedBackground))
    }
}

#Preview("Accessory — connected") {
    KeyboardAccessoryHarness(connected: true)
}

#Preview("Accessory — offline") {
    KeyboardAccessoryHarness(connected: false)
}
