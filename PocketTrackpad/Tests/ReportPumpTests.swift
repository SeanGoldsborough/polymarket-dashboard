//
//  ReportPumpTests.swift
//  PocketTrackpadTests
//
//  Proofs about the coalescing queue, all of them driven through a fake
//  transport. No CoreBluetooth, no radio, no device — which is the point: the
//  backpressure path (`updateValue` returning false, then
//  `peripheralManagerIsReady` firing) is otherwise only reachable by saturating
//  a real BLE link, and a bug in it looks exactly like "Bluetooth is flaky".
//
//  The flush timer is never started. `flush()` is called explicitly so every test
//  is deterministic; a test that waits on a 15 ms timer is a test that fails on
//  a loaded CI machine.
//

import XCTest
@testable import PocketTrackpad

// MARK: - Fake transport

@MainActor
private final class FakeTransport: ReportPumpTransport {

    struct Sent: Equatable {
        let payload: [UInt8]
        let reportID: HIDReportID
    }

    /// Everything that got through, in order.
    private(set) var sent: [Sent] = []

    /// When true, every `transmit` answers `.backpressure` — the fake equivalent
    /// of CoreBluetooth's transmit queue being full.
    var isBlocked = false

    /// Report IDs that answer `.undeliverable` (nobody subscribed).
    var undeliverable: Set<HIDReportID> = []

    /// Deliver at most this many reports before blocking, then block. `nil` means
    /// no limit. Used to prove the queue survives a partial drain.
    var deliveryBudget: Int?

    private(set) var transmitCallCount = 0

    func transmit(_ payload: Data, reportID: HIDReportID) -> ReportTransmitResult {
        transmitCallCount += 1
        if undeliverable.contains(reportID) { return .undeliverable }
        if isBlocked { return .backpressure }
        if let budget = deliveryBudget {
            guard budget > 0 else {
                isBlocked = true
                return .backpressure
            }
            deliveryBudget = budget - 1
        }
        sent.append(Sent(payload: Array(payload), reportID: reportID))
        return .delivered
    }

    // MARK: Convenience readers

    var mouseReports: [Sent] { sent.filter { $0.reportID == .mouse } }

    /// Decode a mouse payload back into signed deltas.
    static func mouseDeltas(_ payload: [UInt8]) -> (buttons: UInt8, dx: Int, dy: Int, wheel: Int, pan: Int) {
        precondition(payload.count == MouseReport.payloadSize)
        return (
            payload[0],
            Int(Int8(bitPattern: payload[1])),
            Int(Int8(bitPattern: payload[2])),
            Int(Int8(bitPattern: payload[3])),
            Int(Int8(bitPattern: payload[4]))
        )
    }

    func reset() {
        sent.removeAll()
        isBlocked = false
        undeliverable.removeAll()
        deliveryBudget = nil
        transmitCallCount = 0
    }
}

// MARK: - Tests

@MainActor
final class ReportPumpTests: XCTestCase {

    // XCTest instantiates the test class once per test method, so these property
    // initialisers give every test a fresh, isolated fixture.
    //
    // `setUp()`/`tearDown()` are deliberately NOT overridden: XCTestCase declares
    // them without actor isolation, and overriding them from a `@MainActor` class
    // changes the isolation of an inherited declaration, which the compiler
    // rejects. Property initialisers sidestep that entirely. Nothing needs tearing
    // down either — no test starts the flush timer, which is what makes them
    // deterministic on a loaded CI machine.
    private let transport = FakeTransport()
    private lazy var pump = ReportPump(transport: transport, topology: .perReportCharacteristic)

    // MARK: - Mouse coalescing

    func testConsecutiveMouseReportsAccumulateRatherThanQueue() {
        for _ in 0..<10 {
            pump.enqueue(mouse: MouseReport(dx: 2, dy: -1))
        }
        // All ten merged into one queue entry: coalescing happens on enqueue, not
        // on flush, so memory stays flat under a fast finger.
        XCTAssertEqual(pump.pendingCount, 1)

        pump.flush()
        XCTAssertEqual(transport.mouseReports.count, 1)
        let deltas = FakeTransport.mouseDeltas(transport.mouseReports[0].payload)
        XCTAssertEqual(deltas.dx, 20)
        XCTAssertEqual(deltas.dy, -10)
    }

