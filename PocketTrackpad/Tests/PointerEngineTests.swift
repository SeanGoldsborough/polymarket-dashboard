//
//  PointerEngineTests.swift
//  PocketTrackpadTests
//
//  Deterministic tests for `PointerEngine` and `GestureState`. No device, no
//  timers, no run loop: every sample stream is synthetic and every timestamp
//  is written out by hand, so a failure here is always a real regression and
//  never flakiness.
//
//  (`GestureStateTests` lives in this file rather than its own because the
//  gesture machine's pointer behaviour is inseparable from the engine it
//  drives.)
//

import XCTest
import CoreGraphics
@testable import PocketTrackpad

// MARK: - Shared helpers

/// A straight-line drag: `count` steps of `step` points along x, one sample
/// every `interval` seconds, preceded by the touch-down sample.
private func ramp(step: Double, count: Int, interval: TimeInterval) -> [TouchSample] {
    precondition(count >= 1)
    var samples: [TouchSample] = [TouchSample(location: .zero, timestamp: 0)]
    for i in 1...count {
        samples.append(
            TouchSample(
                location: CGPoint(x: step * Double(i), y: 0),
                timestamp: interval * Double(i)
            )
        )
    }
    return samples
}

/// Feed the engine and collect every report it wants to send, pumping
/// `drain()` exactly the way the real caller must.
private func collect(_ engine: PointerEngine, _ samples: [TouchSample]) -> [(dx: Int, dy: Int)] {
    var reports: [(dx: Int, dy: Int)] = []
    for sample in samples {
        let delta = engine.consume(sample)
        if delta.dx != 0 || delta.dy != 0 { reports.append(delta) }
        while let extra = engine.drain() { reports.append(extra) }
    }
    return reports
}

private func totalX(_ reports: [(dx: Int, dy: Int)]) -> Int {
    reports.reduce(0) { $0 + $1.dx }
}

private func totalY(_ reports: [(dx: Int, dy: Int)]) -> Int {
    reports.reduce(0) { $0 + $1.dy }
}

// MARK: - PointerEngine

final class PointerEngineTests: XCTestCase {

    // MARK: Residue

    /// The headline property: 100 frames of 0.4 points each is 40 points of
    /// real travel. Truncating every frame would deliver exactly zero, which
    /// is what makes a naive implementation impossible to point with.
    func testSubPixelResidueIsConserved() {
        let tracking = 0.3
        let engine = PointerEngine(tracking: tracking, motion: 0)
        engine.begin()

        let samples = ramp(step: 0.4, count: 100, interval: 1.0 / 120.0)
        let delivered = totalX(collect(engine, samples))

        let ideal = 40.0 * PointerTuning.default.baseGain(for: tracking)
        XCTAssertGreaterThan(delivered, 0, "slow drift was truncated away entirely")
        XCTAssertEqual(Double(delivered), ideal, accuracy: 1.0)
    }

    /// Same property in the negative direction — `rounded(.towardZero)` has to
    /// be symmetric or the pointer drifts one way over a long session.
    func testSubPixelResidueIsConservedGoingBackwards() {
        let tracking = 0.3
        let engine = PointerEngine(tracking: tracking, motion: 0)
        engine.begin()

        let samples = ramp(step: -0.4, count: 100, interval: 1.0 / 120.0)
        let delivered = totalX(collect(engine, samples))

        let ideal = -40.0 * PointerTuning.default.baseGain(for: tracking)
        XCTAssertLessThan(delivered, 0)
        XCTAssertEqual(Double(delivered), ideal, accuracy: 1.0)
    }

    func testResidueIsKeptPerAxis() {
        let engine = PointerEngine(tracking: 0.5, motion: 0)
        engine.begin()

        var samples: [TouchSample] = [TouchSample(location: .zero, timestamp: 0)]
        for i in 1...100 {
            samples.append(
                TouchSample(
                    location: CGPoint(x: 0.3 * Double(i), y: -0.5 * Double(i)),
                    timestamp: Double(i) / 120.0
                )
            )
        }
        let reports = collect(engine, samples)
        let gain = PointerTuning.default.baseGain(for: 0.5)

        XCTAssertEqual(Double(totalX(reports)), 30.0 * gain, accuracy: 1.0)
        XCTAssertEqual(Double(totalY(reports)), -50.0 * gain, accuracy: 1.0)
    }

