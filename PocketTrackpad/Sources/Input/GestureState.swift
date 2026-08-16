//
//  GestureState.swift
//  PocketTrackpad
//
//  The touch classifier, as a pure state machine.
//
//  There is deliberately no UIKit here — no UITouch, no UIGestureRecognizer,
//  no UIView. The view layer reduces its touches to (count, point, time) and
//  hands them over; everything else is arithmetic, which means every gesture
//  in the product can be unit-tested without a device or a run loop.
//
//  Coordinates are UIKit view points: x right-positive, y DOWN-positive.
//
//  Contract for `count`:
//    * `touchesBegan` / `touchesMoved`: the number of touches currently on the
//      surface, including the ones this call is reporting.
//    * `touchesEnded`: the number of touches STILL on the surface after this
//      lift. 0 means the gesture is completely over.
//
//  `point` is always the centroid of the active touches. For one finger that
//  is just the finger.
//

import Foundation
import CoreGraphics

// MARK: - Events

/// What the classifier decided happened. The transport layer maps these onto
/// `MouseReport`s; nothing here knows about HID.
public enum GestureEvent: Equatable, Sendable {

    /// Which way a three-finger swipe went, in screen terms.
    public enum Direction: String, Sendable, CaseIterable, Codable {
        case up, down, left, right
    }

    /// Pointer movement, already gained, accelerated and clamped to one
    /// report's worth by `PointerEngine`. Never emitted as `(0, 0)`.
    case move(dx: Int, dy: Int)

    /// Wheel / AC Pan detents from `ScrollEngine`. Never emitted as `(0, 0)`
    /// during a drag; momentum frames may legitimately be zero and are
    /// delivered through `momentumTick()` instead.
    case scroll(wheel: Int, pan: Int)

    /// A mouse button changed state. Always balanced: every `down: true` is
    /// followed by a `down: false` before the gesture ends.
    case button(MouseButtons, down: Bool)

    /// A semantic three-finger swipe — Mission Control / app switching. The
    /// UI layer turns this into whatever keystroke or consumer usage it wants
    /// (e.g. `ConsumerUsage.acDesktopShowAll` for `.up`).
    case swipe(Direction)
}

// MARK: - Tuning

/// Named thresholds for touch classification. These are the numbers that
/// decide whether the app feels responsive or trigger-happy.
public struct GestureTuning: Sendable, Equatable {

    /// Longest a finger may stay down and still count as a tap, in seconds.
    /// Too short and deliberate tappers get nothing; too long and the start of
    /// a slow drag registers a stray click.
    public var tapMaximumDuration: TimeInterval

    /// How far a finger may wander during a tap, in points. This is the "slop
    /// radius". Fingers are not styluses — a real tap moves 3-8 points. Too
    /// small and taps get eaten on a bumpy train; too large and the start of a
    /// deliberate drag fires a click.
    public var tapSlopRadius: Double

    /// Slop for a two-finger tap (right click). Larger than the one-finger
    /// value because the centroid of two fingers moves when they land or lift
    /// even a few milliseconds apart.
    public var twoFingerTapSlopRadius: Double

    /// How long one finger must stay put before it becomes a held left button
    /// (drag lock without the tap-and-a-half), in seconds.
    public var longPressDuration: TimeInterval

    /// Movement allowed while waiting for the long press, in points.
    public var longPressSlopRadius: Double

    /// Two touches landing within this window are one two-finger gesture, not
    /// a one-finger gesture that got interrupted. Real fingers never land on
    /// the same millisecond; 30-60 ms of skew is normal.
    public var multiTouchGroupingWindow: TimeInterval

    /// Maximum gap between a tap lifting and the next touch landing for that
    /// touch to be a "tap and a half" drag, in seconds.
    public var tapAndAHalfWindow: TimeInterval

    /// How close the follow-on touch must land to the original tap, in points,
    /// to count as a tap and a half rather than an unrelated new gesture.
    public var tapAndAHalfSlopRadius: Double

    /// Centroid travel that promotes a two-finger touch from "maybe a right
    /// click" to "definitely a scroll", in points.
    public var scrollSlopRadius: Double

    /// Three-finger travel required to fire a swipe, in points. Low values
    /// fire swipes on a three-finger tap wobble.
    public var swipeMinimumDistance: Double

