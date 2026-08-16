//
//  RemoteModels.swift
//  PocketTrackpad
//
//  The data model behind the Remotes tab: a `Remote` is a named grid of
//  `RemoteButton`s, each of which carries a `RemoteAction` describing what to
//  put on the wire when it is pressed.
//
//  Everything here is value-typed, `Sendable` and `Codable` so a single remote
//  can be exported as JSON and handed to another device (see `Transferable`
//  at the bottom of this file), and so `RemoteStore` can persist the user's
//  library as one document.
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Action

/// The kinds a `RemoteAction` can take. Split out from the enum itself so the
/// editor can drive a `Picker` without pattern-matching payloads.
public enum RemoteActionKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case consumer
    case key
    case text
    case mouse
    case sequence

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .consumer: return "Media Key"
        case .key:      return "Key Combo"
        case .text:     return "Type Text"
        case .mouse:    return "Mouse Click"
        case .sequence: return "Sequence"
        }
    }

    public var symbolName: String {
        switch self {
        case .consumer: return "playpause"
        case .key:      return "keyboard"
        case .text:     return "text.cursor"
        case .mouse:    return "cursorarrow.click"
        case .sequence: return "list.number"
        }
    }

    public var explanation: String {
        switch self {
        case .consumer: return "A consumer-control usage: playback transport, volume, or a browser-style navigation key."
        case .key:      return "A single keyboard key, optionally with modifiers held down."
        case .text:     return "Types a short string one keystroke at a time."
        case .mouse:    return "Clicks and releases a mouse button."
        case .sequence: return "Runs several actions in order."
        }
    }
}

/// What a remote button does when it is pressed.
///
/// Codable is hand-written (see the extension below) because the associated
/// values differ per case; the synthesised conformance would produce a nested
/// shape that is awkward to read and brittle to evolve.
public enum RemoteAction: Codable, Hashable, Sendable {
    case consumer(ConsumerUsage)
    case key(usage: UInt8, modifiers: KeyModifiers)
    case text(String)
    case mouse(MouseButtons)
    case sequence([RemoteAction])

    public var kind: RemoteActionKind {
        switch self {
        case .consumer: return .consumer
        case .key:      return .key
        case .text:     return .text
        case .mouse:    return .mouse
        case .sequence: return .sequence
        }
    }

    /// A neutral default for each kind, used when the editor switches kinds.
    public static func placeholder(for kind: RemoteActionKind) -> RemoteAction {
        switch kind {
        case .consumer: return .consumer(.playPause)
        case .key:      return .key(usage: HIDKeyCode.return, modifiers: .none)
        case .text:     return .text("")
        case .mouse:    return .mouse(.left)
        case .sequence: return .sequence([])
        }
    }

    /// One-line human description, shown in editor rows and used as the
    /// VoiceOver value for a button's action.
    public var summary: String {
        switch self {
        case .consumer(let usage):
            return usage.remoteDisplayName
        case .key(let usage, let modifiers):
            return modifiers.shortcutDescription + RemoteAction.keyName(for: usage)
        case .text(let string):
            return string.isEmpty ? "No text" : "Type “\(string)”"
        case .mouse(let buttons):
            return buttons.remoteDisplayName
        case .sequence(let actions):
            switch actions.count {
            case 0:  return "Empty sequence"
            case 1:  return "1 step"
            default: return "\(actions.count) steps"
            }
        }
    }

