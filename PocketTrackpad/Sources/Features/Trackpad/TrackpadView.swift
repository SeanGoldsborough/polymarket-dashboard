//
//  TrackpadView.swift
//  PocketTrackpad
//
//  The trackpad screen: touch surface, mouse buttons, and the keyboard stack.
//
//  ASSUMED SIBLING API (Sources/Input)
//  ----------------------------------
//      final class PointerEngine {
//          init()
//          var tracking: Double
//          var motion: Double
//          func begin(); func end()
//          func consume(_ s: TouchSample) -> (dx: Int, dy: Int)
//          func drain() -> (dx: Int, dy: Int)?
//      }
//      final class ScrollEngine {
//          init()
//          var scrolling: Double
//          var natural: Bool
//          func begin(); func end()
//          func consume(_ s: TouchSample) -> (wheel: Int, pan: Int)
//          func momentumTick() -> (wheel: Int, pan: Int)?
//      }
//      final class GestureState {
//          init(pointer: PointerEngine, scroll: ScrollEngine)
//          var onEvent: ((GestureEvent) -> Void)?
//          ...
//      }
//      enum Direction { case up, down, left, right }
//
//  `GestureState` owns the sample-to-event translation; this file owns the
//  event-to-report translation, the overflow pump, and momentum.
//

import SwiftUI
import UIKit
import Observation

// MARK: - Display link

/// A `CADisplayLink` wrapped so the controller does not have to be an NSObject.
///
/// Momentum has to be driven from the display's clock rather than a `Timer`:
/// a repeating Timer drifts and coalesces under load, which makes the deceleration
/// visibly stutter, whereas the display link fires in step with the frames the
/// user is actually watching.
@MainActor
final class TrackpadDisplayLink: NSObject {

    private var link: CADisplayLink?
    private let onTick: @MainActor () -> Void

    init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
        super.init()
    }

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleTick))
        // Ask for a steady 60 and let ProMotion go higher if it is free.
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        // `.common` so the link keeps firing while a gesture is tracking.
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func handleTick() {
        onTick()
    }
}

// MARK: - Controller

/// Owns the input engines and turns `GestureEvent`s into HID reports.
@MainActor
@Observable
final class TrackpadController {

    /// Safety valve on the overflow pump. A single gesture frame should never
    /// need more than a handful of Int8-clamped reports; if the engine keeps
    /// handing back work we stop rather than block the main thread.
    private static let drainLimit = 32

    /// Pointer pixels per wheel detent when one-finger scroll mode is on.
    private static let scrollModeDivisor = 8

    @ObservationIgnored let sender: HIDSending
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let pointer: PointerEngine
    @ObservationIgnored let scroll: ScrollEngine
    @ObservationIgnored let gestures: GestureState

    /// Shared with the accessory rows and the invisible capture field.
    let keyboard: KeyboardBridge

    /// Mouse buttons currently held. Every outgoing report carries these so a
    /// click-and-drag survives the pointer moving.
    private(set) var heldButtons: MouseButtons = []

    /// One-finger drag scrolls instead of moving the pointer.
    var isScrollModeEnabled = false

    /// The system keyboard and accessory rows are showing.
    var isKeyboardVisible = false

    @ObservationIgnored private var momentumLink: TrackpadDisplayLink?
    @ObservationIgnored private var rockerTask: Task<Void, Never>?
    @ObservationIgnored private var scrollModeRemainder: (x: Int, y: Int) = (0, 0)

    init(sender: HIDSending, settings: AppSettings) {
        let pointer = PointerEngine()
        let scroll = ScrollEngine()
        self.sender = sender
        self.settings = settings
        self.pointer = pointer
        self.scroll = scroll
        self.gestures = GestureState(pointer: pointer, scroll: scroll)
        self.keyboard = KeyboardBridge(sender: sender, settings: settings)
        applySettings()
    }

    // MARK: State

    var connectionState: HIDConnectionState { sender.connectionState }

    var isInputEnabled: Bool { sender.connectionState.isConnected }

    /// Copy the user's normalised preferences onto the engines. The engines own
    /// the curve that maps 0...1 onto real gain, so this is a straight handoff.
    func applySettings() {
        pointer.tracking = settings.tracking
        pointer.motion = settings.motion
        scroll.scrolling = settings.scrolling
        scroll.natural = settings.naturalScrolling
    }

    // MARK: Event routing

