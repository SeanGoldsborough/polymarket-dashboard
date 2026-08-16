//
//  TrackpadView.swift
//  PocketTrackpad
//
//  The primary screen: touch surface, mouse buttons, and the keyboard stack.
//
//  Division of labour with `Sources/Input`:
//
//    * `GestureState` classifies touches and returns finished `GestureEvent`s.
//      It already pumps `PointerEngine.drain()` and `ScrollEngine.drain()` to
//      nil internally and delivers the overflow as extra `.move`/`.scroll`
//      events, so nothing here needs to drain again — the tail of a fast flick
//      arrives as additional events, in order.
//    * This file owns the event-to-report translation, the display link that
//      drives `tick(now:)` and momentum, and the held-button state that every
//      outgoing report has to carry.
//

import SwiftUI
import UIKit
import Observation

// MARK: - Display link

/// A `CADisplayLink` wrapped so the controller does not have to be an NSObject.
///
/// Momentum and long-press timing have to run off the display's clock rather
/// than a `Timer`: a repeating Timer drifts and coalesces under load, which
/// makes a deceleration visibly stutter, whereas the display link fires in step
/// with the frames the user is actually watching.
@MainActor
final class TrackpadDisplayLink: NSObject {

    private var link: CADisplayLink?

    /// Return false to stop the link.
    ///
    /// `CADisplayLink` retains its target, and the run loop retains the link,
    /// so a link whose owner has gone away would keep firing forever with
    /// nothing to do. Letting the callback say "I am finished" is how the owner
    /// can disappear without leaking a run-loop source.
    private let onTick: @MainActor () -> Bool

    init(onTick: @escaping @MainActor () -> Bool) {
        self.onTick = onTick
        super.init()
    }

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleTick))
        // Ask for a steady 60 and let ProMotion go higher when it is free.
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
        if !onTick() { stop() }
    }
}

// MARK: - Controller

/// Turns `GestureEvent`s into HID reports and owns everything time-based.
@MainActor
@Observable
final class TrackpadController {

    /// Pointer points per wheel detent when one-finger scroll mode is on.
    private static let scrollModeDivisor = 8

    @ObservationIgnored let sender: any HIDSending
    @ObservationIgnored let settings: AppSettings

    /// The classifier, which owns the pointer and scroll engines. Exposed as
    /// `gestures.pointer` / `gestures.scroll` if a caller ever needs them.
    @ObservationIgnored let gestures: GestureState

    /// Shared with the accessory rows and the invisible capture field.
    let keyboard: KeyboardBridge

    /// Mouse buttons currently held. Every outgoing report carries these, so a
    /// click-and-drag survives the pointer moving underneath it.
    private(set) var heldButtons: MouseButtons = []

    /// One-finger drag scrolls instead of moving the pointer.
    var isScrollModeEnabled = false

    /// The system keyboard and accessory rows are showing.
    var isKeyboardVisible = false

    @ObservationIgnored private var displayLink: TrackpadDisplayLink?
    @ObservationIgnored private var isTouching = false
    @ObservationIgnored private var rockerTask: Task<Void, Never>?
    @ObservationIgnored private var scrollModeRemainder: (x: Int, y: Int) = (0, 0)

    init(sender: any HIDSending, settings: AppSettings) {
        self.sender = sender
        self.settings = settings
        self.gestures = GestureState()
        self.keyboard = KeyboardBridge(sender: sender, settings: settings)
        applySettings()
    }

    // MARK: State

    var connectionState: HIDConnectionState { sender.connectionState }

    var isInputEnabled: Bool { sender.connectionState.isConnected }

    /// Push the user's normalised sliders into both engines. `GestureState`
    /// owns the handoff so the 0...1 to real-gain curve stays in one place.
    func applySettings() {
        gestures.apply(tracking: settings.tracking,
                       motion: settings.motion,
                       scrolling: settings.scrolling,
                       naturalScrolling: settings.naturalScrolling)
    }

    // MARK: Event routing

    func handle(_ event: GestureEvent) {
        guard isInputEnabled else { return }
        switch event {
        case .move(let dx, let dy):
            if isScrollModeEnabled {
                accumulateScrollMode(dx: dx, dy: dy)
            } else {
                sender.send(mouse: MouseReport(buttons: heldButtons, dx: dx, dy: dy))
            }
        case .scroll(let wheel, let pan):
            send(wheel: wheel, pan: pan)
        case .button(let button, down: let isDown):
            setButton(button, down: isDown)
        case .swipe(let direction):
            perform(swipe: direction)
        }
    }

