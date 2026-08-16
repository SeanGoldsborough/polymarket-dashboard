//
//  HiddenKeyboardField.swift
//  PocketTrackpad
//
//  Capturing real typing and turning it into HID keyboard reports.
//
//  ASSUMED SIBLING API
//  -------------------
//      enum HIDKeyCode {
//          static func keystrokes(for character: Character) -> (usage: UInt8, modifiers: KeyModifiers)?
//          static func keystrokes(for string: String) -> [(UInt8, KeyModifiers)]
//      }
//
//  Everything else in this file is local.
//

import SwiftUI
import UIKit
import Observation

// MARK: - Raw usage codes

/// HID Keyboard/Keypad usage page (0x07) codes this feature needs by number.
///
/// `HIDKeyCode` maps *characters*; several keys we drive have no character at
/// all (backspace, the arrows, F1–F12), so those usages live here. Named
/// distinctly so it can never collide with the sibling-owned `HIDKeyCode`.
enum TrackpadKeyUsage {
    static let returnOrEnter: UInt8 = 0x28
    static let escape: UInt8        = 0x29
    static let deleteBackward: UInt8 = 0x2A
    static let tab: UInt8           = 0x2B
    static let spacebar: UInt8      = 0x2C
    static let capsLock: UInt8      = 0x39

    static let rightArrow: UInt8 = 0x4F
    static let leftArrow: UInt8  = 0x50
    static let downArrow: UInt8  = 0x51
    static let upArrow: UInt8    = 0x52

    /// F1 is 0x3A and the function keys run contiguously through F12 at 0x45.
    static func function(_ number: Int) -> UInt8? {
        guard (1...12).contains(number) else { return nil }
        return UInt8(0x3A + number - 1)
    }

    /// Translate UIKit's modifier flags into HID modifier bits. UIKit does not
    /// distinguish left from right, so everything maps to the left-hand bit.
    static func hidModifiers(from flags: UIKeyModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift)     { modifiers.insert(.leftShift) }
        if flags.contains(.control)   { modifiers.insert(.leftControl) }
        if flags.contains(.alternate) { modifiers.insert(.leftOption) }
        if flags.contains(.command)   { modifiers.insert(.leftCommand) }
        return modifiers
    }
}

// MARK: - Bridge

/// Shared state between the invisible capture field and the accessory rows.
///
/// The accessory latches modifiers; the field ORs them into the next report
/// and clears the one-shot ones afterwards. Both sides talk to this object
/// rather than to each other.
@MainActor
@Observable
public final class KeyboardBridge {

    /// How a sticky modifier behaves.
    public enum LatchState: Equatable {
        /// Not applied.
        case off
        /// Applied to exactly the next keystroke, then released.
        case oneShot
        /// Applied until the user taps it off.
        case locked
    }

    @ObservationIgnored private let sender: HIDSending
    @ObservationIgnored private let settings: AppSettings

    /// Per-modifier latch state, keyed by raw value so it stays `Hashable`.
    private var latches: [UInt8: LatchState] = [:]

    /// Caps lock is a real toggling key on the host, not a latch.
    public private(set) var isCapsLockEngaged = false

    /// The "hide password" eye. Turns the capture field into a secure field so
    /// iOS stops offering autocorrect/predictions for what is being typed.
    public var masksTypedText = false

    /// Fraction complete of an in-flight paste, `nil` when idle.
    public private(set) var pasteProgress: Double?

    /// Hardware keys currently held down (max six, per the boot report).
    @ObservationIgnored private var heldHardwareKeys: [UInt8] = []

    @ObservationIgnored private var typingTask: Task<Void, Never>?

    /// Gap between synthesised keystrokes during a paste. A BLE connection
    /// interval is 7.5–30 ms; firing faster than that just queues reports up
    /// in the pump and the host coalesces or drops them, which shows up as
    /// dropped characters. 14 ms is comfortably above the fast end.
    @ObservationIgnored private let pasteInterval = Duration.milliseconds(14)

