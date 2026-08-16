//
//  RemoteStoreTests.swift
//  PocketTrackpadTests
//
//  Covers the two things in the Remotes feature that can silently corrupt a
//  user's data: the hand-written `RemoteAction` Codable conformance, and the
//  store's on-disk document.
//

import XCTest
@testable import PocketTrackpad

final class RemoteStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    @MainActor
    private func makeStore() -> RemoteStore {
        RemoteStore(directory: directory)
    }

    private func sampleRemote(named name: String) -> Remote {
        Remote(
            name: name,
            symbolName: "tv",
            buttons: [
                RemoteButton(title: "Play", symbolName: "playpause.fill", action: .consumer(.playPause)),
                RemoteButton(title: "Type", action: .text("hello"), span: 2),
                RemoteButton(
                    title: "Combo",
                    action: .sequence([
                        .key(usage: 0x04, modifiers: [.leftCommand]),
                        .mouse(.left)
                    ])
                )
            ],
            layout: .grid3
        )
    }

    // MARK: - RemoteAction Codable

    /// Every case, including a sequence nested inside a sequence, survives a
    /// full encode/decode cycle unchanged.
    func testActionCodableRoundTripCoversEveryCase() throws {
        let actions: [RemoteAction] = [
            .consumer(.playPause),
            .consumer(.volumeDown),
            .consumer(.acDesktopShowAll),
            .key(usage: 0x28, modifiers: .none),
            .key(usage: 0x04, modifiers: [.leftCommand, .leftShift]),
            .key(usage: 0xFF, modifiers: [.rightControl, .rightOption, .rightShift, .rightCommand]),
            .text(""),
            .text("Hello, world! — “quoted”, 123"),
            .mouse(.left),
            .mouse(.none),
            .mouse([.left, .right, .middle]),
            .sequence([]),
            .sequence([
                .consumer(.mute),
                .text("step"),
                .key(usage: 0x2A, modifiers: [.leftOption]),
                .mouse(.right)
            ]),
            // Nested: a sequence whose first step is itself a sequence.
            .sequence([
                .sequence([
                    .consumer(.stop),
                    .text("inner"),
                    .sequence([.key(usage: 0x29, modifiers: .none)])
                ]),
                .consumer(.play)
            ])
        ]

        let encoder = RemoteCoding.encoder
        let decoder = RemoteCoding.decoder

        for action in actions {
            let data = try encoder.encode(action)
            let decoded = try decoder.decode(RemoteAction.self, from: data)
            XCTAssertEqual(decoded, action, "Round trip changed \(action)")
            XCTAssertEqual(decoded.kind, action.kind)
        }

        // The list above is only meaningful if it exercises all five kinds.
        let covered = Set(actions.map(\.kind))
        XCTAssertEqual(covered, Set(RemoteActionKind.allCases))
    }

    func testActionEncodingIsSelfDescribing() throws {
        let data = try RemoteCoding.encoder.encode(RemoteAction.key(usage: 0x28, modifiers: [.leftCommand]))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["kind"] as? String, "key")
        XCTAssertEqual(json["usage"] as? Int, 0x28)
        XCTAssertEqual(json["modifiers"] as? Int, Int(KeyModifiers.leftCommand.rawValue))
    }

    func testDecodingRejectsUnknownConsumerUsage() {
        let json = Data(#"{"kind":"consumer","usage":65535}"#.utf8)
        XCTAssertThrowsError(try RemoteCoding.decoder.decode(RemoteAction.self, from: json))
    }

    func testDecodingKeyWithoutModifiersDefaultsToNone() throws {
        let json = Data(#"{"kind":"key","usage":40}"#.utf8)
        let action = try RemoteCoding.decoder.decode(RemoteAction.self, from: json)
        XCTAssertEqual(action, .key(usage: 40, modifiers: .none))
    }

    func testRemoteRoundTripsThroughCodable() throws {
        for builtIn in Remote.builtIns {
            let data = try RemoteCoding.encoder.encode(builtIn)
            let decoded = try RemoteCoding.decoder.decode(Remote.self, from: data)
            XCTAssertEqual(decoded, builtIn, "Round trip changed \(builtIn.name)")
        }
    }

    // MARK: - Built-in integrity

    func testBuiltInsHaveDistinctStableIdentifiers() {
        let remoteIDs = Remote.builtIns.map(\.id)
        XCTAssertEqual(Set(remoteIDs).count, remoteIDs.count, "Two built-in remotes share an ID")

        let buttonIDs = Remote.builtIns.flatMap { $0.buttons.map(\.id) }
        XCTAssertEqual(Set(buttonIDs).count, buttonIDs.count, "Two built-in buttons share an ID")

        for remote in Remote.builtIns {
            XCTAssertTrue(remote.isBuiltIn)
            XCTAssertFalse(remote.buttons.isEmpty, "\(remote.name) has no buttons")
        }
    }

    func testGridRowsHonourSpanAndColumnCount() {
        // 0 is a wide key, so the last three rows of the keypad wrap on it.
        let rows = Remote.numericKeypad.gridRows
        for row in rows {
            let used = row.reduce(0) { $0 + $1.effectiveSpan(in: Remote.numericKeypad.columns) }
            XCTAssertLessThanOrEqual(used, Remote.numericKeypad.columns)
        }
        XCTAssertEqual(rows.flatMap { $0 }.map(\.id), Remote.numericKeypad.buttons.map(\.id))

        // A span wider than the grid is clamped rather than dropped.
        let narrow = Remote(
            name: "Narrow",
            symbolName: "tv",
            buttons: [RemoteButton(title: "Wide", action: .text("x"), span: 2)],
            layout: .grid2
        )
        XCTAssertEqual(narrow.gridRows.count, 1)
        XCTAssertEqual(narrow.gridRows[0].count, 1)
    }

    // MARK: - Persistence

    @MainActor
    func testUserRemoteSurvivesStoreReload() throws {
        let store = makeStore()
        let remote = sampleRemote(named: "Studio")
        store.save(remote)

        XCTAssertEqual(store.remotes.count, Remote.builtIns.count + 1)

        let reloaded = RemoteStore(directory: directory)
        let restored = try XCTUnwrap(reloaded.remote(withID: remote.id))
        XCTAssertEqual(restored.name, "Studio")
        XCTAssertEqual(restored.layout, .grid3)
        XCTAssertEqual(restored.buttons.count, 3)
        XCTAssertEqual(restored.buttons.map(\.action), remote.buttons.map(\.action))
        XCTAssertEqual(restored.buttons[1].span, 2)
        XCTAssertNil(reloaded.loadFailure)
    }

    @MainActor
    func testEditingAnExistingRemoteReplacesRatherThanDuplicates() throws {
        let store = makeStore()
        var remote = sampleRemote(named: "Studio")
        store.save(remote)

        remote.name = "Studio Two"
        remote.buttons.removeLast()
        store.save(remote)

        XCTAssertEqual(store.remotes.count, Remote.builtIns.count + 1)

        let reloaded = RemoteStore(directory: directory)
        let restored = try XCTUnwrap(reloaded.remote(withID: remote.id))
        XCTAssertEqual(restored.name, "Studio Two")
        XCTAssertEqual(restored.buttons.count, 2)
    }

    @MainActor
    func testWrittenDocumentLandsInTheInjectedDirectory() {
        let store = makeStore()
        store.save(sampleRemote(named: "Studio"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.documentURL.path))
        XCTAssertEqual(store.documentURL.deletingLastPathComponent().path, directory.path)
        XCTAssertNil(store.saveFailure)
    }

    // MARK: - Hiding and restoring built-ins

    @MainActor
    func testHidingABuiltInPersistsAndRestoreBringsItBackIntact() throws {
        let store = makeStore()
        let media = Remote.mediaRemote

        store.delete(media)
        XCTAssertFalse(store.remotes.contains { $0.id == media.id })
        XCTAssertEqual(store.hiddenBuiltIns.map(\.id), [media.id])

        let reloaded = RemoteStore(directory: directory)
        XCTAssertFalse(reloaded.remotes.contains { $0.id == media.id })
        XCTAssertEqual(reloaded.hiddenBuiltIns.map(\.id), [media.id])

        reloaded.restoreBuiltIn(id: media.id)
        let restored = try XCTUnwrap(reloaded.remote(withID: media.id))
        // A hidden built-in is never destroyed, so it comes back whole.
        XCTAssertEqual(restored, media)
        XCTAssertTrue(reloaded.hiddenBuiltIns.isEmpty)

        let reloadedAgain = RemoteStore(directory: directory)
        XCTAssertTrue(reloadedAgain.remotes.contains { $0.id == media.id })
    }

    @MainActor
    func testRestoreAllBuiltInsBringsBackEverythingHidden() {
        let store = makeStore()
        for remote in Remote.builtIns {
            store.delete(remote)
        }
        XCTAssertTrue(store.remotes.isEmpty)
        XCTAssertEqual(store.hiddenBuiltIns.count, Remote.builtIns.count)

        store.restoreAllBuiltIns()
        XCTAssertEqual(Set(store.remotes.map(\.id)), Set(Remote.builtIns.map(\.id)))
    }

    @MainActor
    func testDeletingAUserRemoteRemovesItPermanently() {
        let store = makeStore()
        let remote = sampleRemote(named: "Studio")
        store.save(remote)
        store.delete(remote)

        XCTAssertNil(store.remote(withID: remote.id))
        XCTAssertTrue(store.hiddenBuiltIns.isEmpty)
        XCTAssertNil(RemoteStore(directory: directory).remote(withID: remote.id))
    }

    // MARK: - Ordering

    @MainActor
    func testReorderIsStableAcrossReloadsAndLaterEdits() {
        let store = makeStore()
        let original = store.remotes.map(\.id)
        XCTAssertEqual(original.count, Remote.builtIns.count)

        // Move the first remote down two places: [A,B,C,D] -> [B,C,A,D].
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        let reordered = store.remotes.map(\.id)
        XCTAssertEqual(reordered, [original[1], original[2], original[0], original[3]])

        let reloaded = RemoteStore(directory: directory)
        XCTAssertEqual(reloaded.remotes.map(\.id), reordered)

        // A remote added afterwards goes to the end and disturbs nothing.
        let added = sampleRemote(named: "Studio")
        reloaded.save(added)
        XCTAssertEqual(reloaded.remotes.map(\.id), reordered + [added.id])

        // Hiding then restoring a built-in must not scramble the rest.
        reloaded.delete(Remote.tvRemote)
        let withoutTV = reordered.filter { $0 != Remote.tvRemote.id }
        XCTAssertEqual(reloaded.remotes.map(\.id), withoutTV + [added.id])

        reloaded.restoreBuiltIn(id: Remote.tvRemote.id)
        XCTAssertEqual(reloaded.remotes.map(\.id), withoutTV + [added.id, Remote.tvRemote.id])
    }

    @MainActor
    func testDuplicateLandsBeneathItsOriginalWithFreshIdentifiers() throws {
        let store = makeStore()
        let source = Remote.mediaRemote
        let copy = store.duplicate(source)

        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertNotEqual(copy.name, source.name)
        XCTAssertEqual(copy.buttons.map(\.action), source.buttons.map(\.action))
        XCTAssertTrue(Set(copy.buttons.map(\.id)).isDisjoint(with: Set(source.buttons.map(\.id))))

        let ids = store.remotes.map(\.id)
        let sourceIndex = try XCTUnwrap(ids.firstIndex(of: source.id))
        XCTAssertEqual(ids[sourceIndex + 1], copy.id)
    }

    // MARK: - Export / import

    @MainActor
    func testExportImportRoundTripPreservesEverythingButIdentity() throws {
        let store = makeStore()
        let source = Remote.presentationRemote

        let data = try store.exportData(for: source)
        let imported = try store.importRemote(from: data)

        XCTAssertEqual(imported.layout, source.layout)
        XCTAssertEqual(imported.symbolName, source.symbolName)
        XCTAssertEqual(imported.buttons.map(\.title), source.buttons.map(\.title))
        XCTAssertEqual(imported.buttons.map(\.action), source.buttons.map(\.action))
        XCTAssertEqual(imported.buttons.map(\.span), source.buttons.map(\.span))

        // Identity is deliberately not preserved: an import must never
        // overwrite or shadow something already in the library.
        XCTAssertNotEqual(imported.id, source.id)
        XCTAssertFalse(imported.isBuiltIn)
        XCTAssertNotEqual(imported.name, source.name)
        XCTAssertTrue(Set(imported.buttons.map(\.id)).isDisjoint(with: Set(source.buttons.map(\.id))))

        // And it is durable.
        let reloaded = RemoteStore(directory: directory)
        XCTAssertNotNil(reloaded.remote(withID: imported.id))
    }

    @MainActor
    func testImportingTheSameRemoteTwiceProducesTwoDistinctEntries() throws {
        let store = makeStore()
        let data = try store.exportData(for: Remote.tvRemote)

        let first = try store.importRemote(from: data)
        let second = try store.importRemote(from: data)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.name, second.name)
        XCTAssertEqual(store.remotes.count, Remote.builtIns.count + 2)
    }

    @MainActor
    func testImportingGarbageThrowsAndLeavesTheLibraryAlone() {
        let store = makeStore()
        let before = store.remotes.map(\.id)

        XCTAssertThrowsError(try store.importRemote(from: Data("not a remote".utf8)))
        XCTAssertEqual(store.remotes.map(\.id), before)
    }

    // MARK: - Corrupt document

    @MainActor
    func testCorruptDocumentFallsBackToBuiltInsAndIsPreserved() throws {
        let documentURL = directory.appendingPathComponent(RemoteStore.documentName, isDirectory: false)
        try Data(#"{"version":1,"userRemotes":[ this is not JSON"#.utf8).write(to: documentURL)

        let store = makeStore()

        XCTAssertEqual(store.remotes.map(\.id), Remote.builtIns.map(\.id))
        XCTAssertNotNil(store.loadFailure)
        XCTAssertTrue(store.hiddenBuiltIns.isEmpty)

        // The damaged file is moved aside, not silently overwritten.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(contents.contains { $0.hasPrefix("Remotes-damaged-") })

        // And the store is still usable afterwards.
        let remote = sampleRemote(named: "Studio")
        store.save(remote)
        XCTAssertNotNil(RemoteStore(directory: directory).remote(withID: remote.id))
    }

    @MainActor
    func testDocumentWithAnUndecodableActionFallsBackRatherThanCrashing() throws {
        let documentURL = directory.appendingPathComponent(RemoteStore.documentName, isDirectory: false)
        let json = """
        {
          "version": 1,
          "hiddenBuiltInIDs": [],
          "order": [],
          "userRemotes": [
            {
              "id": "\(UUID().uuidString)",
              "name": "Broken",
              "symbolName": "tv",
              "layout": "grid3",
              "isBuiltIn": false,
              "buttons": [
                {
                  "id": "\(UUID().uuidString)",
                  "title": "Bad",
                  "span": 1,
                  "action": { "kind": "consumer", "usage": 65535 }
                }
              ]
            }
          ]
        }
        """
        try Data(json.utf8).write(to: documentURL)

        let store = makeStore()
        XCTAssertEqual(store.remotes.map(\.id), Remote.builtIns.map(\.id))
        XCTAssertNotNil(store.loadFailure)
    }

    @MainActor
    func testMissingDocumentIsNotAFailure() {
        let store = makeStore()
        XCTAssertNil(store.loadFailure)
        XCTAssertEqual(store.remotes.map(\.id), Remote.builtIns.map(\.id))
    }

    // MARK: - Reorder helper

    func testMovingMatchesSwiftUIMoveSemantics() {
        let ids = (0..<4).map { _ in UUID() }

        XCTAssertEqual(
            RemoteStore.moving(ids, fromOffsets: IndexSet(integer: 0), toOffset: 3),
            [ids[1], ids[2], ids[0], ids[3]]
        )
        XCTAssertEqual(
            RemoteStore.moving(ids, fromOffsets: IndexSet(integer: 3), toOffset: 0),
            [ids[3], ids[0], ids[1], ids[2]]
        )
        XCTAssertEqual(
            RemoteStore.moving(ids, fromOffsets: IndexSet([0, 1]), toOffset: 4),
            [ids[2], ids[3], ids[0], ids[1]]
        )
        // A move that goes nowhere leaves the array untouched.
        XCTAssertEqual(
            RemoteStore.moving(ids, fromOffsets: IndexSet(integer: 1), toOffset: 1),
            ids
        )
        // Out-of-range offsets are ignored rather than trapping.
        XCTAssertEqual(
            RemoteStore.moving(ids, fromOffsets: IndexSet(integer: 99), toOffset: 0),
            ids
        )
    }

    // MARK: - Action execution

    @MainActor
    func testPerformAlwaysSendsAReleaseReport() {
        let sender = StubHIDSender()

        perform(.consumer(.volumeUp), on: sender)
        XCTAssertEqual(sender.sentConsumer.count, 2)
        XCTAssertEqual(sender.sentConsumer.first?.usage, ConsumerUsage.volumeUp.rawValue)
        XCTAssertEqual(sender.sentConsumer.last?.usage, 0)

        sender.reset()
        perform(.key(usage: 0x04, modifiers: [.leftCommand]), on: sender)
        XCTAssertEqual(sender.sentKeyboard.count, 2)
        XCTAssertEqual(sender.sentKeyboard.first?.keys, [0x04])
        XCTAssertEqual(sender.sentKeyboard.first?.modifiers, KeyModifiers.leftCommand)
        XCTAssertTrue(sender.sentKeyboard.last?.keys.isEmpty ?? false)
        XCTAssertEqual(sender.sentKeyboard.last?.modifiers, KeyModifiers.none)

        sender.reset()
        perform(.mouse(.right), on: sender)
        XCTAssertEqual(sender.sentMouse.count, 2)
        XCTAssertEqual(sender.sentMouse.first?.buttons, MouseButtons.right)
        XCTAssertTrue(sender.sentMouse.last?.isIdle ?? false)
    }

    @MainActor
    func testPerformRecursesThroughSequences() {
        let sender = StubHIDSender()

        perform(
            .sequence([
                .consumer(.mute),
                .sequence([.mouse(.left), .consumer(.play)])
            ]),
            on: sender
        )

        // Two consumer taps (press + release each) and one mouse click.
        XCTAssertEqual(sender.sentConsumer.count, 4)
        XCTAssertEqual(sender.sentMouse.count, 2)
        XCTAssertEqual(sender.sentConsumer.map(\.usage),
                       [ConsumerUsage.mute.rawValue, 0, ConsumerUsage.play.rawValue, 0])
    }

    @MainActor
    func testConsumerActionFallsBackToFunctionKeysUnderBootProtocol() throws {
        let sender = StubHIDSender()
        sender.activeTopology = .bootProtocolOnly

        perform(.consumer(.volumeUp), on: sender)

        XCTAssertTrue(sender.sentConsumer.isEmpty, "Boot protocol carries no consumer report")
        XCTAssertEqual(sender.sentKeyboard.count, 2)
        XCTAssertEqual(sender.sentKeyboard.first?.keys, [HIDKeyCode.f12])
        XCTAssertTrue(sender.sentKeyboard.last?.keys.isEmpty ?? false)

        // A usage with no function-row equivalent sends nothing at all rather
        // than sending something wrong.
        sender.reset()
        perform(.consumer(.acHome), on: sender)
        XCTAssertTrue(sender.sentKeyboard.isEmpty)
        XCTAssertTrue(sender.sentConsumer.isEmpty)
    }
}
