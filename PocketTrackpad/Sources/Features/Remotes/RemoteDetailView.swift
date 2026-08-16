//
//  RemoteDetailView.swift
//  PocketTrackpad
//
//  Renders one remote as a grid of large tap targets.
//
//  Layout note: the grid is built from `Remote.gridRows`, which packs buttons
//  into rows honouring each button's `span`, and each row is laid out with
//  `Grid`/`GridRow` + `gridCellColumns(_:)`. `LazyVGrid` cannot express a cell
//  that occupies two columns — `gridCellColumns` is inert inside it — and the
//  span is load-bearing for the keypad's wide 0/Delete/Enter keys. Nothing
//  here is long enough to need laziness: a remote is tens of buttons, not
//  thousands.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public struct RemoteDetailView: View {
    private let remote: Remote
    private let sender: any HIDSending
    private let settings: AppSettings

    public init(remote: Remote, sender: any HIDSending, settings: AppSettings) {
        self.remote = remote
        self.sender = sender
        self.settings = settings
    }

    private var isConnected: Bool { sender.connectionState.isConnected }

    private var disconnectedExplanation: String {
        switch sender.connectionState {
        case .poweredOff:      return "Bluetooth is switched off. Turn it on in Settings to use this remote."
        case .unauthorized:    return "Pocket Trackpad is not allowed to use Bluetooth. Grant access in Settings ▸ Privacy."
        case .unsupported:     return "This device cannot act as a Bluetooth keyboard."
        case .idle:            return "Not advertising. Open the Connection tab and start advertising, then pair from your Mac."
        case .advertising:     return "Waiting for your Mac to connect. Open Bluetooth settings on the Mac and click Connect."
        case .failed(let why): return why
        case .connected:       return ""
        }
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !isConnected {
                    DisconnectedBanner(message: disconnectedExplanation)
                }

                if remote.buttons.isEmpty {
                    ContentUnavailableView(
                        "No Buttons",
                        systemImage: "square.dashed",
                        description: Text("Edit this remote to add buttons.")
                    )
                    .padding(.top, 40)
                } else {
                    grid
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(remote.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var grid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(remote.gridRows.enumerated()), id: \.offset) { pair in
                GridRow {
                    ForEach(pair.element) { button in
                        RemoteButtonView(
                            button: button,
                            isEnabled: isConnected,
                            hapticsEnabled: settings.hapticsEnabled,
                            repeats: button.repeatsWhenHeld
                        ) {
                            perform(button.action, on: sender)
                        }
                        .gridCellColumns(button.effectiveSpan(in: remote.columns))
                    }
                }
            }
        }
        .disabled(!isConnected)
        .accessibilityLabel("\(remote.name) buttons")
    }
}

// MARK: - Banner

private struct DisconnectedBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Not Connected")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Not connected. \(message)")
    }
}

// MARK: - Button

/// Which buttons make sense to hold down. Volume and channel are stepwise and
/// repeat naturally; a power or select key repeating is a bug, not a feature.
extension RemoteButton {
    var repeatsWhenHeld: Bool {
        switch action {
        case .consumer(let usage):
            switch usage {
            case .volumeUp, .volumeDown, .brightnessUp, .brightnessDown,
                 .fastForward, .rewind:
                return true
            case .play, .pause, .stop, .playPause, .scanNext, .scanPrevious,
                 .mute, .acHome, .acBack, .acForward, .acRefresh, .acSearch,
                 .acDesktopShowAll, .power, .sleep:
                return false
            }
        case .key(let usage, _):
            switch usage {
            case HIDKeyCode.upArrow, HIDKeyCode.downArrow,
                 HIDKeyCode.leftArrow, HIDKeyCode.rightArrow,
                 RemoteKeyUsage.pageUp, RemoteKeyUsage.pageDown,
                 RemoteKeyUsage.deleteBackspace:
                return true
            default:
                return false
            }
        case .text, .mouse, .sequence:
            return false
        }
    }
}

/// A remote key.
///
/// Deliberately *not* a `Button`. A remote fires on press, the way a physical
/// one does, and holding volume has to repeat — and a `Button` plus a
/// simultaneous long-press gesture fight over the same touch, so the tap gets
/// swallowed or fires twice. Driving everything from
/// `onLongPressGesture(onPressingChanged:)` gives one source of truth for the
/// press: down fires once, hold repeats, release and cancellation both stop it.
@MainActor
private struct RemoteButtonView: View {
    let button: RemoteButton
    let isEnabled: Bool
    let hapticsEnabled: Bool
    let repeats: Bool
    let fire: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var repeatTask: Task<Void, Never>?
    @State private var isPressed = false

    /// Long enough that a normal tap never trips it, short enough that holding
    /// feels immediate. Then roughly eight steps a second, which is where a
    /// Mac's own key repeat settles.
    private static let repeatDelay = Duration.milliseconds(450)
    private static let repeatInterval = Duration.milliseconds(120)
    /// A press that somehow never reports its release must not repeat forever.
    private static let repeatCeiling = 400

    private var minimumHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 88 : 68
    }

    var body: some View {
        label
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(isPressed ? 0.18 : 0))
            )
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onLongPressGesture(minimumDuration: 60, maximumDistance: 44) {
                // Unreachable in practice: the minimum duration is set past any
                // real press so the gesture never "succeeds" and never ends the
                // press behind our back. All the behaviour is in
                // `onPressingChanged`.
            } onPressingChanged: { pressing in
                pressChanged(to: pressing)
            }
            .onDisappear { stopRepeating() }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(button.accessibilityLabel)
            .accessibilityValue(button.action.summary)
            .accessibilityHint(repeats ? "Sends on press. Touch and hold to repeat." : "Sends on press.")
            .accessibilityAction { trigger() }
    }

    @ViewBuilder
    private var label: some View {
        VStack(spacing: 4) {
            if let symbolName = button.symbolName {
                Image(systemName: symbolName)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                if shouldShowTitleAlongsideSymbol {
                    Text(button.title)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text(button.title)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// A glyph plus its name is clearer, except where the title is only a
    /// restatement of a universally understood transport symbol.
    private var shouldShowTitleAlongsideSymbol: Bool {
        !dynamicTypeSize.isAccessibilitySize
    }

    // MARK: Firing

    private func pressChanged(to pressing: Bool) {
        guard isEnabled else { return }
        isPressed = pressing
        if pressing {
            trigger()
            if repeats { startRepeating() }
        } else {
            stopRepeating()
        }
    }

    private func trigger() {
        fire()
        emitHaptic()
    }

    private func startRepeating() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: RemoteButtonView.repeatDelay)
            var sent = 0
            while !Task.isCancelled && sent < RemoteButtonView.repeatCeiling {
                trigger()
                sent += 1
                try? await Task.sleep(for: RemoteButtonView.repeatInterval)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private func emitHaptic() {
        guard hapticsEnabled else { return }
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
}

// MARK: - Previews

#Preview("Media — Connected") {
    NavigationStack {
        RemoteDetailView(
            remote: .mediaRemote,
            sender: StubHIDSender(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "preview.detail") ?? .standard)
        )
    }
}

#Preview("Keypad — Disconnected") {
    NavigationStack {
        RemoteDetailView(
            remote: .numericKeypad,
            sender: StubHIDSender(connectionState: .advertising, knownCentrals: []),
            settings: AppSettings(defaults: UserDefaults(suiteName: "preview.detail.off") ?? .standard)
        )
    }
}
