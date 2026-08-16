//
//  ConnectionView.swift
//  PocketTrackpad
//
//  The device list: which Macs this iPhone has been paired with, which one is
//  live right now, and the button that puts the radio back on the air.
//
//  Presented inside `SettingsSheet`'s `NavigationStack`, so this view owns its
//  navigation title but no chrome of its own.
//

import SwiftUI

@MainActor
public struct ConnectionView: View {

    private let peripheral: any HIDPeripheralControlling
    private let settings: AppSettings

    @State private var startFailure: String?

    public init(peripheral: any HIDPeripheralControlling, settings: AppSettings) {
        self.peripheral = peripheral
        self.settings = settings
    }

    public var body: some View {
        List {
            headerSection

            if isAdvertising {
                advertisingSection
            }

            deviceSection

            actionSection
        }
        .listStyle(.insetGrouped)
        // The page behind the list is `Theme.pageBackground`, applied by the
        // sheet. Hiding the list's own background lets that show through so the
        // designed dark palette is not overpainted by the system grouped grey.
        .scrollContentBackground(.hidden)
        .navigationTitle("Connection")
        .animation(.easeInOut(duration: 0.25), value: isAdvertising)
        .animation(.easeInOut(duration: 0.25), value: peripheral.knownCentrals)
        .alert("Could not start advertising",
               isPresented: Binding(get: { startFailure != nil },
                                    set: { if !$0 { startFailure = nil } })) {
            Button("OK", role: .cancel) { startFailure = nil }
        } message: {
            Text(startFailure ?? "")
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(iconTint.gradient)
                    .frame(width: 88, height: 88)
                    .overlay {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: iconTint.opacity(0.28), radius: 10, x: 0, y: 5)
                    .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text("Device List")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Device list")
            .accessibilityValue(statusSubtitle)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var iconTint: Color {
        switch peripheral.connectionState {
        case .connected, .advertising:
            return Theme.accent
        case .poweredOff, .unauthorized, .unsupported, .failed:
            return Theme.danger
        case .idle:
            return Theme.secondaryText
        }
    }

    private var statusSubtitle: String {
        switch peripheral.connectionState {
        case .connected(let name):
            return "Connected to \(name ?? "a Mac")"
        case .advertising:
            return "Visible to nearby Macs"
        case .idle:
            return "Not advertising"
        case .poweredOff:
            return "Bluetooth is switched off"
        case .unauthorized:
            return "Bluetooth permission was denied in Settings"
        case .unsupported:
            return "This device cannot act as a Bluetooth keyboard"
        case .failed(let message):
            return message
        }
    }

    // MARK: Advertising

    private var isAdvertising: Bool {
        if case .advertising = peripheral.connectionState { return true }
        return false
    }

    private var advertisingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Waiting for a Mac to connect")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                }

                // Said plainly on purpose. iOS cannot initiate this pairing —
                // a peripheral advertises and waits — so the last step really
                // does have to happen on the Mac, and a vaguer sentence would
                // leave the user staring at a spinner that never resolves.
                Text("Open System Settings ▸ Bluetooth on your Mac and click Connect next to \u{201C}\(settings.advertisedName)\u{201D}.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Waiting for a Mac to connect")
            .accessibilityValue("On your Mac, open System Settings, then Bluetooth, and click Connect next to \(settings.advertisedName).")
        }
    }

    // MARK: Devices

