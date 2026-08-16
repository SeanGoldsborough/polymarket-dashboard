//
//  HIDKeyCode.swift
//  PocketTrackpad
//
//  HID Usage Page 0x07 (Keyboard/Keypad) usage IDs, and the ASCII -> usage
//  mapping the text-entry feature needs.
//
//  WHY THESE ARE NOT AN ENUM WITH A RAW VALUE
//  ------------------------------------------
//  `KeyboardReport.keys` is `[UInt8]` in the shared contract, and the six-slot
//  array in the report descriptor accepts the full 0...255 range. Modelling the
//  page as a Swift enum would force every call site through `.rawValue` and,
//  worse, would make an unrecognised usage from a future feature unrepresentable
//  without a `.unknown(UInt8)` case that defeats the point. A caseless enum of
//  `static let`s gives the same namespacing and autocompletion with none of that.
//
//  WHY THE ASCII MAP IS US-LAYOUT ONLY
//  -----------------------------------
//  HID keycodes name PHYSICAL KEYS, not characters. Usage 0x1E is "the key
//  labelled 1 on a US keyboard"; what the host actually types when it receives
//  0x1E depends entirely on the keyboard layout selected in macOS System
//  Settings. There is no BLE mechanism for a peripheral to ask the host what its
//  layout is, and no way to send a Unicode scalar directly. Consequently
//  `keystrokes(for:)` is correct if and only if the Mac is set to a US layout —
//  on an AZERTY Mac, sending the usage for "q" produces "a". This is a hard
//  limitation of HID, shared by every BLE keyboard emulator, not a bug to fix.
//

import Foundation

/// HID Keyboard/Keypad page (0x07) usage IDs.
public enum HIDKeyCode {

    // MARK: Letters (0x04...0x1D)

    public static let a: UInt8 = 0x04
    public static let b: UInt8 = 0x05
    public static let c: UInt8 = 0x06
    public static let d: UInt8 = 0x07
    public static let e: UInt8 = 0x08
    public static let f: UInt8 = 0x09
    public static let g: UInt8 = 0x0A
    public static let h: UInt8 = 0x0B
    public static let i: UInt8 = 0x0C
    public static let j: UInt8 = 0x0D
    public static let k: UInt8 = 0x0E
    public static let l: UInt8 = 0x0F
    public static let m: UInt8 = 0x10
    public static let n: UInt8 = 0x11
    public static let o: UInt8 = 0x12
    public static let p: UInt8 = 0x13
    public static let q: UInt8 = 0x14
    public static let r: UInt8 = 0x15
    public static let s: UInt8 = 0x16
    public static let t: UInt8 = 0x17
    public static let u: UInt8 = 0x18
    public static let v: UInt8 = 0x19
    public static let w: UInt8 = 0x1A
    public static let x: UInt8 = 0x1B
    public static let y: UInt8 = 0x1C
    public static let z: UInt8 = 0x1D

    // MARK: Digit row (0x1E...0x27)
    //
    // Note the ordering quirk that has bitten every HID implementation ever
    // written: the usages run 1,2,3,4,5,6,7,8,9,0 — zero is at the END, at 0x27,
    // not at 0x1D or 0x28. `keystrokes(for:)` special-cases it for that reason.

    public static let one:   UInt8 = 0x1E
    public static let two:   UInt8 = 0x1F
    public static let three: UInt8 = 0x20
    public static let four:  UInt8 = 0x21
    public static let five:  UInt8 = 0x22
    public static let six:   UInt8 = 0x23
    public static let seven: UInt8 = 0x24
    public static let eight: UInt8 = 0x25
    public static let nine:  UInt8 = 0x26
    public static let zero:  UInt8 = 0x27

    // MARK: Control and punctuation (0x28...0x39)

    public static let `return`:     UInt8 = 0x28
    public static let escape:       UInt8 = 0x29
    /// Backspace. Named `delete` to match the label on an Apple keyboard; the
    /// forward-delete key is `forwardDelete` (0x4C).
    public static let delete:       UInt8 = 0x2A
    public static let tab:          UInt8 = 0x2B
    public static let space:        UInt8 = 0x2C
    public static let minus:        UInt8 = 0x2D
    public static let equal:        UInt8 = 0x2E
    public static let leftBracket:  UInt8 = 0x2F
    public static let rightBracket: UInt8 = 0x30
    public static let backslash:    UInt8 = 0x31
    /// Non-US "#" / "~" key. Present so the constant set is complete; the ASCII
    /// map never emits it, because on a US layout those characters come from
    /// `backslash` and `grave`.
    public static let nonUSHash:    UInt8 = 0x32
    public static let semicolon:    UInt8 = 0x33
    public static let quote:        UInt8 = 0x34
    public static let grave:        UInt8 = 0x35
    public static let comma:        UInt8 = 0x36
    public static let period:       UInt8 = 0x37
    public static let slash:        UInt8 = 0x38
    public static let capsLock:     UInt8 = 0x39

