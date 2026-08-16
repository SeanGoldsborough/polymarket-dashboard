//
//  ScrollEngineTests.swift
//  PocketTrackpadTests
//
//  Deterministic tests for `ScrollEngine`: residue conservation, the
//  natural-scrolling sign convention (the bug that ships if nobody pins it),
//  and momentum that provably terminates.
//

import XCTest
import CoreGraphics
@testable import PocketTrackpad

// MARK: - Helpers

/// A straight two-finger drag, `count` steps of `(stepX, stepY)` points, one
/// sample every `interval` seconds, preceded by the touch-down sample.
private func drag(
    stepX: Double,
    stepY: Double,
    count: Int,
    interval: TimeInterval,
    origin: CGPoint = CGPoint(x: 200, y: 400)
) -> [TouchSample] {
    precondition(count >= 1)
    var samples: [TouchSample] = [TouchSample(location: origin, timestamp: 0)]
    for i in 1...count {
        samples.append(
            TouchSample(
                location: CGPoint(
                    x: Double(origin.x) + stepX * Double(i),
                    y: Double(origin.y) + stepY * Double(i)
                ),
                timestamp: interval * Double(i)
            )
        )
    }
    return samples
}

private func collect(_ engine: ScrollEngine, _ samples: [TouchSample]) -> [(wheel: Int, pan: Int)] {
    var reports: [(wheel: Int, pan: Int)] = []
    for sample in samples {
        let delta = engine.consume(sample)
        if delta.wheel != 0 || delta.pan != 0 { reports.append(delta) }
        while let extra = engine.drain() { reports.append(extra) }
    }
    return reports
}

private func totalWheel(_ reports: [(wheel: Int, pan: Int)]) -> Int {
    reports.reduce(0) { $0 + $1.wheel }
}

private func totalPan(_ reports: [(wheel: Int, pan: Int)]) -> Int {
    reports.reduce(0) { $0 + $1.pan }
}

// MARK: - Tests

final class ScrollEngineTests: XCTestCase {

    // MARK: Direction — the part everybody gets backwards

    /// `natural == false` is the macOS default ("Natural scrolling" unchecked).
    ///
    /// Fingers moving DOWN the screen must scroll the document DOWN, i.e. the
    /// content moves UP, i.e. a NEGATIVE wheel value. Fingers moving UP must
    /// produce a POSITIVE wheel value.
    func testClassicDirectionMatchesMacOSDefault() {
        let downwards = ScrollEngine(scrolling: 0.5, natural: false)
        downwards.begin()
        let downwardsTotal = totalWheel(collect(downwards, drag(stepX: 0, stepY: 100, count: 1, interval: 0.1)))
        XCTAssertLessThan(downwardsTotal, 0, "fingers down with natural OFF must give a negative wheel")

        let upwards = ScrollEngine(scrolling: 0.5, natural: false)
        upwards.begin()
        let upwardsTotal = totalWheel(collect(upwards, drag(stepX: 0, stepY: -100, count: 1, interval: 0.1)))
        XCTAssertGreaterThan(upwardsTotal, 0, "fingers up with natural OFF must give a positive wheel")
    }

    /// `natural == true` is macOS "Natural scrolling" checked: the content
    /// follows the finger. Fingers moving DOWN must move the content DOWN,
    /// which is a scroll toward the start of the document — a POSITIVE wheel.
    func testNaturalDirectionMovesContentWithTheFinger() {
        let engine = ScrollEngine(scrolling: 0.5, natural: true)
        engine.begin()
        let total = totalWheel(collect(engine, drag(stepX: 0, stepY: 100, count: 1, interval: 0.1)))
        XCTAssertGreaterThan(total, 0, "fingers down with natural ON must give a positive wheel")
    }

    /// The switch flips the vertical wheel and NOTHING else. Horizontal pan is
    /// identical in both modes.
    func testNaturalScrollingFlipsVerticalSignOnly() {
        let samples = drag(stepX: 60, stepY: 100, count: 1, interval: 0.1)

        let classic = ScrollEngine(scrolling: 0.5, natural: false)
        classic.begin()
        let classicReports = collect(classic, samples)

        let natural = ScrollEngine(scrolling: 0.5, natural: true)
        natural.begin()
        let naturalReports = collect(natural, samples)

        let classicWheel = totalWheel(classicReports)
        let naturalWheel = totalWheel(naturalReports)
        let classicPan = totalPan(classicReports)
        let naturalPan = totalPan(naturalReports)

        XCTAssertNotEqual(classicWheel, 0)
        XCTAssertEqual(naturalWheel, -classicWheel, "natural scrolling must mirror the vertical wheel")
        XCTAssertEqual(naturalPan, classicPan, "natural scrolling must NOT touch the horizontal axis")
        XCTAssertGreaterThan(classicPan, 0, "fingers moving right must pan the viewport right")
    }

