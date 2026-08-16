//
//  HIDPeripheralManager.swift
//  PocketTrackpad
//
//  The real radio. Publishes HID-over-GATT, Device Information and Battery
//  services, advertises, tracks subscriptions, and feeds the `ReportPump`.
//
//  THE ONE BEHAVIOUR THIS FILE MUST GET RIGHT
//  ------------------------------------------
//  `start(topology:)` must THROW, never trap. `HIDDiagnostics` works by trying
//  each `ReportTopology` in turn and keeping the first one iOS accepts and macOS
//  enumerates. If a rejected topology terminates the process, the diagnostics
//  screen cannot exist, and the product's answer to "it doesn't connect to my
//  Mac" becomes a shrug. Every `CBPeripheralManager.add(_:)` and every
//  `CBMutableDescriptor` construction therefore goes through `PTExceptionCatcher`
//  (see that header for the gory details), and every failure becomes an
//  `HIDError` plus a `.failure` log line.
//
//  CONCURRENCY
//  -----------
//  The class is `@MainActor`; the `CBPeripheralManager` is created with
//  `queue: .main`, so every delegate callback genuinely arrives on the main
//  thread. `CBPeripheralManagerDelegate` is an `@objc` protocol with no isolation,
//  so the callbacks are declared `nonisolated` and immediately re-enter the actor
//  with `MainActor.assumeIsolated`. That is not a fudge: `assumeIsolated` is a
//  runtime assertion that traps if the callback ever arrives off-main, which is
//  strictly better than a `Task { @MainActor in … }` hop. A hop would also
//  REORDER callbacks — `didSubscribeTo` could land after the first report — and
//  reordering is exactly what the backpressure protocol cannot tolerate.
//
//  BACKGROUNDING IS A KNOWN LIMITATION
//  -----------------------------------
//  See `startAdvertising()`.
//

import Foundation
import CoreBluetooth
// `@Observable` / `@ObservationIgnored` live in the Observation module, which
// Foundation does not re-export. Imported explicitly so this file does not
// silently depend on SwiftUI being pulled into the target by something else.
import Observation

#if canImport(UIKit)
import UIKit
#endif

// If PTExceptionCatcher is built as its own SwiftPM target rather than reached
// through the app target's bridging header, uncomment the import:
// import ObjCShim

@MainActor
@Observable
public final class HIDPeripheralManager: NSObject, HIDPeripheralControlling {

    // MARK: - Observable state (contract surface)

    public private(set) var connectionState: HIDConnectionState = .idle
    public private(set) var activeTopology: ReportTopology = .perReportCharacteristic
    public private(set) var knownCentrals: [KnownCentral] = []
    public private(set) var subscribedReports: Set<HIDReportID> = []
    public private(set) var log: [HIDLogEntry] = []

    /// CoreBluetooth's peripheral role exposes NO API for the negotiated
    /// connection interval — not on `CBCentral`, not on `CBPeripheralManager`, not
    /// in any delegate callback. (`CBCentral.maximumUpdateValueLength` reports the
    /// negotiated ATT MTU, which is a different negotiation entirely.) This stays
    /// nil unless something upstream measures an interval and feeds it in via
    /// `setNegotiatedConnectionInterval(_:)`; the pump falls back to its 15 ms
    /// default, which is the slow end of what macOS negotiates for HID and is
    /// therefore always safe, just not always optimal.
    public private(set) var negotiatedConnectionInterval: TimeInterval?

    // MARK: - Configuration

    /// When true, report characteristics are published with
    /// `.readEncryptionRequired` instead of plain `.readable`.
    ///
    /// HOGP §5 requires encryption on the Report characteristics, and macOS will
    /// happily drive an unencrypted HID device it has already bonded with, so the
    /// flag looks academic — but it changes the pairing dance materially. With
    /// encryption required, the first read or subscribe from an unbonded Mac
    /// triggers an insufficient-authentication ATT error, which is what PROMPTS
    /// the pairing sheet. Without it, some Macs subscribe unencrypted, never
    /// prompt, and then the HID driver refuses to attach — a device that connects
    /// and does nothing. Defaults to true for that reason. Set false only when
    /// bisecting a pairing failure. (`.notifyEncryptionRequired` is the even
    /// stricter sibling that gates the SUBSCRIBE rather than the read; it is not
    /// used because a Mac that fails to subscribe gives us no callback at all to
    /// diagnose from.)
    public var requireEncryption: Bool = true

    /// Maximum log lines retained. The diagnostics screen renders the whole array.
    public static let logLimit = 500

    // MARK: - Internals

    @ObservationIgnored private var peripheral: CBPeripheralManager?
    @ObservationIgnored private let bondStore: BondStore
    @ObservationIgnored private var pump: ReportPump!

