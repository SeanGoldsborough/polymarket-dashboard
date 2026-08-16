//
//  HIDDiagnostics.swift
//  PocketTrackpad
//
//  The spike that the whole product rests on.
//
//  Two questions, neither of which is answerable from documentation:
//
//    1. Which `ReportTopology` will *iOS* let us publish at all?
//       `CBMutableDescriptor` only accepts
//       `kCBUUIDCharacteristicUserDescriptionString` and
//       `kCBUUIDCharacteristicFormatString`. A Report Reference descriptor
//       (0x2908) raises `NSInternalInconsistencyException` from
//       `CBPeripheralManager.add(_:)`. That is an Objective-C exception, not a
//       Swift error, so `HIDPeripheralManager` is responsible for catching it
//       behind a shim and rethrowing as `HIDError.descriptorRejected`. This
//       class only needs to observe that `start(topology:)` threw.
//
//    2. Which topology will *macOS* actually accept as a keyboard/trackpad?
//       There is no API for this. The only observable proxy is: does a central
//       connect, and does it subscribe to our report characteristic? macOS
//       subscribes to the HID report characteristics only once IOBluetoothHID
//       has parsed the report map and instantiated a HID device. So
//       "a central subscribed" is the strongest signal available from the
//       peripheral side, and it is the signal this harness measures.
//
//  Because question 2 requires a human to open Bluetooth settings on the Mac
//  and click Connect, every wait in here is bounded and cancellable. There is
//  no unbounded await anywhere in this file: an operator who walks away must
//  not leave the radio advertising forever.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Timing

/// Every timeout the probe run uses, in one injectable value.
///
/// Injectable because the defaults are tuned for a human walking to a Mac
/// (tens of seconds) and unit tests must not wait that long.
public struct ProbeTiming: Sendable, Equatable {
    /// How long to advertise while waiting for a central to subscribe.
    public var subscriptionWindow: Duration
    /// How often to re-read the manager's observable state while waiting.
    public var pollInterval: Duration
    /// How long to let the link settle after sending the probe reports, before
    /// deciding whether they "stuck".
    public var settleInterval: Duration

    public init(subscriptionWindow: Duration, pollInterval: Duration, settleInterval: Duration) {
        self.subscriptionWindow = subscriptionWindow
        self.pollInterval = pollInterval
        self.settleInterval = settleInterval
    }

    /// On-device defaults: 20 s is about as long as it takes to unlock a Mac,
    /// open System Settings › Bluetooth and click Connect.
    public static let `default` = ProbeTiming(
        subscriptionWindow: .seconds(20),
        pollInterval: .milliseconds(200),
        settleInterval: .milliseconds(500)
    )

    /// Sub-second timings for unit tests and previews.
    public static let fast = ProbeTiming(
        subscriptionWindow: .milliseconds(150),
        pollInterval: .milliseconds(10),
        settleInterval: .milliseconds(20)
    )
}

// MARK: - Diagnostics

@MainActor
@Observable
public final class HIDDiagnostics {

    // MARK: Result model

    /// The outcome of probing one topology.
    ///
    /// The fields are deliberately flat and additive rather than a single
    /// enum: a probe can be partially successful (published but never
    /// subscribed) and the bug report needs to say exactly how far it got.
    public struct ProbeResult: Identifiable, Equatable {
        public let topology: ReportTopology

        /// True once `start(topology:)` returned without throwing — i.e. iOS
        /// accepted the service, characteristics and descriptors.
        /// This is where the 0x2908 rejection surfaces.
        public var servicePublished: Bool

        /// The error text from `start(topology:)`, verbatim. Never rewritten
        /// into friendly copy: the exact string is the deliverable.
        public var failureReason: String?

        /// True if a central subscribed to at least one report characteristic
        /// inside the advertising window.
        public var centralSubscribed: Bool

        /// Which report characteristics the central subscribed to. macOS
        /// subscribing to only a subset is itself a meaningful finding.
        public var subscribedReports: Set<HIDReportID>