    func testMouseDeltasAccumulateAcrossABlockedWindow() {
        // One report gets through, then the link jams.
        pump.enqueue(mouse: MouseReport(dx: 1, dy: 1))
        pump.flush()
        XCTAssertEqual(transport.mouseReports.count, 1)

        transport.isBlocked = true
        pump.enqueue(mouse: MouseReport(dx: 3, dy: 0, wheel: 1, pan: 0))
        pump.flush()
        XCTAssertTrue(pump.isBlocked, "A backpressure result must latch the pump")
        XCTAssertEqual(transport.mouseReports.count, 1, "Nothing more should have gone out")

        // A whole flick's worth of motion arrives while the link is jammed.
        for _ in 0..<50 {
            pump.enqueue(mouse: MouseReport(dx: 2, dy: -2, wheel: 0, pan: 1))
            pump.flush() // no-op while blocked; proves flush is safe to spam
        }
        XCTAssertEqual(pump.pendingCount, 1, "Blocked motion must merge into one entry")

        transport.isBlocked = false
        pump.resume()

        XCTAssertFalse(pump.isBlocked)
        XCTAssertEqual(transport.mouseReports.count, 2)
        let deltas = FakeTransport.mouseDeltas(transport.mouseReports[1].payload)
        // 3 + 50*2 = 103, 0 + 50*(-2) = -100, 1 + 0 = 1, 0 + 50*1 = 50.
        XCTAssertEqual(deltas.dx, 103, "Every pixel of travel must survive the jam")
        XCTAssertEqual(deltas.dy, -100)
        XCTAssertEqual(deltas.wheel, 1)
        XCTAssertEqual(deltas.pan, 50)
        XCTAssertEqual(pump.pendingCount, 0)
    }

    func testAccumulatedMotionIsClampedNotWrappedOnTheWire() {
        // 200 x dx=5 = 1000, far past Int8. The encoder clamps to 127; what must
        // NOT happen is an overflow trap or a wrapped negative delta, which would
        // send the cursor backwards.
        transport.isBlocked = true
        for _ in 0..<200 { pump.enqueue(mouse: MouseReport(dx: 5)) }
        transport.isBlocked = false
        pump.resume()

        XCTAssertEqual(transport.mouseReports.count, 1)
        let deltas = FakeTransport.mouseDeltas(transport.mouseReports[0].payload)
        XCTAssertEqual(deltas.dx, 127)
    }

    func testButtonTransitionBreaksTheMergeSoClicksAreNeverLost() {
        // A tap: press and release inside one flush window. Naive "keep the latest
        // buttons" coalescing swallows this entirely.
        transport.isBlocked = true
        pump.enqueue(mouse: MouseReport(buttons: .none, dx: 1))
        pump.enqueue(mouse: MouseReport(buttons: .left, dx: 0))
        pump.enqueue(mouse: MouseReport(buttons: .left, dx: 2))
        pump.enqueue(mouse: MouseReport(buttons: .none, dx: 0))
        XCTAssertEqual(pump.pendingCount, 3, "Two button transitions => three entries")

        transport.isBlocked = false
        pump.resume()

        XCTAssertEqual(transport.mouseReports.count, 3)
        let states = transport.mouseReports.map { FakeTransport.mouseDeltas($0.payload).buttons }
        XCTAssertEqual(states, [0, MouseButtons.left.rawValue, 0], "Press and release must both reach the host")

        // The two same-button reports still merged their motion.
        XCTAssertEqual(FakeTransport.mouseDeltas(transport.mouseReports[1].payload).dx, 2)
    }

    // MARK: - Stateful reports

    func testKeyboardReportsAreNeverCoalesced() {
        transport.isBlocked = true
        pump.enqueue(keyboard: KeyboardReport(keys: [HIDKeyCode.a]))
        pump.enqueue(keyboard: KeyboardReport.released)
        pump.enqueue(keyboard: KeyboardReport(keys: [HIDKeyCode.a]))
        pump.enqueue(keyboard: KeyboardReport.released)
        XCTAssertEqual(pump.pendingCount, 4, "Dropping a key-up would stick a key down on the host")

        transport.isBlocked = false
        pump.resume()

        let keyboard = transport.sent.filter { $0.reportID == .keyboard }
        XCTAssertEqual(keyboard.count, 4)
        XCTAssertEqual(keyboard[0].payload[2], HIDKeyCode.a)
        XCTAssertEqual(keyboard[1].payload[2], 0)
        XCTAssertEqual(keyboard[2].payload[2], HIDKeyCode.a)
        XCTAssertEqual(keyboard[3].payload[2], 0)
    }

