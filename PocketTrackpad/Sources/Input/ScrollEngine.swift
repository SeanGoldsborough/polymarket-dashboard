//
//  ScrollEngine.swift
//  PocketTrackpad
//
//  Two-finger drag in, wheel/pan detents out.
//
//  ============================================================================
//  SIGN CONVENTION — read this before changing a single minus sign.
//  ============================================================================
//
//  Finger space (input): UIKit view coordinates. `dy > 0` means the fingers
//  moved DOWN the screen (toward the user). `dx > 0` means they moved RIGHT.
//
//  Wire space (output): HID Generic Desktop Wheel (usage 0x38) and Consumer AC
//  Pan (usage 0x0238).
//
//    * `wheel > 0` is a wheel rotation AWAY from the user. Every host maps
//      that to "scroll toward the START of the document" — i.e. the content
//      visibly moves DOWN the screen and you see earlier content.
//    * `wheel < 0` scrolls toward the END of the document; content moves UP.
//    * `pan > 0` scrolls the viewport RIGHT (content moves left).
//
//  Therefore:
//
//    natural == false  (macOS default, "Natural scrolling" unchecked):
//        content moves OPPOSITE the finger, like dragging a scrollbar.
//        Fingers down (dy > 0)  ->  wheel < 0  ->  document scrolls down.
//        wheel = -dy / pointsPerDetent
//
//    natural == true   (macOS "Natural scrolling" checked):
//        content moves WITH the finger, like dragging a sheet of paper.
//        Fingers down (dy > 0)  ->  wheel > 0  ->  content moves down.
//        wheel = +dy / pointsPerDetent
//
//  So `natural` flips exactly one thing: the sign of the vertical wheel.
//  Horizontal pan is NOT flipped by this switch (macOS applies its own
//  horizontal inversion host-side; inverting here too would double-negate and
//  produce the classic "horizontal scrolling is backwards" bug report).
//
//  `testNaturalScrollingFlipsVerticalSignOnly` and
//  `testClassicDirectionMatchesMacOSDefault` in ScrollEngineTests pin all of
//  the above. If you flip a sign here, those tests must fail.
//  ============================================================================
//

import Foundation
import CoreGraphics

// MARK: - Tuning

/// Every magic number the scroll feel depends on, named and documented.
public struct ScrollTuning: Sendable, Equatable {

    /// Points of finger travel per wheel detent when `scrolling == 0`.
    /// Large number = you drag a long way for one click of the wheel = slow,
    /// precise scrolling.
    public var coarsePointsPerDetent: Double

    /// Points of finger travel per wheel detent when `scrolling == 1`.
    /// Below ~4 a single frame of movement emits several detents and long
    /// documents become impossible to land on.
    public var finePointsPerDetent: Double

    /// Shape of the slider→detent-size curve. Same geometric interpolation as
    /// the pointer gain: equal slider steps are equal ratio steps. 1.0 is pure
    /// exponential; above 1 gives more of the slider to the slow end.
    public var detentSkew: Double

    /// dt floor / ceiling, in seconds. Same rationale as `PointerTuning`:
    /// a duplicated timestamp must not produce an infinite release velocity
    /// and launch a runaway momentum ride.
    public var minimumSampleInterval: TimeInterval
    public var maximumSampleInterval: TimeInterval

    /// Weight of the newest sample in the release-velocity estimate, 0...1.
    /// Low values ignore the last-instant flick (momentum feels detached from
    /// the gesture); high values let one noisy final frame decide the throw.
    public var velocitySmoothing: Double

    /// Release speed, in points per second, below which lifting the fingers
    /// simply stops. Raise it and gentle drags stop dead; lower it and every
    /// release coasts, which feels mushy.
    public var momentumLaunchSpeed: Double

    /// Speed, in points per second, at which a momentum ride is considered
    /// finished and `momentumTick()` starts returning nil. This is what
    /// guarantees termination together with the decay constant.
    public var momentumStopSpeed: Double

    /// Exponential decay time constant, in seconds: velocity falls to 1/e of
    /// its value every `momentumDecayTime`. Larger = longer, glidier coast.
    /// The whole ride lasts roughly `tau * ln(launchSpeed / stopSpeed)`.
    public var momentumDecayTime: TimeInterval

    /// Simulated time advanced by one `momentumTick()`. Pump this from a
    /// display link at the matching rate.
    public var momentumTickInterval: TimeInterval

    /// Absolute cap on momentum ticks. The exponential decay already
    /// terminates; this is a belt-and-braces guarantee that a NaN or an absurd
    /// velocity can never hang the report pump.
    public var momentumMaximumTicks: Int

    /// Ceiling on the launch velocity, in points per second, so that one
    /// pathological frame cannot buy a ten-second coast.
    public var momentumSpeedCeiling: Double

