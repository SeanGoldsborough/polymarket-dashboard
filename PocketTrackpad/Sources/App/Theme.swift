//
//  Theme.swift
//  PocketTrackpad
//
//  The visual system: a light grey page, white rounded cards, a system-blue
//  accent, and a capsule call-to-action button.
//
//  WHY the palette is hand-rolled rather than `Color(.systemGroupedBackground)`
//  and friends: the stock semantic colours give a *usable* dark mode but not a
//  *designed* one — `.systemGroupedBackground` inverts to pure black with
//  `.secondarySystemGroupedBackground` cards that sit only 11% above it, which
//  reads as flat and makes the card edges disappear on OLED. Every colour here
//  is specified twice, once per interface style, so the dark palette is its own
//  design: a near-black page (not #000) with cards lifted clearly above it and a
//  hairline border doing the work the shadow does in light mode.
//
//  All colours are built from a `UIColor` dynamic provider rather than from an
//  asset catalog so that this file is the single, greppable source of truth and
//  so the module carries no resource bundle.
//

import SwiftUI
import UIKit

// MARK: - Palette

public enum Theme {

    // MARK: Metrics

    /// Card corner radius used throughout the app. Matches the reference design.
    public static let cardCornerRadius: CGFloat = 14
    /// Inset between a card's edge and its content.
    public static let cardPadding: CGFloat = 16
    /// Vertical rhythm between stacked `CardSection`s.
    public static let sectionSpacing: CGFloat = 18
    /// Radius for inline controls (chips, small buttons) nested inside a card.
    public static let controlCornerRadius: CGFloat = 10

    // MARK: Surfaces

    /// The page behind every card. Light: iOS grouped-background grey.
    /// Dark: a very slightly blue near-black, never #000, so cards can sit above it.
    public static let pageBackground = adaptive(light: 0xF2F2F7, dark: 0x0E0E12)

    /// The white card. In dark mode it is deliberately *lighter* than the page
    /// by a perceptible amount rather than the 4-point step UIKit uses.
    public static let cardBackground = adaptive(light: 0xFFFFFF, dark: 0x1B1B21)

    /// A card nested inside another card (e.g. the log console).
    public static let insetBackground = adaptive(light: 0xF6F6F9, dark: 0x121217)

    /// Hairline around cards. Carries the edge in dark mode where the shadow
    /// is invisible; nearly absent in light mode where the shadow does the work.
    public static let cardBorder = adaptive(light: 0x000000, dark: 0xFFFFFF,
                                            lightAlpha: 0.05, darkAlpha: 0.10)

    /// Row divider inside a card.
    public static let separator = adaptive(light: 0x000000, dark: 0xFFFFFF,
                                           lightAlpha: 0.08, darkAlpha: 0.12)

    /// The trackpad's touch surface — slightly recessed from the card.
    public static let trackpadSurface = adaptive(light: 0xFAFAFC, dark: 0x232329)

    // MARK: Text

    public static let primaryText   = adaptive(light: 0x1C1C1E, dark: 0xF4F4F7)
    public static let secondaryText = adaptive(light: 0x6E6E73, dark: 0x9A9AA2)
    public static let tertiaryText  = adaptive(light: 0x9A9AA0, dark: 0x6D6D76)

    // MARK: Accent + status

    /// System blue, spelled out so it is identical in previews and on device.
    public static let accent  = adaptive(light: 0x007AFF, dark: 0x0A84FF)
    public static let success = adaptive(light: 0x248A3D, dark: 0x30D158)
    public static let warning = adaptive(light: 0xB25000, dark: 0xFF9F0A)
    public static let danger  = adaptive(light: 0xD70015, dark: 0xFF453A)

    /// Tint behind a status glyph, at low opacity so it reads as a wash.
    public static func statusWash(_ color: Color) -> Color { color.opacity(0.14) }

    // MARK: Shadow

    /// Card shadow. Suppressed in dark mode (a black shadow on a near-black
    /// page is invisible and only costs off-screen render passes) — the border
    /// carries the separation there instead.
    public static let cardShadow = adaptive(light: 0x000000, dark: 0x000000,
                                            lightAlpha: 0.06, darkAlpha: 0.0)
    public static let cardShadowRadius: CGFloat = 8
    public static let cardShadowOffsetY: CGFloat = 2

    // MARK: Construction