    /// Ceiling on a single paste so a stray multi-megabyte clipboard cannot
    /// hold the keyboard hostage for an hour.
    @ObservationIgnored private let pasteCharacterLimit = 2_000

    public init(sender: HIDSending, settings: AppSettings) {
        self.sender = sender
        self.settings = settings
    }

    // MARK: Connection

    public var isConnected: Bool { sender.connectionState.isConnected }

    // MARK: Latched modifiers

    public func latchState(for modifier: KeyModifiers) -> LatchState {
        latches[modifier.rawValue] ?? .off
    }

    /// off -> one-shot -> locked -> off. Matches the reference app, where a
    /// second tap on shift locks it and a third clears it.
    public func cycleLatch(for modifier: KeyModifiers) {
        let next: LatchState
        switch latchState(for: modifier) {
        case .off:     next = .oneShot
        case .oneShot: next = .locked
        case .locked:  next = .off
        }
        latches[modifier.rawValue] = next
        impact(.light)
    }

    public func clearAllLatches() {
        latches.removeAll()
    }

    /// Every modifier bit that should ride along with the next report.
    public var activeModifiers: KeyModifiers {
        var result: KeyModifiers = []
        for (raw, state) in latches where state != .off {
            result.insert(KeyModifiers(rawValue: raw))
        }
        return result
    }

    /// Drop the one-shot latches. Called after a keystroke has gone out.
    private func consumeOneShots() {
        guard latches.contains(where: { $0.value == .oneShot }) else { return }
        latches = latches.filter { $0.value == .locked }
    }

    // MARK: Sending

    /// Send a single usage with the latched modifiers folded in.
    public func send(usage: UInt8, extraModifiers: KeyModifiers = []) {
        guard isConnected else { return }
        sender.tap(key: usage, modifiers: activeModifiers.union(extraModifiers))
        consumeOneShots()
    }

    /// Send one typed character, looking its usage up through `HIDKeyCode`.
    /// Characters with no mapping (emoji, most CJK) are silently skipped —
    /// a boot keyboard report simply cannot express them.
    public func sendCharacter(_ character: Character) {
        guard isConnected else { return }
        guard let stroke = HIDKeyCode.keystrokes(for: character) else { return }
        sender.tap(key: stroke.usage, modifiers: activeModifiers.union(stroke.modifiers))
        consumeOneShots()
    }

    /// Send a run of text, one character at a time.
    public func sendText(_ text: String) {
        guard isConnected else { return }
        for character in text {
            switch character {
            case "\n", "\r":
                send(usage: TrackpadKeyUsage.returnOrEnter)
            case "\t":
                send(usage: TrackpadKeyUsage.tab)
            default:
                sendCharacter(character)
            }
        }
    }

    public func tapConsumer(_ usage: ConsumerUsage) {
        guard isConnected else { return }
        sender.tap(consumer: usage)
        impact(.light)
    }

    public func toggleCapsLock() {
        guard isConnected else { return }
        isCapsLockEngaged.toggle()
        sender.tap(key: TrackpadKeyUsage.capsLock, modifiers: [])
        impact(.medium)
    }

    // MARK: Paste

    /// Type the clipboard out, paced so the report pump is never flooded.
    public func pasteClipboard() {
        guard isConnected else { return }
        guard let clipboard = UIPasteboard.general.string, !clipboard.isEmpty else { return }
        typeSlowly(String(clipboard.prefix(pasteCharacterLimit)))
    }

