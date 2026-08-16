//
//  HIDContract.swift
//  PocketTrackpad
//
//  SHARED CONTRACT — every module compiles against the types in this file.
//  Do not change a public signature here without updating all call sites.
//
//  Design notes that constrain everything downstream:
//
//  * iOS refuses `CBUUID(string: "1812")` when adding a service to
//    CBPeripheralManager ("The specified UUID is not allowed for this
//    operation"). The fully-expanded 128-bit form is accepted. See
//    `HIDUUID` below — always use those constants, never a short form.
//
//  * HOGP normally wants one Report characteristic per report ID, each
//    carrying a Report Reference descriptor (0x2908) whose value is
//    [reportID, reportType]. iOS's CBMutableDescriptor only supports
//    kCBUUIDCharacteristicUserDescriptionString and
//    kCBUUIDCharacteristicFormatString; anything else raises an
//    NSInternalInconsistencyException at `add(_:)` time. That is an ObjC
//    exception, not a Swift error, so it cannot be caught without a shim.
//    `ReportTopology` encodes the candidate ways around it and
//    `HIDDiagnostics` measures which one a given macOS build accepts.
//
//  * Report payloads sent over the wire EXCLUDE the report ID byte when the
//    topology is `.perReportCharacteristic` (the ID is carried by the
//    descriptor) and INCLUDE it as byte 0 when the topology is
//    `.singleCharacteristicPrefixed`. Encoders below always produce the
//    payload WITHOUT the ID; the transport prepends it when required.
//

import Foundation

// MARK: - UUIDs

/// All Bluetooth SIG UUIDs this app publishes, in the fully-expanded 128-bit
/// form. The short 16-bit form is rejected by iOS for the HID service and is
/// avoided everywhere else for consistency.
public enum HIDUUID {
    public static let base = "0000%@-0000-1000-8000-00805F9B34FB"

    /// Expand a 16-bit assigned number into the 128-bit Bluetooth base UUID.
    public static func expand(_ short: String) -> String {
        String(format: base, short.uppercased())
    }

    // Services
    public static let humanInterfaceDevice = expand("1812")
    public static let deviceInformation    = expand("180A")
    public static let battery              = expand("180F")

    // HID service characteristics
    public static let hidInformation       = expand("2A4A")
    public static let reportMap            = expand("2A4B")
    public static let hidControlPoint      = expand("2A4C")
    public static let report               = expand("2A4D")
    public static let protocolMode         = expand("2A4E")
    public static let bootKeyboardInput    = expand("2A22")
    public static let bootMouseInput       = expand("2A33")

    // Device information characteristics
    public static let manufacturerName     = expand("2A29")
    public static let modelNumber          = expand("2A24")
    public static let serialNumber         = expand("2A25")
    public static let firmwareRevision     = expand("2A26")
    public static let softwareRevision     = expand("2A28")
    /// PnP ID — macOS will not bond cleanly as a HID device without it.
    public static let pnpID                = expand("2A50")

    // Battery
    public static let batteryLevel         = expand("2A19")

    // Descriptors
    public static let reportReference      = expand("2908")
    public static let clientCharacteristicConfiguration = expand("2902")
}

// MARK: - Report identity

public enum HIDReportID: UInt8, Sendable, CaseIterable, Codable {
    case mouse    = 1
    case keyboard = 2
    case consumer = 3

    public var displayName: String {
        switch self {
        case .mouse:    return "Mouse"
        case .keyboard: return "Keyboard"
        case .consumer: return "Consumer Control"
        }
    }
}

/// Report Reference descriptor's second byte.
public enum HIDReportType: UInt8, Sendable {
    case input   = 1
    case output  = 2
    case feature = 3
}

// MARK: - Report topology

