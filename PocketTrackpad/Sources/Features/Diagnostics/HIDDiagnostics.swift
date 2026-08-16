//
//  HIDDiagnostics.swift
//  PocketTrackpad
//
//  The spike that the whole product rests on.
//
//  Two questions, neither of which is answerable from documentation:
//
//    1. Which `ReportTopology` will *iOS* let us publish at all?
//       There are TWO rejection paths and they behave completely differently:
//
//       * SYNCHRONOUS. `CBMutableDescriptor` only accepts
//         `kCBUUIDCharacteristicUserDescriptionString` and
//         `kCBUUIDCharacteristicFormatString`. A Report Reference descriptor
//         (0x2908) raises `NSInternalInconsistencyException` from
//         `CBPeripheralManager.add(_:)`. `HIDPeripheralManager` catches that
//         behind an ObjC shim and rethrows it, so `start(topology:)` throws.
//
//       * ASYNCHRONOUS. A short-form UUID, or re-adding a service that is
//         already published, is accepted by `add(_:)` and refused seconds later
//         in `peripheralManager(_:didAdd:error:)`. `start(topology:)` has long
//         since returned cleanly. `HIDPeripheralManager.handleServiceAdded`
//         surfaces this as `connectionState == .failed(...)`.
//
//       So a clean return from `start` is NECESSARY BUT NOT SUFFICIENT, and a
//       harness that treats it as success will report a dead topology as
//       working. `waitForPublishResolution` closes that gap.
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
//  READ `HIDDiagnostics.gattCacheWarning` BEFORE TRUSTING A SWEEP. It is the
//  single largest threat to the validity of these measurements and it is
//  reproduced on screen and in every exported report for that reason.
//

import Foundation
// `@Observable` and `@ObservationIgnored` live in the Observation module, which
// Foundation does not re-export. Imported explicitly so this file does not
// depend on SwiftUI being pulled in by something else in the target.
import Observation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Timing

/// Every timeout the probe run uses, in one injectable value.
///
/// Injectable because the defaults are tuned for a human walking to a Mac
/// (tens of seconds) and unit tests must not wait that long.
public struct ProbeTiming: Sendable, Equatable {
    /// How long to wait for `didAdd` to confirm or refuse the services after a
    /// non-throwing `start(topology:)`.
    public var publishWindow: Duration
    /// How long to advertise while waiting for a central to subscribe.
    public var subscriptionWindow: Duration
    /// How often to re-read the manager's observable state while waiting.
    public var pollInterval: Duration
    /// How long to let the link settle after sending the probe reports, before
    /// deciding whether they "stuck".
    public var settleInterval: Duration

    public init(
        publishWindow: Duration,
        subscriptionWindow: Duration,
        pollInterval: Duration,
        settleInterval: Duration
    ) {
        self.publishWindow = publishWindow
        self.subscriptionWindow = subscriptionWindow
        self.pollInterval = pollInterval
        self.settleInterval = settleInterval
    }

    /// On-device defaults: 20 s is about as long as it takes to unlock a Mac,
    /// open System Settings › Bluetooth and click Connect. 3 s is generous for
    /// `didAdd`, which normally lands in well under a second.
    public static let `default` = ProbeTiming(
        publishWindow: .seconds(3),
        subscriptionWindow: .seconds(20),
        pollInterval: .milliseconds(200),
        settleInterval: .milliseconds(500)
    )