    /// Report characteristics keyed by report ID, for `.perReportCharacteristic`.
    @ObservationIgnored private var reportCharacteristics: [HIDReportID: CBMutableCharacteristic] = [:]
    /// Reverse lookup so `didSubscribeTo` can identify which one fired. All three
    /// share UUID 0x2A4D, so identity — not UUID — is the only way to tell them
    /// apart.
    @ObservationIgnored private var reportIDsByCharacteristic: [ObjectIdentifier: HIDReportID] = [:]
    /// The single 0x2A4D characteristic, for `.singleCharacteristicPrefixed`.
    @ObservationIgnored private var singleReportCharacteristic: CBMutableCharacteristic?
    /// Boot characteristics, for `.bootProtocolOnly`.
    @ObservationIgnored private var bootMouseCharacteristic: CBMutableCharacteristic?
    @ObservationIgnored private var bootKeyboardCharacteristic: CBMutableCharacteristic?

    @ObservationIgnored private var protocolModeCharacteristic: CBMutableCharacteristic?
    @ObservationIgnored private var batteryLevelCharacteristic: CBMutableCharacteristic?

    /// Last payload written per report, so a `didReceiveRead` on a report
    /// characteristic can be answered. HOGP hosts do read reports directly; an
    /// unanswered ATT read stalls the link until it times out.
    @ObservationIgnored private var lastPayload: [HIDReportID: Data] = [:]

    /// Centrals currently subscribed to at least one report characteristic.
    @ObservationIgnored private var subscribedCentrals: [UUID: CBCentral] = [:]

    /// Services successfully handed to `add(_:)`, awaiting `didAdd`.
    @ObservationIgnored private var pendingServiceAdds: Set<CBUUID> = []
    /// Services `didAdd` confirmed.
    @ObservationIgnored private var publishedServices: Set<CBUUID> = []

    /// Topology the caller last asked for, replayed if Bluetooth powers on late.
    @ObservationIgnored private var desiredTopology: ReportTopology?

    /// Host's current Protocol Mode. 0x00 = Boot, 0x01 = Report.
    @ObservationIgnored private var protocolMode: UInt8 = 0x01

    @ObservationIgnored private var batteryObserver: NSObjectProtocol?

    // MARK: - Init

    public init(bondStore: BondStore = BondStore()) {
        self.bondStore = bondStore
        super.init()
        self.knownCentrals = bondStore.all()
        self.pump = ReportPump(transport: self, topology: activeTopology)

        // The peripheral manager is created eagerly, before `start(topology:)`, so
        // `connectionState` reflects the radio's real state (off / unauthorised /
        // unsupported) the moment the Connection tab appears rather than only
        // after the user taps something.
        //
        // `queue: .main` is load-bearing — see the concurrency note in the file
        // header. No restore identifier is passed: state restoration requires the
        // `bluetooth-peripheral` background mode AND an implementation of
        // `willRestoreState`, and a restored session whose services were built by
        // a previous launch's topology is a worse starting point than a clean
        // rebuild. `willRestoreState` is implemented below anyway, defensively.
        self.peripheral = CBPeripheralManager(delegate: self, queue: .main)

        configureBatteryMonitoring()
        appendLog(.info, "HIDPeripheralManager initialised. Remembered centrals: \(knownCentrals.count).")
    }

    // MARK: - HIDPeripheralControlling

    public func start(topology: ReportTopology) throws {
        desiredTopology = topology
        activeTopology = topology
        pump.setTopology(topology)

        guard let peripheral else {
            let message = "CBPeripheralManager was never created."
            appendLog(.failure, message)
            throw HIDError.bluetoothUnavailable(message)
        }

        guard peripheral.state == .poweredOn else {
            let message = Self.describe(peripheral.state)
            appendLog(.warning, "start(topology:) deferred — \(message)")
            throw HIDError.bluetoothUnavailable(message)
        }

        appendLog(.info, "Starting: \(topology.summary)")

        // Always tear down first. `add(_:)` on a UUID that is already published
        // fails asynchronously with a vague error, and the diagnostics screen
        // calls start() repeatedly with different topologies.
        teardownServices(stopAdvertising: true)

        let hidService = try makeHIDService(topology: topology)
        try addService(hidService, describedAs: "HID service (\(topology.rawValue))", carriesDescriptors: topology == .perReportCharacteristic)

        let disService = makeDeviceInformationService()
        try addService(disService, describedAs: "Device Information service", carriesDescriptors: false)

        let batteryService = makeBatteryService()
        try addService(batteryService, describedAs: "Battery service", carriesDescriptors: false)

        startAdvertising()
        pump.start()
    }

    public func stop() {
        appendLog(.info, "Stopping.")
        desiredTopology = nil
        pump.stop()
        pump.reset()
        teardownServices(stopAdvertising: true)
        subscribedCentrals.removeAll()
        subscribedReports.removeAll()
        if case .failed = connectionState {
            // Preserve a failure reason the user has not seen yet.
        } else {
            connectionState = .idle
        }
    }

    public func forget(_ central: KnownCentral) {
        bondStore.remove(central)
        knownCentrals = bondStore.all()
        appendLog(
            .warning,
            "Forgot \"\(central.name)\" locally. CoreBluetooth still holds the bond — "
            + "the user must also remove this device in macOS System Settings > Bluetooth."
        )
    }

    public func clearLog() {
        log.removeAll(keepingCapacity: true)
    }

    // MARK: - HIDSending

    public func send(mouse: MouseReport) {
        pump.enqueue(mouse: mouse)
    }

    public func send(keyboard: KeyboardReport) {
        pump.enqueue(keyboard: keyboard)
    }