    func testIdenticalConsecutiveKeyboardReportsAreBothDelivered() {
        // Auto-repeat is the host's job, but a caller that deliberately sends the
        // same report twice must not have the second one eaten.
        pump.enqueue(keyboard: KeyboardReport(keys: [HIDKeyCode.space]))
        pump.enqueue(keyboard: KeyboardReport(keys: [HIDKeyCode.space]))
        pump.flush()
        XCTAssertEqual(transport.sent.count, 2)
    }

    func testConsumerReportsPreserveOrder() {
        transport.isBlocked = true
        pump.enqueue(consumer: ConsumerReport(.volumeUp))
        pump.enqueue(consumer: .released)
        pump.enqueue(consumer: ConsumerReport(.volumeDown))
        pump.enqueue(consumer: .released)
        transport.isBlocked = false
        pump.resume()

        let payloads = transport.sent.filter { $0.reportID == .consumer }.map(\.payload)
        XCTAssertEqual(payloads, [
            [0xE9, 0x00],   // volumeUp
            [0x00, 0x00],
            [0xEA, 0x00],   // volumeDown
            [0x00, 0x00]
        ])
    }

    func testInterleavedReportsKeepGlobalOrder() {
        // Ordering across report types matters: a Command-click is a keyboard
        // modifier report that must land BEFORE the mouse button report.
        transport.isBlocked = true
        pump.enqueue(keyboard: KeyboardReport(modifiers: .leftCommand))
        pump.enqueue(mouse: MouseReport(buttons: .left))
        pump.enqueue(mouse: MouseReport(buttons: .none))
        pump.enqueue(keyboard: KeyboardReport.released)
        transport.isBlocked = false
        pump.resume()

        XCTAssertEqual(transport.sent.map(\.reportID), [.keyboard, .mouse, .mouse, .keyboard])
    }

    func testMouseDoesNotMergeAcrossAnInterveningKeyboardReport() {
        transport.isBlocked = true
        pump.enqueue(mouse: MouseReport(dx: 5))
        pump.enqueue(keyboard: KeyboardReport(keys: [HIDKeyCode.a]))
        pump.enqueue(mouse: MouseReport(dx: 7))
        XCTAssertEqual(pump.pendingCount, 3)

        transport.isBlocked = false
        pump.resume()
        XCTAssertEqual(transport.sent.map(\.reportID), [.mouse, .keyboard, .mouse])
        XCTAssertEqual(FakeTransport.mouseDeltas(transport.sent[0].payload).dx, 5)
        XCTAssertEqual(FakeTransport.mouseDeltas(transport.sent[2].payload).dx, 7)
    }

    // MARK: - Backpressure protocol

    func testFlushIsANoOpWhileBlockedAndDoesNotHammerTheTransport() {
        transport.isBlocked = true
        pump.enqueue(keyboard: KeyboardReport(keys: [HIDKeyCode.a]))
        pump.flush()
        let callsAfterFirstFlush = transport.transmitCallCount
        XCTAssertEqual(callsAfterFirstFlush, 1)

        for _ in 0..<20 { pump.flush() }
        XCTAssertEqual(
            transport.transmitCallCount, callsAfterFirstFlush,
            "Calling updateValue again before peripheralManagerIsReady is pointless and slows recovery"
        )
    }

    func testResumeDrainsEverythingInOrderWithNoLoss() {
        transport.isBlocked = true
        for index in 0..<16 {
            pump.enqueue(keyboard: KeyboardReport(keys: [UInt8(0x04 + index)]))
        }
        pump.flush()
        XCTAssertEqual(transport.sent.count, 0)
        XCTAssertEqual(pump.pendingCount, 16)

        transport.isBlocked = false
        pump.resume()

        XCTAssertEqual(pump.pendingCount, 0)
        XCTAssertEqual(transport.sent.count, 16)
        XCTAssertEqual(transport.sent.map { $0.payload[2] }, (0..<16).map { UInt8(0x04 + $0) })
        XCTAssertEqual(pump.deliveredCount, 16)
        XCTAssertEqual(pump.undeliverableCount, 0)
        XCTAssertEqual(pump.overflowCount, 0, "Nothing may be dropped")
    }