    /// Rate-limited bulk typing. Cancels any paste already running.
    public func typeSlowly(_ text: String) {
        typingTask?.cancel()
        let strokes = HIDKeyCode.keystrokes(for: text)
        guard !strokes.isEmpty else { return }

        // The latched modifiers apply to the paste as a whole, not to every
        // character in it, so snapshot them once and release them now.
        let carried = activeModifiers
        consumeOneShots()

        pasteProgress = 0
        typingTask = Task { @MainActor [weak self] in
            defer { self?.pasteProgress = nil }
            for (index, stroke) in strokes.enumerated() {
                guard let self, !Task.isCancelled, self.isConnected else { return }
                self.sender.tap(key: stroke.0, modifiers: stroke.1.union(carried))
                self.pasteProgress = Double(index + 1) / Double(strokes.count)
                try? await Task.sleep(for: self.pasteInterval)
            }
        }
    }

    public func cancelTyping() {
        typingTask?.cancel()
        typingTask = nil
        pasteProgress = nil
    }

    // MARK: Hardware keys

    /// A physical key went down. Reported as a real held key rather than a tap
    /// so auto-repeat and chords behave the way the host expects.
    public func hardwareKeyDown(usage: UInt8, modifiers: KeyModifiers) {
        guard isConnected else { return }
        if !heldHardwareKeys.contains(usage) {
            heldHardwareKeys.append(usage)
        }
        sender.send(keyboard: KeyboardReport(modifiers: modifiers.union(activeModifiers),
                                             keys: Array(heldHardwareKeys.prefix(6))))
    }

    public func hardwareKeyUp(usage: UInt8, modifiers: KeyModifiers) {
        guard isConnected else { return }
        heldHardwareKeys.removeAll { $0 == usage }
        sender.send(keyboard: KeyboardReport(modifiers: modifiers,
                                             keys: Array(heldHardwareKeys.prefix(6))))
        if heldHardwareKeys.isEmpty {
            consumeOneShots()
        }
    }

    public func releaseAllHardwareKeys() {
        guard !heldHardwareKeys.isEmpty else { return }
        heldHardwareKeys.removeAll()
        sender.send(keyboard: .released)
    }

    // MARK: Haptics

    public func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard settings.hapticsEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

// MARK: - The capture field

/// A `UITextField` that never actually holds text: it exists only to raise the
/// system keyboard and convert what the user types into HID usages.
final class HIDKeyCaptureField: UITextField {

    /// THE SENTINEL TRICK.
    ///
    /// `deleteBackward()` is only delivered to a responder that reports having
    /// something to delete. An empty field means UIKit still calls it in most
    /// iOS versions, but the *keyboard* renders the delete key as a no-op and,
    /// worse, some input modes stop sending the message entirely once the
    /// buffer is empty. The standard workaround — used by every "capture the
    /// keyboard" implementation — is to keep exactly one throwaway character
    /// in the buffer (a single space here) and override `hasText` to always
    /// report true. The user never sees it: `insertText` and `deleteBackward`
    /// are both overridden so `super` never runs and the buffer never changes
    /// from the sentinel, and the caret and selection rects are suppressed.
    static let sentinel = " "

    var onInsert: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onHardwareKeyDown: ((UInt8, KeyModifiers) -> Void)?
    var onHardwareKeyUp: ((UInt8, KeyModifiers) -> Void)?

    private var isRestoringSentinel = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HIDKeyCaptureField is created in code only.")
    }