/// How report characteristics are laid out inside the HID service.
///
/// The whole product depends on at least one of these being accepted by both
/// iOS (as peripheral) and macOS (as central). `HIDDiagnostics` exists to find
/// out which, on real hardware, because this is undocumented behaviour.
public enum ReportTopology: String, Sendable, CaseIterable, Codable {
    /// Spec-correct: one 0x2A4D characteristic per report ID, each with a
    /// 0x2908 Report Reference descriptor. Descriptor add may throw on iOS.
    case perReportCharacteristic

    /// One 0x2A4D characteristic, no Report Reference descriptor. Every
    /// notification is prefixed with its report ID byte. Non-conformant, but
    /// costs nothing to try and some hosts tolerate it.
    case singleCharacteristicPrefixed

    /// Boot-protocol characteristics only (0x2A22 keyboard, 0x2A33 mouse).
    /// No report IDs, no consumer control, but the descriptor problem
    /// disappears entirely. Guaranteed-ish fallback for mouse + keyboard.
    case bootProtocolOnly

    public var summary: String {
        switch self {
        case .perReportCharacteristic:
            return "Per-report characteristics with 0x2908 descriptors (spec-correct)"
        case .singleCharacteristicPrefixed:
            return "Single report characteristic, report ID prefixed in payload"
        case .bootProtocolOnly:
            return "Boot keyboard + boot mouse characteristics only"
        }
    }

    /// Report IDs this topology can carry.
    public var supportedReports: [HIDReportID] {
        switch self {
        case .perReportCharacteristic, .singleCharacteristicPrefixed:
            return HIDReportID.allCases
        case .bootProtocolOnly:
            return [.mouse, .keyboard]
        }
    }
}

// MARK: - Reports

public struct MouseButtons: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let left   = MouseButtons(rawValue: 1 << 0)
    public static let right  = MouseButtons(rawValue: 1 << 1)
    public static let middle = MouseButtons(rawValue: 1 << 2)
    public static let none: MouseButtons = []
}

public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let leftControl  = KeyModifiers(rawValue: 1 << 0)
    public static let leftShift    = KeyModifiers(rawValue: 1 << 1)
    public static let leftOption   = KeyModifiers(rawValue: 1 << 2)
    public static let leftCommand  = KeyModifiers(rawValue: 1 << 3)
    public static let rightControl = KeyModifiers(rawValue: 1 << 4)
    public static let rightShift   = KeyModifiers(rawValue: 1 << 5)
    public static let rightOption  = KeyModifiers(rawValue: 1 << 6)
    public static let rightCommand = KeyModifiers(rawValue: 1 << 7)
    public static let none: KeyModifiers = []
}

/// A report payload, WITHOUT its leading report ID byte.
public protocol HIDReportEncodable: Sendable, Equatable {
    static var reportID: HIDReportID { get }
    /// Fixed size in bytes, must match the Report Count/Size in the report map.
    static var payloadSize: Int { get }
    func encodePayload() -> Data
}

public extension HIDReportEncodable {
    /// Payload with the report ID prepended, for `.singleCharacteristicPrefixed`.
    func encodePrefixed() -> Data {
        var d = Data([Self.reportID.rawValue])
        d.append(encodePayload())
        return d
    }
}

// MARK: - Report values

/// 3 bytes of movement resolution: buttons, dx, dy, wheel, pan.
/// Layout must match `HIDReportMap.descriptor`.
public struct MouseReport: HIDReportEncodable {
    public static let reportID: HIDReportID = .mouse
    public static let payloadSize = 5

    public var buttons: MouseButtons
    /// Clamped to Int8 range by the encoder.
    public var dx: Int
    public var dy: Int
    public var wheel: Int
    public var pan: Int

    public init(buttons: MouseButtons = .none, dx: Int = 0, dy: Int = 0, wheel: Int = 0, pan: Int = 0) {
        self.buttons = buttons
        self.dx = dx
        self.dy = dy
        self.wheel = wheel
        self.pan = pan
    }

    public var isIdle: Bool {
        buttons.isEmpty && dx == 0 && dy == 0 && wheel == 0 && pan == 0
    }
}

