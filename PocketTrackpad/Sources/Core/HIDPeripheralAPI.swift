//
//  HIDPeripheralAPI.swift
//  PocketTrackpad
//
//  SHARED CONTRACT — the public surface of the real radio, plus a stub the UI
//  and tests build against. `HIDPeripheralManager` (in Sources/HID) must
//  conform to `HIDPeripheralControlling` exactly as declared here.
//

import Foundation

/// One entry in the Connection tab's device list.
public struct KnownCentral: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var lastSeen: Date
    /// The most recent topology that successfully delivered reports to it.
    public var workingTopology: ReportTopology?

    public init(id: UUID, name: String, lastSeen: Date = .now, workingTopology: ReportTopology? = nil) {
        self.id = id
        self.name = name
        self.lastSeen = lastSeen
        self.workingTopology = workingTopology
    }
}

/// A single line in the diagnostics log.
public struct HIDLogEntry: Identifiable, Hashable, Sendable {
    public enum Level: String, Sendable { case info, success, warning, failure }

    public let id = UUID()
    public let timestamp: Date
    public let level: Level
    public let message: String

    public init(level: Level, message: String, timestamp: Date = .now) {
        self.level = level
        self.message = message
        self.timestamp = timestamp
    }
}

/// Radio control. Everything that touches CoreBluetooth sits behind this.
@MainActor
public protocol HIDPeripheralControlling: HIDSending {
    var knownCentrals: [KnownCentral] { get }
    var subscribedReports: Set<HIDReportID> { get }
    var log: [HIDLogEntry] { get }
    /// Nil until the central negotiates one; used to size the report pump.
    var negotiatedConnectionInterval: TimeInterval? { get }

    /// Publish the HID/DIS/Battery services using `topology` and begin
    /// advertising. Throws rather than trapping when iOS rejects a service or
    /// descriptor, so the diagnostics screen can try the next candidate.
    ///
    /// IMPORTANT — returning without throwing does NOT mean the topology was
    /// accepted. There are two distinct rejection paths and this call only
    /// covers the first:
    ///
    ///  1. Synchronous. `CBPeripheralManager.add(_:)` RAISES an ObjC exception
    ///     for a disallowed descriptor (0x2908). The shim converts that into a
    ///     thrown `HIDError`, which is what this signature expresses.
    ///  2. Asynchronous. Other rejections — short-form UUIDs, duplicate
    ///     publishes — are delivered much later via
    ///     `peripheralManager(_:didAdd:error:)`, long after this call has
    ///     returned successfully. Those surface as `connectionState == .failed`.
    ///
    /// Any caller sweeping topologies must therefore await a `didAdd` success
    /// or a `.failed` state before declaring a topology viable. Treating "did
    /// not throw" as success will report a broken topology as working.
    func start(topology: ReportTopology) throws

    /// Tear down services and stop advertising.
    func stop()

    /// Remove a remembered central. macOS-side unpairing still has to be done
    /// by the user in System Settings — surfaced in the UI as a hint.
    func forget(_ central: KnownCentral)

    func clearLog()
}

// MARK: - Stub

/// In-memory implementation used by SwiftUI previews, unit tests, and the
/// Simulator (where CoreBluetooth peripheral mode does not work at all).
@MainActor
@Observable
public final class StubHIDSender: HIDPeripheralControlling {
    public var connectionState: HIDConnectionState
    public var activeTopology: ReportTopology = .perReportCharacteristic
    public var knownCentrals: [KnownCentral]
    public var subscribedReports: Set<HIDReportID> = Set(HIDReportID.allCases)
    public var log: [HIDLogEntry] = []
    public var negotiatedConnectionInterval: TimeInterval? = 0.015

    /// Everything the UI has "sent", for assertions in tests.
    public private(set) var sentMouse: [MouseReport] = []
    public private(set) var sentKeyboard: [KeyboardReport] = []
    public private(set) var sentConsumer: [ConsumerReport] = []

    public init(
        connectionState: HIDConnectionState = .connected(centralName: "Sean's Mac mini"),
        knownCentrals: [KnownCentral] = [
            KnownCentral(id: UUID(), name: "Sean's Mac mini", workingTopology: .perReportCharacteristic)
        ]
    ) {
        self.connectionState = connectionState
        self.knownCentrals = knownCentrals
    }

    public func send(mouse: MouseReport)       { sentMouse.append(mouse) }
    public func send(keyboard: KeyboardReport) { sentKeyboard.append(keyboard) }
    public func send(consumer: ConsumerReport) { sentConsumer.append(consumer) }

    public func start(topology: ReportTopology) throws {
        activeTopology = topology
        connectionState = .advertising
        log.append(HIDLogEntry(level: .info, message: "Stub started with \(topology.summary)"))
    }

    public func stop() {
        connectionState = .idle
    }

    public func forget(_ central: KnownCentral) {
        knownCentrals.removeAll { $0.id == central.id }
    }

    public func clearLog() { log.removeAll() }

    public func reset() {
        sentMouse.removeAll(); sentKeyboard.removeAll(); sentConsumer.removeAll()
    }
}