    private var deviceSection: some View {
        Section("Paired Macs") {
            if peripheral.knownCentrals.isEmpty {
                emptyState
            } else {
                ForEach(peripheral.knownCentrals) { central in
                    deviceRow(central)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                peripheral.forget(central)
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                            .accessibilityLabel("Forget \(central.name)")
                        }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Devices Yet", systemImage: "laptopcomputer.slash")
        } description: {
            Text("Tap Add Device, then connect from your Mac. Paired Macs appear here and reconnect on their own.")
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
    }

    private func deviceRow(_ central: KnownCentral) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.title3)
                .foregroundStyle(isLive(central) ? Theme.accent : Theme.secondaryText)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(central.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if isPrimary(central) {
                        Image(systemName: "crown.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.warning)
                            .accessibilityHidden(true)
                    }
                }
                Text(detailText(for: central))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if isLive(central) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(central.name)
        .accessibilityValue(accessibilityValue(for: central))
        .accessibilityHint("Swipe left to forget this Mac.")
    }

    /// The first remembered central is the primary — the one the radio prefers
    /// when more than one known Mac is in range.
    private func isPrimary(_ central: KnownCentral) -> Bool {
        peripheral.knownCentrals.first?.id == central.id
    }

    private func isLive(_ central: KnownCentral) -> Bool {
        guard case .connected(let name) = peripheral.connectionState, let name else { return false }
        return name == central.name
    }

    private func detailText(for central: KnownCentral) -> String {
        if isLive(central) { return "Connected now" }
        let seen = central.lastSeen.formatted(.relative(presentation: .named))
        guard let topology = central.workingTopology else {
            return "Last seen \(seen)"
        }
        return "Last seen \(seen) · \(topology.summary)"
    }

    private func accessibilityValue(for central: KnownCentral) -> String {
        var parts: [String] = []
        if isPrimary(central) { parts.append("Primary device") }
        parts.append(isLive(central) ? "Connected" : "Not connected")
        parts.append(detailText(for: central))
        return parts.joined(separator: ". ")
    }

    // MARK: Actions

    private var actionSection: some View {
        Section {
            Button(isAdvertising ? "Stop Advertising" : "Add Device", action: toggleAdvertising)
                .buttonStyle(.primaryCapsule)
                .accessibilityLabel(isAdvertising ? "Stop advertising" : "Add device")
                .accessibilityHint(isAdvertising
                                   ? "Takes this iPhone off the air."
                                   : "Makes this iPhone discoverable so a Mac can connect to it.")
        } footer: {
            Text("Forgetting a Mac here only clears this iPhone's side. Remove the pairing on the Mac too, in System Settings ▸ Bluetooth.")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    }

    private func toggleAdvertising() {
        if isAdvertising {
            peripheral.stop()
            return
        }
        do {
            try peripheral.start(topology: settings.preferredTopology)
        } catch {
            // Verbatim: the exact rejection names which layout iOS refused, and
            // that string is the whole input to the Diagnostics screen.
            startFailure = error.localizedDescription
        }
    }
}

// MARK: - Previews

#Preview("Connection — connected") {
    NavigationStack {
        ConnectionView(peripheral: StubHIDSender(),
                       settings: AppSettings(defaults: .previewDefaults))
            .themedPage()
    }
}

#Preview("Connection — several Macs") {
    NavigationStack {
        ConnectionView(
            peripheral: StubHIDSender(
                connectionState: .connected(centralName: "Studio iMac"),
                knownCentrals: [
                    KnownCentral(id: UUID(), name: "Sean's Mac mini",
                                 lastSeen: .now.addingTimeInterval(-3_600),
                                 workingTopology: .perReportCharacteristic),
                    KnownCentral(id: UUID(), name: "Studio iMac",
                                 workingTopology: .bootProtocolOnly),
                    KnownCentral(id: UUID(), name: "MacBook Air",
                                 lastSeen: .now.addingTimeInterval(-86_400 * 3))
                ]
            ),
            settings: AppSettings(defaults: .previewDefaults)
        )
        .themedPage()
    }
}

#Preview("Connection — empty") {
    NavigationStack {
        ConnectionView(peripheral: StubHIDSender(connectionState: .idle, knownCentrals: []),
                       settings: AppSettings(defaults: .previewDefaults))
            .themedPage()
    }
}

#Preview("Connection — advertising") {
    NavigationStack {
        ConnectionView(peripheral: StubHIDSender(connectionState: .advertising, knownCentrals: []),
                       settings: AppSettings(defaults: .previewDefaults))
            .themedPage()
    }
}