    /// One-finger scroll mode: pointer deltas are far finer than wheel detents,
    /// so accumulate and emit a detent every `scrollModeDivisor` points, keeping
    /// the remainder instead of throwing the sub-detent travel away.
    private func accumulateScrollMode(dx: Int, dy: Int) {
        scrollModeRemainder.x += dx
        scrollModeRemainder.y += dy

        let pan = scrollModeRemainder.x / Self.scrollModeDivisor
        let steps = scrollModeRemainder.y / Self.scrollModeDivisor
        guard pan != 0 || steps != 0 else { return }

        scrollModeRemainder.x -= pan * Self.scrollModeDivisor
        scrollModeRemainder.y -= steps * Self.scrollModeDivisor

        // Dragging down pushes content down under natural scrolling and pulls
        // it up otherwise, matching the wheel's sign convention.
        send(wheel: settings.naturalScrolling ? steps : -steps, pan: pan)
    }

    /// Never puts an all-zero report on the air. A wheel/pan frame that
    /// quantised to nothing carries no information, and radio time during a
    /// glide is the scarcest thing the app has.
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

    /// Three-finger swipes, mapped onto what macOS does with them.
    ///
    /// Left/right are inverted on purpose: swiping the fingers left moves the
    /// desktop to the *right* into view, which is Control+Right on the Mac.
    private func perform(swipe direction: GestureEvent.Direction) {
        switch direction {
        case .up:
            sender.tap(consumer: .acDesktopShowAll)
        case .down:
            sender.tap(key: HIDKeyCode.downArrow, modifiers: .leftControl)
        case .left:
            sender.tap(key: HIDKeyCode.rightArrow, modifiers: .leftControl)
        case .right:
            sender.tap(key: HIDKeyCode.leftArrow, modifiers: .leftControl)
        }
        impact(.medium)
    }

    // MARK: Display link

    /// Called by the surface when the first finger lands and the last one goes.
    func touchActivityChanged(isTouching touching: Bool) {
        isTouching = touching
        if touching {
            startDisplayLink()
        }
        // On lift the link deliberately keeps running: momentum starts on the
        // very next frame, and `displayTick` stops the link once the glide ends.
    }

    private func startDisplayLink() {
        if displayLink == nil {
            displayLink = TrackpadDisplayLink { [weak self] in
                guard let self else { return false }
                self.displayTick()
                return true
            }
        }
        displayLink?.start()
    }

    func stopDisplayLink() {
        displayLink?.stop()
    }

    private func displayTick() {
        guard isInputEnabled else {
            stopDisplayLink()
            return
        }

        // Time-based transitions — press-and-hold becoming a drag lock — can
        // only be noticed from here; without the tick a long press would need a
        // finger movement to be detected.
        for event in gestures.tick(now: CACurrentMediaTime()) {
            handle(event)
        }

        guard !isTouching else { return }

        // `nil` is the ONLY end-of-glide signal. A `(0, 0)` frame is a
        // legitimate mid-glide result: the engine quantises travel into whole
        // detents, and at low decay speeds several frames pass before enough
        // travel accumulates to make one. Treating zero as the end would cut
        // every inertial scroll short, so keep the link alive and send nothing.
        guard let event = gestures.momentumTick() else {
            stopDisplayLink()
            return
        }
        handle(event)
    }

    // MARK: Buttons and rocker

    func pressButton(_ button: MouseButtons) { setButton(button, down: true) }

    func releaseButton(_ button: MouseButtons) { setButton(button, down: false) }

    /// A single detent from the middle rocker. Positive is up.
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

    /// Leave nothing latched on the host when the screen goes away or the link
    /// drops. `reset()` hands back a button-up for anything the classifier was
    /// holding; we do not replay those individually because a single idle
    /// report releases every button at once and is what the host needs to see.
    func teardown() {
        endRockerHold()
        stopDisplayLink()
        isTouching = false
        gestures.reset()
        keyboard.cancelTyping()
        keyboard.releaseAllHardwareKeys()
        scrollModeRemainder = (0, 0)
        if !heldButtons.isEmpty {
            heldButtons = []
            sender.send(mouse: MouseReport())
        }
    }

    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard settings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Screen

/// The trackpad screen.
@MainActor
public struct TrackpadView: View {

    @State private var controller: TrackpadController
    private let settings: AppSettings
    private let onOpenMenu: () -> Void

