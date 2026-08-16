//
//  PointerEngine.swift
//  PocketTrackpad
//
//  Touch samples in, integer HID mouse deltas out.
//
//  The whole "does this app feel like a real trackpad" question lives in this
//  file. Three things decide it:
//
//   1. The base gain curve (how far the pointer travels per point of finger
//      travel, as a function of the `tracking` slider).
//   2. The acceleration curve (how much extra a fast flick earns, as a
//      function of the `motion` slider).
//   3. Residue discipline. HID deltas are integers in -127...127. If we
//      truncate the fractional part of every frame, slow deliberate movement
//      loses a huge fraction of its travel (a 0.4 pt/frame drift delivers
//      literally nothing) and fast flicks lose everything past the clamp.
//      Both the fraction AND the overflow are carried forward here.
//

import Foundation
import CoreGraphics

// MARK: - Sample

/// One position report from the touch surface, in view points.
///
/// `location` is in UIKit view coordinates: x grows to the right, y grows
/// DOWNWARD. Every sign convention in this module is derived from that.
public struct TouchSample: Equatable, Sendable {
    public var location: CGPoint
    public var timestamp: TimeInterval

    public init(location: CGPoint, timestamp: TimeInterval) {
        self.location = location
        self.timestamp = timestamp
    }
}

// MARK: - Shared helpers

/// Clamp a slider value into 0...1, defaulting a non-finite value to the
/// midpoint rather than propagating NaN into the gain curve.
@inline(__always)
internal func clampUnitInterval(_ value: Double) -> Double {
    guard value.isFinite else { return 0.5 }
    if value < 0 { return 0 }
    if value > 1 { return 1 }
    return value
}

/// The sub-unit / overflow accumulator arithmetic shared by `PointerEngine`
/// and `ScrollEngine`.
///
/// Splitting an accumulator into "what fits in this report" and "what has to
/// wait for the next one" is the single most important behaviour in both
/// engines, so it lives in exactly one place.
internal enum ResidueQuantiser {
    /// Take as much whole travel out of `value` as one report can carry.
    ///
    /// - Returns: `whole`, the integer to put in the report (always within
    ///   `-limit ... limit`), and `remainder`, everything that did not fit —
    ///   both the fraction below 1 and any overflow above the limit. Feeding
    ///   `remainder` back in on the next call means no travel is ever lost,
    ///   only delayed.
    static func split(_ value: Double, limit: Double) -> (whole: Int, remainder: Double) {
        guard value.isFinite else { return (0, 0) }
        let truncated = value.rounded(.towardZero)
        let clamped = min(max(truncated, -limit), limit)
        return (Int(clamped), value - clamped)
    }
}

// MARK: - Tuning

/// Every magic number the pointer feel depends on, named and documented.
///
/// The defaults are the shipping feel. Each comment says what a user would
/// notice if you moved that number.
public struct PointerTuning: Sendable, Equatable {

    /// Floor on the time between samples, in seconds.
    ///
    /// UIKit can hand us two touches with an identical (or even a
    /// slightly-decreasing) timestamp. Dividing travel by that dt yields an
    /// infinite speed, which the acceleration curve turns into a pointer that
    /// teleports. Raising this floor makes duplicated frames feel *slower*;
    /// lowering it lets one bad frame spike the acceleration.
    public var minimumSampleInterval: TimeInterval

    /// Ceiling on the time between samples, in seconds.
    ///
    /// If the app is descheduled for 300 ms and then gets one huge delta, the
    /// honest speed is "very slow over a long time" — which would strip the
    /// acceleration off a genuine flick. Clamping dt here treats a stall as a
    /// ~15 Hz frame. Raising it makes post-stall movement feel sluggish.
    public var maximumSampleInterval: TimeInterval

    /// Pointer travel per point of finger travel when `tracking == 0`.
    /// Below ~0.5 the slowest setting becomes unusable on a 4K display.
    public var minimumBaseGain: Double

    /// Pointer travel per point of finger travel when `tracking == 1`.
    /// Above ~3.5 the fastest setting overshoots on every correction.
    public var maximumBaseGain: Double