    public func send(consumer: ConsumerReport) {
        pump.enqueue(consumer: consumer)
    }

    // MARK: - Tuning hooks

    /// Feed in a measured connection interval (from a host-side tool, or from
    /// timing `peripheralManagerIsReady` callbacks) so the pump can match it.
    /// See `negotiatedConnectionInterval` for why this cannot be read from
    /// CoreBluetooth.
    public func setNegotiatedConnectionInterval(_ interval: TimeInterval?) {
        negotiatedConnectionInterval = interval
        if let interval {
            pump.setFlushInterval(interval)
            appendLog(.info, "Pump cadence set to \(Int(interval * 1000)) ms.")
        }
    }

    /// Diagnostics counters from the pump, surfaced without exposing the pump.
    public var pumpStatistics: (pending: Int, delivered: Int, undeliverable: Int, overflowed: Int, blocked: Bool) {
        (pump.pendingCount, pump.deliveredCount, pump.undeliverableCount, pump.overflowCount, pump.isBlocked)
    }

    // MARK: - Service construction

    private func makeHIDService(topology: ReportTopology) throws -> CBMutableService {
        // ALWAYS the 128-bit form. `CBUUID(string: "1812")` is accepted by the
        // initialiser and then rejected by `add(_:)` with "The specified UUID is
        // not allowed for this operation" — a failure that arrives asynchronously,
        // several seconds later, in `didAdd`, with no indication that the short
        // form was the problem. Same applies to every other UUID in `HIDUUID`.
        let service = CBMutableService(type: CBUUID(string: HIDUUID.humanInterfaceDevice), primary: true)

        let descriptorBytes = HIDReportMap.descriptor(for: topology)
        appendLog(.info, "Report map for \(topology.rawValue): \(descriptorBytes.count) bytes.")

        // Report Map — static, so it carries a cached value. CoreBluetooth answers
        // reads of cached-value characteristics itself and never calls
        // didReceiveRead for them, which is exactly what we want for a value that
        // is read once at enumeration time and never changes.
        let reportMap = CBMutableCharacteristic(
            type: CBUUID(string: HIDUUID.reportMap),
            properties: [.read],
            value: Data(descriptorBytes),
            permissions: [.readable]
        )

        let hidInformation = CBMutableCharacteristic(
            type: CBUUID(string: HIDUUID.hidInformation),
            properties: [.read],
            value: HIDInformation.value,
            permissions: [.readable]
        )

        // Control Point is where the host tells us it is suspending (0x00) or
        // waking (0x01). Write-without-response by spec; a cached value is
        // forbidden on a writable characteristic, so `value` must be nil.
        let controlPoint = CBMutableCharacteristic(
            type: CBUUID(string: HIDUUID.hidControlPoint),
            properties: [.writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        // Protocol Mode lets the host switch between Boot and Report protocol.
        // Mandatory whenever boot characteristics are present, optional otherwise —
        // published always, because a macOS build that probes for it and finds it
        // missing has been observed to abandon enumeration rather than assume
        // Report protocol.
        let protocolModeCharacteristic = CBMutableCharacteristic(
            type: CBUUID(string: HIDUUID.protocolMode),
            properties: [.read, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )
        self.protocolModeCharacteristic = protocolModeCharacteristic

        var characteristics: [CBCharacteristic] = [
            reportMap, hidInformation, controlPoint, protocolModeCharacteristic
        ]

        reportCharacteristics.removeAll()
        reportIDsByCharacteristic.removeAll()
        singleReportCharacteristic = nil
        bootMouseCharacteristic = nil
        bootKeyboardCharacteristic = nil

        switch topology {
        case .perReportCharacteristic:
            for reportID in topology.supportedReports {
                let characteristic = makeReportCharacteristic(uuid: HIDUUID.report)
                try attachReportReference(to: characteristic, reportID: reportID, type: .input)
                reportCharacteristics[reportID] = characteristic
                reportIDsByCharacteristic[ObjectIdentifier(characteristic)] = reportID
                characteristics.append(characteristic)
            }

        case .singleCharacteristicPrefixed:
            // No Report Reference descriptor at all, which is the entire point:
            // this topology exists to sidestep the descriptor that iOS refuses.
            // The report ID rides in byte 0 of every notification instead, which is
            // not HOGP-conformant — a strict host will parse byte 0 as the first
            // data byte and see garbage. Cheap to try, and some hosts cope.
            let characteristic = makeReportCharacteristic(uuid: HIDUUID.report)
            singleReportCharacteristic = characteristic
            // One characteristic, three report IDs, so the reverse map cannot be
            // one-to-one. It is registered under `.mouse` purely so
            // `reportID(for:)` returns non-nil; `didSubscribeTo` special-cases this
            // topology and marks all three reports subscribed at once.
            reportIDsByCharacteristic[ObjectIdentifier(characteristic)] = .mouse
            characteristics.append(characteristic)

        case .bootProtocolOnly:
            // Boot characteristics have their own UUIDs and implicit, fixed report
            // formats, so no report IDs and no Report Reference descriptors are
            // involved anywhere. This is the topology that cannot hit the iOS
            // descriptor restriction by construction.
            let mouse = makeReportCharacteristic(uuid: HIDUUID.bootMouseInput)
            let keyboard = makeReportCharacteristic(uuid: HIDUUID.bootKeyboardInput)
            bootMouseCharacteristic = mouse
            bootKeyboardCharacteristic = keyboard
            reportIDsByCharacteristic[ObjectIdentifier(mouse)] = .mouse
            reportIDsByCharacteristic[ObjectIdentifier(keyboard)] = .keyboard
            characteristics.append(contentsOf: [mouse, keyboard])
        }

        service.characteristics = characteristics
        return service
    }

    /// A notifying input report characteristic.
    ///
    /// `.notify` + `.read` with a nil value: CoreBluetooth forbids a cached value
    /// on anything notifying, and a report's value changes every 15 ms anyway, so
    /// reads are answered live in `didReceiveRead`.
    ///
    /// No Client Characteristic Configuration descriptor (0x2902) is created.
    /// CoreBluetooth adds it implicitly for every notifying characteristic and
    /// raises an exception if you supply your own — one of the few places its
    /// behaviour is actually documented.
    private func makeReportCharacteristic(uuid: String) -> CBMutableCharacteristic {
        CBMutableCharacteristic(
            type: CBUUID(string: uuid),
            properties: [.read, .notify],
            value: nil,
            permissions: requireEncryption ? [.readEncryptionRequired] : [.readable]
        )
    }

    /// Attach the HOGP-mandated Report Reference descriptor (0x2908), value
    /// `[reportID, reportType]`.
    ///
    /// THIS IS THE CALL THAT BREAKS. iOS's `CBMutableDescriptor` supports exactly
    /// two descriptor UUIDs (User Description and Presentation Format); anything
    /// else raises `NSInternalInconsistencyException`. Which call raises has moved
    /// between iOS releases — sometimes the `CBMutableDescriptor` initialiser,
    /// sometimes `add(_:)` — so BOTH are wrapped, here and in `addService`.
    private func attachReportReference(
        to characteristic: CBMutableCharacteristic,
        reportID: HIDReportID,
        type: HIDReportType
    ) throws {
        var descriptor: CBMutableDescriptor?
        do {
            try PTExceptionCatcher.tryBlock {
                descriptor = CBMutableDescriptor(
                    type: CBUUID(string: HIDUUID.reportReference),
                    value: Data([reportID.rawValue, type.rawValue])
                )
            }
        } catch {
            let message = "0x2908 Report Reference for \(reportID.displayName) — \(error.localizedDescription)"
            appendLog(.failure, "CBMutableDescriptor raised: \(message)")
            throw HIDError.descriptorRejected(message)
        }

        guard let descriptor else {
            let message = "0x2908 Report Reference for \(reportID.displayName) could not be constructed."
            appendLog(.failure, message)
            throw HIDError.descriptorRejected(message)
        }

        // Assigning `descriptors` can itself raise on some iOS versions when the
        // characteristic already carries CoreBluetooth's implicit 0x2902.
        do {
            try PTExceptionCatcher.tryBlock {
                characteristic.descriptors = [descriptor]
            }
        } catch {
            let message = "Assigning 0x2908 to the \(reportID.displayName) report — \(error.localizedDescription)"
            appendLog(.failure, message)
            throw HIDError.descriptorRejected(message)
        }
    }

    /// Device Information Service.
    ///
    /// PnP ID is the important one. Without it macOS treats the peripheral as a
    /// generic BLE accessory: it will pair, it will connect, it will show up in
    /// System Settings — and it will never be handed to the HID driver, so the
    /// cursor never moves and no keystroke lands. Every other characteristic here
    /// is cosmetic by comparison (they populate the "About" panel), but they are
    /// published because a DIS with a lone PnP ID looks synthetic to the host and
    /// costs nothing to fill in.
    private func makeDeviceInformationService() -> CBMutableService {
        let service = CBMutableService(type: CBUUID(string: HIDUUID.deviceInformation), primary: true)

        func staticCharacteristic(_ uuid: String, _ value: Data) -> CBMutableCharacteristic {
            CBMutableCharacteristic(
                type: CBUUID(string: uuid),
                properties: [.read],
                value: value,
                permissions: [.readable]
            )
        }

        let modelName: String
        #if canImport(UIKit)
        modelName = UIDevice.current.model
        #else
        modelName = "Pocket Trackpad"
        #endif

        service.characteristics = [
            staticCharacteristic(HIDUUID.manufacturerName, Data("Pocket Trackpad".utf8)),
            staticCharacteristic(HIDUUID.modelNumber, Data(modelName.utf8)),
            staticCharacteristic(HIDUUID.serialNumber, Data(Self.stableSerialNumber.utf8)),
            staticCharacteristic(HIDUUID.firmwareRevision, Data("1.0".utf8)),
            staticCharacteristic(HIDUUID.softwareRevision, Data(Self.softwareRevision.utf8)),
            staticCharacteristic(HIDUUID.pnpID, PnPID.value)
        ]
        return service
    }

    /// Battery Service, reporting the phone's real charge.
    private func makeBatteryService() -> CBMutableService {
        let service = CBMutableService(type: CBUUID(string: HIDUUID.battery), primary: true)
        let characteristic = CBMutableCharacteristic(
            type: CBUUID(string: HIDUUID.batteryLevel),
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        batteryLevelCharacteristic = characteristic
        service.characteristics = [characteristic]
        return service
    }

    /// Wrap `add(_:)` in the ObjC shim and convert a raised exception into the
    /// right `HIDError`.
    ///
    /// `carriesDescriptors` decides between `.descriptorRejected` and
    /// `.serviceRejected`: both are the same NSException as far as iOS is
    /// concerned, but the diagnostics screen reacts differently — a descriptor
    /// rejection means "try the next topology", a service rejection means "this
    /// device cannot host the service at all, stop trying".
    private func addService(
        _ service: CBMutableService,
        describedAs description: String,
        carriesDescriptors: Bool
    ) throws {
        guard let peripheral else {
            throw HIDError.bluetoothUnavailable("CBPeripheralManager was never created.")
        }
        do {
            try PTExceptionCatcher.tryBlock {
                peripheral.add(service)
            }
        } catch {
            let message = "\(description): \(error.localizedDescription)"
            appendLog(.failure, "add(_:) raised — \(message)")
            if carriesDescriptors {
                throw HIDError.descriptorRejected(message)
            } else {
                throw HIDError.serviceRejected(message)
            }
        }
        pendingServiceAdds.insert(service.uuid)
        appendLog(.info, "add(_:) accepted \(description); awaiting didAdd.")
    }

    private func teardownServices(stopAdvertising: Bool) {
        guard let peripheral else { return }
        if stopAdvertising, peripheral.isAdvertising {
            peripheral.stopAdvertising()
        }
        // `removeAllServices` is documented not to raise, but it is three lines to
        // be certain, and a raise here would take down a diagnostics sweep midway.
        do {
            try PTExceptionCatcher.tryBlock {
                peripheral.removeAllServices()
            }
        } catch {
            appendLog(.warning, "removeAllServices() raised: \(error.localizedDescription)")
        }
        pendingServiceAdds.removeAll()
        publishedServices.removeAll()
    }

    // MARK: - Advertising

    private func startAdvertising() {
        guard let peripheral else { return }
        let name = AppSettings.shared.advertisedName

        // Only two keys are legal for a peripheral: LocalName and ServiceUUIDs.
        // Anything else is silently dropped by CoreBluetooth.
        //
        // BACKGROUNDING IS A KNOWN LIMITATION, NOT A BUG TO CHASE.
        // When the app leaves the foreground, iOS rewrites this advertisement: the
        // local name is dropped entirely, and the service UUIDs are moved out of
        // the ADV packet into the "overflow" area — a special, Apple-proprietary
        // section that only iOS/macOS CoreBluetooth CENTRALS can decode, and only
        // when they scan with an explicit UUID filter. macOS's Bluetooth
        // *settings* pane and its HID auto-connect logic do not scan that way, so
        // a backgrounded PocketTrackpad is effectively invisible for INITIAL
        // pairing. An ALREADY-BONDED Mac can still reconnect, because reconnection
        // is driven by the Mac and does not depend on parsing our advertisement.
        // There is no entitlement, background mode, or advertising key that
        // changes this. The correct product response is to tell the user to keep
        // the app in the foreground while pairing.
        let advertisement: [String: Any] = [
            CBAdvertisementDataLocalNameKey: name,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: HIDUUID.humanInterfaceDevice)]
        ]

        peripheral.startAdvertising(advertisement)
        connectionState = .advertising
        appendLog(.info, "Advertising as \"\(name)\" with the HID service UUID.")
    }

    // MARK: - Logging

    private func appendLog(_ level: HIDLogEntry.Level, _ message: String) {
        log.append(HIDLogEntry(level: level, message: message))
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
    }

    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn:     return "Bluetooth is on."
        case .poweredOff:    return "Bluetooth is switched off."
        case .unauthorized:  return "This app is not authorised to use Bluetooth."
        case .unsupported:   return "This device does not support Bluetooth LE peripheral mode (the Simulator never does)."
        case .resetting:     return "The Bluetooth stack is resetting; try again shortly."
        case .unknown:       return "The Bluetooth state is not known yet."
        @unknown default:    return "The Bluetooth state is not recognised by this build."
        }
    }