    func testBeginClearsResidue() {
        let engine = PointerEngine(tracking: 0.5, motion: 0)
        engine.begin()
        _ = engine.consume(TouchSample(location: .zero, timestamp: 0))
        _ = engine.consume(TouchSample(location: CGPoint(x: 900, y: 0), timestamp: 1.0 / 120.0))
        XCTAssertTrue(engine.hasPendingTravel, "a 900 pt jump must leave overflow banked")

        engine.begin()
        XCTAssertFalse(engine.hasPendingTravel)
        XCTAssertNil(engine.drain(), "residue leaked from the previous gesture")
    }

    // MARK: Overflow

    /// A single report can only carry ±127. A 900 point flick must arrive in
    /// full, spread over consecutive reports — clamping and discarding would
    /// turn a full-screen flick into a 127 point nudge.
    func testOverflowIsCarriedAcrossReportsNotDiscarded() {
        let tracking = 1.0
        let engine = PointerEngine(tracking: tracking, motion: 0)
        engine.begin()

        let samples = [
            TouchSample(location: .zero, timestamp: 0),
            TouchSample(location: CGPoint(x: 900, y: 0), timestamp: 1.0 / 120.0)
        ]
        let reports = collect(engine, samples)

        XCTAssertGreaterThan(reports.count, 1, "the flick was delivered in a single clamped report")
        for report in reports {
            XCTAssertLessThanOrEqual(abs(report.dx), 127)
            XCTAssertLessThanOrEqual(abs(report.dy), 127)
        }

        let ideal = 900.0 * PointerTuning.default.baseGain(for: tracking)
        XCTAssertEqual(Double(totalX(reports)), ideal, accuracy: 1.0)
    }

    func testOverflowIsCarriedInBothDirections() {
        let engine = PointerEngine(tracking: 0.5, motion: 0)
        engine.begin()

        let samples = [
            TouchSample(location: .zero, timestamp: 0),
            TouchSample(location: CGPoint(x: -600, y: 400), timestamp: 1.0 / 120.0)
        ]
        let reports = collect(engine, samples)
        for report in reports {
            XCTAssertLessThanOrEqual(abs(report.dx), 127)
            XCTAssertLessThanOrEqual(abs(report.dy), 127)
        }

        let gain = PointerTuning.default.baseGain(for: 0.5)
        XCTAssertEqual(Double(totalX(reports)), -600.0 * gain, accuracy: 1.0)
        XCTAssertEqual(Double(totalY(reports)), 400.0 * gain, accuracy: 1.0)
    }

    func testDrainTerminates() {
        let engine = PointerEngine(tracking: 1.0, motion: 1.0)
        engine.begin()
        _ = engine.consume(TouchSample(location: .zero, timestamp: 0))
        _ = engine.consume(TouchSample(location: CGPoint(x: 4000, y: -4000), timestamp: 1.0 / 240.0))

        var pumps = 0
        while engine.drain() != nil {
            pumps += 1
            if pumps > 10_000 { break }
        }
        XCTAssertLessThan(pumps, 10_000, "drain() never returned nil — the report pump would hang")
    }

    // MARK: Acceleration