    /// Shape of the slider→gain curve. The mapping is exponential
    /// (geometric interpolation between min and max), so equal slider steps
    /// feel like equal *ratio* steps, which is how speed is actually
    /// perceived — a linear map wastes the bottom third of the slider in a
    /// dead zone.
    ///
    /// 1.0 = pure exponential. Below 1 pushes gain up early, so the middle of
    /// the slider is livelier; above 1 gives more fine control in the slow
    /// half. At the default 0.9 the midpoint lands at ~1.44x, which is the
    /// comfortable "1:1-ish, slightly quick" default.
    public var baseGainSkew: Double

    /// Acceleration multiplier at infinite speed when `motion == 1`.
    /// The curve saturates, so this is a hard ceiling: the pointer can never
    /// travel more than `(1 + this)` times its base gain, no matter how hard
    /// the flick. Raising it makes flicks cross the screen faster and makes
    /// the pointer feel twitchier; `motion == 0` bypasses it entirely.
    public var maximumMotionStrength: Double

    /// Speed, in points per second, at which the acceleration curve reaches
    /// half of its maximum strength.
    ///
    /// This is the "knee". Lower values make acceleration kick in during
    /// ordinary movement (the pointer feels eager, but precision suffers);
    /// higher values reserve acceleration for deliberate flicks.
    public var accelerationKnee: Double

    /// Hard ceiling on the measured speed, in points per second. Purely
    /// defensive: keeps `speed / (speed + knee)` from evaluating inf/inf.
    public var speedCeiling: Double

    /// Largest magnitude a single HID mouse report can carry. The field is an
    /// Int8; we use a symmetric ±127 rather than -128...127 so that negative
    /// and positive flicks are delivered in the same number of reports.
    public var maximumReportDelta: Int

    public init(
        minimumSampleInterval: TimeInterval = 1.0 / 240.0,
        maximumSampleInterval: TimeInterval = 1.0 / 15.0,
        minimumBaseGain: Double = 0.6,
        maximumBaseGain: Double = 3.0,
        baseGainSkew: Double = 0.9,
        maximumMotionStrength: Double = 2.2,
        accelerationKnee: Double = 900.0,
        speedCeiling: Double = 20_000.0,
        maximumReportDelta: Int = 127
    ) {
        self.minimumSampleInterval = minimumSampleInterval
        self.maximumSampleInterval = maximumSampleInterval
        self.minimumBaseGain = minimumBaseGain
        self.maximumBaseGain = maximumBaseGain
        self.baseGainSkew = baseGainSkew
        self.maximumMotionStrength = maximumMotionStrength
        self.accelerationKnee = accelerationKnee
        self.speedCeiling = speedCeiling
        self.maximumReportDelta = maximumReportDelta
    }

    public static let `default` = PointerTuning()

    /// Slider position → pointer travel per point of finger travel.
    ///
    ///     gain(t) = gMin * (gMax / gMin) ^ (t ^ skew)
    ///
    /// With the defaults: 0.0 → 0.60, 0.25 → 0.94, 0.5 → 1.44, 0.75 → 2.14,
    /// 1.0 → 3.00. Strictly increasing in `t`, which is what the monotonicity
    /// test pins.
    public func baseGain(for tracking: Double) -> Double {
        let t = clampUnitInterval(tracking)
        let shaped = pow(t, baseGainSkew)
        return minimumBaseGain * pow(maximumBaseGain / minimumBaseGain, shaped)
    }

    /// Speed → extra gain multiplier.
    ///
    ///     accel(v) = 1 + (motion * maxStrength) * (v / (v + knee))
    ///
    /// Saturating by construction: the second term is always < 1, so the
    /// multiplier is bounded by `1 + motion * maxStrength` and the pointer can
    /// never run away. `motion == 0` returns exactly 1.0 — bit-for-bit linear,
    /// not "approximately linear".
    public func accelerationMultiplier(speed: Double, motion: Double) -> Double {
        let m = clampUnitInterval(motion)
        guard m > 0 else { return 1.0 }
        guard speed.isFinite else { return 1.0 + m * maximumMotionStrength }
        let v = min(max(speed, 0), speedCeiling)
        return 1.0 + (m * maximumMotionStrength) * (v / (v + accelerationKnee))
    }
}

