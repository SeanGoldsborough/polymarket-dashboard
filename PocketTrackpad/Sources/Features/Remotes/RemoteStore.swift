//
//  RemoteStore.swift
//  PocketTrackpad
//
//  The user's remote library. Persisted as a single JSON document in
//  Application Support rather than UserDefaults: a remote with a hundred
//  buttons and long `.text` payloads is a document, not a preference, and
//  UserDefaults is loaded wholesale on every launch.
//
//  Built-in remotes are not stored — they are compiled in and merged at read
//  time, so a shipped remote gaining a button in a future release reaches
//  users who already have a library on disk. Deleting a built-in records its
//  ID in `hiddenBuiltInIDs`; the remote itself is never destroyed and can be
//  restored.
//

import Foundation
import Observation

@MainActor
@Observable
public final class RemoteStore {

    // MARK: Stored state

    /// Remotes the user created, imported or duplicated, in creation order.
    public private(set) var userRemotes: [Remote] = []

    /// Built-ins the user has removed from the list.
    public private(set) var hiddenBuiltInIDs: Set<UUID> = []

    /// Explicit display order across built-ins and user remotes. IDs not
    /// present here fall to the end in their natural order, which is what
    /// makes a newly shipped built-in appear rather than vanish.
    public private(set) var order: [UUID] = []

    /// Set when the document on disk could not be read. The list falls back to
    /// the built-ins; the UI surfaces this so a failure is not silent.
    public private(set) var loadFailure: String?

    /// Set when the last write failed.
    public private(set) var saveFailure: String?

    // MARK: Location

    private let directory: URL
    private let fileURL: URL
    private let fileManager: FileManager

    public static let documentName = "Remotes.json"
    private static let documentVersion = 1