    private func commonInit() {
        text = Self.sentinel
        tintColor = .clear                      // no visible caret
        textColor = .clear
        backgroundColor = .clear
        borderStyle = .none

        // Everything that could rewrite the buffer behind our back, off.
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        enablesReturnKeyAutomatically = false
        keyboardType = .default
        returnKeyType = .default
        textContentType = nil

        // The iPad shortcuts bar would sit between our accessory rows and the
        // keyboard and offer undo/redo we cannot honour.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []

        isAccessibilityElement = false
        accessibilityElementsHidden = true

        addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)
    }

    // MARK: UIKeyInput

    override var hasText: Bool { true }

    override func insertText(_ text: String) {
        // Deliberately no `super.insertText` — the buffer stays at the
        // sentinel forever, which is what keeps delete working.
        guard !text.isEmpty else { return }
        onInsert?(text)
    }

    override func deleteBackward() {
        // Same: no `super`. The sentinel is never actually consumed.
        onDeleteBackward?()
    }

    // MARK: Cosmetics

    override func caretRect(for position: UITextPosition) -> CGRect { .zero }

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    /// Flipping secure entry while first responder makes UIKit clear the field,
    /// so the sentinel has to be put back.
    func setMasked(_ masked: Bool) {
        guard isSecureTextEntry != masked else { return }
        isSecureTextEntry = masked
        restoreSentinel()
    }

    private func restoreSentinel() {
        guard text != Self.sentinel else { return }
        isRestoringSentinel = true
        text = Self.sentinel
        isRestoringSentinel = false
    }

    /// Dictation, autofill and a few third-party keyboards mutate `text`
    /// directly instead of going through `insertText`. Catch that here, emit
    /// whatever was appended, and put the sentinel back.
    @objc private func handleEditingChanged() {
        guard !isRestoringSentinel else { return }
        let current = text ?? ""
        guard current != Self.sentinel else { return }
        if current.hasPrefix(Self.sentinel) {
            let appended = String(current.dropFirst(Self.sentinel.count))
            if !appended.isEmpty { onInsert?(appended) }
        } else if current.isEmpty {
            onDeleteBackward?()
        } else {
            onInsert?(current)
        }
        restoreSentinel()
    }

    // MARK: Hardware keys

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = forward(presses) { [weak self] usage, modifiers in
            self?.onHardwareKeyDown?(usage, modifiers)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = forward(presses) { [weak self] usage, modifiers in
            self?.onHardwareKeyUp?(usage, modifiers)
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = forward(presses) { [weak self] usage, modifiers in
            self?.onHardwareKeyUp?(usage, modifiers)
        }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    /// Route the presses we can express as raw usages, and return the ones the
    /// responder chain should keep handling.
    ///
    /// A press that would also arrive through `insertText` must NOT be
    /// forwarded, or every character typed on a physical keyboard goes out
    /// twice. So: printable, unmodified keys fall through to `super` (and
    /// reach us again as text), everything else — arrows, escape, tab, the
    /// function row, and any chord holding command or control — is sent here
    /// as a real key-down/key-up pair.
    private func forward(_ presses: Set<UIPress>,
                         to sink: (UInt8, KeyModifiers) -> Void) -> Set<UIPress> {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key,
                  key.keyCode != .keyboardErrorUndefined,
                  !Self.isPlainTextInsertion(key) else {
                unhandled.insert(press)
                continue
            }
            // `UIKeyboardHIDUsage` raw values ARE HID usage IDs on page 0x07,
            // so no translation table is needed here.
            let usage = UInt8(clamping: key.keyCode.rawValue)
            sink(usage, TrackpadKeyUsage.hidModifiers(from: key.modifierFlags))
        }
        return unhandled
    }

    private static func isPlainTextInsertion(_ key: UIKey) -> Bool {
        let flags = key.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.alternate) {
            return false
        }
        let scalars = Array(key.characters.unicodeScalars)
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        if scalar.value < 0x20 { return false }                     // control codes
        if (0xF700...0xF8FF).contains(scalar.value) { return false } // function-key private use
        return true
    }
}

// MARK: - SwiftUI wrapper

/// A one-point, effectively invisible view that owns the capture field.
///
/// It has to stay in the hierarchy and stay non-hidden: a `hidden` or detached
/// view cannot become first responder, so the keyboard would never appear.
@MainActor
struct HiddenKeyboardField: UIViewRepresentable {

    let bridge: KeyboardBridge