    private static var softwareRevision: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    /// A serial number that is stable for this install but is not a device
    /// identifier. `identifierForVendor` would be the obvious choice; it is
    /// deliberately avoided because DIS characteristics are readable by any
    /// central that connects, bonded or not, and publishing a cross-app-stable
    /// identifier over an unauthenticated link is a tracking vector.
    private static let stableSerialNumber: String = {
        let key = "hid.serialNumber"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let generated = String(UUID().uuidString.prefix(8))
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()

    // MARK: - Battery

    private func configureBatteryMonitoring() {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Posted on the main queue because that is the queue we asked for.
            MainActor.assumeIsolated {
                self?.publishBatteryLevel()
            }
        }
        #endif
    }

    /// Current charge as the Battery Level characteristic wants it: 0...100.
    private var batteryPercent: UInt8 {
        #if canImport(UIKit)
        let level = UIDevice.current.batteryLevel
        // -1 means monitoring is off or the value is unknown. Reporting 0% would
        // make macOS pop a "keyboard battery is low" alert on every connect, so an
        // unknown battery is reported as full.
        guard level >= 0 else { return 100 }
        return UInt8(max(0, min(100, Int((level * 100).rounded()))))
        #else
        return 100
        #endif
    }

    private func publishBatteryLevel() {
        guard let peripheral, let characteristic = batteryLevelCharacteristic else { return }
        let value = Data([batteryPercent])
        // Battery notifications are fire-and-forget: if the queue is full we skip
        // this update rather than compete with input reports, because the next
        // battery change is at most one percent away and input latency is not.
        _ = peripheral.updateValue(value, for: characteristic, onSubscribedCentrals: nil)
    }