        /// True if the harmless probe reports were sent and the link was still
        /// up and still subscribed afterwards.
        public var roundTripConfirmed: Bool

        /// Human-readable trail of everything that happened, in order.
        public var notes: [String]

        public var id: ReportTopology { topology }

        public init(
            topology: ReportTopology,
            servicePublished: Bool = false,
            failureReason: String? = nil,
            centralSubscribed: Bool = false,
            subscribedReports: Set<HIDReportID> = [],
            roundTripConfirmed: Bool = false,
            notes: [String] = []
        ) {
            self.topology = topology
            self.servicePublished = servicePublished
            self.failureReason = failureReason
            self.centralSubscribed = centralSubscribed
            self.subscribedReports = subscribedReports
            self.roundTripConfirmed = roundTripConfirmed
            self.notes = notes
        }
    }

    /// Presentation state for one row of the diagnostics list.
    public enum ProbeState: Equatable {
        /// Not yet attempted in this run.
        case pending
        /// Currently publishing / advertising / waiting.
        case running
        /// iOS refused to publish the service. `failureReason` is populated.
        case rejected
        /// iOS published it, but no central subscribed inside the window.
        case published
        /// A central subscribed but the probe reports could not be confirmed.
        case subscribed
        /// Published, subscribed, and the probe reports stuck. This is a pass.
        case confirmed

        public var title: String {
            switch self {
            case .pending:    return "Not run"
            case .running:    return "Running"
            case .rejected:   return "Rejected by iOS"
            case .published:  return "Published, no subscriber"
            case .subscribed: return "Subscribed"
            case .confirmed:  return "Confirmed"
            }
        }

        public var systemImage: String {
            switch self {
            case .pending:    return "circle.dashed"
            case .running:    return "arrow.triangle.2.circlepath"
            case .rejected:   return "xmark.octagon.fill"
            case .published:  return "exclamationmark.triangle.fill"
            case .subscribed: return "checkmark.circle"
            case .confirmed:  return "checkmark.seal.fill"
            }
        }
    }

    // MARK: Dependencies

    /// The radio under test. Held as the protocol so the harness can be driven
    /// by a fake with failure injection.
    public let manager: any HIDPeripheralControlling

    /// Timeouts. Mutable so a test or preview can shorten the run.
    public var timing: ProbeTiming

    // MARK: Observable state

    /// One entry per topology, in `ReportTopology.allCases` order. Populated
    /// with `.pending` placeholders at init so the UI has stable rows to draw
    /// before the first run.
    public private(set) var results: [ProbeResult]

    /// True for the duration of `runAll()`.
    public private(set) var isRunning: Bool = false

    /// The topology currently being probed, for the "running" glyph.
    public private(set) var currentTopology: ReportTopology?

    /// Set when the last run ended because it was cancelled rather than
    /// completing. Surfaced in the export so a truncated report is not mistaken
    /// for a clean negative result.
    public private(set) var lastRunWasCancelled: Bool = false

    /// When the last run finished, for the exported report's header.
    public private(set) var lastRunFinished: Date?

    /// Not observable: the UI never renders the task itself, and letting it
    /// invalidate views would redraw the whole screen twice per run.
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let clock = ContinuousClock()

    // MARK: Init

    public init(manager: any HIDPeripheralControlling, timing: ProbeTiming = .default) {
        self.manager = manager
        self.timing = timing
        self.results = ReportTopology.allCases.map { ProbeResult(topology: $0) }
    }

    // MARK: Derived state

    /// The best topology that both published *and* attracted a subscription,
    /// preferring the earliest entry in `ReportTopology.allCases` — which is
    /// ordered most-correct-first, so the earliest passing candidate is also
    /// the most spec-conformant one available.
    ///
    /// Deliberately *not* written into `AppSettings` by this class. Adopting a
    /// topology changes what the app advertises to every Mac the user owns, and
    /// a probe run that succeeded once is not proof it will succeed again;
    /// `adopt(_:into:)` exists for the explicit, user-confirmed action.
    public var recommendation: ReportTopology? {
        results.first { $0.servicePublished && $0.centralSubscribed }?.topology
    }