    /// Two-way: set true to raise the keyboard, and the field sets it back to
    /// false when the keyboard is dismissed from the system side.
    @Binding var isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge, isActive: $isActive) }

    func makeUIView(context: Context) -> HIDKeyCaptureField {
        let field = HIDKeyCaptureField()
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)

        field.onInsert = { [weak coordinator = context.coordinator] text in
            coordinator?.handleInsert(text)
        }
        field.onDeleteBackward = { [weak coordinator = context.coordinator] in
            coordinator?.handleDelete()
        }
        field.onHardwareKeyDown = { [weak coordinator = context.coordinator] usage, modifiers in
            coordinator?.handleHardwareDown(usage, modifiers)
        }
        field.onHardwareKeyUp = { [weak coordinator = context.coordinator] usage, modifiers in
            coordinator?.handleHardwareUp(usage, modifiers)
        }
        return field
    }

    func updateUIView(_ uiView: HIDKeyCaptureField, context: Context) {
        context.coordinator.bridge = bridge
        context.coordinator.isActive = $isActive
        uiView.setMasked(bridge.masksTypedText)

        // Responder changes are deferred off the layout pass: taking first
        // responder synchronously posts keyboard notifications, which SwiftUI
        // turns into safe-area changes, i.e. state mutation mid-update.
        let shouldBeActive = isActive
        DispatchQueue.main.async {
            guard uiView.window != nil else { return }
            if shouldBeActive, !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            } else if !shouldBeActive, uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: HIDKeyCaptureField, coordinator: Coordinator) {
        uiView.onInsert = nil
        uiView.onDeleteBackward = nil
        uiView.onHardwareKeyDown = nil
        uiView.onHardwareKeyUp = nil
        uiView.delegate = nil
        uiView.resignFirstResponder()
        coordinator.bridge.releaseAllHardwareKeys()
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var bridge: KeyboardBridge
        var isActive: Binding<Bool>

        init(bridge: KeyboardBridge, isActive: Binding<Bool>) {
            self.bridge = bridge
            self.isActive = isActive
        }

        func handleInsert(_ text: String) {
            for character in text {
                switch character {
                case "\n", "\r":
                    bridge.send(usage: TrackpadKeyUsage.returnOrEnter)
                case "\t":
                    bridge.send(usage: TrackpadKeyUsage.tab)
                default:
                    bridge.sendCharacter(character)
                }
            }
        }

        func handleDelete() {
            bridge.send(usage: TrackpadKeyUsage.deleteBackward)
        }

        func handleHardwareDown(_ usage: UInt8, _ modifiers: KeyModifiers) {
            bridge.hardwareKeyDown(usage: usage, modifiers: modifiers)
        }

        func handleHardwareUp(_ usage: UInt8, _ modifiers: KeyModifiers) {
            bridge.hardwareKeyUp(usage: usage, modifiers: modifiers)
        }

        // Never let the field's own buffer change through the delegate path
        // either; `insertText`/`deleteBackward` already did the work.
        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            bridge.releaseAllHardwareKeys()
            if isActive.wrappedValue { isActive.wrappedValue = false }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            bridge.send(usage: TrackpadKeyUsage.returnOrEnter)
            return false
        }
    }
}

// MARK: - Preview

@MainActor
private struct HiddenKeyboardFieldHarness: View {
    @State private var isActive = true
    private let stub: StubHIDSender
    @State private var bridge: KeyboardBridge

    init() {
        let sender = StubHIDSender()
        self.stub = sender
        _bridge = State(initialValue: KeyboardBridge(sender: sender, settings: AppSettings()))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Type on the system keyboard — every keystroke becomes a HID report.")
                .font(.callout)
                .multilineTextAlignment(.center)

            Toggle("Keyboard raised", isOn: $isActive)

            Text(verbatim: "\(stub.sentKeyboard.count) keyboard reports sent")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HiddenKeyboardField(bridge: bridge, isActive: $isActive)
                .frame(width: 1, height: 1)
                .opacity(0.02)

            Spacer()
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}

#Preview("Hidden keyboard field") {
    HiddenKeyboardFieldHarness()
}