    /// `motion == 0` must be linear in the strict sense: delivered distance is
    /// a function of travel alone, so the same travel at four times the speed
    /// delivers exactly the same distance, and twice the travel delivers twice
    /// the distance.
    func testMotionZeroIsExactlyLinear() {
        let slow = ramp(step: 3, count: 20, interval: 1.0 / 60.0)
        let fast = ramp(step: 3, count: 20, interval: 1.0 / 240.0)

        let slowEngine = PointerEngine(tracking: 0.5, motion: 0)
        slowEngine.begin()
        let slowDistance = totalX(collect(slowEngine, slow))

        let fastEngine = PointerEngine(tracking: 0.5, motion: 0)
        fastEngine.begin()
        let fastDistance = totalX(collect(fastEngine, fast))

        XCTAssertEqual(slowDistance, fastDistance, "motion == 0 must not depend on speed at all")
        XCTAssertGreaterThan(slowDistance, 0)

        let doubleTravelEngine = PointerEngine(tracking: 0.5, motion: 0)
        doubleTravelEngine.begin()
        let doubled = totalX(collect(doubleTravelEngine, ramp(step: 6, count: 20, interval: 1.0 / 60.0)))
        XCTAssertEqual(Double(doubled), Double(slowDistance) * 2.0, accuracy: 1.0)
    }

    func testMotionAboveZeroRewardsSpeed() {
        let slow = ramp(step: 3, count: 20, interval: 1.0 / 60.0)
        let fast = ramp(step: 3, count: 20, interval: 1.0 / 240.0)

        let slowEngine = PointerEngine(tracking: 0.5, motion: 1.0)
        slowEngine.begin()
        let slowDistance = totalX(collect(slowEngine, slow))

        let fastEngine = PointerEngine(tracking: 0.5, motion: 1.0)
        fastEngine.begin()
        let fastDistance = totalX(collect(fastEngine, fast))

        XCTAssertGreaterThan(fastDistance, slowDistance)
    }

    /// The curve saturates: even an absurd speed cannot multiply gain by more
    /// than `1 + maximumMotionStrength`.
    func testAccelerationSaturates() {
        let tuning = PointerTuning.default
        let ceiling = 1.0 + tuning.maximumMotionStrength
        for speed in [0.0, 10.0, 500.0, 5_000.0, 1_000_000.0] {
            let multiplier = tuning.accelerationMultiplier(speed: speed, motion: 1.0)
            XCTAssertGreaterThanOrEqual(multiplier, 1.0)
            XCTAssertLessThan(multiplier, ceiling)
        }
        XCTAssertEqual(tuning.accelerationMultiplier(speed: 12_345, motion: 0), 1.0)
    }

    // MARK: Monotonicity

    func testHigherTrackingNeverDeliversLessDistance() {
        let samples = ramp(step: 2.5, count: 40, interval: 1.0 / 120.0)
        var previous = Int.min
        for stepIndex in 0...20 {
            let tracking = Double(stepIndex) / 20.0
            let engine = PointerEngine(tracking: tracking, motion: 0.5)
            engine.begin()
            let delivered = totalX(collect(engine, samples))
            XCTAssertGreaterThanOrEqual(
                delivered, previous,
                "tracking \(tracking) delivered less than the setting below it"
            )
            previous = delivered
        }
    }

    func testHigherMotionNeverDeliversLessDistance() {
        let samples = ramp(step: 12, count: 30, interval: 1.0 / 120.0)
        var previous = Int.min
        for stepIndex in 0...10 {
            let motion = Double(stepIndex) / 10.0
            let engine = PointerEngine(tracking: 0.5, motion: motion)
            engine.begin()
            let delivered = totalX(collect(engine, samples))
            XCTAssertGreaterThanOrEqual(delivered, previous)
            previous = delivered
        }
    }

    func testBaseGainCurveIsStrictlyIncreasingAndInRange() {
        let tuning = PointerTuning.default
        XCTAssertEqual(tuning.baseGain(for: 0), tuning.minimumBaseGain, accuracy: 1e-9)
        XCTAssertEqual(tuning.baseGain(for: 1), tuning.maximumBaseGain, accuracy: 1e-9)

        var previous = -Double.infinity
        for stepIndex in 0...100 {
            let gain = tuning.baseGain(for: Double(stepIndex) / 100.0)
            XCTAssertGreaterThan(gain, previous)
            previous = gain
        }

        // The midpoint must be a usable default, not a dead zone.
        let midpoint = tuning.baseGain(for: 0.5)
        XCTAssertGreaterThan(midpoint, 1.0)
        XCTAssertLessThan(midpoint, 2.0)
    }

