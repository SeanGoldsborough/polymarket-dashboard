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
//   1. It coalesces and smooths. SwiftUI hands you a single `translation`
//      per frame that has already been filtered; the intermediate samples
//      that make velocity estimation honest are gone before we see them.
//   2. It adds latency. The gesture has to lose to (or win against) the
//      surrounding scroll/navigation gestures before the first value is
//      delivered, which shows up as a dead zone at the start of every flick.
//   3. It hides multi-touch. `DragGesture` is single-touch by construction,
//      so a two-finger scroll and a one-finger move are indistinguishable.
//   4. Its `time` is `Date`-based wall clock, not the event timestamp.
//
//  Raw `touchesBegan/Moved/Ended/Cancelled` on a plain UIView gives us every
//  touch, every coalesced sample, and `UITouch.timestamp` — the host-clock
//  timestamp the event was actually generated at. That last point matters a
//  lot: velocity computed from `Date()` at delivery time is polluted by main
//  thread jitter, so acceleration curves fed from it feel inconsistent.
//  `touch.timestamp` is what makes the velocity math honest.
//
//  ASSUMED SIBLING API (Sources/Input/GestureState.swift)
//  -----------------------------------------------------
//  This file and `TrackpadView` are the only places that touch `GestureState`.
//  The assumptions, all concentrated in `Coordinator` below, are:
//
//      final class GestureState {
//          init(pointer: PointerEngine, scroll: ScrollEngine)
//          var onEvent: ((GestureEvent) -> Void)?
//          func touchesBegan(_ samples: [TouchSample])
//          func touchesMoved(_ samples: [TouchSample])
//          func touchesEnded(_ samples: [TouchSample])
//          func touchesCancelled()
//      }
//
//  If the shipped names differ, `Coordinator` is the single edit site.
//

import SwiftUI
import UIKit

// MARK: - Handler protocol

/// What `TouchCaptureView` reports upwards. Declared here (rather than using a
/// bag of closures) so the view holds a single weak reference and cannot
/// accidentally retain the SwiftUI coordinator.
@MainActor
protocol TouchCaptureHandling: AnyObject {
    func captureBegan(_ samples: [TouchSample], activeTouchCount: Int)
    func captureMoved(_ samples: [TouchSample], activeTouchCount: Int)
    func captureEnded(_ samples: [TouchSample], activeTouchCount: Int)
    func captureCancelled()
}

// MARK: - The UIView

/// A bare UIView whose only job is to turn `UITouch`es into `TouchSample`s.
///
/// Deliberately has no gesture recognisers of its own: a recogniser would
/// impose a recognition delay and could be cancelled by an ancestor, and the
/// state machine we feed already does the discrimination we need.
final class TouchCaptureView: UIView {

    weak var handler: TouchCaptureHandling?