    /// Best-effort name for a raw keyboard usage, for display only.
    public static func keyName(for usage: UInt8) -> String {
        switch usage {
        case HIDKeyCode.return:            return "Return"
        case HIDKeyCode.escape:            return "Escape"
        case HIDKeyCode.space:             return "Space"
        case HIDKeyCode.upArrow:           return "Up Arrow"
        case HIDKeyCode.downArrow:         return "Down Arrow"
        case HIDKeyCode.leftArrow:         return "Left Arrow"
        case HIDKeyCode.rightArrow:        return "Right Arrow"
        case HIDKeyCode.delete: return "Delete"
        case HIDKeyCode.tab:           return "Tab"
        case HIDKeyCode.pageUp:        return "Page Up"
        case HIDKeyCode.pageDown:      return "Page Down"
        case HIDKeyCode.home:          return "Home"
        case HIDKeyCode.end:           return "End"
        case HIDKeyCode.keypadSlash:   return "Keypad ÷"
        case HIDKeyCode.keypadAsterisk: return "Keypad ×"
        case HIDKeyCode.keypadMinus:   return "Keypad −"
        case HIDKeyCode.keypadPlus:    return "Keypad +"
        case HIDKeyCode.keypadEnter:   return "Keypad Enter"
        case HIDKeyCode.keypadPeriod:  return "Keypad ."
        case HIDKeyCode.keypad0:       return "Keypad 0"
        case HIDKeyCode.keypad1:       return "Keypad 1"
        case HIDKeyCode.keypad2:       return "Keypad 2"
        case HIDKeyCode.keypad3:       return "Keypad 3"
        case HIDKeyCode.keypad4:       return "Keypad 4"
        case HIDKeyCode.keypad5:       return "Keypad 5"
        case HIDKeyCode.keypad6:       return "Keypad 6"
        case HIDKeyCode.keypad7:       return "Keypad 7"
        case HIDKeyCode.keypad8:       return "Keypad 8"
        case HIDKeyCode.keypad9:       return "Keypad 9"
        case 0x04...0x1D:
            // a…z are contiguous from usage 0x04.
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            return String(letters[Int(usage) - 0x04]).uppercased()
        case 0x1E...0x26:
            // 1…9 are contiguous from usage 0x1E.
            return String(Int(usage) - 0x1E + 1)
        case 0x27:
            return "0"
        case 0x3A...0x45:
            // F1…F12 are contiguous from usage 0x3A.
            return "F\(Int(usage) - 0x3A + 1)"
        default:
            return String(format: "Usage 0x%02X", Int(usage))
        }
    }
}

// MARK: - RemoteAction Codable

extension RemoteAction {
    /// The discriminator written to disk. Raw values are part of the on-disk
    /// format and of exported remotes — do not rename them.
    private enum Kind: String, Codable {
        case consumer, key, text, mouse, sequence
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case usage
        case modifiers
        case text
        case buttons
        case actions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .consumer:
            let raw = try container.decode(UInt16.self, forKey: .usage)
            guard let usage = ConsumerUsage(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .usage,
                    in: container,
                    debugDescription: String(format: "Unknown consumer usage 0x%04X", Int(raw))
                )
            }
            self = .consumer(usage)

        case .key:
            let usage = try container.decode(UInt8.self, forKey: .usage)
            let rawModifiers = try container.decodeIfPresent(UInt8.self, forKey: .modifiers) ?? 0
            self = .key(usage: usage, modifiers: KeyModifiers(rawValue: rawModifiers))

        case .text:
            self = .text(try container.decode(String.self, forKey: .text))

        case .mouse:
            let rawButtons = try container.decode(UInt8.self, forKey: .buttons)
            self = .mouse(MouseButtons(rawValue: rawButtons))

        case .sequence:
            self = .sequence(try container.decode([RemoteAction].self, forKey: .actions))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .consumer(let usage):
            try container.encode(Kind.consumer, forKey: .kind)
            try container.encode(usage.rawValue, forKey: .usage)

        case .key(let usage, let modifiers):
            try container.encode(Kind.key, forKey: .kind)
            try container.encode(usage, forKey: .usage)
            try container.encode(modifiers.rawValue, forKey: .modifiers)

        case .text(let string):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(string, forKey: .text)

        case .mouse(let buttons):
            try container.encode(Kind.mouse, forKey: .kind)
            try container.encode(buttons.rawValue, forKey: .buttons)

        case .sequence(let actions):
            try container.encode(Kind.sequence, forKey: .kind)
            try container.encode(actions, forKey: .actions)
        }
    }
}

// MARK: - Button

public struct RemoteButton: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// Optional SF Symbol. When nil the title carries the button on its own.
    public var symbolName: String?
    public var action: RemoteAction
    /// How many grid columns this button occupies: 1 or 2.
    public var span: Int

    public init(
        id: UUID = UUID(),
        title: String,
        symbolName: String? = nil,
        action: RemoteAction,
        span: Int = 1
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.action = action
        self.span = min(max(span, 1), 2)
    }

    /// Span clamped to something the given grid can actually place.
    public func effectiveSpan(in columns: Int) -> Int {
        min(max(span, 1), max(columns, 1))
    }

    /// What VoiceOver reads for the button, independent of whether the visual
    /// label is a glyph or text.
    public var accessibilityLabel: String { title }
    public var accessibilityHint: String { action.summary }
}