    /// Sub-second timings for unit tests and previews.
    public static let fast = ProbeTiming(
        publishWindow: .milliseconds(60),
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

    /// How far the *publish* half of a probe got.
    ///
    /// Three distinct failure shapes, deliberately not collapsed into a single
    /// `Bool`: "iOS threw", "iOS accepted then refused asynchronously" and "we
    /// never found out" have completely different next actions.
    public enum PublishOutcome: String, Sendable, Equatable {
        /// Not probed in this session.
        case notAttempted
        /// `start(topology:)` threw — the ObjC exception path (0x2908).
        case threwSynchronously
        /// `start(topology:)` returned cleanly and `didAdd` (or advertising)
        /// then reported an error. The layout is dead.
        case rejectedAsynchronously
        /// `start(topology:)` returned cleanly and neither a `didAdd`
        /// confirmation nor a failure arrived inside the window. Nothing can be
        /// concluded — this is explicitly NOT counted as success.
        case unresolved
        /// `didAdd` confirmed the services with no error.
        case confirmed

        public var title: String {
            switch self {
            case .notAttempted:          return "Not probed"
            case .threwSynchronously:    return "Threw on publish"
            case .rejectedAsynchronously:return "Refused after publish"
            case .unresolved:            return "Publish unconfirmed"
            case .confirmed:             return "Published"
            }
        }
    }

    /// The outcome of probing one topology.
    ///
    /// The fields are deliberately flat and additive rather than a single
    /// enum: a probe can be partially successful (published but never
    /// subscribed) and the bug report needs to say exactly how far it got.
    public struct ProbeResult: Identifiable, Equatable, Sendable {
        public let topology: ReportTopology

        /// How the publish attempt resolved. The authoritative field.
        public var publishOutcome: PublishOutcome

        /// True only when `publishOutcome == .confirmed`. Kept as a separate
        /// stored field because it is what the rest of the app reads, and
        /// keeping it in lockstep with `publishOutcome` in one place is safer
        /// than every call site remembering the distinction.
        public var servicePublished: Bool

        /// The error text from `start(topology:)` or from `didAdd`, verbatim.
        /// Never rewritten into friendly copy: the exact string is the
        /// deliverable.
        public var failureReason: String?

        /// True if a central subscribed to at least one report characteristic
        /// inside the advertising window.
        public var centralSubscribed: Bool

        /// Which report characteristics the central subscribed to. macOS
        /// subscribing to only a subset is itself a meaningful finding.
        public var subscribedReports: Set<HIDReportID>

        /// True if the harmless probe reports were sent and the link was still
        /// up and still subscribed afterwards. See `roundTripCaveat` — this is
        /// a negative inference, not an acknowledgement.
        public var roundTripConfirmed: Bool

        /// Reasons this row must not be read as an unqualified pass, even when
        /// every other field looks green. Rendered next to the result and
        /// reproduced in the exported report.
        public var qualifications: [String]

        /// Human-readable trail of everything that happened, in order.
        public var notes: [String]

        /// When this row was last actually measured. Nil means the row is a
        /// placeholder — important after a single-topology probe, where the
        /// other rows are stale or empty.
        public var measuredAt: Date?

        public var id: ReportTopology { topology }

        public init(
            topology: ReportTopology,
            publishOutcome: PublishOutcome = .notAttempted,
            servicePublished: Bool = false,
            failureReason: String? = nil,
            centralSubscribed: Bool = false,
            subscribedReports: Set<HIDReportID> = [],
            roundTripConfirmed: Bool = false,
            qualifications: [String] = [],
            notes: [String] = [],
            measuredAt: Date? = nil
        ) {
            self.topology = topology
            self.publishOutcome = publishOutcome
            self.servicePublished = servicePublished
            self.failureReason = failureReason
            self.centralSubscribed = centralSubscribed
            self.subscribedReports = subscribedReports
            self.roundTripConfirmed = roundTripConfirmed
            self.qualifications = qualifications
            self.notes = notes
            self.measuredAt = measuredAt
        }
    }

    /// Presentation state for one row of the diagnostics list.
    public enum ProbeState: Equatable, Sendable {
        /// Not yet attempted in this session.
        case pending
        /// Currently publishing / advertising / waiting.
        case running
        /// `start(topology:)` threw. `failureReason` is populated.
        case rejected
        /// `start` returned cleanly, then `didAdd` refused it.
        case rejectedAsynchronously
        /// `start` returned cleanly and nothing confirmed or refused it.
        case unresolved
        /// Published, but no central subscribed inside the window.
        case published
        /// A central subscribed but the probe reports could not be confirmed.
        case subscribed
        /// Published, subscribed, and the probe reports stuck. A pass — but see
        /// the row's `qualifications` before trusting it.
        case confirmed

        public var title: String {
            switch self {
            case .pending:                return "Not run"
            case .running:                return "Running"
            case .rejected:               return "Rejected by iOS (threw)"
            case .rejectedAsynchronously: return "Refused after publish"
            case .unresolved:             return "Publish unconfirmed"
            case .published:              return "Published, no subscriber"
            case .subscribed:             return "Subscribed"
            case .confirmed:              return "Confirmed"
            }
        }

        public var systemImage: String {
            switch self {
            case .pending:                return "circle.dashed"
            case .running:                return "arrow.triangle.2.circlepath"
            case .rejected:               return "xmark.octagon.fill"
            case .rejectedAsynchronously: return "xmark.octagon.fill"
            case .unresolved:             return "questionmark.circle.fill"
            case .published:              return "exclamationmark.triangle.fill"
            case .subscribed:             return "checkmark.circle"
            case .confirmed:              return "checkmark.seal.fill"
            }
        }

        /// True for every state that must not be read as a pass.
        public var isFailure: Bool {
            switch self {
            case .rejected, .rejectedAsynchronously, .unresolved: return true
            default: return false
            }
        }
    }

    /// What the last run covered, so a result read later is not mistaken for a
    /// complete sweep.
    public enum RunScope: Equatable, Sendable {
        case none
        case sweep
        case single(ReportTopology)

        public var description: String {
            switch self {
            case .none:                return "none"
            case .sweep:               return "full sweep of all topologies"
            case .single(let topology):return "single probe of \(topology.rawValue)"
            }
        }
    }

    // MARK: Standing caveats

    /// The single largest threat to the validity of a sweep.
    ///
    /// Reproduced verbatim on screen and in every exported report because a
    /// result read a week later, out of context, is otherwise actively
    /// misleading — a sweep against a bonded Mac can invert the ranking.
    public static let gattCacheWarning = """
        macOS CACHES THE GATT DATABASE OF A BONDED DEVICE, AND THIS APP CANNOT \
        INVALIDATE IT. Invalidation requires a Service Changed indication \
        (0x2A05) from the system-owned GATT service, which CBPeripheralManager \
        gives no access to. Cycling topologies with removeAllServices() and \
        re-adding therefore does NOT guarantee the Mac re-reads the new layout: \
        if it has already bonded with this iPhone it may keep using the FIRST \
        probe's service layout for every later probe. A sweep against a bonded \
        Mac can invert the entire result. Remove this iPhone from System \
        Settings > Bluetooth on the Mac between probes, or sweep against a Mac \
        that has never paired with it. A SINGLE probe against a fresh Mac is \
        the only fully trustworthy measurement.
        """

    /// Why a green `.perReportCharacteristic` row still cannot be trusted.
    public static let descriptorSilentFailureCaveat = """
        UNVERIFIED: this layout depends on the 0x2908 Report Reference \
        descriptors surviving publish. If iOS accepted the CBMutableDescriptor \
        objects and then dropped them during publish — which it can do without \
        raising an exception and without reporting an error — macOS sees three \
        identical 0x2A4D characteristics with no Report References, cannot tell \
        them apart, and enumerates a HID device that does nothing. Nothing \
        observable from the peripheral side distinguishes that from a working \
        publish. Confirm on the Mac that the pointer actually moves before \
        trusting this row.
        """

    /// Why `roundTripConfirmed` is weaker than it sounds.
    public static let roundTripCaveat = """
        "Round trip confirmed" is inferred NEGATIVELY: a HID notification is \
        never acknowledged, so this only means the link did not drop and the \
        central did not unsubscribe during the settle window. A host that \
        silently discards our reports reads as confirmed. Only a human watching \
        the Mac's cursor can confirm delivery.
        """

    /// Why the connection interval is never shown as a measurement.
    public static let connectionIntervalCaveat = """
        The negotiated connection interval is NOT observable from the \
        peripheral role: no CBCentral, CBPeripheralManager or delegate callback \
        exposes it. (CBCentral.maximumUpdateValueLength reports the negotiated \
        ATT MTU, a different negotiation.) It is reported here only if \
        something upstream measured it externally and fed it in.
        """

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

    /// True for the duration of a run.
    public private(set) var isRunning: Bool = false

    /// The topology currently being probed, for the "running" glyph.
    public private(set) var currentTopology: ReportTopology?

    /// Set when the last run ended because it was cancelled rather than
    /// completing. Surfaced in the export so a truncated report is not mistaken
    /// for a clean negative result.
    public private(set) var lastRunWasCancelled: Bool = false

    /// When the last run finished, for the exported report's header.
    public private(set) var lastRunFinished: Date?

    /// What the last run covered.
    public private(set) var lastRunScope: RunScope = .none

    /// Not observable: the UI never renders the task itself, and letting it
    /// invalidate views would redraw the whole screen twice per run.
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let clock = ContinuousClock()

    /// `HIDPeripheralManager.start(topology:)` publishes HID, Device
    /// Information and Battery. Each produces its own `didAdd`, so a fully
    /// resolved publish is three confirmations.
    static let expectedServiceCount = 3

    /// `handleServiceAdded` logs `.success` with this prefix on a clean
    /// `didAdd`. Matching on the log is the only channel available: the
    /// `HIDPeripheralControlling` contract exposes no publish-confirmation
    /// state, and `publishedServices` is private to the manager. If that
    /// message ever changes, every probe degrades to `.unresolved` — which
    /// under-claims rather than over-claims, and is the safe direction to fail.
    static let publishedLogPrefix = "Published "

    // MARK: Init

    public init(manager: any HIDPeripheralControlling, timing: ProbeTiming = .default) {
        self.manager = manager
        self.timing = timing
        self.results = ReportTopology.allCases.map { ProbeResult(topology: $0) }
    }

    // MARK: Derived state

    /// The best topology that confirmed its publish *and* attracted a
    /// subscription, preferring the earliest entry in
    /// `ReportTopology.allCases` — which is ordered most-correct-first, so the
    /// earliest passing candidate is also the most spec-conformant available.
    ///
    /// Requires `publishOutcome == .confirmed`, not merely a non-throwing
    /// `start`: an asynchronously-refused or unconfirmed publish is not a
    /// candidate no matter what happened afterwards.
    ///
    /// Deliberately *not* written into `AppSettings` by this class. Adopting a
    /// topology changes what the app advertises to every Mac the user owns, and
    /// a probe run that succeeded once is not proof it will succeed again;
    /// `adopt(_:into:)` exists for the explicit, user-confirmed action.
    public var recommendation: ReportTopology? {
        results.first { $0.publishOutcome == .confirmed && $0.centralSubscribed }?.topology
    }

    /// Presentation state for one topology.
    public func state(for topology: ReportTopology) -> ProbeState {
        guard let result = results.first(where: { $0.topology == topology }) else { return .pending }
        if currentTopology == topology, isRunning { return .running }

        switch result.publishOutcome {
        case .notAttempted:           return .pending
        case .threwSynchronously:     return .rejected
        case .rejectedAsynchronously: return .rejectedAsynchronously
        case .unresolved:             return .unresolved
        case .confirmed:              break
        }

        guard result.centralSubscribed else { return .published }
        return result.roundTripConfirmed ? .confirmed : .subscribed
    }

    public func result(for topology: ReportTopology) -> ProbeResult? {
        results.first { $0.topology == topology }
    }

    /// `CBCentral` exposes no name and the bond store has nothing to show for a
    /// Mac's first connection, so `connected(centralName:)` carries nil far
    /// more often than not. Never render that as a blank.
    public var centralDisplayName: String? {
        guard case .connected(let name) = manager.connectionState else { return nil }
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Unknown Mac"
        }
        return name
    }