    @ScaledMetric(relativeTo: .body) private var buttonRowHeight: CGFloat = 76
    @ScaledMetric(relativeTo: .body) private var rockerWidth: CGFloat = 80

    public init(sender: any HIDSending,
                settings: AppSettings,
                onOpenMenu: @escaping () -> Void = {}) {
        self.settings = settings
        self.onOpenMenu = onOpenMenu
        _controller = State(initialValue: TrackpadController(sender: sender, settings: settings))
    }

    public var body: some View {
        VStack(spacing: 10) {
            topBar
            padArea
                .layoutPriority(1)
            buttonRow
                .frame(height: buttonRowHeight)
            if controller.isKeyboardVisible {
                KeyboardAccessoryView(bridge: controller.keyboard)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .overlay(alignment: .bottomTrailing) {
            // Must stay in the hierarchy and stay non-hidden: a hidden or
            // detached view cannot become first responder, so the system
            // keyboard would never come up.
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
            // A link that drops mid-drag must not leave a button held on the Mac.
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
        HStack(spacing: 10) {
            Button(action: onOpenMenu) {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 38, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Menu")
            .accessibilityHint("Opens the device list, settings and diagnostics.")

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
                hint: "Shows the system keyboard and the modifier rows."
            ) {
                controller.isKeyboardVisible.toggle()
                controller.impact(.light)
            }
        }
    }

    /// Bluetooth status: blue when the Mac is on the other end, red when it is
    /// not. The colour is the whole point — this is glanceable status for
    /// someone who is looking at the Mac, not at the phone.
    private var connectionGlyph: some View {
        let tint = controller.isInputEnabled ? Theme.accent : Theme.danger
        return HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
            Text(connectionTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.statusWash(tint), in: Capsule(style: .continuous))
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
        case .unsupported:          return "Not supported"
        case .failed:               return "Radio error"
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
                .foregroundStyle(isOn ? Color.white : Theme.primaryText)
                .background(isOn ? Theme.accent : Theme.cardBackground,
                            in: RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous)
                        .strokeBorder(isOn ? Color.clear : Theme.cardBorder, lineWidth: 1)
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
                        onEvent: controller.handle(_:),
                        onTouchActivityChange: controller.touchActivityChanged(isTouching:))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.trackpadSurface,
                        in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(alignment: .top) {
                if !controller.isInputEnabled {
                    disconnectedBanner
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: Theme.cardShadowRadius, x: 0, y: Theme.cardShadowOffsetY)
    }

    private var disconnectedBanner: some View {
        Text("Requires a connection to this device")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.danger)
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
        .foregroundStyle(Theme.primaryText)
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
                    .foregroundStyle(Theme.primaryText)
            }

            HoldButton(accessibilityLabel: "Scroll down",
                       accessibilityHint: "Hold to keep scrolling.",
                       isEnabled: controller.isInputEnabled,
                       onPress: { controller.beginRockerHold(-1) },
                       onRelease: { controller.endRockerHold() }) {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
            }
        }
    }
}

// MARK: - Hold button

/// A button that reports press and release separately.
///
/// `Button` only fires on release, which cannot express "hold the left button
/// down while the pointer moves" — i.e. dragging a window. A zero-distance
/// `DragGesture` gives both edges, so the button state on the Mac tracks the
/// finger rather than lagging it by a whole press.
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
        let shape = RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous)
        return content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isPressed ? Theme.insetBackground : Theme.cardBackground, in: shape)
            .overlay { shape.strokeBorder(Theme.cardBorder, lineWidth: 1) }
            .scaleEffect(isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .shadow(color: Theme.cardShadow, radius: isPressed ? 0 : 4, x: 0, y: 1)
            .contentShape(shape)
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
            // VoiceOver has no press-and-hold, so give it a plain activate that
            // performs a complete press/release cycle.
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
    TrackpadView(sender: StubHIDSender(),
                 settings: AppSettings(defaults: .previewDefaults))
        .themedPage()
}

#Preview("Trackpad — disconnected") {
    TrackpadView(sender: StubHIDSender(connectionState: .idle, knownCentrals: []),
                 settings: AppSettings(defaults: .previewDefaults))
        .themedPage()
}

#Preview("Trackpad — large text") {
    TrackpadView(sender: StubHIDSender(),
                 settings: AppSettings(defaults: .previewDefaults))
        .themedPage()
        .environment(\.dynamicTypeSize, .accessibility2)
}