// MARK: - Layout

public enum RemoteLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    case grid2
    case grid3
    case grid4

    public var id: String { rawValue }

    public var columns: Int {
        switch self {
        case .grid2: return 2
        case .grid3: return 3
        case .grid4: return 4
        }
    }

    public var title: String {
        switch self {
        case .grid2: return "2 Columns"
        case .grid3: return "3 Columns"
        case .grid4: return "4 Columns"
        }
    }

    public var shortTitle: String { "\(columns)" }
}

// MARK: - Remote

public struct Remote: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var buttons: [RemoteButton]
    public var layout: RemoteLayout
    /// True for the four remotes that ship with the app. Built-ins can be
    /// hidden and duplicated, but never edited or destroyed.
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        symbolName: String,
        buttons: [RemoteButton],
        layout: RemoteLayout,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.buttons = buttons
        self.layout = layout
        self.isBuiltIn = isBuiltIn
    }

    public var columns: Int { layout.columns }

    /// Packs `buttons` into rows honouring each button's `span`. Both the
    /// detail screen and the editor's live preview render from this, so a
    /// remote looks identical in both places.
    public var gridRows: [[RemoteButton]] {
        let columns = max(1, layout.columns)
        var rows: [[RemoteButton]] = []
        var current: [RemoteButton] = []
        var used = 0

        for button in buttons {
            let span = button.effectiveSpan(in: columns)
            if used + span > columns {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(button)
            used += span
            if used >= columns {
                rows.append(current)
                current = []
                used = 0
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Built-ins

extension Remote {
    /// Stable identifiers for the shipped remotes and their buttons.
    ///
    /// These must not change between releases: `RemoteStore` records hidden
    /// built-ins by ID, so a new ID would silently un-hide a remote the user
    /// had removed. Built by hand from a fixed byte pattern rather than
    /// hand-typed UUID strings so a typo cannot collide two of them.
    static func builtInID(remote: UInt8, button: UInt8) -> UUID {
        UUID(uuid: (
            0x50, 0x54, 0x52, 0x4D,   // "PTRM"
            0x00, 0x01,
            0x40, 0x00,               // version 4 nibble
            0x80, 0x00,               // RFC 4122 variant
            0x00, 0x00, 0x00, 0x00,
            remote, button
        ))
    }

    public static let builtIns: [Remote] = [.mediaRemote, .numericKeypad, .presentationRemote, .tvRemote]

    // MARK: Media

    public static let mediaRemote = Remote(
        id: builtInID(remote: 1, button: 0),
        name: "Media",
        symbolName: "play.rectangle.fill",
        buttons: [
            RemoteButton(
                id: builtInID(remote: 1, button: 1),
                title: "Previous",
                symbolName: "backward.end.fill",
                action: .consumer(.scanPrevious)
            ),
            RemoteButton(
                id: builtInID(remote: 1, button: 2),
                title: "Play / Pause",
                symbolName: "playpause.fill",
                action: .consumer(.playPause)
            ),
            RemoteButton(
                id: builtInID(remote: 1, button: 3),
                title: "Next",
                symbolName: "forward.end.fill",
                action: .consumer(.scanNext)
            ),
            RemoteButton(
                id: builtInID(remote: 1, button: 4),
                title: "Rewind",
                symbolName: "backward.fill",
                action: .consumer(.rewind)
            ),
            RemoteButton(
                id: builtInID(remote: 1, button: 5),
                title: "Stop",
                symbolName: "stop.fill",
                action: .consumer(.stop)
            ),
            RemoteButton(
                id: builtInID(remote: 1, button: 6),
                title: "Fast Forward",
                symbolName: "forward.fill",
                action: .consumer(.fastForward)
            ),
            RemoteButton(
                id: builtInID(remote: 1, button: 7),
                title: "Mute",
                symbolName: "speaker.slash.fill",
                action: .consumer(.mute)
            ),
            RemoteButton(
                id: builtInID(remote: 1, button: 8),
                title: "Volume Down",
                symbolName: "speaker.wave.1.fill",
                action: .consumer(.volumeDown)
            ),
            RemoteButton(
                id: builtInID(remote: 1, button: 9),
                title: "Volume Up",
                symbolName: "speaker.wave.3.fill",
                action: .consumer(.volumeUp)
            )
        ],
        layout: .grid3,
        isBuiltIn: true
    )

    // MARK: Numeric keypad

    public static let numericKeypad = Remote(
        id: builtInID(remote: 2, button: 0),
        name: "Numeric Keypad",
        symbolName: "number.square.fill",
        buttons: [
            RemoteButton(id: builtInID(remote: 2, button: 1), title: "7",
                         action: .key(usage: HIDKeyCode.keypad7, modifiers: .none)),
            RemoteButton(id: builtInID(remote: 2, button: 2), title: "8",
                         action: .key(usage: HIDKeyCode.keypad8, modifiers: .none)),
            RemoteButton(id: builtInID(remote: 2, button: 3), title: "9",
                         action: .key(usage: HIDKeyCode.keypad9, modifiers: .none)),
            RemoteButton(id: builtInID(remote: 2, button: 4), title: "÷",
                         action: .key(usage: HIDKeyCode.keypadSlash, modifiers: .none)),

            RemoteButton(id: builtInID(remote: 2, button: 5), title: "4",
                         action: .key(usage: HIDKeyCode.keypad4, modifiers: .none)),
            RemoteButton(id: builtInID(remote: 2, button: 6), title: "5",
                         action: .key(usage: HIDKeyCode.keypad5, modifiers: .none)),
            RemoteButton(id: builtInID(remote: 2, button: 7), title: "6",
                         action: .key(usage: HIDKeyCode.keypad6, modifiers: .none)),
            RemoteButton(id: builtInID(remote: 2, button: 8), title: "×",
                         action: .key(usage: HIDKeyCode.keypadAsterisk, modifiers: .none)),

            RemoteButton(id: builtInID(remote: 2, button: 9), title: "1",
                         action: .key(usage: HIDKeyCode.keypad1, modifiers: .none)),
            RemoteButton(id: builtInID(remote: 2, button: 10), title: "2",
                         action: .key(usage: HIDKeyCode.keypad2, modifiers: .none)),
            RemoteButton(id: builtInID(remote: 2, button: 11), title: "3",
                         action: .key(usage: HIDKeyCode.keypad3, modifiers: .none)),
            RemoteButton(id: builtInID(remote: 2, button: 12), title: "−",
                         action: .key(usage: HIDKeyCode.keypadMinus, modifiers: .none)),

            RemoteButton(id: builtInID(remote: 2, button: 13), title: "0",
                         action: .key(usage: HIDKeyCode.keypad0, modifiers: .none), span: 2),
            RemoteButton(id: builtInID(remote: 2, button: 14), title: ".",
                         action: .key(usage: HIDKeyCode.keypadPeriod, modifiers: .none)),
            RemoteButton(id: builtInID(remote: 2, button: 15), title: "+",
                         action: .key(usage: HIDKeyCode.keypadPlus, modifiers: .none)),

            RemoteButton(id: builtInID(remote: 2, button: 16), title: "Delete",
                         symbolName: "delete.left.fill",
                         action: .key(usage: HIDKeyCode.delete, modifiers: .none),
                         span: 2),
            RemoteButton(id: builtInID(remote: 2, button: 17), title: "Enter",
                         symbolName: "return",
                         action: .key(usage: HIDKeyCode.keypadEnter, modifiers: .none),
                         span: 2)
        ],
        layout: .grid4,
        isBuiltIn: true
    )

    // MARK: Presentation

    public static let presentationRemote = Remote(
        id: builtInID(remote: 3, button: 0),
        name: "Presentation",
        symbolName: "rectangle.on.rectangle.angled",
        buttons: [
            RemoteButton(
                id: builtInID(remote: 3, button: 1),
                title: "Previous Slide",
                symbolName: "chevron.left",
                action: .key(usage: HIDKeyCode.leftArrow, modifiers: .none)
            ),
            RemoteButton(
                id: builtInID(remote: 3, button: 2),
                title: "Next Slide",
                symbolName: "chevron.right",
                action: .key(usage: HIDKeyCode.rightArrow, modifiers: .none)
            ),
            RemoteButton(
                id: builtInID(remote: 3, button: 3),
                title: "Page Up",
                symbolName: "arrow.up.doc",
                action: .key(usage: HIDKeyCode.pageUp, modifiers: .none)
            ),
            RemoteButton(
                id: builtInID(remote: 3, button: 4),
                title: "Page Down",
                symbolName: "arrow.down.doc",
                action: .key(usage: HIDKeyCode.pageDown, modifiers: .none)
            ),
            RemoteButton(
                id: builtInID(remote: 3, button: 5),
                title: "Start from Beginning",
                symbolName: "play.rectangle",
                // Keynote and PowerPoint both start a show on ⌘⇧↩.
                action: .key(usage: HIDKeyCode.return, modifiers: [.leftCommand, .leftShift]),
                span: 2
            ),
            RemoteButton(
                id: builtInID(remote: 3, button: 6),
                title: "Black Screen",
                symbolName: "moon.fill",
                action: .key(usage: HIDKeyCode.b, modifiers: .none)
            ),
            RemoteButton(
                id: builtInID(remote: 3, button: 7),
                title: "White Screen",
                symbolName: "sun.max.fill",
                action: .key(usage: HIDKeyCode.w, modifiers: .none)
            ),
            RemoteButton(
                id: builtInID(remote: 3, button: 8),
                title: "Laser Pointer",
                symbolName: "cursorarrow.rays",
                // PowerPoint toggles the laser pointer on ⌃L while presenting.
                action: .key(usage: HIDKeyCode.l, modifiers: .leftControl),
                span: 2
            ),
            RemoteButton(
                id: builtInID(remote: 3, button: 9),
                title: "End Show",
                symbolName: "xmark.rectangle",
                action: .key(usage: HIDKeyCode.escape, modifiers: .none),
                span: 2
            )
        ],
        layout: .grid2,
        isBuiltIn: true
    )

    // MARK: TV

    public static let tvRemote = Remote(
        id: builtInID(remote: 4, button: 0),
        name: "TV",
        symbolName: "tv",
        buttons: [
            RemoteButton(
                id: builtInID(remote: 4, button: 1),
                title: "Power",
                symbolName: "power",
                action: .consumer(.power)
            ),
            RemoteButton(
                id: builtInID(remote: 4, button: 2),
                title: "Home",
                symbolName: "house.fill",
                action: .consumer(.acHome)
            ),
            RemoteButton(
                id: builtInID(remote: 4, button: 3),
                title: "Back",
                symbolName: "chevron.backward",
                action: .consumer(.acBack)
            ),

            RemoteButton(
                id: builtInID(remote: 4, button: 4),
                title: "Volume Up",
                symbolName: "speaker.wave.3.fill",
                action: .consumer(.volumeUp)
            ),
            RemoteButton(
                id: builtInID(remote: 4, button: 5),
                title: "Up",
                symbolName: "chevron.up",
                action: .key(usage: HIDKeyCode.upArrow, modifiers: .none)
            ),
            RemoteButton(
                id: builtInID(remote: 4, button: 6),
                title: "Channel Up",
                symbolName: "chevron.up.square.fill",
                // The consumer page's channel usages are outside the set this
                // app's report map declares; Page Up is what tvOS and most
                // media apps treat as "next".
                action: .key(usage: HIDKeyCode.pageUp, modifiers: .none)
            ),

            RemoteButton(
                id: builtInID(remote: 4, button: 7),
                title: "Left",
                symbolName: "chevron.left",
                action: .key(usage: HIDKeyCode.leftArrow, modifiers: .none)
            ),
            RemoteButton(
                id: builtInID(remote: 4, button: 8),
                title: "Select",
                symbolName: "circle.inset.filled",
                action: .key(usage: HIDKeyCode.return, modifiers: .none)
            ),
            RemoteButton(
                id: builtInID(remote: 4, button: 9),
                title: "Right",
                symbolName: "chevron.right",
                action: .key(usage: HIDKeyCode.rightArrow, modifiers: .none)
            ),

            RemoteButton(
                id: builtInID(remote: 4, button: 10),
                title: "Volume Down",
                symbolName: "speaker.wave.1.fill",
                action: .consumer(.volumeDown)
            ),
            RemoteButton(
                id: builtInID(remote: 4, button: 11),
                title: "Down",
                symbolName: "chevron.down",
                action: .key(usage: HIDKeyCode.downArrow, modifiers: .none)
            ),
            RemoteButton(
                id: builtInID(remote: 4, button: 12),
                title: "Channel Down",
                symbolName: "chevron.down.square.fill",
                action: .key(usage: HIDKeyCode.pageDown, modifiers: .none)
            ),

            RemoteButton(
                id: builtInID(remote: 4, button: 13),
                title: "Mute",
                symbolName: "speaker.slash.fill",
                action: .consumer(.mute),
                span: 2
            ),
            RemoteButton(
                id: builtInID(remote: 4, button: 14),
                title: "Play / Pause",
                symbolName: "playpause.fill",
                action: .consumer(.playPause)
            )
        ],
        layout: .grid3,
        isBuiltIn: true
    )
}

// MARK: - Execution

/// Sends `action` on `sender`, press followed by release.
///
/// Every path releases what it pressed. A stuck modifier or a held consumer
/// usage is invisible on the phone and miserable on the Mac, so the release is
/// unconditional rather than deferred to a timer.
@MainActor
public func perform(_ action: RemoteAction, on sender: any HIDSending) {
    switch action {
    case .consumer(let usage):
        if sender.activeTopology.supportedReports.contains(.consumer) {
            sender.send(consumer: ConsumerReport(usage))
            sender.send(consumer: .released)
        } else if let fallback = usage.bootProtocolFallbackKey {
            // Boot-protocol topology carries no consumer report; the Mac's
            // function row is the closest equivalent for transport and volume.
            sender.send(keyboard: KeyboardReport(modifiers: .none, keys: [fallback]))
            sender.send(keyboard: .released)
        }

    case .key(let usage, let modifiers):
        sender.send(keyboard: KeyboardReport(modifiers: modifiers, keys: [usage]))
        sender.send(keyboard: .released)

    case .text(let string):
        for character in string {
            guard let stroke = HIDKeyCode.keystrokes(for: character) else { continue }
            sender.send(keyboard: KeyboardReport(modifiers: stroke.modifiers, keys: [stroke.usage]))
            sender.send(keyboard: .released)
        }

    case .mouse(let buttons):
        sender.send(mouse: MouseReport(buttons: buttons))
        sender.send(mouse: MouseReport())

    case .sequence(let actions):
        for step in actions {
            perform(step, on: sender)
        }
    }
}

// MARK: - Display helpers

extension ConsumerUsage {
    public var remoteDisplayName: String {
        switch self {
        case .play:             return "Play"
        case .pause:            return "Pause"
        case .stop:             return "Stop"
        case .playPause:        return "Play / Pause"
        case .scanNext:         return "Next Track"
        case .scanPrevious:     return "Previous Track"
        case .fastForward:      return "Fast Forward"
        case .rewind:           return "Rewind"
        case .volumeUp:         return "Volume Up"
        case .volumeDown:       return "Volume Down"
        case .mute:             return "Mute"
        case .brightnessUp:     return "Brightness Up"
        case .brightnessDown:   return "Brightness Down"
        case .acHome:           return "Home"
        case .acBack:           return "Back"
        case .acForward:        return "Forward"
        case .acRefresh:        return "Refresh"
        case .acSearch:         return "Search"
        case .acDesktopShowAll: return "Mission Control"
        case .power:            return "Power"
        case .sleep:            return "Sleep"
        }
    }

    public var remoteSymbolName: String {
        switch self {
        case .play:             return "play.fill"
        case .pause:            return "pause.fill"
        case .stop:             return "stop.fill"
        case .playPause:        return "playpause.fill"
        case .scanNext:         return "forward.end.fill"
        case .scanPrevious:     return "backward.end.fill"
        case .fastForward:      return "forward.fill"
        case .rewind:           return "backward.fill"
        case .volumeUp:         return "speaker.wave.3.fill"
        case .volumeDown:       return "speaker.wave.1.fill"
        case .mute:             return "speaker.slash.fill"
        case .brightnessUp:     return "sun.max.fill"
        case .brightnessDown:   return "sun.min.fill"
        case .acHome:           return "house.fill"
        case .acBack:           return "chevron.backward"
        case .acForward:        return "chevron.forward"
        case .acRefresh:        return "arrow.clockwise"
        case .acSearch:         return "magnifyingglass"
        case .acDesktopShowAll: return "square.grid.3x3.fill"
        case .power:            return "power"
        case .sleep:            return "moon.zzz.fill"
        }
    }

    /// The Mac function-row key that stands in for this usage when the active
    /// topology is `.bootProtocolOnly` and no consumer report exists.
    /// Nil where there is no sensible equivalent.
    public var bootProtocolFallbackKey: UInt8? {
        switch self {
        case .play, .pause, .playPause, .stop: return HIDKeyCode.f8
        case .scanNext, .fastForward:          return HIDKeyCode.f9
        case .scanPrevious, .rewind:           return HIDKeyCode.f7
        case .mute:                            return HIDKeyCode.f10
        case .volumeDown:                      return HIDKeyCode.f11
        case .volumeUp:                        return HIDKeyCode.f12
        case .brightnessDown:                  return HIDKeyCode.f1
        case .brightnessUp:                    return HIDKeyCode.f2
        case .acHome, .acBack, .acForward, .acRefresh, .acSearch,
             .acDesktopShowAll, .power, .sleep:
            return nil
        }
    }
}

/// One row in the key-combo recorder's modifier list.
///
/// A struct rather than a tuple because `ForEach` needs an `id`, and Swift key
/// paths cannot address tuple elements.
public struct KeyModifierChoice: Identifiable, Hashable, Sendable {
    public let modifier: KeyModifiers
    public let name: String
    public let glyph: String

    public var id: String { name }

    public init(modifier: KeyModifiers, name: String, glyph: String) {
        self.modifier = modifier
        self.name = name
        self.glyph = glyph
    }
}

extension KeyModifiers {
    /// Ordered list used by the key-combo recorder, left-hand modifiers only —
    /// the right-hand variants exist in the report but no UI needs them.
    public static let editableModifiers: [KeyModifierChoice] = [
        KeyModifierChoice(modifier: .leftControl, name: "Control", glyph: "⌃"),
        KeyModifierChoice(modifier: .leftOption,  name: "Option",  glyph: "⌥"),
        KeyModifierChoice(modifier: .leftShift,   name: "Shift",   glyph: "⇧"),
        KeyModifierChoice(modifier: .leftCommand, name: "Command", glyph: "⌘")
    ]

    /// "⌘⇧" style prefix, empty when no modifiers are held.
    public var shortcutDescription: String {
        var result = ""
        if contains(.leftControl) || contains(.rightControl) { result += "⌃" }
        if contains(.leftOption)  || contains(.rightOption)  { result += "⌥" }
        if contains(.leftShift)   || contains(.rightShift)   { result += "⇧" }
        if contains(.leftCommand) || contains(.rightCommand) { result += "⌘" }
        return result
    }

    /// Spoken form, for VoiceOver, where "⌘⇧" is read as punctuation soup.
    public var spokenDescription: String {
        var parts: [String] = []
        if contains(.leftControl) || contains(.rightControl) { parts.append("Control") }
        if contains(.leftOption)  || contains(.rightOption)  { parts.append("Option") }
        if contains(.leftShift)   || contains(.rightShift)   { parts.append("Shift") }
        if contains(.leftCommand) || contains(.rightCommand) { parts.append("Command") }
        return parts.joined(separator: " ")
    }
}

extension MouseButtons {
    public var remoteDisplayName: String {
        if self == .left   { return "Left Click" }
        if self == .right  { return "Right Click" }
        if self == .middle { return "Middle Click" }
        if isEmpty         { return "No Button" }
        var parts: [String] = []
        if contains(.left)   { parts.append("Left") }
        if contains(.right)  { parts.append("Right") }
        if contains(.middle) { parts.append("Middle") }
        return parts.joined(separator: " + ") + " Click"
    }

    /// The single-button choices the editor offers.
    public static var editableChoices: [MouseButtons] { [.left, .right, .middle] }
}

// MARK: - Coding + sharing

/// One JSON configuration, shared by the store's document and by single-remote
/// export, so a remote written by one path reads back through the other.
public enum RemoteCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        JSONDecoder()
    }

    /// Filename extension used for exported remotes.
    public static let fileExtension = "json"
}

extension Remote: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .json) { remote in
            try RemoteCoding.encoder.encode(remote)
        } importing: { data in
            try RemoteCoding.decoder.decode(Remote.self, from: data)
        }
        .suggestedFileName("Remote.json")
    }
}