    /// Touches currently down on this view. Kept so the handler can tell a
    /// one-finger move from a two-finger scroll without owning UIKit types.
    private var activeTouches: Set<UITouch> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TouchCaptureView is created in code only.")
    }

    private func commonInit() {
        // Without this, UIKit delivers only the first touch and every
        // multi-finger gesture silently degrades to a single-finger one.
        isMultipleTouchEnabled = true
        // NOT exclusive: holding the left-click button while dragging here is
        // how you drag a window, so the button row must keep getting touches.
        isExclusiveTouch = false
        isOpaque = false
        backgroundColor = .clear
        // Touch delivery must not wait on anything above us.
        isUserInteractionEnabled = true
    }

    // MARK: Touch plumbing

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        activeTouches.formUnion(touches)
        handler?.captureBegan(samples(from: touches, event: event),
                              activeTouchCount: activeTouches.count)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        handler?.captureMoved(samples(from: touches, event: event),
                              activeTouchCount: activeTouches.count)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        let batch = samples(from: touches, event: event)
        activeTouches.subtract(touches)
        handler?.captureEnded(batch, activeTouchCount: activeTouches.count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        activeTouches.subtract(touches)
        if activeTouches.isEmpty {
            handler?.captureCancelled()
        } else {
            handler?.captureEnded(samples(from: touches, event: event),
                                  activeTouchCount: activeTouches.count)
        }
    }

    /// Called when the surface is disabled out from under a live touch (for
    /// example the link drops mid-swipe). UIKit will not always synthesise a
    /// cancel for us, so we do it explicitly and leave the state machine clean.
    func abandonActiveTouches() {
        guard !activeTouches.isEmpty else { return }
        activeTouches.removeAll()
        handler?.captureCancelled()
    }

    // MARK: Sample extraction

    /// Convert a UIKit touch set into engine samples.
    ///
    /// `coalescedTouches` is the important part. Between two `touchesMoved:`
    /// deliveries the digitiser may have produced several samples (240 Hz on
    /// ProMotion hardware versus a 120 Hz — or worse, stalled — run loop). If
    /// we only read `touch.location(in:)` we throw those away, and a fast flick
    /// collapses into one enormous jump that the acceleration curve then
    /// misreads. Feeding every coalesced sample keeps the intermediate motion.
    ///
    /// `predictedTouches` is deliberately NOT forwarded. Predicted samples are
    /// speculative and must be rolled back when the real ones arrive; there is
    /// no "unsend" for a HID report already on the air, so acting on a
    /// prediction would mean sending pointer movement that never happened.
    private func samples(from touches: Set<UITouch>, event: UIEvent?) -> [TouchSample] {
        var result: [TouchSample] = []
        result.reserveCapacity(touches.count * 4)

        for touch in touches {
            let coalesced = event?.coalescedTouches(for: touch) ?? []
            let sequence: [UITouch] = coalesced.isEmpty ? [touch] : coalesced
            for sample in sequence {
                result.append(
                    TouchSample(location: sample.location(in: self),
                                timestamp: sample.timestamp)
                )
            }
        }

        // Multiple touches arrive as an unordered Set; the engines integrate
        // over time, so hand them a monotonically ordered stream.
        result.sort { $0.timestamp < $1.timestamp }
        return result
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI face of `TouchCaptureView`.
///
/// Owns nothing: the caller supplies the `GestureState` (so the same machine
/// survives view-body churn) and receives `GestureEvent`s through `onEvent`.
@MainActor
struct TrackpadSurface: UIViewRepresentable {

    /// The sibling-owned state machine that turns samples into events.
    let gestures: GestureState

    /// When false the surface stops accepting touches entirely — used to hard
    /// disable input while the link is down.
    var isEnabled: Bool

    /// Every event the state machine emits. Main-actor isolated: it lands
    /// straight on `HIDSending`, which is `@MainActor`.
    var onEvent: @MainActor (GestureEvent) -> Void

    init(gestures: GestureState,
         isEnabled: Bool = true,
         onEvent: @escaping @MainActor (GestureEvent) -> Void) {
        self.gestures = gestures
        self.isEnabled = isEnabled
        self.onEvent = onEvent
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(gestures: gestures, onEvent: onEvent)
    }

    func makeUIView(context: Context) -> TouchCaptureView {
        let view = TouchCaptureView()
        view.handler = context.coordinator
        view.isUserInteractionEnabled = isEnabled
        view.isAccessibilityElement = true
        view.accessibilityTraits = .allowsDirectInteraction
        view.accessibilityLabel = "Trackpad"
        view.accessibilityHint =
            "Drag with one finger to move the pointer. Drag with two fingers to scroll. "
            + "Tap to click. Swipe with three fingers to switch desktops."
        context.coordinator.connect()
        return view
    }

    func updateUIView(_ uiView: TouchCaptureView, context: Context) {
        // The closure captured at make time is stale after every body pass.
        context.coordinator.onEvent = onEvent
        context.coordinator.gestures = gestures
        context.coordinator.connect()

        if uiView.isUserInteractionEnabled != isEnabled {
            uiView.isUserInteractionEnabled = isEnabled
            if !isEnabled { uiView.abandonActiveTouches() }
        }
    }

    static func dismantleUIView(_ uiView: TouchCaptureView, coordinator: Coordinator) {
        uiView.handler = nil
        coordinator.disconnect()
    }

    // MARK: Coordinator

    /// The ONLY place that speaks to `GestureState`. See the file header for
    /// the assumed shape of that API.
    @MainActor
    final class Coordinator: TouchCaptureHandling {

        var gestures: GestureState
        var onEvent: @MainActor (GestureEvent) -> Void

        init(gestures: GestureState, onEvent: @escaping @MainActor (GestureEvent) -> Void) {
            self.gestures = gestures
            self.onEvent = onEvent
        }

        /// Point the state machine's output at us. Safe to call repeatedly.
        ///
        /// `GestureState` is deliberately UIKit-free and therefore carries no
        /// actor annotation, but every call into it originates from a UIKit
        /// touch callback, so its output is already on the main actor. The
        /// assumption is stated rather than hopped, because hopping would
        /// reorder reports relative to the touches that produced them.
        func connect() {
            gestures.onEvent = { [weak self] event in
                MainActor.assumeIsolated {
                    self?.onEvent(event)
                }
            }
        }

        func disconnect() {
            gestures.onEvent = nil
        }

        func captureBegan(_ samples: [TouchSample], activeTouchCount: Int) {
            guard !samples.isEmpty else { return }
            gestures.touchesBegan(samples)
        }

        func captureMoved(_ samples: [TouchSample], activeTouchCount: Int) {
            guard !samples.isEmpty else { return }
            gestures.touchesMoved(samples)
        }

        func captureEnded(_ samples: [TouchSample], activeTouchCount: Int) {
            gestures.touchesEnded(samples)
        }

        func captureCancelled() {
            gestures.touchesCancelled()
        }
    }
}

// MARK: - Preview

/// Live event log so the surface can be exercised on its own in a preview.
@MainActor
private struct TrackpadSurfaceHarness: View {
    @State private var log: [String] = []
    private let gestures = GestureState(pointer: PointerEngine(), scroll: ScrollEngine())

    var body: some View {
        VStack(spacing: 12) {
            TrackpadSurface(gestures: gestures) { event in
                log.insert(String(describing: event), at: 0)
                if log.count > 12 { log.removeLast() }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 160)
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}

#Preview("Trackpad surface") {
    TrackpadSurfaceHarness()
}