    // MARK: Degenerate input

    /// Two samples with the same timestamp must not divide by zero and must
    /// not teleport the pointer.
    func testDuplicateTimestampCannotProduceInfiniteSpeed() {
        let tuning = PointerTuning.default
        let engine = PointerEngine(tracking: 1.0, motion: 1.0)
        engine.begin()
        _ = engine.consume(TouchSample(location: .zero, timestamp: 5))

        var delivered = engine.consume(TouchSample(location: CGPoint(x: 5, y: 0), timestamp: 5)).dx
        while let extra = engine.drain() { delivered += extra.dx }

        let hardCeiling = 5.0 * tuning.maximumBaseGain * (1.0 + tuning.maximumMotionStrength)
        XCTAssertGreaterThan(delivered, 0)
        XCTAssertLessThanOrEqual(Double(delivered), hardCeiling)
    }

    func testBackwardsTimestampIsTreatedAsTheFastestPlausibleFrame() {
        let engine = PointerEngine(tracking: 0.5, motion: 1.0)
        engine.begin()
        _ = engine.consume(TouchSample(location: .zero, timestamp: 10))

        var delivered = engine.consume(TouchSample(location: CGPoint(x: 4, y: 0), timestamp: 9.5)).dx
        while let extra = engine.drain() { delivered += extra.dx }

        let tuning = PointerTuning.default
        let hardCeiling = 4.0 * tuning.maximumBaseGain * (1.0 + tuning.maximumMotionStrength)
        XCTAssertGreaterThan(delivered, 0)
        XCTAssertLessThanOrEqual(Double(delivered), hardCeiling)
    }

    func testFirstSampleOfAGestureProducesNoMovement() {
        let engine = PointerEngine(tracking: 1.0, motion: 1.0)
        engine.begin()
        let delta = engine.consume(TouchSample(location: CGPoint(x: 999, y: 999), timestamp: 42))
        XCTAssertEqual(delta.dx, 0)
        XCTAssertEqual(delta.dy, 0)
        XCTAssertNil(engine.drain())
    }
}

// MARK: - GestureState

final class GestureStateTests: XCTestCase {

    private func makeState() -> GestureState {
        GestureState(
            pointer: PointerEngine(tracking: 0.5, motion: 0),
            scroll: ScrollEngine(scrolling: 0.5, natural: false)
        )
    }

    private func containsButton(_ events: [GestureEvent]) -> Bool {
        events.contains {
            if case .button = $0 { return true }
            return false
        }
    }

    private func containsMove(_ events: [GestureEvent]) -> Bool {
        events.contains {
            if case .move = $0 { return true }
            return false
        }
    }

    // MARK: Taps

    func testSingleFingerTapIsALeftClick() {
        let state = makeState()
        let point = CGPoint(x: 100, y: 100)
        XCTAssertTrue(state.touchesBegan(count: 1, at: point, time: 0).isEmpty)
        let events = state.touchesEnded(count: 0, at: point, time: 0.08)
        XCTAssertEqual(events, [.button(.left, down: true), .button(.left, down: false)])
        XCTAssertEqual(state.phase, .idle)
    }

    func testTapWithATinyWobbleStillClicks() {
        let state = makeState()
        _ = state.touchesBegan(count: 1, at: CGPoint(x: 100, y: 100), time: 0)
        _ = state.touchesMoved(count: 1, at: CGPoint(x: 104, y: 103), time: 0.03)
        let events = state.touchesEnded(count: 0, at: CGPoint(x: 104, y: 103), time: 0.07)
        XCTAssertTrue(containsButton(events), "a 5 pt wobble is well inside the slop radius")
    }

