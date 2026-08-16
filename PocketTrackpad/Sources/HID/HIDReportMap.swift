//
//  HIDReportMap.swift
//  PocketTrackpad
//
//  The USB HID Report Descriptor, plus the GATT payloads that describe the
//  device to a host, plus the wire encoders for the three report types.
//
//  WHY A DSL AND NOT A BYTE BLOB
//  -----------------------------
//  Every HID example on the internet is a copy-pasted array of hex. When macOS
//  silently refuses to enumerate the device, a hex blob gives you nothing to
//  debug: you cannot tell whether the bug is a wrong Report Count, a Logical
//  Maximum that got sign-extended, or an unbalanced collection. The builder in
//  this file emits exactly the same bytes, but the source reads like the HID
//  spec's own tables, and `HIDReportMapTests` can walk the emitted stream and
//  prove structural invariants (items are not truncated, collections balance,
//  each report's declared bit count matches `payloadSize * 8`).
//
//  The one hard rule this file exists to enforce: the descriptor and the
//  encoders at the bottom of this file MUST agree, byte for byte. A descriptor
//  that promises 5 bytes of mouse data and an encoder that emits 4 produces a
//  device that pairs, subscribes, and then does nothing at all — the most
//  expensive failure mode in this project, because it looks like a Bluetooth
//  problem and is actually an arithmetic one.
//

import Foundation

// MARK: - Usage pages

/// HID Usage Pages (HUT 1.4 §3) used by this device.
public enum HIDUsagePage {
    public static let genericDesktop = 0x01
    public static let keyboard       = 0x07
    public static let led            = 0x08
    public static let button         = 0x09
    public static let consumer       = 0x0C
}

/// Generic Desktop (0x01) usages used by this device.
public enum HIDGenericDesktopUsage {
    public static let mouse    = 0x02
    public static let keyboard = 0x06
    public static let pointer  = 0x01
    public static let x        = 0x30
    public static let y        = 0x31
    public static let wheel    = 0x38
}

/// Consumer (0x0C) usages used *inside the descriptor* (as opposed to
/// `ConsumerUsage` in the contract, which is what we send at runtime).
public enum HIDConsumerDescriptorUsage {
    public static let consumerControl = 0x01
    /// AC Pan — horizontal scroll. Lives on the Consumer page even though it is
    /// reported inside the Mouse collection; that mixed-page arrangement is what
    /// macOS's Bluetooth stack expects for two-axis scrolling, and is exactly
    /// what Apple's own Magic Trackpad descriptor does.
    public static let acPan = 0x0238
    /// Highest usage this device will ever emit (`ConsumerUsage.acDesktopShowAll`).
    /// The consumer collection's Logical/Usage Maximum is pinned to this so that
    /// every case of `ConsumerUsage` is representable — see `appendConsumerCollection`.
    public static let maximumEmitted = 0x029F
}

/// Keyboard/Keypad (0x07) usages needed by the descriptor itself.
public enum HIDKeyboardDescriptorUsage {
    /// Left Control — first of the eight contiguous modifier usages.
    public static let modifierFirst = 0xE0
    /// Right GUI (Command) — last of the eight contiguous modifier usages.
    public static let modifierLast  = 0xE7
    /// Largest keycode a host may see in the 6-key array.
    public static let keyMaximum    = 0xFF
}

/// LED page (0x08) usages for the boot keyboard's output report.
public enum HIDLEDUsage {
    public static let numLock  = 0x01
    public static let kana     = 0x05
}

// MARK: - Item primitives

/// The two-bit `bType` field of a HID short item prefix (HID 1.11 §6.2.2.2).
public enum HIDItemType: UInt8, Sendable {
    case main   = 0
    case global = 1
    case local  = 2
}

/// The `bTag` values this builder emits. Kept as raw nibbles because that is how
/// the spec tabulates them, which makes cross-checking against HID 1.11 §6.2.2
/// a matter of reading one column.
public enum HIDItemTag {
    // Main items (bType == 0)
    public static let input         : UInt8 = 0x8
    public static let output        : UInt8 = 0x9
    public static let collection    : UInt8 = 0xA
    public static let feature       : UInt8 = 0xB
    public static let endCollection : UInt8 = 0xC