    /// Largest magnitude a single report's wheel/pan byte can carry.
    public var maximumReportDelta: Int

    public init(
        coarsePointsPerDetent: Double = 28.0,
        finePointsPerDetent: Double = 6.0,
        detentSkew: Double = 1.0,
        minimumSampleInterval: TimeInterval = 1.0 / 240.0,
        maximumSampleInterval: TimeInterval = 1.0 / 15.0,
        velocitySmoothing: Double = 0.35,
        momentumLaunchSpeed: Double = 220.0,
        momentumStopSpeed: Double = 12.0,
        momentumDecayTime: TimeInterval = 0.325,
        momentumTickInterval: TimeInterval = 1.0 / 60.0,
        momentumMaximumTicks: Int = 300,
        momentumSpeedCeiling: Double = 6000.0,
        maximumReportDelta: Int = 127
    ) {
        self.coarsePointsPerDetent = coarsePointsPerDetent
        self.finePointsPerDetent = finePointsPerDetent
        self.detentSkew = detentSkew
        self.minimumSampleInterval = minimumSampleInterval
        self.maximumSampleInterval = maximumSampleInterval
        self.velocitySmoothing = velocitySmoothing
        self.momentumLaunchSpeed = momentumLaunchSpeed
        self.momentumStopSpeed = momentumStopSpeed
        self.momentumDecayTime = momentumDecayTime
        self.momentumTickInterval = momentumTickInterval
        self.momentumMaximumTicks = momentumMaximumTicks
        self.momentumSpeedCeiling = momentumSpeedCeiling
        self.maximumReportDelta = maximumReportDelta
    }

    public static let `default` = ScrollTuning()

    /// Slider position → points of finger travel per emitted detent.
    ///
    ///     pointsPerDetent(s) = coarse * (fine / coarse) ^ (s ^ skew)
    ///
    /// With the defaults: 0.0 → 28.0, 0.5 → 12.96, 1.0 → 6.0. Strictly
    /// DEcreasing in `s`, so a higher slider always scrolls further.
    public func pointsPerDetent(for scrolling: Double) -> Double {
        let s = clampUnitInterval(scrolling)
        let shaped = pow(s, detentSkew)
        let value = coarsePointsPerDetent * pow(finePointsPerDetent / coarsePointsPerDetent, shaped)
        // Never allow a zero or negative divisor, whatever someone puts in the
        // tuning struct.
        return max(value, 0.5)
    }
}

// MARK: - Engine

/// Converts a two-finger drag (fed as the centroid of the two touches) into
/// `MouseReport.wheel` / `MouseReport.pan` detents, with momentum.
///
/// Usage per gesture:
///
///     engine.begin()
///     let d = engine.consume(centroidSample)   // send if non-zero
///     while let more = engine.drain() { ... }
///     engine.end()
///     while let m = engine.momentumTick() { ... }   // one call per frame
public final class ScrollEngine {

    /// Scroll gain slider, 0...1, straight from `AppSettings.scrolling`.
    public var scrolling: Double

    /// `AppSettings.naturalScrolling`. See the sign-convention banner at the
    /// top of this file: true = content follows the finger.
    public var natural: Bool

    public var tuning: ScrollTuning

    /// Undelivered travel, in DETENTS (not points), already sign-converted to
    /// wire space. Holds both the fraction below one detent and any overflow
    /// beyond ±127.
    private var wheelResidue: Double = 0
    private var panResidue: Double = 0

    private var previous: TouchSample?

    /// Smoothed finger velocity in points per second, in FINGER space
    /// (y down-positive). Sign conversion happens at emit time.
    private var velocityX: Double = 0
    private var velocityY: Double = 0

    /// Live momentum velocity, finger space, points per second.
    private var momentumVX: Double = 0
    private var momentumVY: Double = 0
    private var momentumTicksElapsed: Int = 0
    private var momentumRunning: Bool = false

    public init(
        scrolling: Double = 0.5,
        natural: Bool = false,
        tuning: ScrollTuning = .default
    ) {
        self.scrolling = scrolling
        self.natural = natural
        self.tuning = tuning
    }

    /// True while `momentumTick()` will still return a value.
    public var isMomentumActive: Bool { momentumRunning }

    /// Smoothed release velocity in points per second, for tests/diagnostics.
    public var fingerVelocity: (x: Double, y: Double) { (velocityX, velocityY) }

    /// Start a new scroll gesture. Clears residue, velocity and any momentum
    /// still running from the previous gesture (putting a finger down must
    /// stop the coast — this is the "catch the page" behaviour users expect).
    public func begin() {
        previous = nil
        wheelResidue = 0
        panResidue = 0
        velocityX = 0
        velocityY = 0
        stopMomentum()
    }

