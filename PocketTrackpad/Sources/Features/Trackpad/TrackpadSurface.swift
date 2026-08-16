//
//  TrackpadSurface.swift
//  PocketTrackpad
//
//  The raw touch capture surface that sits under the trackpad screen.
//
//  WHY A UIViewRepresentable AND NOT SwiftUI's DragGesture
//  ------------------------------------------------------
//  SwiftUI's `DragGesture` is the wrong tool for a pointing device:
//
//   1. It coalesces and smooths. SwiftUI hands you one filtered `translation`
//      per body pass; the intermediate samples that make velocity estimation
//      honest are gone before we ever see them.
//   2. It adds latency. The gesture has to win against (or lose to) the
//      surrounding scroll/navigation gestures before the first value arrives,
//      which shows up as a dead zone at the start of every flick.
//   3. It hides multi-touch. `DragGesture` is single-touch by construction, so
//      a two-finger scroll and a one-finger move are indistinguishable — and
//      this app needs one, two and three-finger gestures to differ.
//   4. Its clock is `Date`-based wall time, not the event timestamp.
//
//  Raw `touchesBegan/Moved/Ended/Cancelled` on a plain UIView gives us every
//  touch, every coalesced sample, and `UITouch.timestamp` — the host-clock time
//  the event was actually generated at, on the same timebase as
//  `CACurrentMediaTime()`. That last point is what makes the velocity maths in
//  `PointerEngine`/`ScrollEngine` honest: a velocity computed from `Date()` at
//  delivery time is polluted by main-thread jitter, so the acceleration curve
//  amplifies scheduling noise instead of finger speed.
//
//  This file owns the *only* translation from UIKit touches into the
//  UIKit-free contract `GestureState` publishes: (count, centroid, time).
//

import SwiftUI
import UIKit

// MARK: - Handler protocol

/// What `TouchCaptureView` reports upwards, in `GestureState`'s vocabulary.
///
/// `count` follows the classifier's contract exactly: on began/moved it is the
/// number of touches on the surface including the ones being reported; on ended
/// it is the number STILL down after the lift. `point` is always the centroid of
/// the touches that count covers.
@MainActor
protocol TouchCaptureHandling: AnyObject {
    func captureBegan(count: Int, at point: CGPoint, time: TimeInterval)
    func captureMoved(count: Int, at point: CGPoint, time: TimeInterval)
    func captureEnded(count: Int, at point: CGPoint, time: TimeInterval)
    /// Every touch went away without a clean lift — flush any held state.
    func captureCancelled()
    /// True when the first finger lands, false when the last one leaves.
    func captureActivityChanged(isTouching: Bool)
}

// MARK: - The UIView

/// A bare UIView whose only job is to turn `UITouch`es into centroid samples.
///
/// Deliberately has no gesture recognisers of its own: a recogniser imposes a
/// recognition delay, can be cancelled by an ancestor, and would duplicate the
/// discrimination `GestureState` already does far more precisely.
final class TouchCaptureView: UIView {

    weak var handler: TouchCaptureHandling?

