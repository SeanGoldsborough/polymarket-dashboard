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
//  Second rule, added after the HID core team's review: this screen must not
//  overclaim. A green row that depends on an unverifiable assumption is shown
//  green *with its qualifications attached*, never green alone. The three
//  things that can make a green row a lie — a cached GATT database on the Mac,
//  a silently dropped 0x2908 descriptor, and the negative inference behind
//  "round trip confirmed" — are all on screen, not buried in the export.
//

import SwiftUI

@MainActor
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

                gattCacheWarningCard
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
                .accessibilityHint("Exports a plain-text report of every probe result, its caveats, and the radio log.")
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
            Text(adoptionWarning(for: topology))
        }
        .onDisappear {
            // Leaving the screen must not leave the radio cycling through
            // topologies in the background.
            diagnostics.cancel()
        }
    }

    private func adoptionWarning(for topology: ReportTopology) -> String {
        var message = topology.summary + "\n\n"
        if let result = diagnostics.result(for: topology), !result.qualifications.isEmpty {
            message += "This result is qualified:\n"
            for qualification in result.qualifications {
                message += "• \(qualification)\n"
            }
            message += "\n"
        }
        message += "The app will publish this layout to every Mac from now on. "
            + "A probe that passed once is not a guarantee — you can change this again at any time."
        return message
    }

    // MARK: The warning that invalidates sweeps

    /// Deliberately the first thing on screen, above the instructions.
    ///
    /// A sweep against a Mac that has already bonded with this iPhone can
    /// measure probe 1's service layout for probes 2 and 3, which does not
    /// merely add noise — it can invert the ranking and make the harness
    /// recommend a layout that has never actually worked.
    private var gattCacheWarningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                Text("A sweep is only valid on an unpaired Mac")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
            }

            Text(HIDDiagnostics.gattCacheWarning)
                .font(.caption)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Text("Probe one layout at a time using the button on each row below — a single probe against a Mac that has never paired with this iPhone is the only fully trustworthy measurement.")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Theme.statusWash(Theme.warning), in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Important: a sweep is only valid on an unpaired Mac")
        .accessibilityValue(HIDDiagnostics.gattCacheWarning)
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
                text: "On the Mac, open System Settings › Bluetooth. If this iPhone is already listed, remove it — otherwise the Mac will keep using the service layout it cached the first time."
            )
            instructionStep(
                number: 2,
                text: "Start a probe. Each layout advertises for about \(HIDDiagnostics.describe(diagnostics.timing.subscriptionWindow))."
            )
            instructionStep(
                number: 3,
                text: "When \"\(settings.advertisedName)\" appears in the Mac's device list, click Connect. Nothing can be measured until you do — the peripheral cannot make a Mac pair with it."
            )
            instructionStep(
                number: 4,
                text: "Remove the device on the Mac again before probing the next layout."
            )
            instructionStep(
                number: 5,
                text: "A row that reaches Confirmed still proves only that the Mac subscribed and did not hang up. Watch the Mac's cursor to confirm reports actually arrive."
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
            footer: runFooter
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
                Button("Run All Probes") { diagnostics.startSweep() }
                    .buttonStyle(.primaryCapsule)
                    .accessibilityHint("Tries each report layout in turn. Only trustworthy on a Mac that has never paired with this iPhone.")

                Text("Sweeping all three in one go is convenient but only valid on an unpaired Mac. Prefer the per-row probe buttons.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let central = diagnostics.centralDisplayName {
                Divider().overlay(Theme.separator)
                HStack {
                    Text("Connected to")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Text(central)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                }
                .accessibilityElement(children: .combine)
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

    private var runFooter: String? {
        if diagnostics.lastRunWasCancelled {
            return "The last run was cancelled, so the results below are incomplete."
        }
        switch diagnostics.lastRunScope {
        case .none:
            return nil
        case .sweep:
            return "Last run: full sweep. Rows may have been measured against a cached service layout if this Mac was already paired."
        case .single(let topology):
            return "Last run: single probe of \(topology.rawValue). The other rows are from earlier runs or were never measured."
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
                ForEach(Array(ReportTopology.allCases.enumerated()), id: \.element) { pair in
                    if pair.offset > 0 {
                        Divider().overlay(Theme.separator).padding(.leading, 16)
                    }
                    ResultRow(
                        topology: pair.element,
                        state: diagnostics.state(for: pair.element),
                        result: diagnostics.result(for: pair.element),
                        isAdopted: settings.preferredTopology == pair.element,
                        isBusy: diagnostics.isRunning,
                        onProbe: { diagnostics.startProbe(pair.element) },
                        onAdopt: { pendingAdoption = pair.element }
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

@MainActor
private struct ResultRow: View {
    let topology: ReportTopology
    let state: HIDDiagnostics.ProbeState
    let result: HIDDiagnostics.ProbeResult?
    let isAdopted: Bool
    let isBusy: Bool
    let onProbe: () -> Void
    let onAdopt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let reason = result?.failureReason {
                failureReasonBlock(reason)
            }

            if let result, result.publishOutcome == .confirmed, result.centralSubscribed {
                detailLine(
                    "Subscribed reports",
                    HIDDiagnostics.describe(result.subscribedReports)
                )
                detailLine(
                    "Probe reports",
                    result.roundTripConfirmed ? "delivered, link held" : "sent, but the link did not hold"
                )
            }

            if let qualifications = result?.qualifications, !qualifications.isEmpty {
                qualificationsBlock(qualifications)
            }

            if let notes = result?.notes, !notes.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { pair in
                            Text("• \(pair.element)")
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

            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(topology.rawValue)
        .accessibilityValue(accessibilityValue)
    }

    private var header: some View {
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
                HStack(spacing: 6) {
                    Text(state.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(stateColor)
                    if hasQualifications, !state.isFailure {
                        // A qualified pass must never read as a clean pass at a
                        // glance — the glyph alone would say "green".
                        Text("— qualified")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.warning)
                    }
                }
                if let measuredAt = result?.measuredAt {
                    Text("Measured \(Self.measuredFormatter.string(from: measuredAt))")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onProbe) {
                Label("Probe only this layout", systemImage: "play.circle")
            }
            .buttonStyle(.secondaryCapsule)
            .disabled(isBusy)
            .accessibilityHint("Runs a single probe of \(topology.rawValue). This is the only measurement a cached GATT database cannot corrupt.")

            if canAdopt {
                Button("Use this", action: onAdopt)
                    .buttonStyle(.secondaryCapsule)
                    .accessibilityHint("Makes \(topology.rawValue) the layout the app publishes.")
            }
        }
    }

    private var hasQualifications: Bool {
        !(result?.qualifications.isEmpty ?? true)
    }

    /// A row is adoptable once its publish was *confirmed* and it attracted a
    /// subscriber. A merely-unresolved or asynchronously-refused publish is
    /// never offered, however green the rest of the row looks.
    private var canAdopt: Bool {
        guard !isAdopted, let result else { return false }
        return result.publishOutcome == .confirmed && result.centralSubscribed
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
        case .pending:                return Theme.tertiaryText
        case .running:                return Theme.accent
        case .rejected:               return Theme.danger
        case .rejectedAsynchronously: return Theme.danger
        case .unresolved:             return Theme.warning
        case .published:              return Theme.warning
        case .subscribed:             return Theme.accent
        case .confirmed:              return Theme.success
        }
    }

    private func failureReasonBlock(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state == .rejectedAsynchronously
                 ? "Refused asynchronously in didAdd, verbatim"
                 : "Failure reason, verbatim")
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

    /// Reasons this row is not an unqualified pass. Shown inline, not behind a
    /// disclosure: a caveat the reader has to go looking for is a caveat that
    /// does not exist.
    private func qualificationsBlock(_ qualifications: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not an unqualified pass", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.warning)
            ForEach(Array(qualifications.enumerated()), id: \.offset) { pair in
                Text(pair.element)
                    .font(.caption)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.statusWash(Theme.warning), in: RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Not an unqualified pass. \(qualifications.joined(separator: ". "))")
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
        if let qualifications = result?.qualifications, !qualifications.isEmpty {
            parts.append("Not an unqualified pass. \(qualifications.joined(separator: ". "))")
        }
        if isAdopted { parts.append("Currently in use") }
        return parts.joined(separator: ". ")
    }

    @MainActor private static let measuredFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Log line

@MainActor
private struct LogLine: View {
    let entry: HIDLogEntry

    /// Explicitly main-actor isolated: `DateFormatter` is not `Sendable`, and
    /// this is only ever touched from `body`.
    @MainActor private static let formatter: DateFormatter = {
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
        HIDLogEntry(level: .success, message: "Published 00001812-0000-1000-8000-00805F9B34FB."),
        HIDLogEntry(level: .failure, message: "didAdd rejected 180A: The specified UUID is not allowed for this operation.")
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