    /// Presentation state for one topology.
    public func state(for topology: ReportTopology) -> ProbeState {
        guard let result = results.first(where: { $0.topology == topology }) else { return .pending }
        if currentTopology == topology, isRunning { return .running }
        if result.failureReason != nil { return .rejected }
        guard result.servicePublished else { return .pending }
        guard result.centralSubscribed else { return .published }
        return result.roundTripConfirmed ? .confirmed : .subscribed
    }

    public func result(for topology: ReportTopology) -> ProbeResult? {
        results.first { $0.topology == topology }
    }

    // MARK: Run control

    /// Fire-and-forget entry point for the UI. Safe to call twice; the second
    /// call is a no-op while a run is in flight.
    public func start() {
        guard !isRunning else { return }
        runTask = Task { [weak self] in
            await self?.runAll()
        }
    }

    /// Cancel an in-flight run. The run's own cleanup stops the radio.
    public func cancel() {
        runTask?.cancel()
    }

    /// Probe every topology in order.
    ///
    /// Never throws: a run that dies halfway is still a result worth exporting,
    /// so failures are recorded into `results` rather than propagated.
    /// Cancellation is honoured between and inside probes, and the radio is
    /// always stopped on the way out.
    public func runAll() async {
        guard !isRunning else { return }
        isRunning = true
        lastRunWasCancelled = false
        results = ReportTopology.allCases.map { ProbeResult(topology: $0) }

        defer {
            // Runs on every exit path including cancellation: leaving the
            // peripheral advertising after the screen is dismissed would keep
            // the radio hot and confuse the next probe run.
            manager.stop()
            currentTopology = nil
            isRunning = false
            lastRunFinished = .now
        }

        for (index, topology) in ReportTopology.allCases.enumerated() {
            if Task.isCancelled {
                lastRunWasCancelled = true
                results[index].notes.append("Skipped: the probe run was cancelled.")
                continue
            }
            currentTopology = topology
            await probe(topology, at: index)
        }

        if Task.isCancelled { lastRunWasCancelled = true }
    }

    // MARK: One probe

