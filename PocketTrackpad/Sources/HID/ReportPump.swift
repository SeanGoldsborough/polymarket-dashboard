//
//  ReportPump.swift
//  PocketTrackpad
//
//  The queue that sits between "the UI produced a report" and
//  "CBPeripheralManager.updateValue succeeded".
//
//  WHY THIS EXISTS AT ALL
//  ----------------------
//  A finger moving across a 120 Hz touch surface produces a touch sample roughly
//  every 8 ms. A BLE connection to macOS negotiates a connection interval of
//  11.25 ms to 15 ms and will carry, optimistically, one notification per
//  interval. Sending one report per touch sample therefore overruns the link
//  within a few hundred milliseconds. CoreBluetooth signals the overrun by
//  returning `false` from `updateValue(_:for:onSubscribedCentrals:)` and then
//  calling `peripheralManagerIsReady(toUpdateSubscribers:)` when there is room
//  again. Everything in this file is about surviving that window without losing
//  user intent.
//
//  THE TWO KINDS OF REPORT, AND WHY THEY ARE TREATED DIFFERENTLY
//  ------------------------------------------------------------
//  * Mouse reports are RELATIVE and therefore ADDITIVE. Two reports of dx=3 and
//    dx=4 are indistinguishable, to the host, from one report of dx=7. Dropping a
//    mouse report loses 7 pixels of travel forever; merging two loses nothing.
//    So mouse reports coalesce by accumulation — never by discarding.
//
//  * Keyboard and consumer reports are ABSOLUTE STATE. A key-down report and the
//    key-up report that follows it are not summable, and they are not
//    interchangeable: dropping the key-up leaves the host with a key held down
//    forever, which from the user's point of view is a stuck keyboard requiring
//    an unpair to fix. So these are a strict FIFO with no coalescing of any kind.
//
//  MOUSE BUTTON TRANSITIONS ARE A THIRD CASE
//  -----------------------------------------
//  The button bits live inside the mouse report, but they are absolute state, not
//  relative motion. The naive coalescing rule ("accumulate the deltas, keep the
//  latest buttons") silently eats a click whenever press and release land inside
//  the same flush window — which for a fast tap on a trackpad is the common case,
//  not the edge case. This pump therefore merges a new mouse report into the
//  tail of the queue ONLY when the button state is unchanged; a button transition
//  starts a new queue entry. Motion still accumulates without bound within each
//  button state, and no click is ever lost.
//

import Foundation

// MARK: - Transport

/// Outcome of handing one encoded report to the radio.
public enum ReportTransmitResult: Equatable, Sendable {
    /// The report reached CoreBluetooth's transmit queue.
    case delivered
    /// The transmit queue is full. The pump must stop and wait for
    /// `peripheralManagerIsReady(toUpdateSubscribers:)`; the report is retained
    /// and retried. This is the `false` return from `updateValue`.
    case backpressure
    /// Nobody is subscribed to this report, or the active topology cannot carry
    /// it (a consumer report under `.bootProtocolOnly`). Retrying will never
    /// help, so the report is discarded and counted.
    case undeliverable
}

/// The pump's view of the radio. Kept to two members so `ReportPumpTests` can
/// implement it with a fake that returns `.backpressure` on demand — the whole
/// backpressure path is otherwise untestable without a Mac in the room.
@MainActor
public protocol ReportPumpTransport: AnyObject {
    /// Write one fully-encoded report (already prefixed with its report ID if the
    /// topology requires it). `reportID` is passed alongside because
    /// `.perReportCharacteristic` needs it to pick a characteristic and cannot
    /// recover it from the bytes.
    func transmit(_ payload: Data, reportID: HIDReportID) -> ReportTransmitResult
}

// MARK: - Pump

@MainActor
public final class ReportPump {

    /// One queued report, in the order it was produced.
    ///
    /// Internal rather than private so the tests can assert on queue contents
    /// without reaching through the transport.
    internal enum Pending: Equatable {
        case mouse(MouseReport)
        case keyboard(KeyboardReport)
        case consumer(ConsumerReport)

        var isMouse: Bool {
            if case .mouse = self { return true }
            return false
        }

        var reportID: HIDReportID {
            switch self {
            case .mouse:    return .mouse
            case .keyboard: return .keyboard
            case .consumer: return .consumer
            }
        }

        func encodePayload() -> Data {
            switch self {
            case .mouse(let r):    return r.encodePayload()
            case .keyboard(let r): return r.encodePayload()
            case .consumer(let r): return r.encodePayload()
            }
        }