    /// Build a colour that resolves per interface style.
    ///
    /// `UIColor`'s dynamic provider is re-invoked whenever the trait collection
    /// changes, which is what makes these correct under a mid-session appearance
    /// switch *and* under `.preferredColorScheme` overrides applied by the app.
    private static func adaptive(
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? rgb(dark, alpha: darkAlpha)
                : rgb(light, alpha: lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> UIColor {
        UIColor(
            red:   CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >>  8) & 0xFF) / 255.0,
            blue:  CGFloat( hex        & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

// MARK: - Card container

/// The white rounded container every screen is built from.
///
/// Title and footer live *outside* the card (as in iOS grouped lists) so that
/// several cards can be stacked with consistent rhythm without the caller
/// hand-rolling padding each time.
public struct CardSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let contentPadding: CGFloat
    private let content: Content

    public init(
        _ title: String? = nil,
        footer: String? = nil,
        contentPadding: CGFloat = Theme.cardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.contentPadding = contentPadding
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.footnote.weight(.semibold))
                    .kerning(0.4)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 4)
                    // The card below already carries the heading semantically;
                    // marking it as a header lets VoiceOver's rotor jump between sections.
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(contentPadding)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            )
            .shadow(color: Theme.cardShadow, radius: Theme.cardShadowRadius, x: 0, y: Theme.cardShadowOffsetY)

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Buttons

/// The blue capsule call-to-action ("Add Device", "Run All Probes").
public struct PrimaryCapsuleButton: ButtonStyle {
    /// When true the button fills the available width, as in the reference design.
    private let fillsWidth: Bool

    public init(fillsWidth: Bool = true) {
        self.fillsWidth = fillsWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration, fillsWidth: fillsWidth)
    }

    /// A nested view is required because `ButtonStyle.makeBody` cannot read the
    /// environment directly, and the disabled appearance must respond to
    /// `.disabled(_:)` applied by the caller.
    private struct Body: View {
        let configuration: Configuration
        let fillsWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 14)
                .padding(.horizontal, 22)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .background(Theme.accent.opacity(isEnabled ? 1.0 : 0.35), in: Capsule(style: .continuous))
                .opacity(configuration.isPressed ? 0.82 : 1.0)
                .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .contentShape(Capsule(style: .continuous))
        }
    }
}

public extension ButtonStyle where Self == PrimaryCapsuleButton {
    /// `.buttonStyle(.primaryCapsule)`
    static var primaryCapsule: PrimaryCapsuleButton { PrimaryCapsuleButton() }

    /// A capsule button sized to its label rather than the full width.
    static var primaryCapsuleCompact: PrimaryCapsuleButton { PrimaryCapsuleButton(fillsWidth: false) }
}

/// A quiet bordered button for secondary actions inside a card.
public struct SecondaryCapsuleButton: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(Theme.statusWash(Theme.accent), in: Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .contentShape(Capsule(style: .continuous))
    }
}

public extension ButtonStyle where Self == SecondaryCapsuleButton {
    static var secondaryCapsule: SecondaryCapsuleButton { SecondaryCapsuleButton() }
}

// MARK: - Page background

private struct PageBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.pageBackground.ignoresSafeArea())
            .tint(Theme.accent)
    }
}

public extension View {
    /// Apply the standard page background and accent tint.
    func themedPage() -> some View {
        modifier(PageBackgroundModifier())
    }
}

// MARK: - Simulator badge

/// Shown whenever the app is running against `StubHIDSender` instead of the
/// real radio.
///
/// WHY this must never be silent: CoreBluetooth's peripheral role is
/// non-functional in the iOS Simulator — `CBPeripheralManager` reports
/// `.unsupported` (or never leaves `.unknown`) and no service can be published.
/// The app therefore substitutes a stub so the UI remains explorable, but a
/// stub that quietly reports "connected" would make the Simulator look like a
/// working end-to-end path and produce false confidence in exactly the area the
/// product is riskiest. The badge makes the substitution impossible to miss.
public struct StubbedRadioBadge: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.bold))
            Text("Simulator — radio stubbed")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(Theme.warning)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.statusWash(Theme.warning), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Simulator mode")
        .accessibilityValue("Bluetooth radio is stubbed. No reports leave this device.")
    }
}

// MARK: - Preview

#Preview("Theme gallery") {
    ScrollView {
        VStack(spacing: Theme.sectionSpacing) {
            StubbedRadioBadge()

            CardSection("Connection", footer: "The Mac must initiate pairing from Bluetooth settings.") {
                HStack {
                    Text("Status").foregroundStyle(Theme.primaryText)
                    Spacer()
                    Text("Advertising").foregroundStyle(Theme.secondaryText)
                }
                Divider().overlay(Theme.separator)
                HStack {
                    Text("Topology").foregroundStyle(Theme.primaryText)
                    Spacer()
                    Text("Per-report").foregroundStyle(Theme.secondaryText)
                }
            }

            CardSection("Actions") {
                Button("Add Device") {}
                    .buttonStyle(.primaryCapsule)
                Button("Use this topology") {}
                    .buttonStyle(.secondaryCapsule)
                Button("Disabled") {}
                    .buttonStyle(.primaryCapsule)
                    .disabled(true)
            }
        }
        .padding(20)
    }
    .themedPage()
}
