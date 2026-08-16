//
//  RemoteEditorView.swift
//  PocketTrackpad
//
//  Create and edit a remote: name, symbol, layout, and the button list, with a
//  live preview of the resulting grid.
//
//  The action editor is split across three types on purpose. A view that
//  presents itself — directly or through a sheet — makes its own body's type
//  infinitely recursive and will not compile, so `RemoteActionEditorView`
//  (which offers every kind, including `.sequence`) delegates the four leaf
//  kinds to `LeafActionEditor`, and edits a sequence's steps by presenting
//  that same leaf editor. Sequences are therefore one level deep, which is
//  also the only depth anyone can reason about on a remote button.
//

import SwiftUI

@MainActor
public struct RemoteEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let store: RemoteStore
    private let isNew: Bool
    @State private var draft: Remote

    public init(remote: Remote, store: RemoteStore, isNew: Bool = false) {
        self.store = store
        self.isNew = isNew
        _draft = State(initialValue: remote)
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        NavigationStack {
            Form {
                nameSection
                layoutSection
                buttonsSection
                previewSection
            }
            .navigationTitle(isNew ? "New Remote" : "Edit Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        Section {
            TextField("Name", text: $draft.name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .accessibilityLabel("Remote name")

            NavigationLink {
                SymbolPickerView(selection: $draft.symbolName)
            } label: {
                HStack {
                    Text("Symbol")
                    Spacer()
                    Image(systemName: draft.symbolName)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Symbol")
            .accessibilityValue(SymbolCatalogue.readableName(for: draft.symbolName))
        } header: {
            Text("Remote").textCase(.uppercase)
        }
    }

    private var layoutSection: some View {
        Section {
            Picker(selection: $draft.layout) {
                ForEach(RemoteLayout.allCases) { layout in
                    Text(layout.shortTitle).tag(layout)
                }
            } label: {
                Text("Columns")
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Grid columns")
            .accessibilityValue(draft.layout.title)
        } header: {
            Text("Layout").textCase(.uppercase)
        } footer: {
            Text("Buttons flow left to right. A wide button takes two columns.")
        }
    }

    private var buttonsSection: some View {
        Section {
            ForEach($draft.buttons) { $button in
                NavigationLink {
                    RemoteButtonEditorView(button: $button, columns: draft.columns)
                } label: {
                    ButtonRow(button: button)
                }
            }
            .onMove { offsets, destination in
                draft.buttons.move(fromOffsets: offsets, toOffset: destination)
            }
            .onDelete { offsets in
                draft.buttons.remove(atOffsets: offsets)
            }

            Button {
                draft.buttons.append(
                    RemoteButton(
                        title: "New Button",
                        symbolName: nil,
                        action: .key(usage: HIDKeyCode.return, modifiers: .none),
                        span: 1
                    )
                )
            } label: {
                Label("Add Button", systemImage: "plus.circle.fill")
            }
            .accessibilityHint("Adds a button to the end of the grid")
        } header: {
            HStack {
                Text("Buttons").textCase(.uppercase)
                Spacer()
                EditButton()
                    .textCase(nil)
                    .font(.body)
            }
        } footer: {
            if draft.buttons.isEmpty {
                Text("A remote with no buttons will show an empty grid.")
            } else {
                Text("Drag to reorder, swipe to delete. Tap a button to change what it sends.")
            }
        }
    }

    private var previewSection: some View {
        Section {
            if draft.buttons.isEmpty {
                Text("Nothing to preview yet.")
                    .foregroundStyle(.secondary)
            } else {
                RemoteGridPreview(remote: draft)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Preview of \(trimmedName.isEmpty ? "this remote" : trimmedName)")
            }
        } header: {
            Text("Preview").textCase(.uppercase)
        }
    }

    // MARK: Saving

    private func save() {
        var remote = draft
        remote.name = trimmedName.isEmpty ? "Remote" : trimmedName
        // A built-in is never edited in place; the list duplicates it first.
        remote.isBuiltIn = false
        store.save(remote)
        dismiss()
    }
}

// MARK: - Button row

private struct ButtonRow: View {
    let button: RemoteButton

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let symbolName = button.symbolName {
                    Image(systemName: symbolName)
                } else {
                    Text(button.title.prefix(2))
                        .font(.caption.weight(.semibold))
                }
            }
            .frame(width: 26, height: 26)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(button.title)
                Text(button.action.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if button.span > 1 {
                Text("Wide")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(button.title)
        .accessibilityValue("\(button.action.summary)\(button.span > 1 ? ", wide" : "")")
    }
}

// MARK: - Grid preview

/// Non-interactive rendering of a remote's grid, used by the editor. Shares
/// `Remote.gridRows` with the real screen so what you see here is what you get.
struct RemoteGridPreview: View {
    let remote: Remote

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(remote.gridRows.enumerated()), id: \.offset) { pair in
                GridRow {
                    ForEach(pair.element) { button in
                        cell(for: button)
                            .gridCellColumns(button.effectiveSpan(in: remote.columns))
                    }
                }
            }
        }
    }

    private func cell(for button: RemoteButton) -> some View {
        VStack(spacing: 2) {
            if let symbolName = button.symbolName {
                Image(systemName: symbolName)
                    .font(.callout)
            }
            Text(button.title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(button.title)
    }
}

// MARK: - Button editor

struct RemoteButtonEditorView: View {
    @Binding var button: RemoteButton
    let columns: Int

    private var spanBinding: Binding<Int> {
        Binding(
            get: { button.span },
            set: { button.span = min(max($0, 1), 2) }
        )
    }

    private var symbolBinding: Binding<String> {
        Binding(
            get: { button.symbolName ?? "" },
            set: { button.symbolName = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $button.title)
                    .accessibilityLabel("Button title")

                NavigationLink {
                    SymbolPickerView(selection: symbolBinding, allowsNone: true)
                } label: {
                    HStack {
                        Text("Symbol")
                        Spacer()
                        if let symbolName = button.symbolName {
                            Image(systemName: symbolName)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        } else {
                            Text("None").foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityLabel("Symbol")
                .accessibilityValue(button.symbolName.map(SymbolCatalogue.readableName(for:)) ?? "None")
            } header: {
                Text("Appearance").textCase(.uppercase)
            }

            Section {
                Picker(selection: spanBinding) {
                    Text("Normal").tag(1)
                    Text("Wide").tag(2)
                } label: {
                    Text("Width")
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Button width")
                .accessibilityValue(button.span > 1 ? "Wide, two columns" : "Normal, one column")
                .disabled(columns < 2)
            } header: {
                Text("Size").textCase(.uppercase)
            } footer: {
                Text(columns < 2
                     ? "A one-column grid has no room for a wide button."
                     : "A wide button occupies two of the grid's \(columns) columns.")
            }

            Section {
                NavigationLink {
                    RemoteActionEditorView(action: $button.action)
                } label: {
                    HStack {
                        Label(button.action.kind.title, systemImage: button.action.kind.symbolName)
                        Spacer()
                        Text(button.action.summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityLabel("Action")
                .accessibilityValue("\(button.action.kind.title), \(button.action.summary)")
            } header: {
                Text("Action").textCase(.uppercase)
            }
        }
        .navigationTitle(button.title.isEmpty ? "Button" : button.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Action editor

/// Picks the kind of action and edits it. Sequence steps are edited with the
/// leaf editor in a sheet — see the note at the top of this file.
struct RemoteActionEditorView: View {
    @Binding var action: RemoteAction

    @State private var stepEditing: StepEditing?
    @State private var newStep: RemoteAction = .consumer(.playPause)

    /// Both step sheets share one presentation state. Two `.sheet` modifiers on
    /// the same view race each other; one modifier with a case per sheet does
    /// not.
    private enum StepEditing: Identifiable {
        case existing(Int)
        case new

        var id: String {
            switch self {
            case .existing(let index): return "step-\(index)"
            case .new:                 return "step-new"
            }
        }
    }

    private var kindBinding: Binding<RemoteActionKind> {
        Binding(
            get: { action.kind },
            set: { newKind in
                guard newKind != action.kind else { return }
                action = .placeholder(for: newKind)
            }
        )
    }

    private var stepsBinding: Binding<[RemoteAction]> {
        Binding(
            get: { if case .sequence(let steps) = action { return steps } else { return [] } },
            set: { action = .sequence($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: kindBinding) {
                    ForEach(RemoteActionKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbolName).tag(kind)
                    }
                } label: {
                    Text("Type")
                }
                .accessibilityLabel("Action type")
                .accessibilityValue(action.kind.title)
            } footer: {
                Text(action.kind.explanation)
            }

            if case .sequence = action {
                sequenceSections
            } else {
                LeafActionEditor(action: $action)
            }
        }
        .navigationTitle("Action")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $stepEditing) { editing in
            NavigationStack {
                switch editing {
                case .existing(let index):
                    Form {
                        LeafActionEditor(action: stepBinding(at: index))
                    }
                    .navigationTitle("Step \(index + 1)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { stepEditing = nil }
                        }
                    }

                case .new:
                    Form {
                        LeafActionEditor(action: $newStep)
                    }
                    .navigationTitle("New Step")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { stepEditing = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                var steps = stepsBinding.wrappedValue
                                steps.append(newStep)
                                stepsBinding.wrappedValue = steps
                                newStep = .consumer(.playPause)
                                stepEditing = nil
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sequenceSections: some View {
        Section {
            let steps = stepsBinding.wrappedValue
            ForEach(Array(steps.enumerated()), id: \.offset) { pair in
                Button {
                    stepEditing = .existing(pair.offset)
                } label: {
                    HStack {
                        Text("\(pair.offset + 1).")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(pair.element.kind.title)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Text(pair.element.summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(pair.offset + 1), \(pair.element.kind.title)")
                .accessibilityValue(pair.element.summary)
                .accessibilityHint("Opens this step for editing")
            }
            .onMove { offsets, destination in
                var steps = stepsBinding.wrappedValue
                steps.move(fromOffsets: offsets, toOffset: destination)
                stepsBinding.wrappedValue = steps
            }
            .onDelete { offsets in
                var steps = stepsBinding.wrappedValue
                steps.remove(atOffsets: offsets)
                stepsBinding.wrappedValue = steps
            }

            Button {
                stepEditing = .new
            } label: {
                Label("Add Step", systemImage: "plus.circle.fill")
            }
        } header: {
            HStack {
                Text("Steps").textCase(.uppercase)
                Spacer()
                EditButton().textCase(nil).font(.body)
            }
        } footer: {
            Text("Steps run in order, each pressed and released before the next. Steps cannot themselves be sequences.")
        }
    }

    /// Bounds-checked so a step deleted while its sheet is open cannot trap.
    private func stepBinding(at index: Int) -> Binding<RemoteAction> {
        Binding(
            get: {
                let steps = stepsBinding.wrappedValue
                return steps.indices.contains(index) ? steps[index] : .text("")
            },
            set: { newValue in
                var steps = stepsBinding.wrappedValue
                guard steps.indices.contains(index) else { return }
                steps[index] = newValue
                stepsBinding.wrappedValue = steps
            }
        )
    }
}

// MARK: - Leaf action editor

/// Editor for the four non-recursive action kinds. Emits `Section`s, so it is
/// always placed inside a `Form` or `List`.
struct LeafActionEditor: View {
    @Binding var action: RemoteAction

    private var consumerBinding: Binding<ConsumerUsage> {
        Binding(
            get: { if case .consumer(let usage) = action { return usage } else { return .playPause } },
            set: { action = .consumer($0) }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { if case .text(let string) = action { return string } else { return "" } },
            set: { action = .text($0) }
        )
    }

    private var mouseBinding: Binding<UInt8> {
        Binding(
            get: { if case .mouse(let buttons) = action { return buttons.rawValue } else { return MouseButtons.left.rawValue } },
            set: { action = .mouse(MouseButtons(rawValue: $0)) }
        )
    }

    private var keyUsage: UInt8 {
        if case .key(let usage, _) = action { return usage }
        return HIDKeyCode.return
    }

    private var keyModifiers: KeyModifiers {
        if case .key(_, let modifiers) = action { return modifiers }
        return .none
    }

    private func modifierBinding(_ modifier: KeyModifiers) -> Binding<Bool> {
        Binding(
            get: { keyModifiers.contains(modifier) },
            set: { isOn in
                var modifiers = keyModifiers
                if isOn { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
                action = .key(usage: keyUsage, modifiers: modifiers)
            }
        )
    }

    private var keyBinding: Binding<UInt8> {
        Binding(
            get: { keyUsage },
            set: { action = .key(usage: $0, modifiers: keyModifiers) }
        )
    }

    var body: some View {
        switch action {
        case .consumer:
            Section {
                Picker(selection: consumerBinding) {
                    ForEach(ConsumerUsage.allCases, id: \.self) { usage in
                        Label(usage.remoteDisplayName, systemImage: usage.remoteSymbolName)
                            .tag(usage)
                    }
                } label: {
                    Text("Media Key")
                }
                .accessibilityLabel("Media key")
                .accessibilityValue(consumerBinding.wrappedValue.remoteDisplayName)
            } footer: {
                Text("Sent on the consumer page. If your Mac only accepts the boot-protocol layout, these fall back to the equivalent function key.")
            }

        case .key:
            Section {
                ForEach(KeyModifiers.editableModifiers) { entry in
                    Toggle(isOn: modifierBinding(entry.modifier)) {
                        HStack {
                            Text(entry.glyph)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(entry.name)
                        }
                    }
                    .accessibilityLabel(entry.name)
                    .accessibilityValue(keyModifiers.contains(entry.modifier) ? "Held" : "Not held")
                }
            } header: {
                Text("Modifiers").textCase(.uppercase)
            }

            Section {
                NavigationLink {
                    KeyChooserView(selection: keyBinding)
                } label: {
                    HStack {
                        Text("Key")
                        Spacer()
                        Text(RemoteAction.keyName(for: keyUsage))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Key")
                .accessibilityValue(RemoteAction.keyName(for: keyUsage))
            } header: {
                Text("Key").textCase(.uppercase)
            } footer: {
                Text(recordedCombinationDescription)
            }

        case .text:
            Section {
                TextField("Text to type", text: textBinding, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Text to type")
            } header: {
                Text("Text").textCase(.uppercase)
            } footer: {
                Text("Typed one keystroke at a time. Characters with no key on a US layout are skipped.")
            }

        case .mouse:
            Section {
                Picker(selection: mouseBinding) {
                    ForEach(MouseButtons.editableChoices, id: \.rawValue) { buttons in
                        Text(buttons.remoteDisplayName).tag(buttons.rawValue)
                    }
                } label: {
                    Text("Button")
                }
                .pickerStyle(.inline)
                .accessibilityLabel("Mouse button")
            } header: {
                Text("Mouse").textCase(.uppercase)
            }

        case .sequence:
            // Sequences are handled a level up; a leaf editor never sees one.
            Section {
                Text("Sequences are edited from the action screen.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordedCombinationDescription: String {
        let glyphs = keyModifiers.shortcutDescription
        let name = RemoteAction.keyName(for: keyUsage)
        return glyphs.isEmpty ? "Sends \(name)." : "Sends \(glyphs)\(name)."
    }
}

// MARK: - Key chooser

struct KeyChoice: Identifiable, Hashable {
    let usage: UInt8
    var id: UInt8 { usage }
    var name: String { RemoteAction.keyName(for: usage) }
}

enum KeyCatalogue {
    static let navigation: [KeyChoice] = [
        KeyChoice(usage: HIDKeyCode.return),
        KeyChoice(usage: HIDKeyCode.escape),
        KeyChoice(usage: HIDKeyCode.space),
        KeyChoice(usage: HIDKeyCode.tab),
        KeyChoice(usage: HIDKeyCode.delete),
        KeyChoice(usage: HIDKeyCode.upArrow),
        KeyChoice(usage: HIDKeyCode.downArrow),
        KeyChoice(usage: HIDKeyCode.leftArrow),
        KeyChoice(usage: HIDKeyCode.rightArrow),
        KeyChoice(usage: HIDKeyCode.pageUp),
        KeyChoice(usage: HIDKeyCode.pageDown),
        KeyChoice(usage: HIDKeyCode.home),
        KeyChoice(usage: HIDKeyCode.end)
    ]

    /// a…z are contiguous from usage 0x04, 1…0 from 0x1E, F1…F12 from 0x3A.
    static let letters: [KeyChoice] = (0x04...0x1D).map { KeyChoice(usage: UInt8($0)) }
    static let numbers: [KeyChoice] = (0x1E...0x27).map { KeyChoice(usage: UInt8($0)) }
    static let functionKeys: [KeyChoice] = (0x3A...0x45).map { KeyChoice(usage: UInt8($0)) }

    static let keypad: [KeyChoice] = [
        KeyChoice(usage: HIDKeyCode.keypad0),
        KeyChoice(usage: HIDKeyCode.keypad1),
        KeyChoice(usage: HIDKeyCode.keypad2),
        KeyChoice(usage: HIDKeyCode.keypad3),
        KeyChoice(usage: HIDKeyCode.keypad4),
        KeyChoice(usage: HIDKeyCode.keypad5),
        KeyChoice(usage: HIDKeyCode.keypad6),
        KeyChoice(usage: HIDKeyCode.keypad7),
        KeyChoice(usage: HIDKeyCode.keypad8),
        KeyChoice(usage: HIDKeyCode.keypad9),
        KeyChoice(usage: HIDKeyCode.keypadPeriod),
        KeyChoice(usage: HIDKeyCode.keypadEnter),
        KeyChoice(usage: HIDKeyCode.keypadPlus),
        KeyChoice(usage: HIDKeyCode.keypadMinus),
        KeyChoice(usage: HIDKeyCode.keypadAsterisk),
        KeyChoice(usage: HIDKeyCode.keypadSlash)
    ]

    static let groups: [KeyGroup] = [
        KeyGroup(title: "Navigation", choices: navigation),
        KeyGroup(title: "Letters", choices: letters),
        KeyGroup(title: "Numbers", choices: numbers),
        KeyGroup(title: "Function Keys", choices: functionKeys),
        KeyGroup(title: "Keypad", choices: keypad)
    ]
}

/// A named run of keys in the chooser. A struct rather than a tuple: `ForEach`
/// needs an `id`, and Swift key paths cannot address tuple elements. Declared
/// at file scope rather than nested, so it does not shadow `SwiftUI.Group`.
struct KeyGroup: Identifiable {
    let title: String
    let choices: [KeyChoice]

    var id: String { title }
}

struct KeyChooserView: View {
    @Binding var selection: UInt8
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(KeyCatalogue.groups) { group in
                Section {
                    ForEach(group.choices) { choice in
                        Button {
                            selection = choice.usage
                            dismiss()
                        } label: {
                            HStack {
                                Text(choice.name)
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                if choice.usage == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityLabel(choice.name)
                        .accessibilityAddTraits(choice.usage == selection ? [.isButton, .isSelected] : .isButton)
                    }
                } header: {
                    Text(group.title).textCase(.uppercase)
                }
            }
        }
        .navigationTitle("Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Symbol picker

enum SymbolCatalogue {
    /// A curated set — the full SF Symbols catalogue is 5,000 glyphs and
    /// browsing it is a worse experience than typing a name. These are the
    /// ones that mean something on a remote.
    static let symbols: [String] = [
        // Transport
        "play.fill", "pause.fill", "playpause.fill", "stop.fill",
        "backward.fill", "forward.fill", "backward.end.fill", "forward.end.fill",
        "gobackward.10", "goforward.10", "shuffle", "repeat",
        // Volume
        "speaker.fill", "speaker.wave.1.fill", "speaker.wave.3.fill", "speaker.slash.fill",
        // Navigation
        "chevron.up", "chevron.down", "chevron.left", "chevron.right",
        "arrow.up", "arrow.down", "arrow.left", "arrow.right",
        "house.fill", "circle.inset.filled", "return", "escape",
        // Screens and devices
        "tv", "display", "airplayvideo", "appletv",
        "rectangle.on.rectangle.angled", "play.rectangle.fill", "square.grid.2x2", "number.square.fill",
        // Utility
        "power", "moon.fill", "sun.max.fill", "magnifyingglass",
        "delete.left.fill", "plus", "minus", "keyboard",
        "cursorarrow.click", "cursorarrow.rays", "text.cursor", "list.number"
    ]

    /// Turns "speaker.wave.3.fill" into "speaker wave 3 fill" so VoiceOver
    /// reads a symbol name rather than spelling punctuation.
    static func readableName(for symbol: String) -> String {
        symbol.replacingOccurrences(of: ".", with: " ")
    }
}

struct SymbolPickerView: View {
    @Binding var selection: String
    var allowsNone: Bool = false

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 56, maximum: 80), spacing: 12)]

    var body: some View {
        ScrollView {
            if allowsNone {
                Button {
                    selection = ""
                    dismiss()
                } label: {
                    Label("No Symbol", systemImage: "nosign")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.cardBackground)
                        )
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .accessibilityAddTraits(selection.isEmpty ? [.isButton, .isSelected] : .isButton)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(SymbolCatalogue.symbols, id: \.self) { symbol in
                    Button {
                        selection = symbol
                        dismiss()
                    } label: {
                        Image(systemName: symbol)
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(symbol == selection
                                          ? Color.accentColor.opacity(0.2)
                                          : Theme.cardBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(symbol == selection ? Color.accentColor : .clear, lineWidth: 2)
                            )
                    }
                    .accessibilityLabel(SymbolCatalogue.readableName(for: symbol))
                    .accessibilityAddTraits(symbol == selection ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
        .navigationTitle("Symbol")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Previews

#Preview("Editor — New") {
    RemoteEditorView(
        remote: Remote(name: "Studio", symbolName: "square.grid.2x2", buttons: [], layout: .grid3),
        store: RemoteStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteEditorPreview", isDirectory: true))
    )
}

#Preview("Editor — Existing") {
    RemoteEditorView(
        remote: {
            var copy = Remote.mediaRemote
            copy.id = UUID()
            copy.isBuiltIn = false
            copy.name = "My Media"
            return copy
        }(),
        store: RemoteStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteEditorPreview2", isDirectory: true))
    )
}