    private func probe(_ topology: ReportTopology, at index: Int) async {
        var result = ProbeResult(topology: topology)

        defer {
            results[index] = result
            // Always tear down between candidates. Publishing a second HID
            // service while the first is still registered makes macOS cache a
            // stale report map against our peripheral's identity, which then
            // poisons every later probe until the user removes the device.
            manager.stop()
        }

        result.notes.append("Publishing: \(topology.summary)")
        results[index] = result

        do {
            try manager.start(topology: topology)
            result.servicePublished = true
            result.notes.append("iOS accepted the service. Advertising.")
            results[index] = result
        } catch {
            result.failureReason = Self.describe(error)
            result.notes.append("iOS refused to publish this layout; no advertising was attempted.")
            return
        }

        // --- Wait for a human to click Connect on the Mac -------------------
        let outcome = await waitForSubscription()

        switch outcome {
        case .cancelled:
            lastRunWasCancelled = true
            result.notes.append("Cancelled while waiting for a central to subscribe.")
            return

        case .timedOut(sawConnection: let sawConnection):
            if sawConnection {
                result.notes.append(
                    "A central connected but never subscribed to a report characteristic "
                    + "within \(Self.describe(timing.subscriptionWindow)). "
                    + "That usually means the host parsed the report map and declined to "
                    + "instantiate a HID device from it."
                )
            } else {
                result.notes.append(
                    "No central connected within \(Self.describe(timing.subscriptionWindow)). "
                    + "Either the Mac never attempted to connect, or it did not see the "
                    + "advertisement at all."
                )
            }
            return

        case .subscribed:
            result.centralSubscribed = true
            result.subscribedReports = manager.subscribedReports
            result.notes.append("Central subscribed to: \(Self.describe(result.subscribedReports)).")
        }

        // --- Send a harmless probe -----------------------------------------
        // A zero-delta mouse report cannot move the cursor and a consumer
        // "released" report cannot trigger media playback, so this is safe to
        // fire at a stranger's Mac while diagnosing.
        manager.send(mouse: MouseReport())
        result.notes.append("Sent a zero-delta mouse report (no pointer movement).")

        if topology.supportedReports.contains(.consumer) {
            manager.send(consumer: .released)
            result.notes.append("Sent a consumer 'released' report (no media action).")
        } else {
            result.notes.append("This layout carries no consumer report; skipped that probe.")
        }
        results[index] = result

        // --- Did it stick? ---------------------------------------------------
        // There is no acknowledgement for a HID notification, so "stuck" is
        // defined negatively: the link did not drop and the central did not
        // unsubscribe in the settle window. A host that rejects our report map
        // typically disconnects within a few hundred milliseconds of the first
        // notification, which is exactly what this catches.
        do {
            try await Task.sleep(for: timing.settleInterval)
        } catch {
            lastRunWasCancelled = true
            result.notes.append("Cancelled before the probe reports could be confirmed.")
            return
        }

        let stillConnected = manager.connectionState.isConnected
        let stillSubscribed = !manager.subscribedReports.isEmpty
        result.subscribedReports.formUnion(manager.subscribedReports)
        result.roundTripConfirmed = stillConnected && stillSubscribed

        if result.roundTripConfirmed {
            result.notes.append("Link still up and still subscribed after the probe reports.")
        } else {
            result.notes.append(
                "The link dropped or the central unsubscribed after the probe reports "
                + "(connected: \(stillConnected), subscribed: \(stillSubscribed)). "
                + "The host accepted the service but rejected the traffic."
            )
        }
    }

    // MARK: Bounded wait

    private enum SubscriptionOutcome {
        case subscribed
        case timedOut(sawConnection: Bool)
        case cancelled
    }

    /// Poll the manager's observable state until a central subscribes, the
    /// window expires, or the task is cancelled.
    ///
    /// Polling rather than awaiting a continuation is deliberate:
    /// `HIDPeripheralControlling` exposes state, not events, and a
    /// `CheckedContinuation` resumed from a CoreBluetooth delegate callback
    /// would need a resume-exactly-once guard plus its own timeout race. A
    /// 200 ms poll costs nothing next to a 20 s human-in-the-loop window and
    /// cannot leak or double-resume.
    private func waitForSubscription() async -> SubscriptionOutcome {
        let deadline = clock.now.advanced(by: timing.subscriptionWindow)
        var sawConnection = false

        while clock.now < deadline {
            if Task.isCancelled { return .cancelled }

            if manager.connectionState.isConnected { sawConnection = true }
            if !manager.subscribedReports.isEmpty { return .subscribed }

            do {
                try await Task.sleep(for: timing.pollInterval)
            } catch {
                // The only error `Task.sleep` throws is cancellation.
                return .cancelled
            }
        }

        // One last read: a subscription may have landed in the final interval.
        if Task.isCancelled { return .cancelled }
        if manager.connectionState.isConnected { sawConnection = true }
        if !manager.subscribedReports.isEmpty { return .subscribed }
        return .timedOut(sawConnection: sawConnection)
    }

    // MARK: Adoption

    /// Write a probed topology into settings. Called only from an explicit,
    /// confirmed user action in `DiagnosticsView` — never automatically.
    public func adopt(_ topology: ReportTopology, into settings: AppSettings) {
        settings.preferredTopology = topology
        if let index = results.firstIndex(where: { $0.topology == topology }) {
            results[index].notes.append("Adopted as the app's preferred topology.")
        }
    }

    // MARK: Export