    // MARK: Function row (0x3A...0x45)

    public static let f1:  UInt8 = 0x3A
    public static let f2:  UInt8 = 0x3B
    public static let f3:  UInt8 = 0x3C
    public static let f4:  UInt8 = 0x3D
    public static let f5:  UInt8 = 0x3E
    public static let f6:  UInt8 = 0x3F
    public static let f7:  UInt8 = 0x40
    public static let f8:  UInt8 = 0x41
    public static let f9:  UInt8 = 0x42
    public static let f10: UInt8 = 0x43
    public static let f11: UInt8 = 0x44
    public static let f12: UInt8 = 0x45

    // MARK: Navigation cluster (0x46...0x52)

    public static let printScreen:   UInt8 = 0x46
    public static let scrollLock:    UInt8 = 0x47
    public static let pause:         UInt8 = 0x48
    public static let insert:        UInt8 = 0x49
    public static let home:          UInt8 = 0x4A
    public static let pageUp:        UInt8 = 0x4B
    /// Forward delete (the key macOS labels "⌦").
    public static let forwardDelete: UInt8 = 0x4C
    public static let end:           UInt8 = 0x4D
    public static let pageDown:      UInt8 = 0x4E
    public static let rightArrow:    UInt8 = 0x4F
    public static let leftArrow:     UInt8 = 0x50
    public static let downArrow:     UInt8 = 0x51
    public static let upArrow:       UInt8 = 0x52

    // MARK: Keypad (0x53...0x67)

    public static let numLock:        UInt8 = 0x53
    public static let keypadSlash:    UInt8 = 0x54
    public static let keypadAsterisk: UInt8 = 0x55
    public static let keypadMinus:    UInt8 = 0x56
    public static let keypadPlus:     UInt8 = 0x57
    public static let keypadEnter:    UInt8 = 0x58
    public static let keypad1:        UInt8 = 0x59
    public static let keypad2:        UInt8 = 0x5A
    public static let keypad3:        UInt8 = 0x5B
    public static let keypad4:        UInt8 = 0x5C
    public static let keypad5:        UInt8 = 0x5D
    public static let keypad6:        UInt8 = 0x5E
    public static let keypad7:        UInt8 = 0x5F
    public static let keypad8:        UInt8 = 0x60
    public static let keypad9:        UInt8 = 0x61
    /// Keypad zero, again at the END of the run — same quirk as the digit row.
    public static let keypad0:        UInt8 = 0x62
    public static let keypadPeriod:   UInt8 = 0x63
    public static let keypadEqual:    UInt8 = 0x67

    // MARK: Modifier usages
    //
    // These are the usages that appear in the modifier BITMAP (byte 0), not in
    // the key array. They are listed for completeness — to press Command you set
    // `KeyModifiers.leftCommand`, you do not put 0xE3 in `keys`. Doing the latter
    // technically works on some hosts and is rejected by others, so the encoder
    // path never produces it.

    public static let leftControl:  UInt8 = 0xE0
    public static let leftShift:    UInt8 = 0xE1
    public static let leftOption:   UInt8 = 0xE2
    public static let leftCommand:  UInt8 = 0xE3
    public static let rightControl: UInt8 = 0xE4
    public static let rightShift:   UInt8 = 0xE5
    public static let rightOption:  UInt8 = 0xE6
    public static let rightCommand: UInt8 = 0xE7

    // MARK: - ASCII mapping