    /// Every touch currently on the glass, with its most recent position.
    /// UITouch hashes by identity, which is exactly the semantics we want.
    private var active: [UITouch: CGPoint] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TouchCaptureView is created in code only.")
    }

    private func commonInit() {
        // Without this UIKit delivers only the first touch, and every
        // multi-finger gesture silently degrades into a single-finger one.
        isMultipleTouchEnabled = true
        // NOT exclusive: holding the left-click button while dragging here is
        // how you drag a window, so the button row must keep getting touches.
        isExclusiveTouch = false
        isOpaque = false
        backgroundColor = .clear
    }

    // MARK: Touch plumbing

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        let wasIdle = active.isEmpty
        for touch in touches {
            active[touch] = touch.location(in: self)
        }
        if wasIdle { handler?.captureActivityChanged(isTouching: true) }
        handler?.captureBegan(count: active.count, at: centroid(), time: latestTime(of: touches))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)

        // One classifier call per coalesced sample, in timestamp order. See
        // `samples(from:event:)` for why the intermediate samples matter.
        for sample in samples(from: touches, event: event) {
            guard active[sample.touch] != nil else { continue }
            active[sample.touch] = sample.location
            handler?.captureMoved(count: active.count, at: centroid(), time: sample.time)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        let time = latestTime(of: touches)

        // Fold in where the lifting fingers actually left before dropping them:
        // tap detection compares this centroid against the gesture's start, so
        // discarding the final position would understate the travel.
        for touch in touches where active[touch] != nil {
            active[touch] = touch.location(in: self)
        }
        let point = centroid()
        for touch in touches {
            active.removeValue(forKey: touch)
        }

        if cancelled, active.isEmpty {
            // A cancel is not a lift: there is no meaningful end position, and
            // anything the classifier is holding has to be flushed.
            handler?.captureCancelled()
            handler?.captureActivityChanged(isTouching: false)
            return
        }

        handler?.captureEnded(count: active.count, at: point, time: time)
        if active.isEmpty { handler?.captureActivityChanged(isTouching: false) }
    }

    /// Called when the surface is disabled out from under a live touch (the
    /// link drops mid-swipe). UIKit does not always synthesise a cancel for us.
    func abandonActiveTouches() {
        guard !active.isEmpty else { return }
        active.removeAll()
        handler?.captureCancelled()
        handler?.captureActivityChanged(isTouching: false)
    }

    // MARK: Sample extraction

    private struct Sample {
        let touch: UITouch
        let location: CGPoint
        let time: TimeInterval
    }

    /// Expand a touch set into every sample UIKit recorded for it.
    ///
    /// `coalescedTouches` is the important part. Between two `touchesMoved:`
    /// deliveries the digitiser may have produced several samples — the panel
    /// scans faster than the run loop delivers, and faster still when the main
    /// thread stalls. Reading only `touch.location(in:)` throws those away, and
    /// a fast flick collapses into one huge jump that the acceleration curve
    /// then misreads as an impossibly fast finger. Replaying every coalesced
    /// sample keeps the intermediate motion, so the velocity estimate matches
    /// what the finger really did.
    ///
    /// `predictedTouches` is deliberately NOT forwarded. Predicted samples are
    /// speculative and are meant to be rolled back when the real ones arrive;
    /// there is no "unsend" for a HID report already on the air, so acting on a
    /// prediction would mean moving the Mac's pointer for motion that never
    /// happened.
    private func samples(from touches: Set<UITouch>, event: UIEvent?) -> [Sample] {
        var result: [Sample] = []
        result.reserveCapacity(touches.count * 4)

        for touch in touches {
            let coalesced = event?.coalescedTouches(for: touch) ?? []
            let sequence: [UITouch] = coalesced.isEmpty ? [touch] : coalesced
            for sample in sequence {
                result.append(Sample(touch: touch,
                                     location: sample.location(in: self),
                                     time: sample.timestamp))
            }
        }

        // A touch set is unordered and the engines integrate over time, so the
        // classifier must see a monotonically increasing stream.
        result.sort { $0.time < $1.time }
        return result
    }

    /// The centroid of the touches currently recorded.
    private func centroid() -> CGPoint {
        guard !active.isEmpty else { return .zero }
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for location in active.values {
            sumX += location.x
            sumY += location.y
        }
        let count = CGFloat(active.count)
        return CGPoint(x: sumX / count, y: sumY / count)
    }

    /// `CACurrentMediaTime()` shares `UITouch.timestamp`'s timebase, so it is a
    /// safe fallback for the (theoretical) empty set.
    private func latestTime(of touches: Set<UITouch>) -> TimeInterval {
        touches.map(\.timestamp).max() ?? CACurrentMediaTime()
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI face of `TouchCaptureView`.
///
/// Owns nothing: the caller supplies the `GestureState` — so the same machine
/// survives view-body churn — and receives every `GestureEvent` it emits.
@MainActor
struct TrackpadSurface: UIViewRepresentable {

    /// The sibling-owned classifier. Its `touches*` methods RETURN the events
    /// they decided on; this view forwards them, in order, to `onEvent`.
    let gestures: GestureState

    /// When false the surface stops accepting touches entirely — used to hard
    /// disable input while the link is down.
    var isEnabled: Bool

    /// Every event the classifier emits, in order. Main-actor isolated: it
    /// lands on `HIDSending`, which is `@MainActor`.
    var onEvent: @MainActor (GestureEvent) -> Void

    /// True while at least one finger is down. The screen uses this to run the
    /// display link that drives `tick(now:)` and scroll momentum.
    var onTouchActivityChange: @MainActor (Bool) -> Void

    init(gestures: GestureState,
         isEnabled: Bool = true,
         onEvent: @escaping @MainActor (GestureEvent) -> Void,
         onTouchActivityChange: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.gestures = gestures
        self.isEnabled = isEnabled
        self.onEvent = onEvent
        self.onTouchActivityChange = onTouchActivityChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(gestures: gestures,
                    onEvent: onEvent,
                    onTouchActivityChange: onTouchActivityChange)
    }

    func makeUIView(context: Context) -> TouchCaptureView {
        let view = TouchCaptureView()
        view.handler = context.coordinator
        view.isUserInteractionEnabled = isEnabled
        view.isAccessibilityElement = true
        // Direct interaction: VoiceOver passes raw touches straight through
        // instead of turning them into explore-by-touch, which is the only way
        // a pointing surface can work at all with the screen reader on.
        view.accessibilityTraits = .allowsDirectInteraction
        view.accessibilityLabel = "Trackpad"
        view.accessibilityHint =
            "Drag one finger to move the pointer, two to scroll. Tap to click, "
            + "two-finger tap to right click, three-finger swipe to switch desktops."
        return view
    }

    func updateUIView(_ uiView: TouchCaptureView, context: Context) {
        // The closures captured at make time are stale after every body pass.
        context.coordinator.gestures = gestures
        context.coordinator.onEvent = onEvent
        context.coordinator.onTouchActivityChange = onTouchActivityChange

        if uiView.isUserInteractionEnabled != isEnabled {
            uiView.isUserInteractionEnabled = isEnabled
            if !isEnabled { uiView.abandonActiveTouches() }
        }
    }

    static func dismantleUIView(_ uiView: TouchCaptureView, coordinator: Coordinator) {
        uiView.handler = nil
        coordinator.flush()
    }

    // MARK: Coordinator

    /// The only place that speaks to `GestureState`.
    ///
    /// Every `touches*` call returns an array, and every element of it must
    /// reach `onEvent` in order — the classifier balances its own button
    /// down/up pairs, so dropping even one event leaves a mouse button stuck
    /// down on the Mac.
    @MainActor
    final class Coordinator: TouchCaptureHandling {

        var gestures: GestureState
        var onEvent: @MainActor (GestureEvent) -> Void
        var onTouchActivityChange: @MainActor (Bool) -> Void

        init(gestures: GestureState,
             onEvent: @escaping @MainActor (GestureEvent) -> Void,
             onTouchActivityChange: @escaping @MainActor (Bool) -> Void) {
            self.gestures = gestures
            self.onEvent = onEvent
            self.onTouchActivityChange = onTouchActivityChange
        }

        func captureBegan(count: Int, at point: CGPoint, time: TimeInterval) {
            dispatch(gestures.touchesBegan(count: count, at: point, time: time))
        }

        func captureMoved(count: Int, at point: CGPoint, time: TimeInterval) {
            dispatch(gestures.touchesMoved(count: count, at: point, time: time))
        }

        func captureEnded(count: Int, at point: CGPoint, time: TimeInterval) {
            dispatch(gestures.touchesEnded(count: count, at: point, time: time))
        }

        func captureCancelled() {
            // `reset()` returns a button-up for anything still held. Forwarding
            // it is not optional: a cancelled drag that never sends the release
            // leaves the Mac holding the left button down forever.
            dispatch(gestures.reset())
        }

        func captureActivityChanged(isTouching: Bool) {
            onTouchActivityChange(isTouching)
        }

        /// Tear-down flush, for when the view goes away mid-gesture.
        func flush() {
            dispatch(gestures.reset())
            onTouchActivityChange(false)
        }

        private func dispatch(_ events: [GestureEvent]) {
            for event in events {
                onEvent(event)
            }
        }
    }
}

// MARK: - Preview

/// Live event log so the surface can be exercised on its own.
@MainActor
private struct TrackpadSurfaceHarness: View {
    @State private var log: [String] = []
    @State private var isTouching = false
    private let gestures = GestureState()

    var body: some View {
        VStack(spacing: 12) {
            TrackpadSurface(
                gestures: gestures,
                onEvent: { event in
                    log.insert(String(describing: event), at: 0)
                    if log.count > 14 { log.removeLast() }
                },
                onTouchActivityChange: { isTouching = $0 }
            )
            .background(Theme.trackpadSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))

            Text(isTouching ? "Touching" : "Idle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 170)
        }
        .padding()
        .themedPage()
    }
}

#Preview("Trackpad surface") {
    TrackpadSurfaceHarness()
}