    /// Near miss: the finger moved past the slop radius, so it was a drag and
    /// must not also fire a click.
    func testTapThatMovedPastSlopIsNotAClick() {
        let state = makeState()
        _ = state.touchesBegan(count: 1, at: CGPoint(x: 100, y: 100), time: 0)
        let moved = state.touchesMoved(count: 1, at: CGPoint(x: 140, y: 100), time: 0.05)
        let ended = state.touchesEnded(count: 0, at: CGPoint(x: 140, y: 100), time: 0.09)

        XCTAssertTrue(containsMove(moved))
        XCTAssertFalse(containsButton(moved))
        XCTAssertFalse(containsButton(ended))
    }

    /// Near miss: the finger stayed put but rested too long to be a tap.
    func testTapThatOutstayedTheWindowIsNotAClick() {
        let state = makeState()
        let point = CGPoint(x: 50, y: 50)
        _ = state.touchesBegan(count: 1, at: point, time: 0)
        let ended = state.touchesEnded(count: 0, at: point, time: 0.4)
        XCTAssertFalse(containsButton(ended))
    }

    // MARK: Pointer

    func testSingleFingerDragEmitsMoves() {
        let state = makeState()
        _ = state.touchesBegan(count: 1, at: CGPoint(x: 0, y: 0), time: 0)

        var totalDX = 0
        var totalDY = 0
        for i in 1...20 {
            let events = state.touchesMoved(
                count: 1,
                at: CGPoint(x: 5 * Double(i), y: -3 * Double(i)),
                time: Double(i) / 120.0
            )
            for event in events {
                if case .move(let dx, let dy) = event {
                    totalDX += dx
                    totalDY += dy
                }
            }
        }
        XCTAssertEqual(state.phase, .pointer)
        XCTAssertGreaterThan(totalDX, 0)
        XCTAssertLessThan(totalDY, 0)
    }

    // MARK: Two fingers

    /// Near miss: real fingers never land on the same millisecond. 40 ms of
    /// skew still has to read as one two-finger gesture.
    func testTwoTouchesLandingFortyMillisecondsApartAreOneTwoFingerTap() {
        let state = makeState()
        let point = CGPoint(x: 120, y: 200)
        _ = state.touchesBegan(count: 1, at: point, time: 0)
        _ = state.touchesBegan(count: 2, at: point, time: 0.04)
        XCTAssertEqual(state.phase, .twoFinger)

        let first = state.touchesEnded(count: 1, at: point, time: 0.1)
        XCTAssertEqual(first, [.button(.right, down: true), .button(.right, down: false)])

        let second = state.touchesEnded(count: 0, at: point, time: 0.12)
        XCTAssertTrue(second.isEmpty, "the trailing lift must not re-fire the click")
        XCTAssertEqual(state.phase, .idle)
    }

    func testTwoFingerDragScrolls() {
        let state = makeState()
        _ = state.touchesBegan(count: 2, at: CGPoint(x: 100, y: 300), time: 0)

        var wheel = 0
        var pan = 0
        for i in 1...20 {
            let events = state.touchesMoved(
                count: 2,
                at: CGPoint(x: 100, y: 300 - 8 * Double(i)),
                time: Double(i) / 60.0
            )
            for event in events {
                if case .scroll(let w, let p) = event {
                    wheel += w
                    pan += p
                }
            }
        }
        XCTAssertEqual(state.phase, .scrolling)
        // Fingers moved UP with natural scrolling off: the document scrolls up,
        // which is a positive wheel. See the banner in ScrollEngine.swift.
        XCTAssertGreaterThan(wheel, 0)
        XCTAssertEqual(pan, 0)

        let ended = state.touchesEnded(count: 0, at: CGPoint(x: 100, y: 140), time: 0.35)
        XCTAssertFalse(containsButton(ended), "a long scroll must not end in a right click")
    }

    /// A second finger arriving long after the pointer has committed to a drag
    /// must not hijack it into a scroll.
    func testLateSecondFingerDoesNotHijackACommittedPointerDrag() {
        let state = makeState()
        _ = state.touchesBegan(count: 1, at: CGPoint(x: 10, y: 10), time: 0)
        _ = state.touchesMoved(count: 1, at: CGPoint(x: 70, y: 10), time: 0.2)
        _ = state.touchesBegan(count: 2, at: CGPoint(x: 70, y: 10), time: 0.4)
        XCTAssertEqual(state.phase, .pointer)
    }