// MARK: - Engine

/// Converts a stream of `TouchSample`s into integer mouse deltas suitable for
/// `MouseReport.dx` / `MouseReport.dy`.
///
/// Usage per gesture:
///
///     engine.begin()
///     let d = engine.consume(sample)          // send if non-zero
///     while let more = engine.drain() { ... }  // send the overflow too
///     engine.end()
///
/// `drain()` is not optional politeness — without it a fast flick is silently
/// truncated to 127 points.
public final class PointerEngine {

    /// Pointer gain slider, 0...1, straight from `AppSettings.tracking`.
    public var tracking: Double

    /// Acceleration slider, 0...1, straight from `AppSettings.motion`.
    /// Exactly 0 means "linear, no acceleration whatsoever".
    public var motion: Double

    /// The named constants. Swappable so tests (and a future "expert" panel)
    /// can poke at the feel without touching call sites.
    public var tuning: PointerTuning

    /// Undelivered horizontal travel, in pointer points. Holds both the
    /// sub-pixel fraction and any overflow beyond ±127.
    private var residueX: Double = 0
    private var residueY: Double = 0

    /// Previous sample of the current gesture; nil until the second sample.
    private var previous: TouchSample?

    public init(
        tracking: Double = 0.5,
        motion: Double = 0.5,
        tuning: PointerTuning = .default
    ) {
        self.tracking = tracking
        self.motion = motion
        self.tuning = tuning
    }

    /// True while `drain()` still has whole points to hand out.
    public var hasPendingTravel: Bool {
        abs(residueX) >= 1 || abs(residueY) >= 1
    }

    /// Undelivered travel, for tests and diagnostics.
    public var pendingTravel: (x: Double, y: Double) { (residueX, residueY) }

    /// Start a new gesture. Clears the residue so travel from the previous
    /// gesture cannot leak into this one as a phantom first movement.
    public func begin() {
        previous = nil
        residueX = 0
        residueY = 0
    }

    /// End the gesture. Deliberately does NOT clear the residue: the caller
    /// should keep pumping `drain()` after the finger lifts so the tail of a
    /// flick is actually delivered. `begin()` is what resets.
    public func end() {
        previous = nil
    }

    /// Feed one sample; get back the delta to put in the next report.
    ///
    /// The first sample of a gesture always returns `(0, 0)` — there is no
    /// previous position to measure against.
    public func consume(_ sample: TouchSample) -> (dx: Int, dy: Int) {
        guard let prev = previous else {
            previous = sample
            return emit()
        }
        previous = sample

        let rawX = Double(sample.location.x - prev.location.x)
        let rawY = Double(sample.location.y - prev.location.y)
        guard rawX.isFinite, rawY.isFinite else { return emit() }

        let dt = min(
            max(sample.timestamp - prev.timestamp, tuning.minimumSampleInterval),
            tuning.maximumSampleInterval
        )
        let distance = (rawX * rawX + rawY * rawY).squareRoot()
        let speed = distance / dt

        let gain = tuning.baseGain(for: tracking)
            * tuning.accelerationMultiplier(speed: speed, motion: motion)

        // Both axes share one gain, computed from the magnitude, so a diagonal
        // flick does not bend toward whichever axis happens to be larger.
        residueX += rawX * gain
        residueY += rawY * gain

        return emit()
    }

    /// Pump this until it returns nil after every `consume()` (and after
    /// `end()`), sending one `MouseReport` per non-nil result.
    ///
    /// Guaranteed to terminate: every non-nil result removes at least one whole
    /// point from the residue, and the residue is finite.
    public func drain() -> (dx: Int, dy: Int)? {
        let next = emit()
        if next.dx == 0 && next.dy == 0 { return nil }
        return next
    }

    // MARK: Private

    /// Take one report's worth out of the accumulators, leaving the rest.
    private func emit() -> (dx: Int, dy: Int) {
        let limit = Double(tuning.maximumReportDelta)
        let x = ResidueQuantiser.split(residueX, limit: limit)
        residueX = x.remainder
        let y = ResidueQuantiser.split(residueY, limit: limit)
        residueY = y.remainder
        return (dx: x.whole, dy: y.whole)
    }
}
