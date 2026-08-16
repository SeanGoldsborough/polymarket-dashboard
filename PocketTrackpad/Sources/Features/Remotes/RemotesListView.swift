//
//  RemotesListView.swift
//  PocketTrackpad
//
//  The Remotes tab root: the library list, reorder/delete via EditButton,
//  swipe actions for duplicate/share/delete, and the entry point to the
//  editor.
//
//  This view does not create its own `NavigationStack` — the tab host owns
//  navigation, the same way the General and About tabs work. Previews supply
//  one.
//

import SwiftUI
import UniformTypeIdentifiers

public struct RemotesListView: View {
    private let store: RemoteStore
    private let sender: any HIDSending
    private let settings: AppSettings

    @State private var editorTarget: EditorTarget?
    @State private var isImporting = false
    @State private var importFailure: String?

    public init(store: RemoteStore, sender: any HIDSending, settings: AppSettings) {
        self.store = store
        self.sender = sender
        self.settings = settings
    }

    private enum EditorTarget: Identifiable {
        case create
        case edit(Remote)

        var id: String {
            switch self {
            case .create:          return "create"
            case .edit(let remote): return remote.id.uuidString
            }
        }
    }

    public var body: some View {
        List {
            if let loadFailure = store.loadFailure {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your saved remotes could not be read")
                            Text(loadFailure)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Section {
                ForEach(store.remotes) { remote in
                    NavigationLink {
                        RemoteDetailView(remote: remote, sender: sender, settings: settings)
                    } label: {
                        RemoteRow(remote: remote)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            store.delete(remote)
                        } label: {
                            Label(remote.isBuiltIn ? "Hide" : "Delete",
                                  systemImage: remote.isBuiltIn ? "eye.slash" : "trash")
                        }

                        Button {
                            store.duplicate(remote)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .tint(.indigo)

                        ShareLink(
                            item: remote,
                            preview: SharePreview(remote.name,
                                                  image: Image(systemName: remote.symbolName))
                        ) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if remote.isBuiltIn {
                            Button {
                                let copy = store.duplicate(remote)
                                editorTarget = .edit(copy)
                            } label: {
                                Label("Customise", systemImage: "square.and.pencil")
                            }
                            .tint(.orange)
                        } else {
                            Button {
                                editorTarget = .edit(remote)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                }
                .onMove { offsets, destination in
                    store.move(fromOffsets: offsets, toOffset: destination)
                }
                .onDelete { offsets in
                    store.delete(atOffsets: offsets)
                }

                Button {
                    editorTarget = .create
                } label: {
                    Label {
                        Text("Create Remote")
                    } icon: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .accessibilityLabel("Create remote")
                .accessibilityHint("Opens the remote editor with an empty remote")
            } footer: {
                Text("Swipe a remote for duplicate, share and delete. Built-in remotes can be hidden and restored, but not deleted.")
            }

            if !store.hiddenBuiltIns.isEmpty {
                Section {
                    ForEach(store.hiddenBuiltIns) { remote in
                        HStack {
                            Label(remote.name, systemImage: remote.symbolName)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") {
                                store.restoreBuiltIn(id: remote.id)
                            }
                            .buttonStyle(.borderless)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(remote.name), hidden")
                        .accessibilityAction(named: "Restore") {
                            store.restoreBuiltIn(id: remote.id)
                        }
                    }
                } header: {
                    Text("Hidden Built-In Remotes").textCase(.uppercase)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Remotes")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import Remote…", systemImage: "square.and.arrow.down")
                    }

                    if !store.hiddenBuiltIns.isEmpty {
                        Button {
                            store.restoreAllBuiltIns()
                        } label: {
                            Label("Restore All Built-Ins", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }

            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(item: $editorTarget) { target in
            switch target {
            case .create:
                RemoteEditorView(remote: store.makeDraft(), store: store)
            case .edit(let remote):
                RemoteEditorView(remote: remote, store: store)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(
            "Could Not Import Remote",
            isPresented: Binding(
                get: { importFailure != nil },
                set: { if !$0 { importFailure = nil } }
            ),
            presenting: importFailure
        ) { _ in
            Button("OK", role: .cancel) { importFailure = nil }
        } message: { message in
            Text(message)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            // Files chosen through the picker live outside the app's sandbox.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            try store.importRemote(from: data)
        } catch {
            importFailure = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct RemoteRow: View {
    let remote: Remote

    private var buttonCountDescription: String {
        remote.buttons.count == 1 ? "1 button" : "\(remote.buttons.count) buttons"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: remote.symbolName)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(remote.name)
                Text(buttonCountDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(remote.name)
        .accessibilityValue(buttonCountDescription)
    }
}

// MARK: - Preview

#Preview("Remotes") {
    NavigationStack {
        RemotesListView(
            store: RemoteStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("RemotesPreview", isDirectory: true)),
            sender: StubHIDSender(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "preview.remotes") ?? .standard)
        )
    }
}