    public init(
        tapMaximumDuration: TimeInterval = 0.25,
        tapSlopRadius: Double = 12.0,
        twoFingerTapSlopRadius: Double = 20.0,
        longPressDuration: TimeInterval = 0.5,
        longPressSlopRadius: Double = 12.0,
        multiTouchGroupingWindow: TimeInterval = 0.08,
        tapAndAHalfWindow: TimeInterval = 0.3,
        tapAndAHalfSlopRadius: Double = 40.0,
        scrollSlopRadius: Double = 6.0,
        swipeMinimumDistance: Double = 60.0
    ) {
        self.tapMaximumDuration = tapMaximumDuration
        self.tapSlopRadius = tapSlopRadius
        self.twoFingerTapSlopRadius = twoFingerTapSlopRadius
        self.longPressDuration = longPressDuration
        self.longPressSlopRadius = longPressSlopRadius
        self.multiTouchGroupingWindow = multiTouchGroupingWindow
        self.tapAndAHalfWindow = tapAndAHalfWindow
        self.tapAndAHalfSlopRadius = tapAndAHalfSlopRadius
        self.scrollSlopRadius = scrollSlopRadius
        self.swipeMinimumDistance = swipeMinimumDistance
    }

    public static let `default` = GestureTuning()
}

// MARK: - State machine

/// Classifies touches into `GestureEvent`s.
///
/// Owns a `PointerEngine` and a `ScrollEngine` because the events it emits
/// carry finished integer deltas; both are exposed so the settings screen can
/// push slider values straight through.
public final class GestureState {

    /// What the machine currently believes is happening.
    public enum Phase: Equatable, Sendable {
        /// Nothing on the surface.
        case idle
        /// One finger down; still could become a move, a tap or a long press.
        case pointer
        /// One finger down shortly after a tap: a second tap (double click) if
        /// it lifts in place, a drag if it moves.
        case dragCandidate
        /// Left button is held down and the finger is dragging.
        case dragging
        /// Two fingers down; still could become a right click or a scroll.
        case twoFinger
        /// Two fingers committed to scrolling.
        case scrolling
        /// Three fingers down; waiting for enough travel to call a swipe.
        case threeFinger
        /// The gesture has been classified and reported; ignore everything
        /// until the last finger comes off.
        case settling
    }

    public let pointer: PointerEngine
    public let scroll: ScrollEngine
    public var tuning: GestureTuning

    public private(set) var phase: Phase = .idle

    /// Where and when the current gesture started (after any promotion).
    private var startPoint: CGPoint = .zero
    private var startTime: TimeInterval = 0
    /// Greatest distance from `startPoint` seen so far, in points.
    private var maximumDisplacement: Double = 0

    /// True while a button emitted by this machine is still held.
    private var buttonIsDown: Bool = false
    /// One swipe per three-finger gesture.
    private var swipeFired: Bool = false
    /// Set once the long press has converted into a held button.
    private var longPressFired: Bool = false

    /// When and where the most recent single-finger tap lifted — the seed for
    /// tap-and-a-half detection.
    private var lastTapTime: TimeInterval?
    private var lastTapPoint: CGPoint?

    public init(
        pointer: PointerEngine = PointerEngine(),
        scroll: ScrollEngine = ScrollEngine(),
        tuning: GestureTuning = .default
    ) {
        self.pointer = pointer
        self.scroll = scroll
        self.tuning = tuning
    }

    /// Push the user's sliders into both engines. Mirrors `AppSettings`.
    public func apply(tracking: Double, motion: Double, scrolling: Double, naturalScrolling: Bool) {
        pointer.tracking = tracking
        pointer.motion = motion
        scroll.scrolling = scrolling
        scroll.natural = naturalScrolling
    }

    /// Drop everything: no phase, no held button, no tap history.
    ///
    /// - Returns: a button-up event if a button was still held, so the caller
    ///   can never be left with a stuck mouse button (e.g. on disconnect).
    @discardableResult
    public func reset() -> [GestureEvent] {
        var events: [GestureEvent] = []
        if buttonIsDown {
            events.append(.button(.left, down: false))
            buttonIsDown = false
        }
        phase = .idle
        maximumDisplacement = 0
        swipeFired = false
        longPressFired = false
        lastTapTime = nil
        lastTapPoint = nil
        pointer.end()
        scroll.end()
        scroll.stopMomentum()
        return events
    }