    /// - Parameter directory: where the library document lives. Tests pass a
    ///   temporary directory; the app passes nil and gets Application Support.
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let resolved = directory ?? RemoteStore.defaultDirectory(fileManager: fileManager)
        self.directory = resolved
        self.fileURL = resolved.appendingPathComponent(RemoteStore.documentName, isDirectory: false)
        load()
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("PocketTrackpad", isDirectory: true)
    }

    /// Exposed so the diagnostics screen and tests can point at the document.
    public var documentURL: URL { fileURL }

    // MARK: Reading

    /// Built-ins (minus hidden ones) plus user remotes, in display order.
    public var remotes: [Remote] {
        let visibleBuiltIns = Remote.builtIns.filter { !hiddenBuiltInIDs.contains($0.id) }
        let all = visibleBuiltIns + userRemotes

        var rank: [UUID: Int] = [:]
        for (index, id) in order.enumerated() { rank[id] = index }

        // Anything the order does not mention sorts after everything it does,
        // keeping its natural position relative to its unranked siblings.
        let unrankedBase = order.count
        return all.enumerated()
            .sorted { lhs, rhs in
                let l = rank[lhs.element.id] ?? (unrankedBase + lhs.offset)
                let r = rank[rhs.element.id] ?? (unrankedBase + rhs.offset)
                if l == r { return lhs.offset < rhs.offset }
                return l < r
            }
            .map(\.element)
    }

    /// Built-ins the user has hidden, for the "Restore" affordance.
    public var hiddenBuiltIns: [Remote] {
        Remote.builtIns.filter { hiddenBuiltInIDs.contains($0.id) }
    }

    public func remote(withID id: UUID) -> Remote? {
        remotes.first { $0.id == id }
    }

    public func isBuiltIn(_ id: UUID) -> Bool {
        Remote.builtIns.contains { $0.id == id }
    }

    // MARK: Mutating

    /// Inserts a new remote or replaces an existing one. Built-ins are not
    /// editable, so a built-in ID is rejected rather than silently shadowed.
    public func save(_ remote: Remote) {
        guard !isBuiltIn(remote.id) else { return }
        var stored = remote
        stored.isBuiltIn = false
        if let index = userRemotes.firstIndex(where: { $0.id == stored.id }) {
            userRemotes[index] = stored
        } else {
            userRemotes.append(stored)
            if !order.isEmpty { order.append(stored.id) }
        }
        persist()
    }

    /// Removes a user remote, or hides a built-in.
    public func delete(_ remote: Remote) {
        if isBuiltIn(remote.id) {
            hiddenBuiltInIDs.insert(remote.id)
        } else {
            userRemotes.removeAll { $0.id == remote.id }
        }
        order.removeAll { $0 == remote.id }
        persist()
    }

    /// List-driven delete. `offsets` index into `remotes`.
    public func delete(atOffsets offsets: IndexSet) {
        let snapshot = remotes
        let doomed = offsets.compactMap { snapshot.indices.contains($0) ? snapshot[$0] : nil }
        for remote in doomed {
            if isBuiltIn(remote.id) {
                hiddenBuiltInIDs.insert(remote.id)
            } else {
                userRemotes.removeAll { $0.id == remote.id }
            }
            order.removeAll { $0 == remote.id }
        }
        persist()
    }

    /// Brings a hidden built-in back, at the end of the list.
    public func restoreBuiltIn(id: UUID) {
        guard hiddenBuiltInIDs.contains(id) else { return }
        hiddenBuiltInIDs.remove(id)
        if !order.isEmpty && !order.contains(id) { order.append(id) }
        persist()
    }

    public func restoreAllBuiltIns() {
        guard !hiddenBuiltInIDs.isEmpty else { return }
        let restored = hiddenBuiltInIDs
        hiddenBuiltInIDs.removeAll()
        if !order.isEmpty {
            for id in Remote.builtIns.map(\.id) where restored.contains(id) && !order.contains(id) {
                order.append(id)
            }
        }
        persist()
    }

    /// Copies a remote — including a built-in — into the editable library.
    @discardableResult
    public func duplicate(_ remote: Remote) -> Remote {
        var copy = remote
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = uniqueName(basedOn: remote.name)
        copy.buttons = remote.buttons.map { button in
            var fresh = button
            fresh.id = UUID()
            return fresh
        }

        // Land the copy directly beneath its original rather than at the end.
        // Captured before the append so `remotes` cannot already contain it.
        var newOrder = order.isEmpty ? remotes.map(\.id) : order
        userRemotes.append(copy)
        if let index = newOrder.firstIndex(of: remote.id) {
            newOrder.insert(copy.id, at: newOrder.index(after: index))
        } else {
            newOrder.append(copy.id)
        }
        order = newOrder
        persist()
        return copy
    }

    /// Reorder from a `List`'s `onMove`. `offsets` index into `remotes`.
    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        order = RemoteStore.moving(remotes.map(\.id), fromOffsets: offsets, toOffset: destination)
        persist()
    }

    /// `SwiftUI`'s `move(fromOffsets:toOffset:)` semantics, reimplemented so the
    /// store stays free of a UI framework import: `destination` is an index in
    /// the *pre-move* array, and everything at or after it shifts down.
    static func moving(_ ids: [UUID], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [UUID] {
        var result = ids
        let sourceIndices = offsets.sorted().filter { result.indices.contains($0) }
        guard !sourceIndices.isEmpty else { return result }

        let lifted = sourceIndices.map { result[$0] }
        let removedBefore = sourceIndices.filter { $0 < destination }.count
        for index in sourceIndices.reversed() {
            result.remove(at: index)
        }
        let insertionPoint = min(max(destination - removedBefore, 0), result.count)
        result.insert(contentsOf: lifted, at: insertionPoint)
        return result
    }

    // MARK: Naming

    /// "Media" -> "Media Copy" -> "Media Copy 2", never colliding with a name
    /// already in the library.
    public func uniqueName(basedOn name: String) -> String {
        let existing = Set(remotes.map(\.name))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Remote" : trimmed

        var candidate = existing.contains(base) ? "\(base) Copy" : base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base) Copy \(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// A blank remote for the editor's "create" path. Not stored until saved.
    public func makeDraft() -> Remote {
        Remote(
            name: uniqueName(basedOn: "New Remote"),
            symbolName: "square.grid.2x2",
            buttons: [],
            layout: .grid3,
            isBuiltIn: false
        )
    }

    // MARK: Export / import

    /// A single remote as shareable JSON.
    public func exportData(for remote: Remote) throws -> Data {
        try RemoteCoding.encoder.encode(remote)
    }

    /// Adds a remote received from elsewhere. Identifiers are regenerated so an
    /// import can never overwrite or shadow something already in the library,
    /// and the name is uniqued so two "Media" remotes are distinguishable.
    @discardableResult
    public func importRemote(from data: Data) throws -> Remote {
        let decoded = try RemoteCoding.decoder.decode(Remote.self, from: data)
        var imported = decoded
        imported.id = UUID()
        imported.isBuiltIn = false
        imported.name = uniqueName(basedOn: decoded.name)
        imported.buttons = decoded.buttons.map { button in
            var fresh = button
            fresh.id = UUID()
            return fresh
        }
        userRemotes.append(imported)
        if !order.isEmpty { order.append(imported.id) }
        persist()
        return imported
    }

    // MARK: Persistence

    private struct StoredLibrary: Codable {
        var version: Int
        var userRemotes: [Remote]
        var hiddenBuiltInIDs: [UUID]
        var order: [UUID]
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let stored = try RemoteCoding.decoder.decode(StoredLibrary.self, from: data)
            userRemotes = stored.userRemotes.map { remote in
                var sanitised = remote
                sanitised.isBuiltIn = false
                return sanitised
            }
            hiddenBuiltInIDs = Set(stored.hiddenBuiltInIDs)
            order = stored.order
            loadFailure = nil
        } catch {
            // A damaged document must not take the app down with it, and must
            // not be silently overwritten either: move it aside so it can be
            // recovered, and start from the built-ins.
            userRemotes = []
            hiddenBuiltInIDs = []
            order = []
            loadFailure = error.localizedDescription
            quarantineDamagedDocument()
        }
    }

    private func quarantineDamagedDocument() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = directory.appendingPathComponent(
            "Remotes-damaged-\(stamp).json",
            isDirectory: false
        )
        try? fileManager.moveItem(at: fileURL, to: destination)
    }

    private func persist() {
        // Drop IDs for remotes that no longer exist so the order list cannot
        // grow without bound across years of edits.
        let live = Set(Remote.builtIns.map(\.id)).union(userRemotes.map(\.id))
        order = order.filter { live.contains($0) }

        let document = StoredLibrary(
            version: RemoteStore.documentVersion,
            userRemotes: userRemotes,
            hiddenBuiltInIDs: Array(hiddenBuiltInIDs),
            order: order
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try RemoteCoding.encoder.encode(document)
            // Atomic: a crash mid-write leaves the previous document intact
            // rather than a truncated one that fails to decode next launch.
            try data.write(to: fileURL, options: [.atomic])
            saveFailure = nil
        } catch {
            saveFailure = error.localizedDescription
        }
    }

    /// Forces a write. Used by tests and by the editor's explicit Save.
    public func flush() { persist() }
}