    // MARK: Run control

    /// Fire-and-forget full sweep. Safe to call twice; the second call is a
    /// no-op while a run is in flight.
    public func startSweep() {
        guard !isRunning else { return }
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runAll()
        }
    }

    /// Fire-and-forget probe of one topology.
    ///
    /// This is the measurement to trust. A single probe against a Mac that has
    /// never bonded with this iPhone is the only run that cannot be corrupted
    /// by the GATT cache — see `gattCacheWarning`.
    public func startProbe(_ topology: ReportTopology) {
        guard !isRunning else { return }
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runOne(topology)
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
        beginRun(scope: .sweep)
        results = ReportTopology.allCases.map { ProbeResult(topology: $0) }

        defer { endRun() }

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

    /// Probe exactly one topology, leaving the other rows untouched.
    ///
    /// The other rows keep whatever they measured before, which is why
    /// `ProbeResult.measuredAt` exists and why the exported report stamps every
    /// row: after a single probe the table can legitimately hold results from
    /// several different runs, and that must be visible.
    public func runOne(_ topology: ReportTopology) async {
        guard !isRunning else { return }
        guard let index = ReportTopology.allCases.firstIndex(of: topology) else { return }
        beginRun(scope: .single(topology))
        results[index] = ProbeResult(topology: topology)

        defer { endRun() }

        if Task.isCancelled {
            lastRunWasCancelled = true
            results[index].notes.append("Skipped: the probe was cancelled before it started.")
            return
        }

        currentTopology = topology
        await probe(topology, at: index)

        if Task.isCancelled { lastRunWasCancelled = true }
    }

    private func beginRun(scope: RunScope) {
        isRunning = true
        lastRunWasCancelled = false
        lastRunScope = scope
    }

    private func endRun() {
        // Runs on every exit path including cancellation: leaving the
        // peripheral advertising after the screen is dismissed would keep the
        // radio hot and confuse the next probe run.
        manager.stop()
        currentTopology = nil
        isRunning = false
        lastRunFinished = .now
    }

    // MARK: One probe

    private func probe(_ topology: ReportTopology, at index: Int) async {
        var result = ProbeResult(topology: topology)

        defer {
            result.measuredAt = .now
            results[index] = result
            // Always tear down between candidates. Note that this does NOT
            // clear a bonded Mac's cached view of our GATT database — see
            // `gattCacheWarning`.
            manager.stop()
        }

        result.notes.append("Publishing: \(topology.summary)")
        results[index] = result

        // Snapshot the log so `didAdd` confirmations from a *previous* probe
        // are not counted towards this one.
        let logBaseline = manager.log.count

        do {
            try manager.start(topology: topology)
            result.notes.append(
                "start(topology:) returned without throwing — iOS raised no exception. "
                + "That is necessary but NOT sufficient; the service can still be refused "
                + "asynchronously in didAdd."
            )
            results[index] = result
        } catch {
            result.publishOutcome = .threwSynchronously
            result.failureReason = Self.describe(error)
            result.notes.append("iOS refused this layout synchronously; no advertising was attempted.")
            return
        }

        // --- Did the services actually publish? -----------------------------
        switch await waitForPublishResolution(logBaseline: logBaseline) {
        case .cancelled:
            lastRunWasCancelled = true
            result.notes.append("Cancelled while waiting for didAdd to resolve the publish.")
            return

        case .rejected(let reason):
            result.publishOutcome = .rejectedAsynchronously
            result.failureReason = reason
            result.notes.append(
                "iOS accepted add(_:) and then refused the service asynchronously. This is how "
                + "a short-form UUID or a duplicate publish fails, and it is invisible to "
                + "start(topology:)."
            )
            return

        case .unresolved:
            result.publishOutcome = .unresolved
            result.notes.append(
                "No didAdd confirmation and no failure arrived within "
                + "\(Self.describe(timing.publishWindow)). Nothing can be concluded about this "
                + "layout — it is deliberately NOT recorded as published."
            )
            return

        case .confirmed(let services):
            result.publishOutcome = .confirmed
            result.servicePublished = true
            result.notes.append("didAdd confirmed \(services) of \(Self.expectedServiceCount) services.")
            if services < Self.expectedServiceCount {
                result.qualifications.append(
                    "Only \(services) of \(Self.expectedServiceCount) services were confirmed by "
                    + "didAdd within the window. macOS may see an incomplete device."
                )
            }
        }

        // The descriptor silent-failure mode is undetectable from here, so it
        // is declared rather than measured. Attached as soon as the layout
        // publishes, so it travels with the row whatever happens next.
        if topology == .perReportCharacteristic {
            result.qualifications.append(Self.descriptorSilentFailureCaveat)
        }
        results[index] = result

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
            let who = centralDisplayName ?? "a central"
            result.notes.append("\(who) subscribed to: \(Self.describe(result.subscribedReports)).")
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
            result.qualifications.append(Self.roundTripCaveat)
        } else {
            result.notes.append(
                "The link dropped or the central unsubscribed after the probe reports "
                + "(connected: \(stillConnected), subscribed: \(stillSubscribed)). "
                + "The host accepted the service but rejected the traffic."
            )
        }
    }

    // MARK: Bounded wait — publish resolution

    private enum PublishResolution {
        case confirmed(services: Int)
        case rejected(String)
        case unresolved
        case cancelled
    }

    /// Wait for `didAdd` to confirm or refuse the services after a clean
    /// `start(topology:)`.
    ///
    /// WHY this exists: `HIDPeripheralManager.handleServiceAdded` documents
    /// that a service accepted by `add(_:)` can be refused seconds later, at
    /// which point `start` has already returned. Without this wait every
    /// asynchronously-refused topology would be recorded as published, and the
    /// harness would recommend a layout that cannot work.
    ///
    /// Note on `.failed` detection: `HIDPeripheralManager.stop()` deliberately
    /// *preserves* an unseen `.failed` state, so a stale failure could leak in
    /// from the previous probe. That cannot happen here because a non-throwing
    /// `start(topology:)` ends in `startAdvertising()`, which sets
    /// `connectionState = .advertising` synchronously before returning. Any
    /// `.failed` observed from this point belongs to this probe.
    private func waitForPublishResolution(logBaseline: Int) async -> PublishResolution {
        let deadline = clock.now.advanced(by: timing.publishWindow)

        while clock.now < deadline {
            if Task.isCancelled { return .cancelled }
            if case .failed(let reason) = manager.connectionState { return .rejected(reason) }

            let confirmed = confirmedPublishCount(since: logBaseline)
            if confirmed >= Self.expectedServiceCount { return .confirmed(services: confirmed) }

            do {
                try await Task.sleep(for: timing.pollInterval)
            } catch {
                return .cancelled
            }
        }

        if Task.isCancelled { return .cancelled }
        if case .failed(let reason) = manager.connectionState { return .rejected(reason) }

        // A partial confirmation is still a confirmation that iOS took the HID
        // service; the shortfall is recorded as a qualification by the caller.
        let confirmed = confirmedPublishCount(since: logBaseline)
        return confirmed > 0 ? .confirmed(services: confirmed) : .unresolved
    }

    /// Count `didAdd` successes logged since `baseline`.
    private func confirmedPublishCount(since baseline: Int) -> Int {
        let log = manager.log
        // `clearLog()` can shrink the log under us; a stale baseline must not
        // trap on an out-of-range slice.
        guard baseline >= 0, log.count > baseline else { return 0 }
        return log[baseline...].reduce(into: 0) { total, entry in
            if entry.level == .success, entry.message.hasPrefix(Self.publishedLogPrefix) {
                total += 1
            }
        }
    }

    // MARK: Bounded wait — subscription

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
    /// finding that can leave the device. Every standing caveat is reproduced
    /// verbatim, because a report read out of context — a week later, by
    /// someone who was not holding the phone — is exactly where a cached GATT
    /// database or an unverified descriptor turns into a wrong decision.
    public func exportReport() -> String {
        var lines: [String] = []

        lines.append("Pocket Trackpad — HID topology diagnostics")
        lines.append(String(repeating: "=", count: 60))
        lines.append("Generated: \(Self.timestampFormatter.string(from: lastRunFinished ?? .now))")
        lines.append("iOS: \(Self.systemVersion)")
        lines.append("Device: \(Self.deviceModelName) (\(Self.hardwareIdentifier))")
        lines.append("Run scope: \(lastRunScope.description)")
        lines.append("Run status: \(runStatusDescription)")
        lines.append("Publish window: \(Self.describe(timing.publishWindow))")
        lines.append("Subscription window: \(Self.describe(timing.subscriptionWindow))")
        lines.append("Recommendation: \(recommendation.map(\.rawValue) ?? "none — no topology both confirmed its publish and attracted a subscriber")")
        lines.append("")

        lines.append("!! READ THIS BEFORE INTERPRETING THE RESULTS !!")
        lines.append(String(repeating: "-", count: 60))
        lines.append(contentsOf: Self.wrap(Self.gattCacheWarning))
        lines.append("")

        for result in results {
            let state = state(for: result.topology)
            lines.append(String(repeating: "-", count: 60))
            lines.append("TOPOLOGY: \(result.topology.rawValue)")
            lines.append("  \(result.topology.summary)")
            lines.append("  outcome            : \(state.title)")
            lines.append("  publish            : \(result.publishOutcome.title)")
            lines.append("  measured           : \(result.measuredAt.map { Self.timestampFormatter.string(from: $0) } ?? "NOT MEASURED in this session")")
            lines.append("  central subscribed : \(result.centralSubscribed ? "yes" : "no")")
            lines.append("  subscribed reports : \(Self.describe(result.subscribedReports))")
            lines.append("  round trip         : \(result.roundTripConfirmed ? "confirmed (see caveat)" : "not confirmed")")
            if let reason = result.failureReason {
                // Verbatim, unwrapped, unedited. The exact NSException or
                // didAdd text is the single most useful line in this report.
                lines.append("  failure reason     : \(reason)")
            }
            if !result.qualifications.isEmpty {
                lines.append("  QUALIFICATIONS — this row is not an unqualified pass:")
                for qualification in result.qualifications {
                    lines.append(contentsOf: Self.wrap(qualification, indent: "    ! "))
                }
            }
            if result.notes.isEmpty {
                lines.append("  notes              : (none)")
            } else {
                lines.append("  notes:")
                for note in result.notes {
                    lines.append(contentsOf: Self.wrap(note, indent: "    • "))
                }
            }
        }

        lines.append(String(repeating: "-", count: 60))
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
        lines.append("ENVIRONMENT NOTES")
        lines.append(String(repeating: "-", count: 60))
        let centrals = manager.knownCentrals.map { $0.name.isEmpty ? "Unknown Mac" : $0.name }
        lines.append("Known centrals: \(centrals.isEmpty ? "(none)" : centrals.joined(separator: ", "))")
        lines.append("Currently connected: \(centralDisplayName ?? "(not connected)")")
        if let interval = manager.negotiatedConnectionInterval {
            lines.append("Connection interval (fed in externally): \(Int((interval * 1000).rounded())) ms")
        } else {
            lines.append("Connection interval: not available")
        }
        lines.append(contentsOf: Self.wrap(Self.connectionIntervalCaveat, indent: "  "))
        lines.append("")
        lines.append(contentsOf: Self.wrap(Self.roundTripCaveat, indent: "  "))

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

    /// Hard-wrap a paragraph for the fixed-width exported report. Plain-text
    /// bug reports get pasted into places that do not soft-wrap.
    static func wrap(_ text: String, indent: String = "  ", width: Int = 76) -> [String] {
        let words = text
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
        guard let first = words.first else { return [] }

        let continuation = String(repeating: " ", count: indent.count)
        var lines: [String] = []
        var current = indent + first

        for word in words.dropFirst() {
            if current.count + 1 + word.count > width {
                lines.append(current)
                current = continuation + word
            } else {
                current += " " + word
            }
        }
        lines.append(current)
        return lines
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