    // MARK: Touch input

    public func touchesBegan(count: Int, at point: CGPoint, time: TimeInterval) -> [GestureEvent] {
        guard count > 0 else { return [] }

        switch phase {
        case .idle:
            return startGesture(count: count, at: point, time: time)

        case .pointer, .dragCandidate:
            // A second finger landed. If the first one has not really
            // committed to pointer movement yet, this is a two-finger gesture
            // that simply did not land on one millisecond.
            guard shouldPromoteToMultiTouch(at: time) else { return [] }
            pointer.end()
            return startGesture(count: max(count, 2), at: point, time: time)

        case .twoFinger, .scrolling:
            // A third finger, arriving promptly, means a swipe.
            guard count >= 3, time - startTime <= tuning.multiTouchGroupingWindow else { return [] }
            scroll.end()
            scroll.stopMomentum()
            return startGesture(count: 3, at: point, time: time)

        case .dragging, .threeFinger, .settling:
            return []
        }
    }

    public func touchesMoved(count: Int, at point: CGPoint, time: TimeInterval) -> [GestureEvent] {
        // Long press is judged on where the finger was BEFORE this movement:
        // holding still for 600 ms and then dragging is a drag lock, not a
        // cancelled long press.
        var events: [GestureEvent] = []
        switch phase {
        case .pointer, .dragCandidate:
            events += fireLongPressIfDue(at: time)
        default:
            break
        }

        maximumDisplacement = max(maximumDisplacement, GestureState.distance(point, startPoint))

        switch phase {
        case .idle, .settling:
            return events

        case .pointer:
            events += pointerEvents(at: point, time: time)
            return events

        case .dragCandidate:
            if maximumDisplacement > tuning.tapSlopRadius {
                // Tap, then press-and-drag: hold the left button for the rest
                // of the gesture.
                phase = .dragging
                buttonIsDown = true
                lastTapTime = nil
                lastTapPoint = nil
                events.append(.button(.left, down: true))
            }
            events += pointerEvents(at: point, time: time)
            return events

        case .dragging:
            events += pointerEvents(at: point, time: time)
            return events

        case .twoFinger:
            if maximumDisplacement > tuning.scrollSlopRadius {
                phase = .scrolling
            }
            events += scrollEvents(at: point, time: time)
            return events

        case .scrolling:
            events += scrollEvents(at: point, time: time)
            return events

        case .threeFinger:
            guard !swipeFired, maximumDisplacement >= tuning.swipeMinimumDistance else { return events }
            swipeFired = true
            events.append(.swipe(GestureState.direction(from: startPoint, to: point)))
            return events
        }
    }

    public func touchesEnded(count: Int, at point: CGPoint, time: TimeInterval) -> [GestureEvent] {
        var events: [GestureEvent] = []
        let withinTapWindow = (time - startTime) <= tuning.tapMaximumDuration

        switch phase {
        case .idle:
            break

        case .settling:
            break

        case .pointer, .dragCandidate:
            events += pointerEvents(at: point, time: time)
            pointer.end()
            if withinTapWindow && maximumDisplacement <= tuning.tapSlopRadius {
                events.append(.button(.left, down: true))
                events.append(.button(.left, down: false))
                lastTapTime = time
                lastTapPoint = startPoint
            } else {
                lastTapTime = nil
                lastTapPoint = nil
            }

        case .dragging:
            events += pointerEvents(at: point, time: time)
            pointer.end()
            if buttonIsDown {
                events.append(.button(.left, down: false))
                buttonIsDown = false
            }
            lastTapTime = nil
            lastTapPoint = nil

        case .twoFinger, .scrolling:
            events += scrollEvents(at: point, time: time)
            scroll.end()
            if withinTapWindow && maximumDisplacement <= tuning.twoFingerTapSlopRadius {
                // Two-finger tap: a right click, and definitely not a coast.
                scroll.stopMomentum()
                events.append(.button(.right, down: true))
                events.append(.button(.right, down: false))
            }
            lastTapTime = nil
            lastTapPoint = nil

        case .threeFinger:
            lastTapTime = nil
            lastTapPoint = nil
        }

        // The first lift resolves the gesture; any remaining fingers are just
        // being taken off the glass.
        phase = count > 0 ? .settling : .idle
        if phase == .idle {
            maximumDisplacement = 0
            swipeFired = false
            longPressFired = false
        }
        return events
    }