    // Global items (bType == 1)
    public static let usagePage     : UInt8 = 0x0
    public static let logicalMin    : UInt8 = 0x1
    public static let logicalMax    : UInt8 = 0x2
    public static let reportSize    : UInt8 = 0x7
    public static let reportID      : UInt8 = 0x8
    public static let reportCount   : UInt8 = 0x9

    // Local items (bType == 2)
    public static let usage         : UInt8 = 0x0
    public static let usageMin      : UInt8 = 0x1
    public static let usageMax      : UInt8 = 0x2
}

/// Collection kinds (HID 1.11 §6.2.2.6).
public enum HIDCollection: UInt8, Sendable {
    case physical      = 0x00
    case application   = 0x01
    case logical       = 0x02
    case report        = 0x03
    case namedArray    = 0x04
    case usageSwitch   = 0x05
    case usageModifier = 0x06
}

/// Data flags for Input/Output/Feature main items (HID 1.11 §6.2.2.5).
///
/// The zero-valued members (`data`, `array`, `absolute`) exist purely so call
/// sites read like the spec's own notation — `Input (Data, Var, Abs)`. They are
/// the *absence* of the corresponding bit, not distinct bits, so
/// `.data == .array == .absolute == []`. That is intentional: writing
/// `input([.data, .variable, .absolute])` documents all three axes of the item
/// even though only one bit is actually set.
public struct HIDMainItemFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    // Bit 0
    public static let data     = HIDMainItemFlags([])
    public static let constant = HIDMainItemFlags(rawValue: 1 << 0)
    // Bit 1
    public static let array    = HIDMainItemFlags([])
    public static let variable = HIDMainItemFlags(rawValue: 1 << 1)
    // Bit 2
    public static let absolute = HIDMainItemFlags([])
    public static let relative = HIDMainItemFlags(rawValue: 1 << 2)
    // Bits 3...8
    public static let wrap          = HIDMainItemFlags(rawValue: 1 << 3)
    public static let nonLinear     = HIDMainItemFlags(rawValue: 1 << 4)
    public static let noPreferred   = HIDMainItemFlags(rawValue: 1 << 5)
    public static let nullState     = HIDMainItemFlags(rawValue: 1 << 6)
    public static let volatileValue = HIDMainItemFlags(rawValue: 1 << 7)
    public static let bufferedBytes = HIDMainItemFlags(rawValue: 1 << 8)

    /// `Input (Cnst, Var, Abs)` — the canonical spelling for bit padding.
    public static let padding: HIDMainItemFlags = [.constant, .variable]
}

// MARK: - Builder

/// Emits HID short items into a byte buffer.
///
/// Only short items are emitted (prefix byte + 0/1/2/4 data bytes). Long items
/// (prefix 0xFE) are vendor-defined, no host cares about them, and their absence
/// is asserted by the test suite's item walker.
public struct HIDReportDescriptorBuilder {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    // MARK: Raw emission

    /// Emit one short item. `payload` must be 0, 1, 2, or 4 bytes — the size
    /// field of a short item is two bits encoding exactly those four lengths,
    /// with `3` meaning four bytes (HID 1.11 §6.2.2.2). Three-byte payloads are
    /// unrepresentable, which is why the unsigned/signed encoders below round up
    /// to 4 rather than emitting 3.
    private mutating func emit(tag: UInt8, type: HIDItemType, payload: [UInt8]) {
        let sizeCode: UInt8
        switch payload.count {
        case 0: sizeCode = 0
        case 1: sizeCode = 1
        case 2: sizeCode = 2
        case 4: sizeCode = 3
        default:
            preconditionFailure("HID short items carry 0, 1, 2 or 4 data bytes, not \(payload.count)")
        }
        bytes.append((tag << 4) | (type.rawValue << 2) | sizeCode)
        bytes.append(contentsOf: payload)
    }