    /// Same guarantee over a long drag rather than a single sample, so it also
    /// covers the residue path.
    func testNaturalScrollingFlipsVerticalSignOverAWholeGesture() {
        let samples = drag(stepX: 3, stepY: 5, count: 40, interval: 1.0 / 60.0)

        let classic = ScrollEngine(scrolling: 0.7, natural: false)
        classic.begin()
        let classicReports = collect(classic, samples)

        let natural = ScrollEngine(scrolling: 0.7, natural: true)
        natural.begin()
        let naturalReports = collect(natural, samples)

        XCTAssertEqual(totalWheel(naturalReports), -totalWheel(classicReports))
        XCTAssertEqual(totalPan(naturalReports), totalPan(classicReports))
    }

    // MARK: Residue

    /// 200 frames of half a point each is 100 points of travel — several
    /// detents. Truncating per frame would deliver nothing at all.
    func testScrollResidueIsConserved() {
        let scrolling = 0.5
        let engine = ScrollEngine(scrolling: scrolling, natural: false)
        engine.begin()

        let samples = drag(stepX: 0, stepY: -0.5, count: 200, interval: 1.0 / 120.0)
        let delivered = totalWheel(collect(engine, samples))

        let ideal = 100.0 / ScrollTuning.default.pointsPerDetent(for: scrolling)
        XCTAssertGreaterThan(delivered, 0)
        XCTAssertEqual(Double(delivered), ideal, accuracy: 1.0)
    }

    func testPanResidueIsConserved() {
        let scrolling = 0.5
        let engine = ScrollEngine(scrolling: scrolling, natural: false)
        engine.begin()

        let samples = drag(stepX: 0.5, stepY: 0, count: 200, interval: 1.0 / 120.0)
        let delivered = totalPan(collect(engine, samples))

        let ideal = 100.0 / ScrollTuning.default.pointsPerDetent(for: scrolling)
        XCTAssertGreaterThan(delivered, 0)
        XCTAssertEqual(Double(delivered), ideal, accuracy: 1.0)
    }

    func testBeginClearsResidue() {
        let engine = ScrollEngine(scrolling: 1.0, natural: false)
        engine.begin()
        _ = engine.consume(TouchSample(location: CGPoint(x: 0, y: 0), timestamp: 0))
        _ = engine.consume(TouchSample(location: CGPoint(x: 0, y: -5_000), timestamp: 0.1))
        XCTAssertNotNil(engine.drain(), "a 5000 pt flick must leave overflow banked")

        engine.begin()
        XCTAssertNil(engine.drain(), "residue leaked from the previous gesture")
    }

    /// A flick that exceeds one report's ±127 must be delivered in full across
    /// consecutive reports.
    func testScrollOverflowIsCarriedAcrossReports() {
        let scrolling = 1.0
        let engine = ScrollEngine(scrolling: scrolling, natural: false)
        engine.begin()

        let reports = collect(engine, drag(stepX: 0, stepY: -5000, count: 1, interval: 1.0 / 60.0))
        XCTAssertGreaterThan(reports.count, 1)
        for report in reports {
            XCTAssertLessThanOrEqual(abs(report.wheel), 127)
            XCTAssertLessThanOrEqual(abs(report.pan), 127)
        }

        let ideal = 5000.0 / ScrollTuning.default.pointsPerDetent(for: scrolling)
        XCTAssertEqual(Double(totalWheel(reports)), ideal, accuracy: 1.0)
    }

    func testDrainTerminates() {
        let engine = ScrollEngine(scrolling: 1.0, natural: false)
        engine.begin()
        _ = engine.consume(TouchSample(location: .zero, timestamp: 0))
        _ = engine.consume(TouchSample(location: CGPoint(x: 9_000, y: -9_000), timestamp: 1.0 / 60.0))

        var pumps = 0
        while engine.drain() != nil {
            pumps += 1
            if pumps > 10_000 { break }
        }
        XCTAssertLessThan(pumps, 10_000, "drain() never returned nil")
    }

    // MARK: Gain

    func testHigherScrollingSliderNeverScrollsLess() {
        let samples = drag(stepX: 0, stepY: -240, count: 1, interval: 0.2)
        var previous = Int.min
        for stepIndex in 0...20 {
            let scrolling = Double(stepIndex) / 20.0
            let engine = ScrollEngine(scrolling: scrolling, natural: false)
            engine.begin()
            let delivered = totalWheel(collect(engine, samples))
            XCTAssertGreaterThanOrEqual(
                delivered, previous,
                "scrolling \(scrolling) delivered fewer detents than the setting below it"
            )
            previous = delivered
        }
    }

    func testDetentCurveIsStrictlyDecreasingAndInRange() {
        let tuning = ScrollTuning.default
        XCTAssertEqual(tuning.pointsPerDetent(for: 0), tuning.coarsePointsPerDetent, accuracy: 1e-9)
        XCTAssertEqual(tuning.pointsPerDetent(for: 1), tuning.finePointsPerDetent, accuracy: 1e-9)

        var previous = Double.infinity
        for stepIndex in 0...100 {
            let value = tuning.pointsPerDetent(for: Double(stepIndex) / 100.0)
            XCTAssertLessThan(value, previous)
            XCTAssertGreaterThan(value, 0)
            previous = value
        }
    }

    // MARK: Degenerate input