    // MARK: - Subscription bookkeeping

    private func reportID(for characteristic: CBCharacteristic) -> HIDReportID? {
        if let mapped = reportIDsByCharacteristic[ObjectIdentifier(characteristic)] {
            return mapped
        }
        // Defensive fallback. CoreBluetooth hands back the exact
        // CBMutableCharacteristic instances we added, so the identity lookup should
        // always hit; if a future iOS starts vending proxies, fall back to UUID —
        // which is unambiguous for the boot characteristics and ambiguous only for
        // 0x2A4D, where the caller already treats a subscribe as "all reports".
        if characteristic.uuid == CBUUID(string: HIDUUID.bootMouseInput) { return .mouse }
        if characteristic.uuid == CBUUID(string: HIDUUID.bootKeyboardInput) { return .keyboard }
        return nil
    }

    private func rememberCentral(_ central: CBCentral) {
        // CBCentral exposes ONLY `identifier` and `maximumUpdateValueLength`. There
        // is no name: the peripheral role cannot read the connected central's GAP
        // Device Name without also acting as a central and connecting back, which
        // iOS does not permit against an active link. So the display name comes
        // from whatever we stored previously, and is otherwise a placeholder the
        // user can live with. This is why `HIDConnectionState.connected` carries an
        // OPTIONAL name.
        let existing = bondStore.central(with: central.identifier)
        bondStore.touch(
            id: central.identifier,
            name: existing?.name,
            workingTopology: activeTopology
        )
        knownCentrals = bondStore.all()
    }