/// Standard boot-compatible keyboard report: modifiers, reserved, 6 keycodes.
public struct KeyboardReport: HIDReportEncodable {
    public static let reportID: HIDReportID = .keyboard
    public static let payloadSize = 8

    public var modifiers: KeyModifiers
    /// Up to 6 concurrently-held HID usage codes. Extra entries are dropped.
    public var keys: [UInt8]

    public init(modifiers: KeyModifiers = .none, keys: [UInt8] = []) {
        self.modifiers = modifiers
        self.keys = keys
    }

    public static let released = KeyboardReport()
}

/// Consumer control: a single 16-bit usage code, 0 means "released".
public struct ConsumerReport: HIDReportEncodable {
    public static let reportID: HIDReportID = .consumer
    public static let payloadSize = 2

    public var usage: UInt16

    public init(usage: UInt16 = 0) { self.usage = usage }
    public init(_ usage: ConsumerUsage) { self.usage = usage.rawValue }

    public static let released = ConsumerReport(usage: 0)
}

/// Consumer page (0x0C) usages used by the Remotes tab.
public enum ConsumerUsage: UInt16, Sendable, CaseIterable, Codable {
    case play              = 0x00B0
    case pause             = 0x00B1
    case stop              = 0x00B7
    case playPause         = 0x00CD
    case scanNext          = 0x00B5
    case scanPrevious      = 0x00B6
    case fastForward       = 0x00B3
    case rewind            = 0x00B4
    case volumeUp          = 0x00E9
    case volumeDown        = 0x00EA
    case mute              = 0x00E2
    case brightnessUp      = 0x006F
    case brightnessDown    = 0x0070
    case acHome            = 0x0223
    case acBack            = 0x0224
    case acForward         = 0x0225
    case acRefresh         = 0x0227
    case acSearch          = 0x0221
    case acDesktopShowAll  = 0x029F
    case power             = 0x0030
    case sleep             = 0x0032
}

// MARK: - Transport

public enum HIDConnectionState: Equatable, Sendable {
    case poweredOff
    case unauthorized
    case unsupported
    case idle
    case advertising
    case connected(centralName: String?)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// What the UI layer is allowed to know about the radio. Kept deliberately
/// narrow so the Trackpad and Remotes features can be built and unit-tested
/// against a stub before the real peripheral manager exists.
@MainActor
public protocol HIDSending: AnyObject {
    var connectionState: HIDConnectionState { get }
    var activeTopology: ReportTopology { get }

    func send(mouse: MouseReport)
    func send(keyboard: KeyboardReport)
    func send(consumer: ConsumerReport)

    /// Convenience: press then release a consumer usage.
    func tap(consumer usage: ConsumerUsage)
    /// Convenience: press then release a keycode with modifiers.
    func tap(key usage: UInt8, modifiers: KeyModifiers)
}

public extension HIDSending {
    func tap(consumer usage: ConsumerUsage) {
        send(consumer: ConsumerReport(usage))
        send(consumer: .released)
    }

    func tap(key usage: UInt8, modifiers: KeyModifiers = .none) {
        send(keyboard: KeyboardReport(modifiers: modifiers, keys: [usage]))
        send(keyboard: .released)
    }
}

// MARK: - Errors

public enum HIDError: LocalizedError, Equatable {
    case serviceRejected(String)
    case descriptorRejected(String)
    case bluetoothUnavailable(String)
    case notSubscribed
    case topologyUnsupported(ReportTopology)

    public var errorDescription: String? {
        switch self {
        case .serviceRejected(let m):     return "The HID service was rejected: \(m)"
        case .descriptorRejected(let m):  return "A report descriptor was rejected: \(m)"
        case .bluetoothUnavailable(let m):return "Bluetooth is unavailable: \(m)"
        case .notSubscribed:              return "No central is subscribed to the report characteristic."
        case .topologyUnsupported(let t): return "This Mac did not accept: \(t.summary)"
        }
    }
}