    /// Drive time-based transitions. Call this from the same display link that
    /// pumps reports; without it a long press can only be detected on the next
    /// finger movement.
    public func tick(now: TimeInterval) -> [GestureEvent] {
        switch phase {
        case .pointer, .dragCandidate:
            return fireLongPressIfDue(at: now)
        default:
            return []
        }
    }

    /// One frame of scroll momentum, or nil when the coast is over.
    /// A `.scroll(wheel: 0, pan: 0)` result is a valid in-between frame — keep
    /// pumping until you get nil.
    public func momentumTick() -> GestureEvent? {
        guard let delta = scroll.momentumTick() else { return nil }
        return .scroll(wheel: delta.wheel, pan: delta.pan)
    }

    public var isMomentumActive: Bool { scroll.isMomentumActive }

    // MARK: Private

    private func startGesture(count: Int, at point: CGPoint, time: TimeInterval) -> [GestureEvent] {
        startPoint = point
        startTime = time
        maximumDisplacement = 0
        swipeFired = false
        longPressFired = false

        if count == 1 {
            phase = followsRecentTap(at: point, time: time) ? .dragCandidate : .pointer
            pointer.begin()
            _ = pointer.consume(TouchSample(location: point, timestamp: time))
        } else if count == 2 {
            phase = .twoFinger
            scroll.begin()
            _ = scroll.consume(TouchSample(location: point, timestamp: time))
        } else {
            phase = .threeFinger
        }
        return []
    }

    private func followsRecentTap(at point: CGPoint, time: TimeInterval) -> Bool {
        guard let tapTime = lastTapTime, let tapPoint = lastTapPoint else { return false }
        return (time - tapTime) <= tuning.tapAndAHalfWindow
            && GestureState.distance(point, tapPoint) <= tuning.tapAndAHalfSlopRadius
    }

    /// A late-arriving second finger still counts as a two-finger gesture if
    /// it lands inside the grouping window, or if the first finger has not yet
    /// moved beyond tap slop (someone resting one finger then adding another).
    private func shouldPromoteToMultiTouch(at time: TimeInterval) -> Bool {
        if buttonIsDown { return false }
        if time - startTime <= tuning.multiTouchGroupingWindow { return true }
        return maximumDisplacement <= tuning.tapSlopRadius
    }

    private func fireLongPressIfDue(at time: TimeInterval) -> [GestureEvent] {
        guard !longPressFired, !buttonIsDown else { return [] }
        guard (time - startTime) >= tuning.longPressDuration else { return [] }
        guard maximumDisplacement <= tuning.longPressSlopRadius else { return [] }
        longPressFired = true
        buttonIsDown = true
        phase = .dragging
        lastTapTime = nil
        lastTapPoint = nil
        return [.button(.left, down: true)]
    }

    /// Feed the pointer engine and collect every report it wants to send,
    /// including the overflow of a fast flick.
    private func pointerEvents(at point: CGPoint, time: TimeInterval) -> [GestureEvent] {
        var events: [GestureEvent] = []
        let delta = pointer.consume(TouchSample(location: point, timestamp: time))
        if delta.dx != 0 || delta.dy != 0 {
            events.append(.move(dx: delta.dx, dy: delta.dy))
        }
        while let extra = pointer.drain() {
            events.append(.move(dx: extra.dx, dy: extra.dy))
        }
        return events
    }

    private func scrollEvents(at point: CGPoint, time: TimeInterval) -> [GestureEvent] {
        var events: [GestureEvent] = []
        let delta = scroll.consume(TouchSample(location: point, timestamp: time))
        if delta.wheel != 0 || delta.pan != 0 {
            events.append(.scroll(wheel: delta.wheel, pan: delta.pan))
        }
        while let extra = scroll.drain() {
            events.append(.scroll(wheel: extra.wheel, pan: extra.pan))
        }
        return events
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Dominant axis wins. y is down-positive in view coordinates, so a
    /// negative dy is an upward swipe.
    private static func direction(from start: CGPoint, to end: CGPoint) -> GestureEvent.Direction {
        let dx = Double(end.x - start.x)
        let dy = Double(end.y - start.y)
        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .down : .up
    }
}
