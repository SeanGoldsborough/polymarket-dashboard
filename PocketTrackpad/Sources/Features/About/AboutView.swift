//
//  AboutView.swift
//  PocketTrackpad
//
//  The About tab: identity, the outward links, and support.
//
//  Version and build are read from the bundle. Hard-coding them means the
//  number in a support email eventually disagrees with the number in App Store
//  Connect, and the first person to notice is the one debugging a report from
//  a build that no longer exists.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Bundle facts

public enum AppInfo {
    public static var displayName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? "Pocket Trackpad"
    }

    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    public static var versionSummary: String { "Version \(version) (\(build))" }

    /// "iPhone15,2" style identifier. `UIDevice.model` only ever says
    /// "iPhone", which is useless in a bug report.
    public static var deviceModelIdentifier: String {
        var info = utsname()
        uname(&info)
        let machine = Mirror(reflecting: info.machine).children
            .compactMap { $0.value as? Int8 }
            .prefix { $0 != 0 }
            .map { Character(UnicodeScalar(UInt8(bitPattern: $0))) }
        let identifier = String(machine)
        return identifier.isEmpty ? "Unknown" : identifier
    }

    /// Read from `ProcessInfo` rather than `UIDevice`, which is main-actor
    /// isolated and would drag that isolation into every caller of this type.
    public static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if os(iOS)
        return "iOS \(number)"
        #else
        return number
        #endif
    }
}

// MARK: - Outward links
//
// PLACEHOLDERS — every URL and address below is a stand-in. Replace them with
// the real ones before the first TestFlight build; nothing else in the app
// depends on their values.

public enum AboutLinks {
    /// PLACEHOLDER: the App Store product identifier, available in App Store
    /// Connect once the app record exists.
    public static let appStoreID = "0000000000"

    /// PLACEHOLDER: opens the App Store review composer for this app.
    public static let writeReview = URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")!

    /// PLACEHOLDER: marketing site.
    public static let website = URL(string: "https://example.com/pockettrackpad")!

    /// PLACEHOLDER: privacy policy. App Review requires this to resolve.
    public static let privacyPolicy = URL(string: "https://example.com/pockettrackpad/privacy")!

    /// PLACEHOLDER: help centre / FAQ.
    public static let helpCenter = URL(string: "https://example.com/pockettrackpad/help")!

    /// PLACEHOLDER: support inbox.
    public static let supportAddress = "support@example.com"

    /// A mailto: with the facts that make a support ticket answerable, so
    /// nobody has to ask "which version, on what device?" as the first reply.
    public static var contact: URL? {
        let body = """


        —
        Sent from \(AppInfo.displayName)
        App: \(AppInfo.version) (\(AppInfo.build))
        Device: \(AppInfo.deviceModelIdentifier)
        System: \(AppInfo.systemVersion)
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "\(AppInfo.displayName) Support"),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}

// MARK: - Release notes

public struct ReleaseNote: Identifiable, Hashable, Sendable {
    public var version: String
    public var date: String
    public var highlights: [String]

    public var id: String { version }

    public init(version: String, date: String, highlights: [String]) {
        self.version = version
        self.date = date
        self.highlights = highlights
    }

    /// Newest first. Kept here rather than fetched: release notes must render
    /// offline, and a network round trip for eight lines of text is a worse
    /// experience than an app update.
    public static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "1.0.0",
            date: "First release",
            highlights: [
                "Use your iPhone as a Bluetooth trackpad and keyboard for your Mac — no software to install on the Mac.",
                "Media, Numeric Keypad, Presentation and TV remotes, ready to use.",
                "Build your own remotes: any key combination, typed text, mouse clicks, or a sequence of steps.",
                "Tracking, motion and scrolling sensitivity, with natural scrolling.",
                "Diagnostics that report exactly which Bluetooth report layout your Mac accepts."
            ]
        )
    ]
}

// MARK: - View

@MainActor
public struct AboutView: View {
    @Environment(\.openURL) private var openURL

    @State private var isShowingWhatsNew = false
    @State private var mailFailure = false

    public init() {}

    public var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                LinkRow(title: "Write a Review", systemImage: "star.bubble") {
                    openURL(AboutLinks.writeReview)
                }
                LinkRow(title: "Website", systemImage: "globe") {
                    openURL(AboutLinks.website)
                }
                LinkRow(title: "Privacy Policy", systemImage: "hand.raised") {
                    openURL(AboutLinks.privacyPolicy)
                }
                LinkRow(title: "What's New", systemImage: "sparkles", opensExternally: false) {
                    isShowingWhatsNew = true
                }
            }

            Section {
                LinkRow(title: "Help Center", systemImage: "questionmark.circle") {
                    openURL(AboutLinks.helpCenter)
                }
                LinkRow(title: "Contact", systemImage: "envelope") {
                    if let contact = AboutLinks.contact {
                        openURL(contact) { accepted in
                            mailFailure = !accepted
                        }
                    } else {
                        mailFailure = true
                    }
                }
            } header: {
                Text("Support").textCase(.uppercase)
            } footer: {
                Text("Contact includes your app version, device model and system version so we can reproduce what you are seeing.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingWhatsNew) {
            WhatsNewView()
        }
        .alert("Could Not Open Mail", isPresented: $mailFailure) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("No mail account is set up on this device. You can reach us at \(AboutLinks.supportAddress).")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.and.hand.point.up.left.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .frame(width: 88, height: 88)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .accessibilityHidden(true)

            Text(AppInfo.displayName)
                .font(.title2.weight(.semibold))

            Text(AppInfo.versionSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppInfo.displayName)
        .accessibilityValue(AppInfo.versionSummary)
    }
}

// MARK: - Row

private struct LinkRow: View {
    let title: String
    let systemImage: String
    var opensExternally: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: opensExternally ? "arrow.up.right" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityHint(opensExternally ? "Opens outside the app" : "Opens a sheet")
    }
}

// MARK: - What's New

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(ReleaseNote.all) { note in
                    Section {
                        ForEach(Array(note.highlights.enumerated()), id: \.offset) { pair in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                                Text(pair.element)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Version \(note.version)")
                                .font(.headline)
                                .foregroundStyle(Color.primary)
                            Text(note.date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("About") {
    NavigationStack {
        AboutView()
    }
}

#Preview("What's New") {
    WhatsNewView()
}
