//
//  AppSettings.swift
//  PocketTrackpad
//
//  SHARED CONTRACT — the single source of truth for user preferences.
//  The General tab writes these; the Trackpad and Remotes features read them.
//

import Foundation
import SwiftUI

public enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Persisted preferences. Values are normalised 0...1 as the sliders present
/// them; the input engines map them onto real gain ranges so the mapping curve
/// lives in one place (`PointerEngine`/`ScrollEngine`) rather than in the UI.
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    /// Pointer gain. 0 = slowest, 1 = fastest. Default matches the midpoint of
    /// the reference app's slider.
    public var tracking: Double {
        didSet { store(tracking, "tracking") }
    }

    /// Pointer acceleration strength (how strongly fast flicks are amplified).
    public var motion: Double {
        didSet { store(motion, "motion") }
    }

    /// Scroll gain.
    public var scrolling: Double {
        didSet { store(scrolling, "scrolling") }
    }

    /// When true, content follows the finger (macOS "Natural scrolling").
    public var naturalScrolling: Bool {
        didSet { store(naturalScrolling, "naturalScrolling") }
    }

    public var appearance: AppearanceMode {
        didSet { store(appearance.rawValue, "appearance") }
    }

    /// Haptic feedback on taps and button presses.
    public var hapticsEnabled: Bool {
        didSet { store(hapticsEnabled, "hapticsEnabled") }
    }

    /// The report topology the user (or the diagnostics screen) selected.
    public var preferredTopology: ReportTopology {
        didSet { store(preferredTopology.rawValue, "preferredTopology") }
    }

    /// Name advertised to macOS. Defaults to the device name.
    public var advertisedName: String {
        didSet { store(advertisedName, "advertisedName") }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func d(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) as? Double ?? fallback
        }
        func b(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        self.tracking          = d("tracking", 0.5)
        self.motion            = d("motion", 0.5)
        self.scrolling         = d("scrolling", 0.5)
        self.naturalScrolling  = b("naturalScrolling", false)
        self.hapticsEnabled    = b("hapticsEnabled", true)
        self.appearance        = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        self.preferredTopology = ReportTopology(rawValue: defaults.string(forKey: "preferredTopology") ?? "")
            ?? .perReportCharacteristic
        self.advertisedName    = defaults.string(forKey: "advertisedName") ?? AppSettings.defaultAdvertisedName
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    public static var defaultAdvertisedName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "Pocket Trackpad"
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