    private func currentCentralName() -> String? {
        guard let identifier = subscribedCentrals.keys.first else { return nil }
        return bondStore.central(with: identifier)?.name
    }
}

// MARK: - ReportPumpTransport

extension HIDPeripheralManager: ReportPumpTransport {

    /// Hand one encoded report to CoreBluetooth.
    ///
    /// The `false` return from `updateValue` is the ONLY backpressure signal the
    /// peripheral role gets, and it is not an error — it means "the transmit queue
    /// is full, I will call you back". Treating it as a failure and dropping the
    /// report is the single most common bug in BLE HID code, and it shows up as a
    /// cursor that stutters under fast motion and keys that occasionally stick.
    public func transmit(_ payload: Data, reportID: HIDReportID) -> ReportTransmitResult {
        guard let peripheral else { return .undeliverable }
        guard !subscribedCentrals.isEmpty else { return .undeliverable }

        let characteristic: CBMutableCharacteristic?
        switch activeTopology {
        case .perReportCharacteristic:
            characteristic = reportCharacteristics[reportID]
        case .singleCharacteristicPrefixed:
            characteristic = singleReportCharacteristic
        case .bootProtocolOnly:
            switch reportID {
            case .mouse:    characteristic = bootMouseCharacteristic
            case .keyboard: characteristic = bootKeyboardCharacteristic
            case .consumer: characteristic = nil   // no boot consumer report exists
            }
        }

        guard let characteristic else { return .undeliverable }
        guard subscribedReports.contains(reportID) else { return .undeliverable }

        lastPayload[reportID] = payload

        // `onSubscribedCentrals: nil` means "everyone subscribed to this
        // characteristic", which is what we want: a Mac and an iPad can both be
        // driven at once and neither needs special-casing.
        if peripheral.updateValue(payload, for: characteristic, onSubscribedCentrals: nil) {
            return .delivered
        }
        return .backpressure
    }
}

// MARK: - CBPeripheralManagerDelegate

extension HIDPeripheralManager: CBPeripheralManagerDelegate {

    // WHY EVERY METHOD HERE IS A ONE-LINER
    //
    // `CBPeripheralManagerDelegate` is a plain @objc protocol with no actor
    // isolation, so its methods cannot be `@MainActor` — the conformance would not
    // type-check. They are therefore `nonisolated` and immediately re-enter the
    // actor with `MainActor.assumeIsolated`, which is a runtime assertion that the
    // current thread really is main. It is, by construction: the manager is created
    // with `queue: .main`. `assumeIsolated` is used rather than
    // `Task { @MainActor in … }` because a Task hop would REORDER callbacks —
    // `didSubscribeTo` could land after the first report, and
    // `peripheralManagerIsReady` could land before the `updateValue` that provoked
    // it. The backpressure protocol cannot survive either.
    //
    // The real work lives in the `@MainActor` handlers below, one per callback,
    // rather than inline in the closure. That keeps each closure a single
    // expression (no generic-inference corners, no early `return` that reads like
    // it exits the delegate method when it only exits the closure) and makes the
    // handlers directly callable from tests or from a replay harness.