    /// Map a character to the physical key (plus modifiers) that produces it on a
    /// US layout.
    ///
    /// Returns `nil` for anything unmapped — accented letters, emoji, control
    /// codes other than the three below, and every non-ASCII scalar. Callers must
    /// handle `nil` by skipping the character; there is deliberately no fallback
    /// or replacement keystroke, because silently typing the wrong character is
    /// worse than typing nothing.
    ///
    /// The three control characters that ARE mapped — newline, carriage return
    /// and tab — map to their physical keys because a string being "typed" almost
    /// always wants Return and Tab to act as keys, not as literal control codes.
    /// Backspace (0x08) is mapped for the same reason.
    public static func keystrokes(for character: Character) -> (usage: UInt8, modifiers: KeyModifiers)? {
        let shifted = KeyModifiers.leftShift

        // CRLF is ONE grapheme cluster in Swift, so `"a\r\nb".count == 3` and the
        // middle character has two scalars. Without this case the newline in every
        // Windows-style string would be silently skipped by the guard below.
        if character == "\r\n" { return (`return`, .none) }

        // Multi-scalar graphemes (flags, ZWJ sequences, "é" written as e +
        // combining acute) have no single physical key. Reject them before
        // touching `unicodeScalars.first`, which would otherwise map "é" to "e"
        // and drop the accent — a silent corruption.
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else { return nil }

        // ASCII code points, spelled numerically rather than as
        // `Unicode.Scalar("a")` because Unicode.Scalar has no String initialiser.
        let asciiLowerA: UInt32 = 0x61
        let asciiUpperA: UInt32 = 0x41
        let asciiOne:    UInt32 = 0x31

        switch scalar {
        // Letters.
        case "a"..."z":
            return (a + UInt8(scalar.value - asciiLowerA), .none)
        case "A"..."Z":
            return (a + UInt8(scalar.value - asciiUpperA), shifted)

        // Digits. 1...9 are contiguous from 0x1E; 0 is at 0x27.
        case "1"..."9":
            return (one + UInt8(scalar.value - asciiOne), .none)
        case "0":
            return (zero, .none)

        // Shifted digit row.
        case "!": return (one,   shifted)
        case "@": return (two,   shifted)
        case "#": return (three, shifted)
        case "$": return (four,  shifted)
        case "%": return (five,  shifted)
        case "^": return (six,   shifted)
        case "&": return (seven, shifted)
        case "*": return (eight, shifted)
        case "(": return (nine,  shifted)
        case ")": return (zero,  shifted)

        // Unshifted punctuation.
        case " ":  return (space,        .none)
        case "-":  return (minus,        .none)
        case "=":  return (equal,        .none)
        case "[":  return (leftBracket,  .none)
        case "]":  return (rightBracket, .none)
        case "\\": return (backslash,    .none)
        case ";":  return (semicolon,    .none)
        case "'":  return (quote,        .none)
        case "`":  return (grave,        .none)
        case ",":  return (comma,        .none)
        case ".":  return (period,       .none)
        case "/":  return (slash,        .none)

        // Shifted punctuation.
        case "_": return (minus,        shifted)
        case "+": return (equal,        shifted)
        case "{": return (leftBracket,  shifted)
        case "}": return (rightBracket, shifted)
        case "|": return (backslash,    shifted)
        case ":": return (semicolon,    shifted)
        case "\"": return (quote,       shifted)
        case "~": return (grave,        shifted)
        case "<": return (comma,        shifted)
        case ">": return (period,       shifted)
        case "?": return (slash,        shifted)

        // Control characters worth honouring as physical keys.
        case "\n": return (`return`, .none)   // U+000A
        case "\r": return (`return`, .none)   // U+000D
        case "\t": return (tab,      .none)   // U+0009
        case "\u{08}": return (delete, .none) // backspace
        case "\u{1B}": return (escape, .none) // escape

        default:
            return nil
        }
    }

    /// Map a whole string, skipping every character with no US-layout key.
    ///
    /// The result is a flat list of single-key presses in order. It is the
    /// caller's job to turn each into a press report followed by a release
    /// report — see `HIDSending.tap(key:modifiers:)`. Repeated identical
    /// characters therefore still work, because every press is bracketed by an
    /// explicit release; emitting two consecutive identical key-down reports with
    /// no release between them would be seen by the host as one held key.
    public static func keystrokes(for string: String) -> [(UInt8, KeyModifiers)] {
        var result: [(UInt8, KeyModifiers)] = []
        result.reserveCapacity(string.count)
        for character in string {
            if let stroke = keystrokes(for: character) {
                result.append((stroke.usage, stroke.modifiers))
            }
        }
        return result
    }

    /// Characters in `string` that `keystrokes(for:)` cannot type.
    ///
    /// Exposed so the text-entry UI can warn ("3 characters will be skipped")
    /// instead of dropping them invisibly.
    public static func unmappableCharacters(in string: String) -> [Character] {
        string.filter { keystrokes(for: $0) == nil }
    }
}