    func handle(_ event: GestureEvent) {
        guard isInputEnabled else { return }
        switch event {
        case .move(let dx, let dy):
            handleMove(dx: dx, dy: dy)
        case .scroll(let wheel, let pan):
            send(wheel: wheel, pan: pan)
            // The engine decides whether there is any momentum left; starting
            // the link here means the glide begins on the very next frame after
            // the finger lifts instead of one event late.
            startMomentum()
        case .button(let button, down: let isDown):
            setButton(button, down: isDown)
        case .swipe(let direction):
            perform(swipe: direction)
        }
    }

    private func handleMove(dx: Int, dy: Int) {
        if isScrollModeEnabled {
            var totalX = dx
            var totalY = dy
            var pumped = 0
            while pumped < Self.drainLimit, let overflow = pointer.drain() {
                totalX += overflow.dx
                totalY += overflow.dy
                pumped += 1
            }
            sendScrollFromPointer(dx: totalX, dy: totalY)
            return
        }

        sender.send(mouse: MouseReport(buttons: heldButtons, dx: dx, dy: dy))

        // A HID mouse report carries one signed byte per axis. Anything past
        // ±127 is held back by the engine and handed over a report at a time,
        // so pump until it says it has nothing left — otherwise a fast flick
        // arrives truncated and the pointer undershoots.
        var pumped = 0
        while pumped < Self.drainLimit, let overflow = pointer.drain() {
            sender.send(mouse: MouseReport(buttons: heldButtons, dx: overflow.dx, dy: overflow.dy))
            pumped += 1
        }
    }

    /// One-finger scroll mode: pointer deltas are far finer than wheel detents,
    /// so accumulate and emit a detent every `scrollModeDivisor` points, keeping
    /// the remainder rather than throwing it away.
    private func sendScrollFromPointer(dx: Int, dy: Int) {
        scrollModeRemainder.x += dx
        scrollModeRemainder.y += dy

        let pan = scrollModeRemainder.x / Self.scrollModeDivisor
        let steps = scrollModeRemainder.y / Self.scrollModeDivisor
        guard pan != 0 || steps != 0 else { return }

        scrollModeRemainder.x -= pan * Self.scrollModeDivisor
        scrollModeRemainder.y -= steps * Self.scrollModeDivisor

        // Dragging down should push content down under natural scrolling and
        // pull it up otherwise, matching the wheel's sign convention.
        let wheel = settings.naturalScrolling ? steps : -steps
        send(wheel: wheel, pan: pan)
    }

    private func send(wheel: Int, pan: Int) {
        guard wheel != 0 || pan != 0 else { return }
        sender.send(mouse: MouseReport(buttons: heldButtons, wheel: wheel, pan: pan))
    }

    private func setButton(_ button: MouseButtons, down: Bool) {
        guard !button.isEmpty else { return }
        if down {
            heldButtons.formUnion(button)
        } else {
            heldButtons.subtract(button)
        }
        sender.send(mouse: MouseReport(buttons: heldButtons))
        impact(down ? .medium : .light)
    }

    private func perform(swipe direction: Direction) {
        switch direction {
        case .up:
            // Mission Control.
            sender.tap(consumer: .acDesktopShowAll)
        case .down:
            // Application windows — macOS's Control+Down.
            sender.tap(key: TrackpadKeyUsage.downArrow, modifiers: .leftControl)
        case .left:
            sender.tap(key: TrackpadKeyUsage.rightArrow, modifiers: .leftControl)
        case .right:
            sender.tap(key: TrackpadKeyUsage.leftArrow, modifiers: .leftControl)
        }
        impact(.medium)
    }

    // MARK: Momentum

    private func startMomentum() {
        if momentumLink == nil {
            momentumLink = TrackpadDisplayLink { [weak self] in self?.momentumTick() }
        }
        momentumLink?.start()
    }

    func stopMomentum() {
        momentumLink?.stop()
    }

    private func momentumTick() {
        guard isInputEnabled, let step = scroll.momentumTick() else {
            stopMomentum()
            return
        }
        guard step.wheel != 0 || step.pan != 0 else {
            stopMomentum()
            return
        }
        sender.send(mouse: MouseReport(buttons: heldButtons, wheel: step.wheel, pan: step.pan))
    }

    // MARK: Buttons and rocker

    func pressButton(_ button: MouseButtons) { setButton(button, down: true) }

    func releaseButton(_ button: MouseButtons) { setButton(button, down: false) }

    /// A single detent from the middle rocker. `steps` is positive for up.
    func rockerStep(_ steps: Int) {
        guard isInputEnabled else { return }
        send(wheel: steps, pan: 0)
        impact(.light)
    }

