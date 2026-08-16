//
//  DiagnosticsView.swift
//  PocketTrackpad
//
//  The screen that presents a probe run.
//
//  Design rule for this screen, which is unusual for the rest of the app: no
//  friendly paraphrasing. The failure strings iOS and CoreBluetooth produce are
//  the *product* of this screen — they are what gets pasted into a bug report,
//  compared across iOS versions, and used to decide which topology ships. A
//  polite "Something went wrong" here would destroy the only evidence there is.
//

import SwiftUI

public struct DiagnosticsView: View {

    private let diagnostics: HIDDiagnostics
    private let settings: AppSettings
    private let isRadioStubbed: Bool

    /// The topology awaiting confirmation before it is written into settings.
    @State private var pendingAdoption: ReportTopology?

    public init(diagnostics: HIDDiagnostics, settings: AppSettings, isRadioStubbed: Bool = false) {
        self.diagnostics = diagnostics
        self.settings = settings
        self.isRadioStubbed = isRadioStubbed
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: Theme.sectionSpacing) {
                if isRadioStubbed {
                    StubbedRadioBadge()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                instructions
                runControls
                resultRows
                logConsole
            }
            .padding(20)
        }
        .themedPage()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: diagnostics.exportReport()) {
                    Label("Share report", systemImage: "square.and.arrow.up")
                }
                .disabled(diagnostics.isRunning)
                .accessibilityLabel("Share diagnostics report")
                .accessibilityHint("Exports a plain-text report of every probe result and the radio log.")
            }
        }
        .alert(
            "Use this layout?",
            isPresented: Binding(
                get: { pendingAdoption != nil },
                set: { if !$0 { pendingAdoption = nil } }
            ),
            presenting: pendingAdoption
        ) { topology in
            Button("Use \(topology.rawValue)") {
                diagnostics.adopt(topology, into: settings)
                pendingAdoption = nil
            }
            Button("Cancel", role: .cancel) { pendingAdoption = nil }
        } message: { topology in
            Text(
                "\(topology.summary)\n\nThe app will publish this layout to every Mac from now on. "
                + "A probe that passed once is not a guarantee — you can change this again at any time."
            )
        }
        .onDisappear {
            // Leaving the screen must not leave the radio cycling through
            // topologies in the background.
            diagnostics.cancel()
        }
    }

    // MARK: Instructions

    /// The probe cannot succeed without a human at the Mac. Saying so up front
    /// is the difference between "the app is broken" and "it is waiting for me".
    private var instructions: some View {
        CardSection("Before you start") {
            Text("This probe answers two questions at once: which report layouts this iPhone is allowed to publish, and which of those your Mac will accept as a keyboard and trackpad.")
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.separator)

            instructionStep(
                number: 1,
                text: "On the Mac, open System Settings › Bluetooth and leave the window open."
            )
            instructionStep(
                number: 2,
                text: "Tap Run All Probes below. Each layout advertises for about \(HIDDiagnostics.describe(diagnostics.timing.subscriptionWindow))."
            )
            instructionStep(
                number: 3,
                text: "When \"\(settings.advertisedName)\" appears in the Mac's device list, click Connect. Nothing can be measured until you do — the peripheral cannot make a Mac pair with it."
            )
            instructionStep(
                number: 4,
                text: "If a layout fails, remove the device on the Mac before re-running, or macOS will reuse the report map it already cached."
            )
        }
    }

    private func instructionStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(Theme.statusWash(Theme.accent), in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }

    // MARK: Controls

    private var runControls: some View {
        CardSection(
            "Probe run",
            footer: diagnostics.lastRunWasCancelled
                ? "The last run was cancelled, so the results below are incomplete."
                : nil
        ) {
            if diagnostics.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(runningDescription)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityElement(children: .combine)

                Button("Cancel Run") { diagnostics.cancel() }
                    .buttonStyle(.primaryCapsule)
            } else {
                Button("Run All Probes") { diagnostics.start() }
                    .buttonStyle(.primaryCapsule)
                    .accessibilityHint("Tries each report layout in turn and reports which ones this Mac accepts.")
            }

            if let recommendation = diagnostics.recommendation {
                Divider().overlay(Theme.separator)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recommended: \(recommendation.rawValue)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text(recommendation.summary)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            HStack {
                Text("Currently in use")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(settings.preferredTopology.rawValue)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Currently in use: \(settings.preferredTopology.summary)")
        }
    }

    private var runningDescription: String {
        if let current = diagnostics.currentTopology {
            return "Probing \(current.rawValue) — waiting for the Mac to connect…"
        }
        return "Starting…"
    }

    // MARK: Results

    private var resultRows: some View {
        CardSection("Results", contentPadding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(ReportTopology.allCases.enumerated()), id: \.element) { index, topology in
                    if index > 0 {
                        Divider().overlay(Theme.separator).padding(.leading, 16)
                    }
                    ResultRow(
                        topology: topology,
                        state: diagnostics.state(for: topology),
                        result: diagnostics.result(for: topology),
                        isAdopted: settings.preferredTopology == topology,
                        onAdopt: { pendingAdoption = topology }
                    )
                    .padding(16)
                }
            }
        }
    }

    // MARK: Log console

    private var logConsole: some View {
        CardSection(
            "Radio log",
            footer: "Everything the peripheral manager reported, newest at the bottom."
        ) {
            if diagnostics.manager.log.isEmpty {
                Text("No log entries yet.")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(diagnostics.manager.log) { entry in
                                LogLine(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(height: 220)
                    .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
                    .onChange(of: diagnostics.manager.log.count) {
                        // Follow the tail while a probe is running; the newest
                        // line is the one that matters.
                        guard let last = diagnostics.manager.log.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .accessibilityLabel("Radio log")
                .accessibilityValue("\(diagnostics.manager.log.count) entries")

                Button("Clear log") { diagnostics.manager.clearLog() }
                    .buttonStyle(.secondaryCapsule)
            }
        }
    }
}

// MARK: - Result row

private struct ResultRow: View {
    let topology: ReportTopology
    let state: HIDDiagnostics.ProbeState
    let result: HIDDiagnostics.ProbeResult?
    let isAdopted: Bool
    let onAdopt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                glyph
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(topology.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                        if isAdopted {
                            Text("IN USE")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.accent)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 6)
                                .background(Theme.statusWash(Theme.accent), in: Capsule())
                        }
                    }
                    Text(topology.summary)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(state.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(stateColor)
                }
                Spacer(minLength: 0)
            }

            if let reason = result?.failureReason {
                failureReasonBlock(reason)
            }

            if let result, result.centralSubscribed {
                detailLine(
                    "Subscribed reports",
                    HIDDiagnostics.describe(result.subscribedReports)
                )
                detailLine(
                    "Probe reports",
                    result.roundTripConfirmed ? "delivered, link held" : "sent, but the link did not hold"
                )
            }

            if let notes = result?.notes, !notes.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            Text("• \(note)")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Trace (\(notes.count))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
                .tint(Theme.accent)
            }

            if canAdopt {
                Button("Use this topology", action: onAdopt)
                    .buttonStyle(.secondaryCapsule)
                    .accessibilityHint("Makes \(topology.rawValue) the layout the app publishes.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(topology.rawValue)
        .accessibilityValue(accessibilityValue)
    }

    /// A row is adoptable once it published and attracted a subscriber. A
    /// merely-published layout is not offered: it would advertise forever
    /// without ever pairing.
    private var canAdopt: Bool {
        guard !isAdopted, let result else { return false }
        return result.servicePublished && result.centralSubscribed
    }

    private var glyph: some View {
        Image(systemName: state.systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(stateColor)
            .frame(width: 30, height: 30)
            .background(Theme.statusWash(stateColor), in: Circle())
            .symbolEffect(.pulse, isActive: state == .running)
            .accessibilityHidden(true)
    }

    private var stateColor: Color {
        switch state {
        case .pending:    return Theme.tertiaryText
        case .running:    return Theme.accent
        case .rejected:   return Theme.danger
        case .published:  return Theme.warning
        case .subscribed: return Theme.accent
        case .confirmed:  return Theme.success
        }
    }

    private func failureReasonBlock(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Failure reason, verbatim")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.danger)
            Text(reason)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.statusWash(Theme.danger), in: RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Failure reason: \(reason)")
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var accessibilityValue: String {
        var parts = [state.title]
        if let reason = result?.failureReason { parts.append("Failure reason: \(reason)") }
        if let result, result.centralSubscribed {
            parts.append("Subscribed reports: \(HIDDiagnostics.describe(result.subscribedReports))")
        }
        if isAdopted { parts.append("Currently in use") }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Log line

private struct LogLine: View {
    let entry: HIDLogEntry

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.formatter.string(from: entry.timestamp))
                .foregroundStyle(Theme.tertiaryText)
            Text(entry.message)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption2.monospaced())
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.level.rawValue) at \(Self.formatter.string(from: entry.timestamp)): \(entry.message)")
    }

    private var color: Color {
        switch entry.level {
        case .info:    return Theme.primaryText
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .failure: return Theme.danger
        }
    }
}