        func encodePrefixed() -> Data {
            switch self {
            case .mouse(let r):    return r.encodePrefixed()
            case .keyboard(let r): return r.encodePrefixed()
            case .consumer(let r): return r.encodePrefixed()
            }
        }
    }

    // MARK: Configuration

    /// Default flush cadence. 15 ms is the slow end of the interval macOS
    /// negotiates for a HID peripheral, so a pump running at 15 ms never queues
    /// faster than the link can drain even before backpressure kicks in. It is
    /// also a whole number of 1.25 ms BLE slots (12), which the negotiated
    /// interval always is.
    public static let defaultFlushInterval: TimeInterval = 0.015

    /// Upper bound on queue length.
    ///
    /// Because consecutive same-button mouse reports merge, the queue only grows
    /// on button transitions and key events, so in normal use it stays in single
    /// digits. A cap exists only for the pathological case of a central that
    /// subscribes, stops draining, and never disconnects. On overflow the OLDEST
    /// mouse entry is evicted rather than the oldest entry outright: losing a
    /// chunk of stale cursor travel is recoverable (the user moves again), losing
    /// a key-up is not.
    public static let queueLimit = 512

    // MARK: State

    private weak var transport: ReportPumpTransport?
    private var queue: [Pending] = []
    private var timer: Timer?

    /// The active topology, which decides whether the report ID byte is prefixed
    /// onto the payload and which reports can be carried at all.
    public private(set) var topology: ReportTopology

    /// Flush cadence currently in use.
    public private(set) var flushInterval: TimeInterval

    /// True between a `.backpressure` result and the next `resume()`. While true,
    /// `flush()` is a no-op: hammering `updateValue` after it has returned false
    /// is documented to be pointless and measurably slows the recovery.
    public private(set) var isBlocked = false

    /// Reports discarded because no subscriber could ever receive them. Surfaced
    /// in diagnostics; a non-zero value while apparently connected means the
    /// central subscribed to some report characteristics but not all of them.
    public private(set) var undeliverableCount = 0

    /// Mouse entries evicted by `queueLimit`. Must stay 0 in every test and in
    /// any healthy session; a non-zero value means the link is wedged.
    public private(set) var overflowCount = 0

    /// Total reports handed to the transport successfully. Diagnostics only.
    public private(set) var deliveredCount = 0

    /// Number of reports waiting to go out.
    public var pendingCount: Int { queue.count }

    /// Whether the flush timer is running.
    public var isRunning: Bool { timer != nil }

    // MARK: Init

    public init(
        transport: ReportPumpTransport?,
        topology: ReportTopology,
        flushInterval: TimeInterval = ReportPump.defaultFlushInterval
    ) {
        self.transport = transport
        self.topology = topology
        self.flushInterval = flushInterval
    }

    deinit {
        // `timer` is only ever touched on the main actor and Timer.invalidate must
        // be called on the thread that scheduled it. Reaching it from a
        // nonisolated deinit is not safe, so lifecycle is explicit: callers must
        // call `stop()`. `HIDPeripheralManager.stop()` does.
    }

    /// Point the pump at a different transport (used when the peripheral manager
    /// is torn down and rebuilt between topology attempts).
    public func setTransport(_ transport: ReportPumpTransport?) {
        self.transport = transport
    }

    /// Change topology. Clears the queue, because payload framing (prefixed vs.
    /// not) and the set of carriable reports both change, and re-framing queued
    /// reports for a link that has just been rebuilt sends stale input to a host
    /// that may not be the same host.
    public func setTopology(_ topology: ReportTopology) {
        self.topology = topology
        queue.removeAll(keepingCapacity: true)
        isBlocked = false
    }

    /// Resize the flush cadence, typically from
    /// `HIDPeripheralControlling.negotiatedConnectionInterval`. Restarts the timer
    /// if one is running so the change takes effect immediately.
    public func setFlushInterval(_ interval: TimeInterval) {
        let clamped = max(0.004, min(interval, 0.100))
        guard clamped != flushInterval else { return }
        flushInterval = clamped
        if isRunning {
            stop()
            start()
        }
    }

    // MARK: Timer lifecycle