    // MARK: Long press

    func testLongPressHoldsAndReleasesTheLeftButton() {
        let state = makeState()
        let point = CGPoint(x: 200, y: 200)
        _ = state.touchesBegan(count: 1, at: point, time: 0)

        XCTAssertTrue(state.tick(now: 0.2).isEmpty, "fired before the long press window")
        XCTAssertEqual(state.tick(now: 0.55), [.button(.left, down: true)])
        XCTAssertEqual(state.phase, .dragging)
        XCTAssertTrue(state.tick(now: 0.9).isEmpty, "the long press fired twice")

        let moved = state.touchesMoved(count: 1, at: CGPoint(x: 240, y: 200), time: 1.0)
        XCTAssertTrue(containsMove(moved))
        XCTAssertFalse(containsButton(moved), "the button is already down")

        let ended = state.touchesEnded(count: 0, at: CGPoint(x: 240, y: 200), time: 1.1)
        guard let last = ended.last else { return XCTFail("expected a button release") }
        XCTAssertEqual(last, GestureEvent.button(.left, down: false))
    }

    func testMovingFingerNeverBecomesALongPress() {
        let state = makeState()
        _ = state.touchesBegan(count: 1, at: CGPoint(x: 0, y: 0), time: 0)
        _ = state.touchesMoved(count: 1, at: CGPoint(x: 80, y: 0), time: 0.1)
        XCTAssertTrue(state.tick(now: 0.7).isEmpty)
        XCTAssertEqual(state.phase, .pointer)
    }

    // MARK: Tap and a half

    func testTapAndAHalfDragsWithTheButtonHeld() {
        let state = makeState()
        let point = CGPoint(x: 150, y: 150)

        _ = state.touchesBegan(count: 1, at: point, time: 0)
        let tap = state.touchesEnded(count: 0, at: point, time: 0.06)
        XCTAssertEqual(tap, [.button(.left, down: true), .button(.left, down: false)])

        _ = state.touchesBegan(count: 1, at: point, time: 0.16)
        XCTAssertEqual(state.phase, .dragCandidate)

        let moved = state.touchesMoved(count: 1, at: CGPoint(x: 190, y: 150), time: 0.2)
        guard let first = moved.first else { return XCTFail("expected a button press") }
        XCTAssertEqual(first, GestureEvent.button(.left, down: true))
        XCTAssertEqual(state.phase, .dragging)
        XCTAssertTrue(containsMove(moved))

        let ended = state.touchesEnded(count: 0, at: CGPoint(x: 190, y: 150), time: 0.3)
        guard let last = ended.last else { return XCTFail("expected a button release") }
        XCTAssertEqual(last, GestureEvent.button(.left, down: false))
    }

    /// The same opening as a tap and a half, but the finger lifts in place:
    /// that is a double click, not a drag.
    func testTwoQuickTapsAreTwoClicksNotADrag() {
        let state = makeState()
        let point = CGPoint(x: 150, y: 150)

        _ = state.touchesBegan(count: 1, at: point, time: 0)
        _ = state.touchesEnded(count: 0, at: point, time: 0.06)

        _ = state.touchesBegan(count: 1, at: point, time: 0.16)
        let second = state.touchesEnded(count: 0, at: point, time: 0.2)
        XCTAssertEqual(second, [.button(.left, down: true), .button(.left, down: false)])
    }

    /// Near miss: the follow-on touch arrived too late, so it is an ordinary
    /// new gesture and must not press the button when it moves.
    func testTouchAfterTheTapAndAHalfWindowIsAPlainDrag() {
        let state = makeState()
        let point = CGPoint(x: 150, y: 150)

        _ = state.touchesBegan(count: 1, at: point, time: 0)
        _ = state.touchesEnded(count: 0, at: point, time: 0.06)

        _ = state.touchesBegan(count: 1, at: point, time: 0.6)
        XCTAssertEqual(state.phase, .pointer)
        let moved = state.touchesMoved(count: 1, at: CGPoint(x: 190, y: 150), time: 0.64)
        XCTAssertFalse(containsButton(moved))
    }