    func testPartialDrainRetriesTheExactReportThatWasRefused() {
        // Deliver three, then jam. The fourth must be retried, not skipped.
        for index in 0..<6 {
            pump.enqueue(keyboard: KeyboardReport(keys: [UInt8(0x10 + index)]))
        }
        transport.deliveryBudget = 3
        pump.flush()

        XCTAssertEqual(transport.sent.count, 3)
        XCTAssertTrue(pump.isBlocked)
        XCTAssertEqual(pump.pendingCount, 3)

        transport.deliveryBudget = nil
        transport.isBlocked = false
        pump.resume()

        XCTAssertEqual(transport.sent.count, 6)
        XCTAssertEqual(transport.sent.map { $0.payload[2] }, (0..<6).map { UInt8(0x10 + $0) })
    }

    func testBlockedFlagClearsOnlyViaResume() {
        transport.isBlocked = true
        pump.enqueue(mouse: MouseReport(dx: 1))
        pump.flush()
        XCTAssertTrue(pump.isBlocked)

        transport.isBlocked = false
        pump.flush()
        XCTAssertTrue(pump.isBlocked, "Only peripheralManagerIsReady may unlatch the pump")
        XCTAssertEqual(transport.sent.count, 0)

        pump.resume()
        XCTAssertFalse(pump.isBlocked)
        XCTAssertEqual(transport.sent.count, 1)
    }

    // MARK: - Undeliverable reports

    func testReportsWithNoSubscriberAreDiscardedNotRetriedForever() {
        transport.undeliverable = [.consumer]
        pump.enqueue(consumer: ConsumerReport(.mute))
        pump.enqueue(keyboard: KeyboardReport(keys: [HIDKeyCode.a]))
        pump.flush()

        XCTAssertEqual(pump.pendingCount, 0, "An undeliverable report must not wedge the queue")
        XCTAssertEqual(pump.undeliverableCount, 1)
        XCTAssertEqual(transport.sent.map(\.reportID), [.keyboard])
        XCTAssertFalse(pump.isBlocked)
    }

    func testBootTopologyRefusesConsumerReportsAtEnqueueTime() {
        let bootPump = ReportPump(transport: transport, topology: .bootProtocolOnly)
        bootPump.enqueue(consumer: ConsumerReport(.volumeUp))
        XCTAssertEqual(bootPump.pendingCount, 0, "Boot protocol has no consumer collection at all")
        XCTAssertEqual(bootPump.undeliverableCount, 1)

        bootPump.enqueue(mouse: MouseReport(dx: 1))
        bootPump.enqueue(keyboard: KeyboardReport(keys: [HIDKeyCode.a]))
        XCTAssertEqual(bootPump.pendingCount, 2)

        bootPump.flush()
        XCTAssertEqual(transport.sent.map(\.reportID), [.mouse, .keyboard])
        // Boot reports are un-prefixed.
        XCTAssertEqual(transport.sent[0].payload.count, MouseReport.payloadSize)
        XCTAssertEqual(transport.sent[1].payload.count, KeyboardReport.payloadSize)
    }

    // MARK: - Framing per topology

    func testPerReportTopologySendsBarePayloads() {
        pump.enqueue(mouse: MouseReport(dx: 4))
        pump.flush()
        XCTAssertEqual(transport.sent[0].payload.count, MouseReport.payloadSize)
        XCTAssertEqual(FakeTransport.mouseDeltas(transport.sent[0].payload).dx, 4)
    }