    /// A plain-text report suitable for pasting into a bug report or a message
    /// to whoever owns the Mac side.
    ///
    /// This is what makes the spike portable: the whole point of the run is a
    /// finding that can leave the device.
    public func exportReport() -> String {
        var lines: [String] = []

        lines.append("Pocket Trackpad — HID topology diagnostics")
        lines.append(String(repeating: "=", count: 44))
        lines.append("Generated: \(Self.timestampFormatter.string(from: lastRunFinished ?? .now))")
        lines.append("iOS: \(Self.systemVersion)")
        lines.append("Device: \(Self.deviceModelName) (\(Self.hardwareIdentifier))")
        lines.append("Subscription window: \(Self.describe(timing.subscriptionWindow))")
        lines.append("Run status: \(runStatusDescription)")
        lines.append("Recommendation: \(recommendation.map(\.rawValue) ?? "none — no topology both published and attracted a subscriber")")
        lines.append("")

        for result in results {
            lines.append(String(repeating: "-", count: 44))
            lines.append("TOPOLOGY: \(result.topology.rawValue)")
            lines.append("  \(result.topology.summary)")
            lines.append("  outcome            : \(state(for: result.topology).title)")
            lines.append("  service published  : \(result.servicePublished ? "yes" : "no")")
            lines.append("  central subscribed : \(result.centralSubscribed ? "yes" : "no")")
            lines.append("  subscribed reports : \(Self.describe(result.subscribedReports))")
            lines.append("  round trip         : \(result.roundTripConfirmed ? "confirmed" : "not confirmed")")
            if let reason = result.failureReason {
                // Verbatim, unwrapped, unedited. The exact NSException text is
                // the single most useful line in this whole report.
                lines.append("  failure reason     : \(reason)")
            }
            if result.notes.isEmpty {
                lines.append("  notes              : (none)")
            } else {
                lines.append("  notes:")
                for note in result.notes {
                    lines.append("    • \(note)")
                }
            }
        }

        lines.append(String(repeating: "-", count: 44))
        lines.append("")
        lines.append("PERIPHERAL MANAGER LOG (\(manager.log.count) entries)")
        if manager.log.isEmpty {
            lines.append("  (empty)")
        } else {
            for entry in manager.log {
                let time = Self.logTimeFormatter.string(from: entry.timestamp)
                lines.append("  [\(time)] \(entry.level.rawValue.uppercased().padded(to: 7)) \(entry.message)")
            }
        }

        lines.append("")
        lines.append("Known centrals: \(manager.knownCentrals.isEmpty ? "(none)" : manager.knownCentrals.map(\.name).joined(separator: ", "))")
        if let interval = manager.negotiatedConnectionInterval {
            lines.append("Negotiated connection interval: \(Int((interval * 1000).rounded())) ms")
        } else {
            lines.append("Negotiated connection interval: not reported")
        }

        return lines.joined(separator: "\n")
    }

    private var runStatusDescription: String {
        if isRunning { return "in progress" }
        if lastRunWasCancelled { return "CANCELLED — results below are incomplete" }
        if lastRunFinished == nil { return "not yet run" }
        return "completed"
    }

    // MARK: Formatting helpers

    static func describe(_ error: Error) -> String {
        if let hidError = error as? HIDError, let description = hidError.errorDescription {
            return description
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    static func describe(_ reports: Set<HIDReportID>) -> String {
        guard !reports.isEmpty else { return "none" }
        return reports
            .sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.displayName) (0x\(String($0.rawValue, radix: 16)))" }
            .joined(separator: ", ")
    }

    static func describe(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded())) ms"
        }
        return "\(String(format: "%.1f", seconds)) s"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: Environment

    static var systemVersion: String {
        #if canImport(UIKit)
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    static var deviceModelName: String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "unknown"
        #endif
    }

    /// e.g. `iPhone16,2`. `UIDevice.model` only ever says "iPhone", which is
    /// useless in a bug report where the radio hardware is the variable.
    static var hardwareIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}

// MARK: - Small helpers

private extension String {
    /// Right-pad for the fixed-width log column in the exported report.
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