    public nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { self.handleStateChange(of: peripheral) }
    }

    public nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated { self.handleServiceAdded(service, error: error) }
    }

    public nonisolated func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        MainActor.assumeIsolated { self.handleAdvertisingStarted(error: error) }
    }

    public nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        MainActor.assumeIsolated { self.handleSubscribe(central: central, to: characteristic) }
    }

    public nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        MainActor.assumeIsolated {
            self.handleUnsubscribe(central: central, from: characteristic, isAdvertising: peripheral.isAdvertising)
        }
    }

    public nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { self.handleReadyToUpdateSubscribers() }
    }

    public nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        MainActor.assumeIsolated { self.handleRead(request, on: peripheral) }
    }

    public nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        MainActor.assumeIsolated { self.handleWrites(requests, on: peripheral) }
    }

    public nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        MainActor.assumeIsolated { self.handleStateRestoration(dict) }
    }
}

// MARK: - Delegate handlers (main-actor isolated)

extension HIDPeripheralManager {

    private func handleStateChange(of peripheral: CBPeripheralManager) {
        let state = peripheral.state
        appendLog(.info, "Bluetooth state: \(Self.describe(state))")

        switch state {
        case .poweredOn:
            // Re-publish if the user (or the diagnostics screen) asked for a
            // topology before the radio was ready. Errors on this path are logged
            // rather than thrown — there is no caller left to throw to — so anything
            // driving `start(topology:)` must also watch `connectionState` for
            // `.failed` rather than relying on the throw alone.
            guard let topology = desiredTopology,
                  publishedServices.isEmpty,
                  pendingServiceAdds.isEmpty else { return }
            do {
                try start(topology: topology)
            } catch {
                connectionState = .failed(error.localizedDescription)
                appendLog(.failure, "Deferred start failed: \(error.localizedDescription)")
            }

        case .poweredOff:
            connectionState = .poweredOff
            resetLinkState()

        case .unauthorized:
            connectionState = .unauthorized
            resetLinkState()

        case .unsupported:
            // The Simulator always lands here — CoreBluetooth's peripheral role is
            // not implemented in it at all. `StubHIDSender` exists for that case.
            connectionState = .unsupported
            resetLinkState()

        case .resetting:
            // Transient: the stack is restarting and will call back with a real
            // state shortly. Services are gone either way.
            connectionState = .idle
            resetLinkState()

        case .unknown:
            connectionState = .idle

        @unknown default:
            connectionState = .idle
        }
    }

    private func handleServiceAdded(_ service: CBService, error: Error?) {
        pendingServiceAdds.remove(service.uuid)
        guard let error else {
            publishedServices.insert(service.uuid)
            appendLog(.success, "Published \(service.uuid.uuidString).")
            return
        }
        // The ASYNCHRONOUS half of the rejection story. `add(_:)` accepted the
        // service synchronously (no NSException, so `start(topology:)` returned
        // cleanly) and iOS refused it here instead — which is how a short-form UUID
        // or a duplicate publish fails. `start(topology:)` has long since returned,
        // so this can only be reported through state and the log. A diagnostics
        // sweep must therefore wait for a `didAdd` success (or a `.failed`) before
        // declaring a topology viable; a clean return from `start` is necessary but
        // not sufficient.
        connectionState = .failed(error.localizedDescription)
        appendLog(.failure, "didAdd rejected \(service.uuid.uuidString): \(error.localizedDescription)")
    }

    private func handleAdvertisingStarted(error: Error?) {
        if let error {
            connectionState = .failed(error.localizedDescription)
            appendLog(.failure, "Advertising failed: \(error.localizedDescription)")
        } else {
            appendLog(.success, "Advertising started.")
        }
    }

    private func handleSubscribe(central: CBCentral, to characteristic: CBCharacteristic) {
        subscribedCentrals[central.identifier] = central

        if let id = reportID(for: characteristic) {
            if activeTopology == .singleCharacteristicPrefixed {
                // One characteristic carries everything, so a single subscribe
                // enables all three report IDs at once.
                subscribedReports.formUnion(activeTopology.supportedReports)
                appendLog(.success, "Central subscribed to the shared report characteristic (all report IDs).")
            } else {
                subscribedReports.insert(id)
                appendLog(.success, "Central subscribed to the \(id.displayName) report.")
            }
        } else {
            appendLog(.info, "Central subscribed to \(characteristic.uuid.uuidString).")
        }

        rememberCentral(central)
        connectionState = .connected(centralName: currentCentralName())
        appendLog(.info, "Link MTU allows \(central.maximumUpdateValueLength) bytes per notification.")

        // Push the current battery level immediately. macOS surfaces a HID device's
        // battery in the Bluetooth menu, and a characteristic that has never
        // notified reads as 0%, which produces a "low battery" warning on connect.
        publishBatteryLevel()

        pump.start()
        pump.resume()
    }