    /// Feed one sample — the centroid of the two touches.
    ///
    /// The first sample of a gesture always returns `(0, 0)`.
    public func consume(_ sample: TouchSample) -> (wheel: Int, pan: Int) {
        guard let prev = previous else {
            previous = sample
            return emit()
        }
        previous = sample

        let dx = Double(sample.location.x - prev.location.x)
        let dy = Double(sample.location.y - prev.location.y)
        guard dx.isFinite, dy.isFinite else { return emit() }

        let dt = min(
            max(sample.timestamp - prev.timestamp, tuning.minimumSampleInterval),
            tuning.maximumSampleInterval
        )

        let smoothing = clampUnitInterval(tuning.velocitySmoothing)
        velocityX += ((dx / dt) - velocityX) * smoothing
        velocityY += ((dy / dt) - velocityY) * smoothing

        accumulate(fingerDX: dx, fingerDY: dy)
        return emit()
    }

    /// End the gesture and, if the fingers were still moving, arm momentum.
    ///
    /// Residue is intentionally preserved so momentum continues from exactly
    /// where the finger left off instead of dropping a partial detent.
    public func end() {
        previous = nil

        let speed = (velocityX * velocityX + velocityY * velocityY).squareRoot()
        guard speed.isFinite, speed >= tuning.momentumLaunchSpeed else {
            stopMomentum()
            return
        }
        // Scale (never amplify) the launch velocity down to the ceiling.
        let scale = speed > tuning.momentumSpeedCeiling ? tuning.momentumSpeedCeiling / speed : 1.0
        momentumVX = velocityX * scale
        momentumVY = velocityY * scale
        momentumTicksElapsed = 0
        momentumRunning = true
    }

    /// Pump after `consume()` / `end()` until it returns nil, sending one
    /// report per non-nil result. This is what delivers overflow past ±127.
    public func drain() -> (wheel: Int, pan: Int)? {
        let next = emit()
        if next.wheel == 0 && next.pan == 0 { return nil }
        return next
    }

    /// Advance the momentum simulation by exactly one frame
    /// (`tuning.momentumTickInterval`).
    ///
    /// - Returns: the deltas for this frame, or nil once the ride is over.
    ///   A returned `(0, 0)` is legitimate — that frame's travel did not add
    ///   up to a whole detent yet — so keep pumping until you get nil. nil is
    ///   the only terminator.
    ///
    /// Termination is guaranteed twice over: velocity is multiplied by
    /// `exp(-dt / tau) < 1` every tick so it must fall below
    /// `momentumStopSpeed` in a finite number of steps, and
    /// `momentumMaximumTicks` caps it regardless.
    public func momentumTick() -> (wheel: Int, pan: Int)? {
        guard momentumRunning else { return nil }

        momentumTicksElapsed += 1
        if momentumTicksElapsed > tuning.momentumMaximumTicks {
            stopMomentum()
            return nil
        }

        let dt = tuning.momentumTickInterval
        accumulate(fingerDX: momentumVX * dt, fingerDY: momentumVY * dt)

        let decay = exp(-dt / tuning.momentumDecayTime)
        momentumVX *= decay
        momentumVY *= decay

        let output = emit()

        let speed = (momentumVX * momentumVX + momentumVY * momentumVY).squareRoot()
        if !speed.isFinite || speed < tuning.momentumStopSpeed {
            stopMomentum()
        }
        return output
    }

    /// Cancel a coast in progress (a new touch, a disconnect, a settings
    /// change). Safe to call at any time.
    public func stopMomentum() {
        momentumRunning = false
        momentumVX = 0
        momentumVY = 0
        momentumTicksElapsed = 0
    }

    // MARK: Private

    /// Convert finger-space travel into wire-space detents and bank it.
    ///
    /// This is the ONLY place the sign convention is applied — see the banner
    /// at the top of the file.
    private func accumulate(fingerDX: Double, fingerDY: Double) {
        let divisor = tuning.pointsPerDetent(for: scrolling)
        // natural == true: content follows the finger, so fingers moving down
        // (dy > 0) must scroll toward the start of the document (wheel > 0).
        // natural == false: the macOS default, exactly inverted.
        let verticalDirection: Double = natural ? 1.0 : -1.0
        wheelResidue += verticalDirection * fingerDY / divisor
        // Horizontal is never flipped by `natural`. Fingers moving right pan
        // the viewport right.
        panResidue += fingerDX / divisor
    }

    private func emit() -> (wheel: Int, pan: Int) {
        let limit = Double(tuning.maximumReportDelta)
        let w = ResidueQuantiser.split(wheelResidue, limit: limit)
        wheelResidue = w.remainder
        let p = ResidueQuantiser.split(panResidue, limit: limit)
        panResidue = p.remainder
        return (wheel: w.whole, pan: p.whole)
    }
}