    /// Begin flushing on a timer.
    ///
    /// A `Timer` rather than a `CADisplayLink`: a display link is locked to the
    /// screen refresh (8.3 ms or 16.7 ms depending on ProMotion state and on
    /// whether the screen is even on), which is neither the connection interval
    /// nor stable. The BLE link's cadence has nothing to do with the display's,
    /// and pumping at 120 Hz into a 66 Hz link just manufactures backpressure.
    ///
    /// `.common` run loop mode is required: in `.default` mode the timer stops
    /// firing while the user is dragging on a SwiftUI scroll view or holding a
    /// press gesture, which is precisely when reports are being produced.
    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: flushInterval, repeats: true) { [weak self] _ in
            // The timer is scheduled on the main run loop, so its callback runs on
            // the main thread; `assumeIsolated` states that contract explicitly and
            // traps loudly if it ever stops holding, rather than silently racing.
            MainActor.assumeIsolated {
                self?.flush()
            }
        }
        timer.tolerance = flushInterval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stop flushing and release the timer. Queued reports are kept: `stop()` is
    /// called when the app backgrounds as well as at teardown, and a user who
    /// foregrounds mid-drag should not lose the drag.
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Enqueue

    public func enqueue(mouse report: MouseReport) {
        guard carries(.mouse) else {
            undeliverableCount += 1
            return
        }
        // Merge into the tail only while the button state is unchanged; see the
        // file header for why a button transition must break the merge.
        if case .some(.mouse(let tail)) = queue.last, tail.buttons == report.buttons {
            var merged = tail
            merged.dx += report.dx
            merged.dy += report.dy
            merged.wheel += report.wheel
            merged.pan += report.pan
            queue[queue.count - 1] = .mouse(merged)
            return
        }
        append(.mouse(report))
    }

    public func enqueue(keyboard report: KeyboardReport) {
        guard carries(.keyboard) else {
            undeliverableCount += 1
            return
        }
        // No coalescing, not even of two identical reports: a host distinguishes
        // "key still held" from "key pressed again" only by the release between
        // them, and auto-repeat is the host's job, not ours.
        append(.keyboard(report))
    }

    public func enqueue(consumer report: ConsumerReport) {
        guard carries(.consumer) else {
            // `.bootProtocolOnly` has no consumer collection at all. Counting the
            // drop rather than silently ignoring it is what lets the Remotes tab
            // tell the user why the volume buttons do nothing.
            undeliverableCount += 1
            return
        }
        append(.consumer(report))
    }

    private func carries(_ id: HIDReportID) -> Bool {
        topology.supportedReports.contains(id)
    }

    private func append(_ item: Pending) {
        queue.append(item)
        guard queue.count > Self.queueLimit else { return }
        evictOldestMouseEntry()
    }

    /// Drop the oldest mouse entry; if the queue somehow contains no mouse entry
    /// at all (a flood of key events with the link wedged) drop the oldest entry
    /// outright, because an unbounded queue is worse than a lost keystroke.
    private func evictOldestMouseEntry() {
        if let index = queue.firstIndex(where: { $0.isMouse }) {
            queue.remove(at: index)
        } else {
            queue.removeFirst()
        }
        overflowCount += 1
    }

    // MARK: Flush

    /// Drain the queue until it is empty or the transport pushes back.
    ///
    /// Idempotent and safe to call at any time; the timer calls it, and
    /// `resume()` calls it so recovery does not wait up to one interval.
    public func flush() {
        guard !isBlocked, let transport else { return }
        while let item = queue.first {
            let payload: Data
            switch topology {
            case .perReportCharacteristic, .bootProtocolOnly:
                // The report ID is carried by the Report Reference descriptor, or
                // is implicit in the boot characteristic. Payload only.
                payload = item.encodePayload()
            case .singleCharacteristicPrefixed:
                // One characteristic for everything, so the ID must ride in byte 0.
                payload = item.encodePrefixed()
            }

            switch transport.transmit(payload, reportID: item.reportID) {
            case .delivered:
                queue.removeFirst()
                deliveredCount += 1
            case .backpressure:
                // Leave the item at the head of the queue. It is retried, in
                // order, the moment `resume()` fires.
                isBlocked = true
                return
            case .undeliverable:
                queue.removeFirst()
                undeliverableCount += 1
            }
        }
    }

    /// Called from `peripheralManagerIsReady(toUpdateSubscribers:)`.
    ///
    /// Flushing immediately rather than waiting for the next timer tick matters:
    /// the ready callback arrives exactly when the link has room, and deferring by
    /// up to 15 ms halves the achievable report rate under sustained motion.
    public func resume() {
        isBlocked = false
        flush()
    }

    /// Throw away everything queued. Used on disconnect, where replaying a
    /// half-finished drag into the next central would be actively wrong.
    public func reset() {
        queue.removeAll(keepingCapacity: true)
        isBlocked = false
    }

    /// Zero the diagnostic counters without touching the queue.
    public func resetCounters() {
        undeliverableCount = 0
        overflowCount = 0
        deliveredCount = 0
    }
}