    /// Two's-complement little-endian encoding, narrowest representation.
    ///
    /// Logical Minimum / Logical Maximum are *signed* fields. This is the single
    /// most common HID descriptor bug: emitting Logical Maximum 255 as the one
    /// byte `0xFF` makes every conformant parser read it as -1, which silently
    /// turns the keyboard's 6-key array into a field with an empty range. Using
    /// the signed encoder forces `26 FF 00` (two bytes) and the bug cannot occur.
    private static func signedPayload(_ value: Int) -> [UInt8] {
        if value >= -128 && value <= 127 {
            return [UInt8(bitPattern: Int8(truncatingIfNeeded: value))]
        }
        if value >= -32_768 && value <= 32_767 {
            let raw = UInt16(bitPattern: Int16(truncatingIfNeeded: value))
            return [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF)]
        }
        let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        return [
            UInt8(raw & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 24) & 0xFF)
        ]
    }

    /// Unsigned little-endian encoding, narrowest representation.
    ///
    /// Usage / Usage Minimum / Usage Maximum / Report Size / Report Count /
    /// Report ID are all unsigned, so `29 FF` (Usage Maximum 255) is correct and
    /// must NOT be widened the way a Logical Maximum would be.
    private static func unsignedPayload(_ value: Int) -> [UInt8] {
        precondition(value >= 0, "HID unsigned item data cannot be negative (got \(value))")
        if value <= 0xFF { return [UInt8(value)] }
        if value <= 0xFFFF { return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        return [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }

    // MARK: Global items

    public mutating func usagePage(_ page: Int) {
        emit(tag: HIDItemTag.usagePage, type: .global, payload: Self.unsignedPayload(page))
    }

    public mutating func logicalMin(_ value: Int) {
        emit(tag: HIDItemTag.logicalMin, type: .global, payload: Self.signedPayload(value))
    }

    public mutating func logicalMax(_ value: Int) {
        emit(tag: HIDItemTag.logicalMax, type: .global, payload: Self.signedPayload(value))
    }

    public mutating func reportSize(_ bits: Int) {
        emit(tag: HIDItemTag.reportSize, type: .global, payload: Self.unsignedPayload(bits))
    }

    public mutating func reportCount(_ count: Int) {
        emit(tag: HIDItemTag.reportCount, type: .global, payload: Self.unsignedPayload(count))
    }

    public mutating func reportID(_ id: Int) {
        precondition(id >= 1 && id <= 255, "Report ID 0 is reserved by HID 1.11 §6.2.2.7")
        emit(tag: HIDItemTag.reportID, type: .global, payload: Self.unsignedPayload(id))
    }

    // MARK: Local items

    public mutating func usage(_ value: Int) {
        emit(tag: HIDItemTag.usage, type: .local, payload: Self.unsignedPayload(value))
    }

    public mutating func usageMin(_ value: Int) {
        emit(tag: HIDItemTag.usageMin, type: .local, payload: Self.unsignedPayload(value))
    }

    public mutating func usageMax(_ value: Int) {
        emit(tag: HIDItemTag.usageMax, type: .local, payload: Self.unsignedPayload(value))
    }

    // MARK: Main items

    public mutating func input(_ flags: HIDMainItemFlags) {
        emit(tag: HIDItemTag.input, type: .main, payload: Self.unsignedPayload(flags.rawValue))
    }

    public mutating func output(_ flags: HIDMainItemFlags) {
        emit(tag: HIDItemTag.output, type: .main, payload: Self.unsignedPayload(flags.rawValue))
    }

    public mutating func feature(_ flags: HIDMainItemFlags) {
        emit(tag: HIDItemTag.feature, type: .main, payload: Self.unsignedPayload(flags.rawValue))
    }

    /// Scoped collection. The closure form exists so an unbalanced descriptor is
    /// not expressible: `End Collection` is emitted by the builder, never by a
    /// call site that might forget it.
    public mutating func collection(
        _ kind: HIDCollection,
        _ body: (inout HIDReportDescriptorBuilder) -> Void
    ) {
        emit(tag: HIDItemTag.collection, type: .main, payload: [kind.rawValue])
        body(&self)
        emit(tag: HIDItemTag.endCollection, type: .main, payload: [])
    }
}

// MARK: - Report map

/// Builds the Report Map characteristic value (0x2A4B) for a given topology, and
/// the two static GATT payloads that make macOS treat this device as a real HID
/// peripheral rather than a nameless BLE accessory.
public enum HIDReportMap {

    /// The descriptor a given topology publishes.
    ///
    /// * `.perReportCharacteristic` and `.singleCharacteristicPrefixed` share one
    ///   descriptor containing three top-level Application collections, tagged
    ///   with Report IDs 1/2/3. The two topologies differ only in how the bytes
    ///   reach the host (separate characteristics vs. one characteristic with the
    ///   ID prefixed onto the payload) — the *descriptor* is identical, and it
    ///   must be, because the host parses report IDs out of this map either way.
    ///
    /// * `.bootProtocolOnly` publishes two collections with NO Report ID items.
    ///   A boot-protocol host does not parse the report map at all (that is the
    ///   entire point of boot protocol — fixed layouts known in advance), but the
    ///   Report Map characteristic is still mandatory in HOGP, and a host that
    ///   later switches Protocol Mode to Report will start parsing it. Report IDs
    ///   must be absent because boot reports are un-prefixed by definition.
    public static func descriptor(for topology: ReportTopology) -> [UInt8] {
        var builder = HIDReportDescriptorBuilder()
        switch topology {
        case .perReportCharacteristic, .singleCharacteristicPrefixed:
            appendMouseCollection(&builder, reportID: HIDReportID.mouse.rawValue)
            appendKeyboardCollection(&builder,
                                     reportID: HIDReportID.keyboard.rawValue,
                                     includeLEDOutputReport: false)
            appendConsumerCollection(&builder, reportID: HIDReportID.consumer.rawValue)
        case .bootProtocolOnly:
            appendMouseCollection(&builder, reportID: nil)
            appendKeyboardCollection(&builder, reportID: nil, includeLEDOutputReport: true)
        }
        return builder.bytes
    }

    // MARK: Mouse

    /// Mouse collection. Emits exactly `MouseReport.payloadSize` (5) bytes:
    ///
    ///     bit  0.. 2   buttons 1..3          (3 x 1 bit,  Data Var Abs)
    ///     bit  3.. 7   padding               (1 x 5 bits, Cnst Var Abs)
    ///     byte 1       dX                    (Int8, relative)
    ///     byte 2       dY                    (Int8, relative)
    ///     byte 3       Wheel   (usage 0x38)  (Int8, relative)
    ///     byte 4       AC Pan  (usage 0x0238 on the Consumer page) (Int8, relative)
    ///
    /// Logical range is -127...127 rather than -128...127. The asymmetric range is
    /// deliberate and matches every shipping BLE mouse: -128 is a legal Int8 but
    /// several host stacks treat the extreme as a sentinel, and clamping to
    /// ±127 costs one unit of travel per report at the very edge of a flick.
    /// `MouseReport.encodePayload()` clamps to the same range, so the encoder can
    /// never emit a value the descriptor says is out of range.
    ///
    /// In `.bootProtocolOnly` the same five bytes are declared even though the
    /// USB boot mouse protocol only defines the first three (buttons, dX, dY). A
    /// host running boot protocol reads three bytes and ignores the tail; a host
    /// that switches to report protocol gets scrolling for free. Truncating the
    /// collection to three bytes for the boot topology would instead break the
    /// invariant that the declared bit count equals `MouseReport.payloadSize * 8`,
    /// and would force a second encoder — a worse trade.
    private static func appendMouseCollection(
        _ b: inout HIDReportDescriptorBuilder,
        reportID: UInt8?
    ) {
        b.usagePage(HIDUsagePage.genericDesktop)
        b.usage(HIDGenericDesktopUsage.mouse)
        b.collection(.application) { b in
            if let reportID { b.reportID(Int(reportID)) }
            b.usage(HIDGenericDesktopUsage.pointer)
            b.collection(.physical) { b in
                // Buttons: three bits, one per physical button.
                b.usagePage(HIDUsagePage.button)
                b.usageMin(1)
                b.usageMax(3)
                b.logicalMin(0)
                b.logicalMax(1)
                b.reportSize(1)
                b.reportCount(3)
                b.input([.data, .variable, .absolute])

                // Five bits of padding to byte-align the motion fields.
                b.reportSize(5)
                b.reportCount(1)
                b.input(.padding)

                // dX, dY, Wheel — three signed bytes on the Generic Desktop page.
                b.usagePage(HIDUsagePage.genericDesktop)
                b.usage(HIDGenericDesktopUsage.x)
                b.usage(HIDGenericDesktopUsage.y)
                b.usage(HIDGenericDesktopUsage.wheel)
                b.logicalMin(-127)
                b.logicalMax(127)
                b.reportSize(8)
                b.reportCount(3)
                b.input([.data, .variable, .relative])

                // AC Pan — horizontal scroll, one signed byte. The Usage Page
                // switch to Consumer applies only to the following Usage; the
                // enclosing collection is still a Generic Desktop Mouse.
                b.usagePage(HIDUsagePage.consumer)
                b.usage(HIDConsumerDescriptorUsage.acPan)
                b.logicalMin(-127)
                b.logicalMax(127)
                b.reportSize(8)
                b.reportCount(1)
                b.input([.data, .variable, .relative])
            }
        }
    }

    // MARK: Keyboard

    /// Keyboard collection. Emits exactly `KeyboardReport.payloadSize` (8) bytes:
    ///
    ///     byte 0       eight modifier bits, LeftCtrl..RightGUI (usages 0xE0..0xE7)
    ///     byte 1       reserved / OEM       (Cnst Var Abs)
    ///     bytes 2..7   six-slot keycode array (Data Array Abs, logical 0...255)
    ///
    /// That is the USB boot keyboard layout verbatim, which is why the same
    /// collection serves both the report-protocol and boot-protocol topologies.
    ///
    /// LED OUTPUT REPORT — why it is conditional:
    /// A boot-protocol host is entitled to assume the standard boot keyboard
    /// interface, which includes a 1-byte output report for the Num/Caps/Scroll/
    /// Compose/Kana LEDs, and some hosts (macOS included, historically) will send
    /// one unprompted after Caps Lock is pressed. If we declare no output report
    /// at all in the boot topology, that write lands on a characteristic the host
    /// believes exists and we do not, which on some stacks aborts the connection.
    /// In the report-protocol topologies we deliberately omit it: an Output item
    /// with a Report ID implies an addressable Output Report, HOGP then expects a
    /// matching Report characteristic with a Report Reference of
    /// `[reportID, .output]` — and adding that descriptor is precisely the
    /// operation iOS raises `NSInternalInconsistencyException` for. Omitting the
    /// output report removes an entire class of failure we cannot work around,
    /// at the cost of the phone never learning the host's Caps Lock LED state,
    /// which this app has no use for.
    private static func appendKeyboardCollection(
        _ b: inout HIDReportDescriptorBuilder,
        reportID: UInt8?,
        includeLEDOutputReport: Bool
    ) {
        b.usagePage(HIDUsagePage.genericDesktop)
        b.usage(HIDGenericDesktopUsage.keyboard)
        b.collection(.application) { b in
            if let reportID { b.reportID(Int(reportID)) }

            // Byte 0: modifier bitmap.
            b.usagePage(HIDUsagePage.keyboard)
            b.usageMin(HIDKeyboardDescriptorUsage.modifierFirst)
            b.usageMax(HIDKeyboardDescriptorUsage.modifierLast)
            b.logicalMin(0)
            b.logicalMax(1)
            b.reportSize(1)
            b.reportCount(8)
            b.input([.data, .variable, .absolute])

            // Byte 1: reserved. Constant so hosts do not try to interpret it.
            b.reportSize(8)
            b.reportCount(1)
            b.input(.padding)

            if includeLEDOutputReport {
                // 5 LED bits + 3 bits of padding = one output byte.
                b.usagePage(HIDUsagePage.led)
                b.usageMin(HIDLEDUsage.numLock)
                b.usageMax(HIDLEDUsage.kana)
                b.logicalMin(0)
                b.logicalMax(1)
                b.reportSize(1)
                b.reportCount(5)
                b.output([.data, .variable, .absolute])

                b.reportSize(3)
                b.reportCount(1)
                b.output(.padding)
            }

            // Bytes 2...7: the six-key rollover array.
            //
            // Logical Maximum 255 is emitted as a two-byte signed item (26 FF 00);
            // see `signedPayload`. Usage Maximum 255 stays one byte (29 FF)
            // because usages are unsigned. Declaring the full 0...255 range rather
            // than 0...101 keeps every keycode in `HIDKeyCode` legal, including
            // the F13+ and international usages above 0x65.
            b.logicalMin(0)
            b.logicalMax(255)
            b.usagePage(HIDUsagePage.keyboard)
            b.usageMin(0)
            b.usageMax(HIDKeyboardDescriptorUsage.keyMaximum)
            b.reportSize(8)
            b.reportCount(6)
            b.input([.data, .array, .absolute])
        }
    }

    // MARK: Consumer

    /// Consumer Control collection. Emits exactly `ConsumerReport.payloadSize`
    /// (2) bytes: a single 16-bit Array field carrying one usage code, where 0
    /// means "nothing pressed".
    ///
    /// The range is Logical/Usage 0...0x029F. 0x029F is `ConsumerUsage.acDesktopShowAll`,
    /// the largest value in the contract's enum, so every case is representable.
    /// A wider range (0...0x03FF or the whole page) is not free: the host builds
    /// an element table sized by the declared usage range, and some macOS builds
    /// refuse a Consumer collection whose Usage Maximum exceeds the largest usage
    /// actually defined on the page. Pinning to exactly what we emit is the
    /// smallest promise that still works, and the test suite asserts that every
    /// `ConsumerUsage` case falls inside it.
    ///
    /// Array (not Variable) is correct here: we send at most one consumer usage at
    /// a time, and an Array field's value *is* the usage code, which is what the
    /// two-byte little-endian payload from `ConsumerReport.encodePayload()`
    /// carries. A Variable field would instead need one bit per usage — 0x2A0
    /// bits, or 84 bytes per report.
    private static func appendConsumerCollection(
        _ b: inout HIDReportDescriptorBuilder,
        reportID: UInt8?
    ) {
        b.usagePage(HIDUsagePage.consumer)
        b.usage(HIDConsumerDescriptorUsage.consumerControl)
        b.collection(.application) { b in
            if let reportID { b.reportID(Int(reportID)) }
            b.logicalMin(0)
            b.logicalMax(HIDConsumerDescriptorUsage.maximumEmitted)
            b.usageMin(0)
            b.usageMax(HIDConsumerDescriptorUsage.maximumEmitted)
            b.reportSize(16)
            b.reportCount(1)
            b.input([.data, .array, .absolute])
        }
    }
}

// MARK: - HID Information (0x2A4A)

/// Value of the HID Information characteristic.
public enum HIDInformation {
    /// Four bytes, in GATT order (HOGP §2.6):
    ///
    ///     [0..1]  bcdHID, little-endian  -> 0x0111 = HID specification 1.11
    ///     [2]     bCountryCode           -> 0x00 = not localised
    ///     [3]     Flags                  -> bit0 RemoteWake, bit1 NormallyConnectable
    ///
    /// NOTE ON THE FLAGS BYTE: this ships as `0x02`, i.e. NormallyConnectable set
    /// and RemoteWake clear. NormallyConnectable is the one that matters — it
    /// tells the host this device advertises on its own and may be reconnected at
    /// any time, which is what makes macOS re-establish the link after the Mac
    /// wakes. RemoteWake (0x01) claims the device can wake a *sleeping host* from
    /// its own initiative; an iPhone whose app has been suspended cannot honour
    /// that promise, and hosts that take it seriously will keep the link in a
    /// higher-power state waiting for a wake we will never send. If you want both
    /// bits, the value is `0x03` — but measure battery drain on the Mac first.
    public static let value = Data([0x11, 0x01, 0x00, 0x02])
}

// MARK: - PnP ID (0x2A50)

/// Value of the Device Information Service's PnP ID characteristic.
public enum PnPID {
    /// Vendor ID Source: 0x01 = Bluetooth SIG assigned, 0x02 = USB Implementer's
    /// Forum assigned. USB is the correct source for a device that presents a USB
    /// HID report descriptor, and is what macOS expects when it goes looking for
    /// a matching HID device profile.
    public static let vendorIDSource: UInt8 = 0x02

    /// USB-IF vendor ID. 0x1D6B is the Linux Foundation's block, which is the
    /// conventional choice for a software-defined HID gadget that does not own a
    /// vendor ID. Deliberately NOT Apple's 0x05AC: macOS special-cases Apple
    /// vendor IDs and will try to match Apple-specific device profiles (Magic
    /// Trackpad multitouch, keyboard backlight) that we do not implement, which
    /// produces stranger failures than being an unknown vendor.
    public static let vendorID: UInt16 = 0x1D6B

    /// Product ID within our vendor block. Arbitrary but stable — changing it
    /// makes macOS treat the device as brand new and re-run the pairing flow.
    public static let productID: UInt16 = 0x0246

    /// Product version, BCD-ish: 0x0100 = 1.0.0.
    public static let productVersion: UInt16 = 0x0100

    /// Seven bytes. Everything after the source byte is LITTLE-ENDIAN, per the
    /// Device Information Service spec (DIS 1.1 §3.9) — 0x1D6B goes on the wire
    /// as `6B 1D`, not `1D 6B`. Getting this backwards is silent: the device still
    /// pairs, macOS just files it under a nonsense vendor and never matches a HID
    /// profile, so it appears as a connected-but-inert Bluetooth device.
    public static var value: Data {
        var data = Data([vendorIDSource])
        data.append(contentsOf: withUnsafeBytes(of: vendorID.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: productID.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: productVersion.littleEndian) { Array($0) })
        return data
    }
}

// MARK: - Clamping

/// Clamp to the descriptor's declared logical range for relative motion fields.
///
/// -127 rather than Int8.min; see `appendMouseCollection`.
@inline(__always)
internal func hidClampMotion(_ value: Int) -> Int8 {
    if value <= -127 { return -127 }
    if value >= 127 { return 127 }
    return Int8(truncatingIfNeeded: value)
}

// MARK: - Encoders

public extension MouseReport {
    /// 5 bytes: buttons, dX, dY, wheel, pan. Matches `appendMouseCollection`.
    ///
    /// Only the low three button bits are emitted; `MouseButtons` is a UInt8
    /// OptionSet and a caller could construct one with bits 3...7 set, which would
    /// spill into the padding field the descriptor declared constant. Masking here
    /// keeps the wire format honest regardless of what the UI hands us.
    func encodePayload() -> Data {
        var data = Data(capacity: MouseReport.payloadSize)
        data.append(buttons.rawValue & 0x07)
        data.append(UInt8(bitPattern: hidClampMotion(dx)))
        data.append(UInt8(bitPattern: hidClampMotion(dy)))
        data.append(UInt8(bitPattern: hidClampMotion(wheel)))
        data.append(UInt8(bitPattern: hidClampMotion(pan)))
        return data
    }
}

public extension KeyboardReport {
    /// 8 bytes: modifiers, reserved, six keycode slots. Matches
    /// `appendKeyboardCollection`.
    ///
    /// `keys` is truncated to six and zero-padded to six. Truncation rather than
    /// rollover-error (`0x01 ErrorRollOver` in every slot, which is what a real
    /// keyboard controller does) is a deliberate simplification: this device's
    /// only source of simultaneous keys is programmatic chords from the app, which
    /// never exceed four, so a genuine 7-key overflow indicates a caller bug and
    /// silently dropping the extras is friendlier than blanking the whole report.
    func encodePayload() -> Data {
        var data = Data(capacity: KeyboardReport.payloadSize)
        data.append(modifiers.rawValue)
        data.append(0) // reserved / OEM byte, declared constant in the descriptor
        for key in keys.prefix(6) { data.append(key) }
        while data.count < KeyboardReport.payloadSize { data.append(0) }
        return data
    }
}

public extension ConsumerReport {
    /// 2 bytes, little-endian. Matches `appendConsumerCollection`.
    ///
    /// GATT and HID both put multi-byte report fields on the wire least
    /// significant byte first, so `ConsumerUsage.acDesktopShowAll` (0x029F) is
    /// transmitted as `9F 02`.
    func encodePayload() -> Data {
        Data([UInt8(usage & 0x00FF), UInt8((usage >> 8) & 0x00FF)])
    }
}