    /// Press-and-hold on the rocker: one immediate detent, a pause so a tap is
    /// not misread as a hold, then a steady repeat.
    func beginRockerHold(_ steps: Int) {
        endRockerHold()
        rockerStep(steps)
        rockerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            while !Task.isCancelled {
                guard let self, self.isInputEnabled else { return }
                self.rockerStep(steps)
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    func endRockerHold() {
        rockerTask?.cancel()
        rockerTask = nil
    }

    // MARK: Lifecycle

    /// Leave nothing latched on the host when the screen goes away.
    func teardown() {
        endRockerHold()
        stopMomentum()
        keyboard.cancelTyping()
        keyboard.releaseAllHardwareKeys()
        if !heldButtons.isEmpty {
            heldButtons = []
            sender.send(mouse: MouseReport())
        }
        scrollModeRemainder = (0, 0)
    }

    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard settings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Screen

/// The trackpad screen.
@MainActor
struct TrackpadView: View {

    @State private var controller: TrackpadController
    private let onOpenMenu: () -> Void
    private let settings: AppSettings

    @ScaledMetric(relativeTo: .body) private var buttonRowHeight: CGFloat = 74
    @ScaledMetric(relativeTo: .body) private var rockerWidth: CGFloat = 78

    init(sender: HIDSending,
         settings: AppSettings = .shared,
         onOpenMenu: @escaping () -> Void = {}) {
        self.settings = settings
        self.onOpenMenu = onOpenMenu
        _controller = State(initialValue: TrackpadController(sender: sender, settings: settings))
    }

    var body: some View {
        VStack(spacing: 10) {
            topBar
            padArea
                .layoutPriority(1)
            buttonRow
                .frame(height: buttonRowHeight)
            if controller.isKeyboardVisible {
                KeyboardAccessoryView(bridge: controller.keyboard, settings: settings)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .bottomTrailing) {
            // Must stay in the hierarchy and stay visible (if only barely) for
            // `becomeFirstResponder` to work.
            HiddenKeyboardField(bridge: controller.keyboard, isActive: keyboardBinding)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(.easeOut(duration: 0.2), value: controller.isKeyboardVisible)
        .onChange(of: settings.tracking) { controller.applySettings() }
        .onChange(of: settings.motion) { controller.applySettings() }
        .onChange(of: settings.scrolling) { controller.applySettings() }
        .onChange(of: settings.naturalScrolling) { controller.applySettings() }
        .onChange(of: controller.isInputEnabled) { _, enabled in
            if !enabled { controller.teardown() }
        }
        .onDisappear { controller.teardown() }
    }

    private var keyboardBinding: Binding<Bool> {
        Binding(get: { controller.isKeyboardVisible },
                set: { controller.isKeyboardVisible = $0 })
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onOpenMenu) {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Menu")
            .accessibilityHint("Opens settings, diagnostics and the device list.")

            Spacer(minLength: 0)

            connectionGlyph

            Spacer(minLength: 0)

            toolbarToggle(
                isOn: controller.isScrollModeEnabled,
                systemImage: "arrow.up.and.down",
                label: "Scroll mode",
                hint: "When on, dragging one finger scrolls instead of moving the pointer."
            ) {
                controller.isScrollModeEnabled.toggle()
                controller.impact(.light)
            }

            toolbarToggle(
                isOn: controller.isKeyboardVisible,
                systemImage: controller.isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                label: "Keyboard",
                hint: "Shows the keyboard and modifier rows."
            ) {
                controller.isKeyboardVisible.toggle()
                controller.impact(.light)
            }
        }
        .padding(.horizontal, 4)
    }

    private var connectionGlyph: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
            Text(connectionTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(controller.isInputEnabled ? Color.accentColor : Color.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule().fill((controller.isInputEnabled ? Color.accentColor : Color.red).opacity(0.12))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bluetooth status")
        .accessibilityValue(connectionTitle)
    }

    private var connectionTitle: String {
        switch controller.connectionState {
        case .connected(let name):  return name ?? "Connected"
        case .advertising:          return "Waiting for a Mac"
        case .idle:                 return "Not connected"
        case .poweredOff:           return "Bluetooth off"
        case .unauthorized:         return "Bluetooth denied"
        case .unsupported:          return "Bluetooth unsupported"
        case .failed(let message):  return message
        }
    }

    private func toolbarToggle(isOn: Bool,
                               systemImage: String,
                               label: String,
                               hint: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 38, height: 34)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isOn ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(hint)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Pad

    private var padArea: some View {
        TrackpadSurface(gestures: controller.gestures,
                        isEnabled: controller.isInputEnabled,
                        onEvent: controller.handle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .top) {
                if !controller.isInputEnabled {
                    disconnectedBanner
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
    }

    private var disconnectedBanner: some View {
        Text("Requires a connection to this device")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color.red)
            .clipShape(
                UnevenRoundedRectangle(topLeadingRadius: 18,
                                       bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0,
                                       topTrailingRadius: 18,
                                       style: .continuous)
            )
            .accessibilityAddTraits(.isStaticText)
    }

    // MARK: Buttons

    private var buttonRow: some View {
        HStack(spacing: 8) {
            HoldButton(accessibilityLabel: "Left click",
                       accessibilityHint: "Hold to drag.",
                       isEnabled: controller.isInputEnabled,
                       onPress: { controller.pressButton(.left) },
                       onRelease: { controller.releaseButton(.left) }) {
                buttonGlyph("cursorarrow.click", title: "Left")
            }

            scrollRocker
                .frame(width: rockerWidth)

            HoldButton(accessibilityLabel: "Right click",
                       accessibilityHint: "Hold to drag.",
                       isEnabled: controller.isInputEnabled,
                       onPress: { controller.pressButton(.right) },
                       onRelease: { controller.releaseButton(.right) }) {
                buttonGlyph("cursorarrow.click.2", title: "Right")
            }
        }
    }

    private func buttonGlyph(_ systemImage: String, title: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.title3)
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .medium))
        }
        .foregroundStyle(.primary)
    }

    private var scrollRocker: some View {
        VStack(spacing: 4) {
            HoldButton(accessibilityLabel: "Scroll up",
                       accessibilityHint: "Hold to keep scrolling.",
                       isEnabled: controller.isInputEnabled,
                       onPress: { controller.beginRockerHold(1) },
                       onRelease: { controller.endRockerHold() }) {
                Image(systemName: "chevron.up")
                    .font(.subheadline.weight(.bold))
            }

            HoldButton(accessibilityLabel: "Scroll down",
                       accessibilityHint: "Hold to keep scrolling.",
                       isEnabled: controller.isInputEnabled,
                       onPress: { controller.beginRockerHold(-1) },
                       onRelease: { controller.endRockerHold() }) {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.bold))
            }
        }
    }
}