// MARK: - Preview

#Preview("Diagnostics — fresh") {
    NavigationStack {
        DiagnosticsView(
            diagnostics: HIDDiagnostics(manager: StubHIDSender(), timing: .fast),
            settings: AppSettings(defaults: .previewDefaults),
            isRadioStubbed: true
        )
    }
}

/// A stub pre-loaded with the kind of log the real manager produces, so the
/// console and its colour coding can be reviewed without a device.
@MainActor
private func previewStubWithLog() -> StubHIDSender {
    let stub = StubHIDSender()
    stub.log = [
        HIDLogEntry(level: .info, message: "CBPeripheralManager did update state: poweredOn"),
        HIDLogEntry(level: .failure, message: "add(_:) raised NSInternalInconsistencyException: Descriptors with UUID 2908 are not supported"),
        HIDLogEntry(level: .warning, message: "Falling back to a single report characteristic"),
        HIDLogEntry(level: .success, message: "Central 'Sean's Mac mini' subscribed to 2A4D")
    ]
    return stub
}

#Preview("Diagnostics — with log") {
    NavigationStack {
        DiagnosticsView(
            diagnostics: HIDDiagnostics(manager: previewStubWithLog(), timing: .fast),
            settings: AppSettings(defaults: .previewDefaults),
            isRadioStubbed: true
        )
    }
}