    func testDuplicateTimestampDoesNotProduceInfiniteVelocity() {
        let engine = ScrollEngine(scrolling: 0.5, natural: false)
        engine.begin()
        _ = engine.consume(TouchSample(location: CGPoint(x: 0, y: 0), timestamp: 3))
        _ = engine.consume(TouchSample(location: CGPoint(x: 0, y: -10), timestamp: 3))

        let velocity = engine.fingerVelocity
        XCTAssertTrue(velocity.y.isFinite)
        XCTAssertTrue(velocity.x.isFinite)
        engine.end()
        // Whatever it decided, momentum must still be bounded.
        var ticks = 0
        while engine.momentumTick() != nil {
            ticks += 1
            if ticks > 1_000 { break }
        }
        XCTAssertLessThanOrEqual(ticks, ScrollTuning.default.momentumMaximumTicks)
    }

    func testFirstSampleOfAGestureProducesNothing() {
        let engine = ScrollEngine(scrolling: 1.0, natural: false)
        engine.begin()
        let delta = engine.consume(TouchSample(location: CGPoint(x: 900, y: 900), timestamp: 7))
        XCTAssertEqual(delta.wheel, 0)
        XCTAssertEqual(delta.pan, 0)
    }

    // MARK: Momentum

    /// The load-bearing property: momentum must stop. An infinite ride would
    /// hang the report pump forever.
    func testMomentumTerminatesInBoundedSteps() {
        let engine = ScrollEngine(scrolling: 0.5, natural: false)
        engine.begin()
        _ = collect(engine, drag(stepX: 0, stepY: -20, count: 12, interval: 1.0 / 60.0))
        engine.end()

        XCTAssertTrue(engine.isMomentumActive, "a 1200 pt/s flick must coast")

        var ticks = 0
        var wheelTotal = 0
        var runaway = false
        while let delta = engine.momentumTick() {
            ticks += 1
            wheelTotal += delta.wheel
            XCTAssertLessThanOrEqual(abs(delta.wheel), 127)
            XCTAssertLessThanOrEqual(abs(delta.pan), 127)
            if ticks > 1_000 { runaway = true; break }
        }

        XCTAssertFalse(runaway, "momentum never returned nil")
        XCTAssertGreaterThan(ticks, 0)
        XCTAssertLessThanOrEqual(ticks, ScrollTuning.default.momentumMaximumTicks)
        XCTAssertFalse(engine.isMomentumActive)
        XCTAssertNil(engine.momentumTick(), "a finished ride must stay finished")
        // Fingers flicked up, natural off: the coast continues upward.
        XCTAssertGreaterThan(wheelTotal, 0)
    }

    func testMomentumDecays() {
        let engine = ScrollEngine(scrolling: 0.5, natural: false)
        engine.begin()
        _ = collect(engine, drag(stepX: 0, stepY: -20, count: 12, interval: 1.0 / 60.0))
        engine.end()

        var wheels: [Int] = []
        var guardCounter = 0
        while let delta = engine.momentumTick() {
            wheels.append(delta.wheel)
            guardCounter += 1
            if guardCounter > 1_000 { break }
        }

        XCTAssertGreaterThan(wheels.count, 20, "expected a ride long enough to measure decay")
        let opening = wheels.prefix(10).reduce(0, +)
        let closing = wheels.suffix(10).reduce(0, +)
        XCTAssertGreaterThan(opening, closing, "momentum did not slow down")
    }

    func testSlowReleaseDoesNotStartMomentum() {
        let engine = ScrollEngine(scrolling: 0.5, natural: false)
        engine.begin()
        // 1 pt per frame at 60 Hz is 60 pt/s, far under the launch threshold.
        _ = collect(engine, drag(stepX: 0, stepY: -1, count: 20, interval: 1.0 / 60.0))
        engine.end()

        XCTAssertFalse(engine.isMomentumActive)
        XCTAssertNil(engine.momentumTick())
    }

    func testTouchingDownCancelsMomentum() {
        let engine = ScrollEngine(scrolling: 0.5, natural: false)
        engine.begin()
        _ = collect(engine, drag(stepX: 0, stepY: -20, count: 12, interval: 1.0 / 60.0))
        engine.end()
        XCTAssertTrue(engine.isMomentumActive)

        _ = engine.momentumTick()
        engine.begin()

        XCTAssertFalse(engine.isMomentumActive, "putting fingers down must catch the page")
        XCTAssertNil(engine.momentumTick())
    }

    func testMomentumRespectsTheNaturalScrollingSign() {
        func ride(natural: Bool) -> Int {
            let engine = ScrollEngine(scrolling: 0.5, natural: natural)
            engine.begin()
            _ = collect(engine, drag(stepX: 0, stepY: -20, count: 12, interval: 1.0 / 60.0))
            engine.end()
            var total = 0
            var ticks = 0
            while let delta = engine.momentumTick() {
                total += delta.wheel
                ticks += 1
                if ticks > 1_000 { break }
            }
            return total
        }

        let classic = ride(natural: false)
        let natural = ride(natural: true)
        XCTAssertGreaterThan(classic, 0)
        XCTAssertLessThan(natural, 0)
    }
}