    private func handleUnsubscribe(
        central: CBCentral,
        from characteristic: CBCharacteristic,
        isAdvertising: Bool
    ) {
        if let id = reportID(for: characteristic) {
            if activeTopology == .singleCharacteristicPrefixed {
                subscribedReports.removeAll()
            } else {
                subscribedReports.remove(id)
            }
            appendLog(.info, "Central unsubscribed from \(id.displayName).")
        } else {
            appendLog(.info, "Central unsubscribed from \(characteristic.uuid.uuidString).")
        }

        guard subscribedReports.isEmpty else { return }
        subscribedCentrals.removeValue(forKey: central.identifier)
        // Anything still queued belongs to a session that is over; replaying a
        // half-finished drag into the next central would be actively wrong.
        pump.reset()
        if case .failed = connectionState {
            // Keep a failure the user has not seen yet.
            return
        }
        connectionState = isAdvertising ? .advertising : .idle
    }

    private func handleReadyToUpdateSubscribers() {
        // THE backpressure signal. Nothing else tells us the transmit queue
        // drained, and there is no polling API to ask.
        pump.resume()
    }

    private func handleRead(_ request: CBATTRequest, on peripheral: CBPeripheralManager) {
        // Only characteristics with a nil cached value reach here; CoreBluetooth
        // answers the static ones (Report Map, HID Information, DIS) itself.
        let uuid = request.characteristic.uuid

        if uuid == CBUUID(string: HIDUUID.batteryLevel) {
            request.value = Data([batteryPercent])
            peripheral.respond(to: request, withResult: .success)
            return
        }

        if uuid == CBUUID(string: HIDUUID.protocolMode) {
            request.value = Data([protocolMode])
            peripheral.respond(to: request, withResult: .success)
            return
        }

        if let id = reportID(for: request.characteristic) {
            // A host may read the current report state at any time. Answer with the
            // last thing we sent, padded to the declared size, or an all-zero (idle)
            // report — never an empty value, which some HID parsers treat as a
            // malformed report and respond to by tearing the connection down.
            let size = Self.payloadSize(for: id)
            var value = lastPayload[id] ?? Data(repeating: 0, count: size)
            if value.count < size {
                value.append(Data(repeating: 0, count: size - value.count))
            }
            request.value = value
            peripheral.respond(to: request, withResult: .success)
            return
        }

        // An unanswered read blocks the ATT channel until it times out, so every
        // path must respond — including the ones we do not recognise.
        peripheral.respond(to: request, withResult: .attributeNotFound)
        appendLog(.warning, "Unhandled read of \(uuid.uuidString).")
    }

    private func handleWrites(_ requests: [CBATTRequest], on peripheral: CBPeripheralManager) {
        for request in requests {
            let uuid = request.characteristic.uuid
            let bytes = request.value.map { Array($0) } ?? []

            if uuid == CBUUID(string: HIDUUID.hidControlPoint) {
                // 0x00 = Suspend, 0x01 = Exit Suspend. macOS sends Suspend as it
                // sleeps; continuing to notify a suspended host drains both batteries
                // and the reports are discarded at the far end anyway.
                if bytes.first == 0x00 {
                    appendLog(.info, "Host requested SUSPEND; pausing the report pump.")
                    pump.stop()
                } else {
                    appendLog(.info, "Host requested EXIT SUSPEND; resuming the report pump.")
                    pump.start()
                    pump.resume()
                }
            } else if uuid == CBUUID(string: HIDUUID.protocolMode) {
                // 0x00 = Boot Protocol, 0x01 = Report Protocol. We record it and
                // report it back on read, but we do NOT reshape the payloads: the
                // boot descriptor already declares layouts whose leading three
                // (mouse) and eight (keyboard) bytes are exactly what boot protocol
                // specifies, so one set of encoders is correct in either mode.
                if let mode = bytes.first {
                    protocolMode = mode
                    appendLog(.info, "Host set Protocol Mode to \(mode == 0 ? "Boot" : "Report").")
                }
            } else {
                appendLog(.warning, "Unhandled write to \(uuid.uuidString).")
            }
        }

        // CoreBluetooth requires exactly one response per `didReceiveWrite` call,
        // addressed to the FIRST request, regardless of how many arrived or whether
        // they were write-without-response. Skipping it wedges the ATT channel.
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    private func handleStateRestoration(_ dict: [String: Any]) {
        // Only reachable if a restore identifier is ever passed to the
        // CBPeripheralManager initialiser (it currently is not — see `init`).
        // Implemented anyway because its ABSENCE, when a restore identifier IS
        // present, raises at launch.
        let services = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        appendLog(.info, "State restoration returned \(services.count) service(s); rebuilding from scratch.")
    }

    // MARK: Shared helpers

    private func resetLinkState() {
        subscribedCentrals.removeAll()
        subscribedReports.removeAll()
        publishedServices.removeAll()
        pendingServiceAdds.removeAll()
        pump.stop()
        pump.reset()
    }

    private static func payloadSize(for reportID: HIDReportID) -> Int {
        switch reportID {
        case .mouse:    return MouseReport.payloadSize
        case .keyboard: return KeyboardReport.payloadSize
        case .consumer: return ConsumerReport.payloadSize
        }
    }
}