// MARK: - Hold button

/// A button that reports press and release separately.
///
/// `Button` only fires on release, which cannot express "hold left down while
/// the pointer moves" — i.e. dragging. A zero-distance `DragGesture` gives us
/// both edges, so the mouse button state on the host matches the finger.
@MainActor
private struct HoldButton<Content: View>: View {

    private let accessibilityLabelText: String
    private let accessibilityHintText: String
    private let isEnabled: Bool
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let content: Content

    @State private var isPressed = false

    init(accessibilityLabel: String,
         accessibilityHint: String,
         isEnabled: Bool,
         onPress: @escaping () -> Void,
         onRelease: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.accessibilityLabelText = accessibilityLabel
        self.accessibilityHintText = accessibilityHint
        self.isEnabled = isEnabled
        self.onPress = onPress
        self.onRelease = onRelease
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isPressed
                          ? Color(.systemFill)
                          : Color(.secondarySystemGroupedBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            }
            .scaleEffect(isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .gesture(pressGesture, including: isEnabled ? .all : .none)
            .onChange(of: isEnabled) { _, nowEnabled in
                // Losing the link mid-press must not leave a button stuck down.
                if !nowEnabled, isPressed {
                    isPressed = false
                    onRelease()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityHint(accessibilityHintText)
            .accessibilityAddTraits(.isButton)
            .accessibilityRemoveTraits(.isImage)
            // VoiceOver cannot express press-and-hold, so give it a plain
            // activate that does a full press/release cycle.
            .accessibilityAction {
                guard isEnabled else { return }
                onPress()
                onRelease()
            }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                onPress()
            }
            .onEnded { _ in
                guard isPressed else { return }
                isPressed = false
                onRelease()
            }
    }
}

// MARK: - Previews

#Preview("Trackpad — connected") {
    TrackpadView(sender: StubHIDSender(), settings: AppSettings())
}

#Preview("Trackpad — disconnected") {
    TrackpadView(sender: StubHIDSender(connectionState: .idle, knownCentrals: []),
                 settings: AppSettings())
}

#Preview("Trackpad — large text") {
    TrackpadView(sender: StubHIDSender(), settings: AppSettings())
        .environment(\.dynamicTypeSize, .accessibility2)
}