    func testPrefixedTopologyPrependsTheReportIDByte() {
        let prefixed = ReportPump(transport: transport, topology: .singleCharacteristicPrefixed)
        prefixed.enqueue(mouse: MouseReport(dx: 4))
        prefixed.enqueue(consumer: ConsumerReport(.mute))
        prefixed.flush()

        XCTAssertEqual(transport.sent[0].payload.count, MouseReport.payloadSize + 1)
        XCTAssertEqual(transport.sent[0].payload[0], HIDReportID.mouse.rawValue)
        // Payload after the report-ID prefix is [buttons, dx, dy, wheel, pan],
        // so dx is at index 2 (index 1 is the buttons byte, 0 here).
        XCTAssertEqual(Int(Int8(bitPattern: transport.sent[0].payload[2])), 4)

        XCTAssertEqual(transport.sent[1].payload.count, ConsumerReport.payloadSize + 1)
        XCTAssertEqual(transport.sent[1].payload[0], HIDReportID.consumer.rawValue)
        XCTAssertEqual(Array(transport.sent[1].payload.dropFirst()), [0xE2, 0x00])
    }

    // MARK: - Lifecycle

    func testSetTopologyClearsTheQueueAndUnlatches() {
        transport.isBlocked = true
        pump.enqueue(keyboard: KeyboardReport(keys: [HIDKeyCode.a]))
        pump.flush()
        XCTAssertTrue(pump.isBlocked)

        pump.setTopology(.bootProtocolOnly)
        XCTAssertEqual(pump.pendingCount, 0, "Reports framed for the old topology must not be replayed")
        XCTAssertFalse(pump.isBlocked)
        XCTAssertEqual(pump.topology, .bootProtocolOnly)
    }

    func testResetDiscardsQueuedReports() {
        transport.isBlocked = true
        pump.enqueue(mouse: MouseReport(dx: 1))
        pump.enqueue(keyboard: KeyboardReport(keys: [HIDKeyCode.a]))
        XCTAssertEqual(pump.pendingCount, 2)

        pump.reset()
        XCTAssertEqual(pump.pendingCount, 0)
        XCTAssertFalse(pump.isBlocked)

        transport.isBlocked = false
        pump.flush()
        XCTAssertEqual(transport.sent.count, 0)
    }

    func testMissingTransportDoesNotDropQueuedReports() {
        pump.setTransport(nil)
        pump.enqueue(mouse: MouseReport(dx: 3))
        pump.flush()
        XCTAssertEqual(pump.pendingCount, 1, "With no radio attached the queue must hold, not drain")

        pump.setTransport(transport)
        pump.flush()
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(FakeTransport.mouseDeltas(transport.sent[0].payload).dx, 3)
    }

    func testFlushIntervalIsClampedToSaneBounds() {
        pump.setFlushInterval(0.0001)
        XCTAssertEqual(pump.flushInterval, 0.004, accuracy: 0.0001, "A 0.1 ms pump would burn the CPU for nothing")

        pump.setFlushInterval(10)
        XCTAssertEqual(pump.flushInterval, 0.100, accuracy: 0.0001, "A 10 s pump would look like a dead device")

        pump.setFlushInterval(0.0075)
        XCTAssertEqual(pump.flushInterval, 0.0075, accuracy: 0.0001)
    }

    // MARK: - Overflow

    func testQueueOverflowEvictsMotionRatherThanKeystrokes() {
        transport.isBlocked = true
        // Keyboard reports never merge, so this is the only way to grow the queue.
        for index in 0..<(ReportPump.queueLimit + 10) {
            pump.enqueue(keyboard: KeyboardReport(keys: [UInt8(truncatingIfNeeded: 0x04 + index)]))
        }
        XCTAssertEqual(pump.pendingCount, ReportPump.queueLimit)
        XCTAssertEqual(pump.overflowCount, 10)

        // The tail — the most recent, most relevant reports, including whatever
        // key-up is outstanding — survives.
        transport.isBlocked = false
        pump.resume()
        XCTAssertEqual(transport.sent.count, ReportPump.queueLimit)
        XCTAssertEqual(
            transport.sent.last?.payload[2],
            UInt8(truncatingIfNeeded: 0x04 + ReportPump.queueLimit + 9)
        )
    }

    func testNormalTrafficNeverOverflows() {
        // 10 000 motion samples — far more than any real gesture — merge down to
        // one entry and never trip the cap.
        transport.isBlocked = true
        for _ in 0..<10_000 { pump.enqueue(mouse: MouseReport(dx: 1, dy: 1)) }
        XCTAssertEqual(pump.pendingCount, 1)
        XCTAssertEqual(pump.overflowCount, 0)
    }
}
