//
//  PocketTrackpadApp.swift
//  PocketTrackpad
//
//  Composition root. Owns the one radio, the one settings object, and the one
//  diagnostics harness, and hands them down by injection. Nothing below this
//  file reaches for a singleton except `AppSettings.shared`, which the shared
//  contract already defines.
//

import SwiftUI

// MARK: - Runtime

/// Everything the app shell owns for its whole lifetime.
///
/// Exists as a class rather than a pile of `@State` properties on the `App` so
/// that (a) the Simulator substitution happens in exactly one place and (b) the
/// scene-phase policy has somewhere to live that is testable by inspection
/// rather than buried in a view modifier.
@MainActor
@Observable
public final class AppRuntime {

    /// The radio, or the stub standing in for it in the Simulator.
    public let sender: any HIDPeripheralControlling

    /// The diagnostics harness, sharing the same radio as the rest of the app.
    public let diagnostics: HIDDiagnostics

    public let settings: AppSettings

    /// The remote library. Owned here rather than by `RemotesListView` so that
    /// the JSON document is read once per launch and the same instance backs
    /// every presentation of the Remotes tab.
    public let remotes: RemoteStore

    /// True when `sender` is a `StubHIDSender` rather than the real radio.
    /// Surfaced in the UI as a badge — see `StubbedRadioBadge`.
    public let isRadioStubbed: Bool

    /// The reason the radio last refused to start, verbatim, or nil.
    /// Shown as a banner on the root screen — a peripheral that never published
    /// its service looks identical to one that is simply not connected yet, and
    /// the user needs to be able to tell those apart.
    public private(set) var lastStartError: String?

    /// Set when we stopped the radio on backgrounding, so foregrounding knows
    /// whether it is responsible for bringing it back.
    @ObservationIgnored private var shouldResumeOnForeground = false

    /// `settings` is required rather than defaulted to `AppSettings.shared`:
    /// a default argument expression is evaluated in a nonisolated context in
    /// Swift 5.9, so `= .shared` on a `@MainActor` type does not compile.
    /// Callers pass `.shared` explicitly; previews and tests pass a throwaway.
    public init(settings: AppSettings) {
        self.settings = settings
        // Built here rather than accepted as a defaulted parameter: a default
        // argument expression is nonisolated in Swift 5.9, and `RemoteStore` is
        // `@MainActor`, so `= RemoteStore()` in the signature would not compile
        // under strict concurrency.
        self.remotes = RemoteStore()

        #if targetEnvironment(simulator)
        // CoreBluetooth's *peripheral* role does not function in the Simulator.
        // `CBPeripheralManager` never reaches `.poweredOn` there — it reports
        // `.unsupported` — so `HIDPeripheralManager` could only ever sit in a
        // failed state, and every screen that reads `connectionState` would be
        // dead. Substituting the stub keeps the entire UI explorable on a Mac,
        // which is where the layout work actually gets done.
        //
        // The substitution is loud, not silent: `isRadioStubbed` drives a
        // permanent on-screen badge. A stub that reports "connected" while no
        // bytes leave the machine is exactly the kind of thing that produces
        // false confidence in the riskiest part of this product.
        let radio: any HIDPeripheralControlling = StubHIDSender()
        self.isRadioStubbed = true
        #else
        let radio: any HIDPeripheralControlling = HIDPeripheralManager()
        self.isRadioStubbed = false
        #endif

        self.sender = radio
        self.diagnostics = HIDDiagnostics(manager: radio)
    }

    // MARK: Lifecycle

    /// Bring the radio up with whichever topology the user has settled on.
    ///
    /// A throw here is not fatal and must not be swallowed: it means iOS
    /// refused to publish the preferred layout — typically the 0x2908
    /// descriptor rejection — and the correct next move is the Diagnostics
    /// screen, which the banner points at.
    public func startRadio() {
        do {
            try sender.start(topology: settings.preferredTopology)
            lastStartError = nil
        } catch {
            lastStartError = HIDDiagnostics.describe(error)
        }
    }

    /// Dismiss the start-failure banner without retrying.
    public func clearStartError() {
        lastStartError = nil
    }

    /// Scene moved to `.background`.
    ///
    /// WHY we stop rather than keep advertising:
    ///
    /// A backgrounded iOS peripheral does not advertise the way a foreground
    /// one does. iOS moves every service UUID out of the advertisement's main
    /// data section and into the *overflow* area
    /// (`CBAdvertisementDataOverflowServiceUUIDsKey`), and the local name is
    /// dropped entirely. The overflow area is an Apple-proprietary encoding
    /// that only another Apple device *explicitly scanning for that exact
    /// UUID* can decode. macOS's Bluetooth settings pane does a generic
    /// discovery scan, so it will typically not list us at all once we are
    /// backgrounded — the advertisement burns radio and battery while being
    /// undiscoverable by the only central that matters.
    ///
    /// An already-established connection is a different matter: the L2CAP link
    /// survives backgrounding, and tearing down the services would drop a Mac
    /// that is mid-session. So we stop only when we are advertising for
    /// discovery and nobody is connected.
    public func handleBackground() {
        guard !sender.connectionState.isConnected else {
            shouldResumeOnForeground = false
            return
        }
        switch sender.connectionState {
        case .advertising:
            sender.stop()
            shouldResumeOnForeground = true
        default:
            shouldResumeOnForeground = false
        }

        // A probe run cannot make progress in the background either — the
        // human step happens on the Mac while looking at this screen.
        diagnostics.cancel()
    }

    /// Scene returned to `.active`.
    public func handleForeground() {
        guard shouldResumeOnForeground else { return }
        shouldResumeOnForeground = false
        startRadio()
    }
}

// MARK: - App

@main
struct PocketTrackpadApp: App {

    @State private var runtime: AppRuntime
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // `App.init()` is a nonisolated protocol requirement but is only ever
        // called on the main thread by the SwiftUI entry point, and `AppRuntime`
        // is `@MainActor`. `assumeIsolated` states that fact to the compiler
        // instead of leaving it to the Swift 5 mode's permissiveness, so this
        // keeps compiling unchanged under strict concurrency.
        _runtime = State(initialValue: MainActor.assumeIsolated { AppRuntime(settings: .shared) })
    }

    var body: some Scene {
        WindowGroup {
            RootView(runtime: runtime)
                .preferredColorScheme(runtime.settings.appearance.colorScheme)
                // Deliberately no auto-start on launch. `HIDPeripheralManager`
                // already brings CoreBluetooth up in `init` so the Connection
                // tab can show the radio's true state, but *advertising* is a
                // user decision made with the "Add Device" button — going on
                // the air unasked drains the battery and makes the Connection
                // tab's toggle read "Stop advertising" before the user has done
                // anything.
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        runtime.handleBackground()
                    case .active:
                        runtime.handleForeground()
                    case .inactive:
                        // Transient (Control Centre, app switcher, an incoming
                        // call banner). Tearing the radio down here would drop
                        // the link every time the user swipes down, so nothing
                        // happens until we actually reach `.background`.
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