    // MARK: Three fingers

    func testThreeFingerSwipeUpFiresOnce() {
        let state = makeState()
        _ = state.touchesBegan(count: 3, at: CGPoint(x: 200, y: 400), time: 0)

        XCTAssertTrue(
            state.touchesMoved(count: 3, at: CGPoint(x: 200, y: 370), time: 0.05).isEmpty,
            "30 pt is below the swipe threshold"
        )
        XCTAssertEqual(state.touchesMoved(count: 3, at: CGPoint(x: 200, y: 320), time: 0.1), [.swipe(.up)])
        XCTAssertTrue(
            state.touchesMoved(count: 3, at: CGPoint(x: 200, y: 250), time: 0.15).isEmpty,
            "one swipe per gesture"
        )
        XCTAssertTrue(state.touchesEnded(count: 0, at: CGPoint(x: 200, y: 250), time: 0.2).isEmpty)
    }

    func testThreeFingerSwipeDirections() {
        let cases: [(CGPoint, GestureEvent.Direction)] = [
            (CGPoint(x: 200, y: 500), .down),
            (CGPoint(x: 300, y: 402), .right),
            (CGPoint(x: 100, y: 398), .left)
        ]
        for (destination, expected) in cases {
            let state = makeState()
            _ = state.touchesBegan(count: 3, at: CGPoint(x: 200, y: 400), time: 0)
            let events = state.touchesMoved(count: 3, at: destination, time: 0.1)
            XCTAssertEqual(events, [.swipe(expected)])
        }
    }

    func testThreeFingerTapEmitsNothing() {
        let state = makeState()
        let point = CGPoint(x: 200, y: 400)
        _ = state.touchesBegan(count: 3, at: point, time: 0)
        _ = state.touchesMoved(count: 3, at: CGPoint(x: 203, y: 402), time: 0.04)
        XCTAssertTrue(state.touchesEnded(count: 0, at: CGPoint(x: 203, y: 402), time: 0.08).isEmpty)
    }

    // MARK: Safety

    func testResetReleasesAHeldButton() {
        let state = makeState()
        _ = state.touchesBegan(count: 1, at: CGPoint(x: 10, y: 10), time: 0)
        XCTAssertEqual(state.tick(now: 0.6), [.button(.left, down: true)])

        let events = state.reset()
        XCTAssertEqual(events, [.button(.left, down: false)])
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.reset().isEmpty, "reset must be idempotent")
    }

    func testGestureEndsBalancedWhenTheButtonWasHeld() {
        let state = makeState()
        var downs = 0
        var ups = 0
        func tally(_ events: [GestureEvent]) {
            for event in events {
                if case .button(_, let down) = event {
                    if down { downs += 1 } else { ups += 1 }
                }
            }
        }

        tally(state.touchesBegan(count: 1, at: CGPoint(x: 10, y: 10), time: 0))
        tally(state.tick(now: 0.6))
        tally(state.touchesMoved(count: 1, at: CGPoint(x: 60, y: 10), time: 0.7))
        tally(state.touchesEnded(count: 0, at: CGPoint(x: 60, y: 10), time: 0.8))

        XCTAssertEqual(downs, 1)
        XCTAssertEqual(ups, 1)
    }

    func testApplyPushesSettingsIntoBothEngines() {
        let state = makeState()
        state.apply(tracking: 0.9, motion: 0.1, scrolling: 0.8, naturalScrolling: true)
        XCTAssertEqual(state.pointer.tracking, 0.9)
        XCTAssertEqual(state.pointer.motion, 0.1)
        XCTAssertEqual(state.scroll.scrolling, 0.8)
        XCTAssertTrue(state.scroll.natural)
    }
}
