//
//  HIDDiagnosticsTests.swift
//  PocketTrackpadTests
//
//  `StubHIDSender` is a success-path stub — it never throws and always reports
//  a full subscription — so it cannot exercise any of the paths that matter
//  here. `FakePeripheral` below adds failure injection for all three of
//  `HIDPeripheralManager`'s documented rejection shapes:
//
//    * synchronous throw from `start(topology:)`      (the 0x2908 exception)
//    * clean return, then `.failed` from `didAdd`     (short UUID, duplicate)
//    * clean return, then nothing at all              (publish unconfirmed)
//
//  The middle one is the reason this file exists in its current form: a probe
//  that treats a non-throwing `start` as success reports a dead topology as
//  working.
//
//  Every timeout comes from `ProbeTiming.fast` (60 ms publish, 150 ms
//  subscription, 10 ms poll, 20 ms settle), so a full three-topology run costs
//  well under a second even in the worst case.
//

import XCTest
@testable import PocketTrackpad

// MARK: - Fake

@MainActor
final class FakePeripheral: HIDPeripheralControlling {

    // MARK: Injection

    /// Topologies whose `start(topology:)` throws — the synchronous ObjC
    /// exception path.
    var startErrors: [ReportTopology: HIDError] = [:]

    /// Topologies where `start` returns cleanly and the service is then
    /// refused in `didAdd`, surfacing as `.failed`.
    var asyncRejections: [ReportTopology: String] = [:]

    /// Topologies where `start` returns cleanly and no `didAdd` ever resolves.
    var unconfirmedPublishTopologies: Set<ReportTopology> = []

    /// How many of the three services confirm via `didAdd`. Lower it to
    /// reproduce a partially-published device.
    var publishedServiceCount = 3

    /// Topologies for which a central connects and subscribes immediately.
    var subscribingTopologies: Set<ReportTopology> = []

    /// Topologies for which a central connects but never subscribes.
    var connectingButSilentTopologies: Set<ReportTopology> = []

    /// Topologies where the host drops the link as soon as we send a report —
    /// the "published, subscribed, but the report map was rejected" case.
    var dropsOnSendTopologies: Set<ReportTopology> = []

    /// Name reported for a connected central. Nil reproduces reality: CBCentral
    /// exposes no name, so a Mac's first connection always lands here.
    var centralName: String?

    // MARK: Recording

    private(set) var startedTopologies: [ReportTopology] = []
    private(set) var stopCount = 0
    private(set) var sentMouse: [MouseReport] = []
    private(set) var sentKeyboard: [KeyboardReport] = []
    private(set) var sentConsumer: [ConsumerReport] = []

    // MARK: HIDSending

    var connectionState: HIDConnectionState = .idle
    var activeTopology: ReportTopology = .perReportCharacteristic

    func send(mouse: MouseReport) {
        sentMouse.append(mouse)
        dropLinkIfConfigured()
    }

    func send(keyboard: KeyboardReport) {
        sentKeyboard.append(keyboard)
        dropLinkIfConfigured()
    }

    func send(consumer: ConsumerReport) {
        sentConsumer.append(consumer)
        dropLinkIfConfigured()
    }

    private func dropLinkIfConfigured() {
        guard dropsOnSendTopologies.contains(activeTopology) else { return }
        connectionState = .idle
        subscribedReports = []
        log.append(HIDLogEntry(level: .failure, message: "Central disconnected after the first notification"))
    }

    // MARK: HIDPeripheralControlling

    var knownCentrals: [KnownCentral] = []
    var subscribedReports: Set<HIDReportID> = []
    var log: [HIDLogEntry] = []

    /// Permanently nil, exactly as the real manager documents: no peripheral-side
    /// CoreBluetooth API exposes the negotiated connection interval.
    var negotiatedConnectionInterval: TimeInterval?

    /// The three services the real manager publishes: HID, Device Information,
    /// Battery.
    private static let serviceUUIDs = ["1812", "180A", "180F"]

    func start(topology: ReportTopology) throws {
        startedTopologies.append(topology)
        activeTopology = topology

        if let error = startErrors[topology] {
            log.append(HIDLogEntry(level: .failure, message: "start(\(topology.rawValue)) threw"))
            throw error
        }

        // The real manager ends a clean `start` in `startAdvertising()`, which
        // sets `.advertising` synchronously. Everything after this point is the
        // asynchronous half.
        connectionState = .advertising

        if let reason = asyncRejections[topology] {
            log.append(HIDLogEntry(level: .failure, message: "didAdd rejected 1812: \(reason)"))
            connectionState = .failed(reason)
            return
        }

        if !unconfirmedPublishTopologies.contains(topology) {
            for uuid in Self.serviceUUIDs.prefix(publishedServiceCount) {
                log.append(HIDLogEntry(level: .success, message: "Published \(uuid)."))
            }
        }

        if subscribingTopologies.contains(topology) {
            connectionState = .connected(centralName: centralName)
            subscribedReports = Set(topology.supportedReports)
            log.append(HIDLogEntry(level: .success, message: "Central subscribed for \(topology.rawValue)"))
        } else if connectingButSilentTopologies.contains(topology) {
            connectionState = .connected(centralName: centralName)
            subscribedReports = []
            log.append(HIDLogEntry(level: .warning, message: "Central connected but did not subscribe"))
        } else {
            log.append(HIDLogEntry(level: .info, message: "Advertising for \(topology.rawValue)"))
        }
    }

    func stop() {
        stopCount += 1
        subscribedReports = []
        // Mirrors the real manager: an unseen `.failed` is preserved.
        if case .failed = connectionState { return }
        connectionState = .idle
    }

    func forget(_ central: KnownCentral) {
        knownCentrals.removeAll { $0.id == central.id }
    }

    func clearLog() { log.removeAll() }
}

// MARK: - Tests

@MainActor
final class HIDDiagnosticsTests: XCTestCase {

    private func makeSubject(_ fake: FakePeripheral) -> HIDDiagnostics {
        HIDDiagnostics(manager: fake, timing: .fast)
    }

    /// Whitespace-insensitive containment, for asserting that a caveat survived
    /// into the export verbatim despite being hard-wrapped there.
    private func containsVerbatim(_ haystack: String, _ needle: String) -> Bool {
        func flatten(_ text: String) -> String {
            text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return flatten(haystack).contains(flatten(needle))
    }

    // MARK: Synchronous rejection

    func testTopologyThatThrowsOnStartIsRecordedAsRejectedAndTheRunContinues() async throws {
        let fake = FakePeripheral()
        fake.startErrors[.perReportCharacteristic] = .descriptorRejected(
            "Descriptors with UUID 2908 are not supported"
        )
        fake.subscribingTopologies = [.singleCharacteristicPrefixed]

        let subject = makeSubject(fake)
        await subject.runAll()

        let rejected = try XCTUnwrap(subject.result(for: .perReportCharacteristic))
        XCTAssertEqual(rejected.publishOutcome, .threwSynchronously)
        XCTAssertFalse(rejected.servicePublished)
        XCTAssertFalse(rejected.centralSubscribed)
        XCTAssertEqual(subject.state(for: .perReportCharacteristic), .rejected)

        // Verbatim: the descriptor text must survive into the result untouched.
        let reason = try XCTUnwrap(rejected.failureReason)
        XCTAssertTrue(
            reason.contains("2908"),
            "The raw rejection text must be preserved, got: \(reason)"
        )

        // The run did not stop at the first failure.
        XCTAssertEqual(fake.startedTopologies, ReportTopology.allCases)
        let next = try XCTUnwrap(subject.result(for: .singleCharacteristicPrefixed))
        XCTAssertEqual(next.publishOutcome, .confirmed)
        XCTAssertTrue(next.centralSubscribed)
    }

    func testRejectedTopologyIsNeverProbedForSubscription() async throws {
        let fake = FakePeripheral()
        for topology in ReportTopology.allCases {
            fake.startErrors[topology] = .serviceRejected("no")
        }

        let subject = makeSubject(fake)
        await subject.runAll()

        XCTAssertTrue(fake.sentMouse.isEmpty)
        XCTAssertTrue(fake.sentConsumer.isEmpty)
        XCTAssertNil(subject.recommendation)
        for topology in ReportTopology.allCases {
            XCTAssertEqual(subject.state(for: topology), .rejected)
        }
    }

    // MARK: Asynchronous rejection — the regression this file exists for

    func testCleanStartFollowedByDidAddFailureIsNotRecordedAsPublished() async throws {
        let fake = FakePeripheral()
        fake.asyncRejections[.perReportCharacteristic] =
            "The specified UUID is not allowed for this operation."

        let subject = makeSubject(fake)
        await subject.runAll()

        let result = try XCTUnwrap(subject.result(for: .perReportCharacteristic))
        XCTAssertEqual(result.publishOutcome, .rejectedAsynchronously)
        XCTAssertFalse(
            result.servicePublished,
            "A non-throwing start() must not by itself count as a published service."
        )
        XCTAssertEqual(subject.state(for: .perReportCharacteristic), .rejectedAsynchronously)
        XCTAssertEqual(
            result.failureReason,
            "The specified UUID is not allowed for this operation.",
            "The didAdd error must be recorded verbatim."
        )
        XCTAssertFalse(result.centralSubscribed)
    }

    func testAsynchronousRejectionIsDistinctFromASynchronousThrow() async throws {
        let fake = FakePeripheral()
        fake.startErrors[.perReportCharacteristic] = .descriptorRejected("2908")
        fake.asyncRejections[.singleCharacteristicPrefixed] = "duplicate service"

        let subject = makeSubject(fake)
        await subject.runAll()

        XCTAssertEqual(subject.state(for: .perReportCharacteristic), .rejected)
        XCTAssertEqual(subject.state(for: .singleCharacteristicPrefixed), .rejectedAsynchronously)
        XCTAssertNotEqual(
            subject.state(for: .perReportCharacteristic),
            subject.state(for: .singleCharacteristicPrefixed)
        )
    }

    func testAsynchronouslyRejectedTopologyIsNeverRecommended() async {
        let fake = FakePeripheral()
        // It would otherwise look perfect: it subscribes and holds the link.
        fake.asyncRejections[.perReportCharacteristic] = "refused in didAdd"
        fake.subscribingTopologies = [.perReportCharacteristic, .bootProtocolOnly]

        let subject = makeSubject(fake)
        await subject.runAll()

        XCTAssertEqual(
            subject.recommendation, .bootProtocolOnly,
            "A topology refused in didAdd must not be recommended even if it looks alive afterwards."
        )
    }

    func testAsynchronousRejectionSkipsTheSubscriptionWaitAndTheProbeReports() async {
        let fake = FakePeripheral()
        fake.asyncRejections[.perReportCharacteristic] = "refused"
        fake.asyncRejections[.singleCharacteristicPrefixed] = "refused"
        fake.asyncRejections[.bootProtocolOnly] = "refused"

        let subject = makeSubject(fake)
        await subject.runAll()

        XCTAssertTrue(fake.sentMouse.isEmpty, "A refused layout must not be sent probe reports.")
        XCTAssertTrue(fake.sentConsumer.isEmpty)
        XCTAssertNil(subject.recommendation)
    }

    // MARK: Unresolved publish

    func testPublishThatNeverResolvesIsRecordedAsUnresolvedNotPublished() async throws {
        let fake = FakePeripheral()
        fake.unconfirmedPublishTopologies = Set(ReportTopology.allCases)
        // It would even subscribe — but the publish was never confirmed, so the
        // probe must stop before it gets that far.
        fake.subscribingTopologies = Set(ReportTopology.allCases)

        let subject = makeSubject(fake)
        await subject.runAll()

        for topology in ReportTopology.allCases {
            let result = try XCTUnwrap(subject.result(for: topology))
            XCTAssertEqual(result.publishOutcome, .unresolved, "\(topology)")
            XCTAssertFalse(result.servicePublished, "\(topology)")
            XCTAssertNil(result.failureReason, "An unresolved publish is not a reported failure.")
            XCTAssertEqual(subject.state(for: topology), .unresolved)
        }
        XCTAssertNil(subject.recommendation)
        XCTAssertTrue(fake.sentMouse.isEmpty)
    }

    func testFullPublishConfirmationRecordsTheServiceCount() async throws {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.perReportCharacteristic]

        let subject = makeSubject(fake)
        await subject.runAll()

        let result = try XCTUnwrap(subject.result(for: .perReportCharacteristic))
        XCTAssertEqual(result.publishOutcome, .confirmed)
        XCTAssertTrue(
            result.notes.contains {
                $0.contains("didAdd confirmed \(HIDDiagnostics.expectedServiceCount) of \(HIDDiagnostics.expectedServiceCount) services")
            },
            "The number of confirmed services must be recorded. Notes: \(result.notes)"
        )
    }

    func testPartialPublishConfirmationIsQualifiedRatherThanPresentedAsClean() async throws {
        let fake = FakePeripheral()
        // Only the HID service confirms; DIS and Battery never resolve.
        fake.publishedServiceCount = 1
        fake.subscribingTopologies = [.bootProtocolOnly]

        let subject = makeSubject(fake)
        await subject.runOne(.bootProtocolOnly)

        let result = try XCTUnwrap(subject.result(for: .bootProtocolOnly))
        XCTAssertEqual(result.publishOutcome, .confirmed)
        XCTAssertTrue(
            result.qualifications.contains { $0.contains("Only 1 of \(HIDDiagnostics.expectedServiceCount) services") },
            "A partial publish must be qualified. Qualifications: \(result.qualifications)"
        )
    }

    // MARK: Published but unsubscribed

    func testTopologyThatPublishesWithoutASubscriberIsRecordedAsPublished() async throws {
        let fake = FakePeripheral()
        let subject = makeSubject(fake)
        await subject.runAll()

        for topology in ReportTopology.allCases {
            let result = try XCTUnwrap(subject.result(for: topology))
            XCTAssertEqual(result.publishOutcome, .confirmed, "\(topology) should have published")
            XCTAssertTrue(result.servicePublished, "\(topology)")
            XCTAssertNil(result.failureReason)
            XCTAssertFalse(result.centralSubscribed)
            XCTAssertFalse(result.roundTripConfirmed)
            XCTAssertTrue(result.subscribedReports.isEmpty)
            XCTAssertEqual(subject.state(for: topology), .published)
        }
        XCTAssertNil(subject.recommendation)
    }

    func testCentralThatConnectsWithoutSubscribingIsDistinguishedInTheNotes() async throws {
        let fake = FakePeripheral()
        fake.connectingButSilentTopologies = [.perReportCharacteristic]

        let subject = makeSubject(fake)
        await subject.runAll()

        let result = try XCTUnwrap(subject.result(for: .perReportCharacteristic))
        XCTAssertTrue(result.servicePublished)
        XCTAssertFalse(result.centralSubscribed)
        XCTAssertTrue(
            result.notes.contains { $0.contains("connected but never subscribed") },
            "Expected a note distinguishing 'connected, did not subscribe' from 'never connected'. Notes: \(result.notes)"
        )
    }

    // MARK: Qualifications — the overclaim guards

    func testPerReportCharacteristicAlwaysCarriesTheSilentDescriptorCaveat() async throws {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.perReportCharacteristic]

        let subject = makeSubject(fake)
        await subject.runAll()

        let result = try XCTUnwrap(subject.result(for: .perReportCharacteristic))
        XCTAssertEqual(subject.state(for: .perReportCharacteristic), .confirmed)
        XCTAssertTrue(
            result.qualifications.contains(HIDDiagnostics.descriptorSilentFailureCaveat),
            "A green perReportCharacteristic row must never be presented as an unqualified pass."
        )
    }

    func testOtherTopologiesDoNotCarryTheDescriptorCaveat() async throws {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.bootProtocolOnly]

        let subject = makeSubject(fake)
        await subject.runAll()

        let result = try XCTUnwrap(subject.result(for: .bootProtocolOnly))
        XCTAssertFalse(result.qualifications.contains(HIDDiagnostics.descriptorSilentFailureCaveat))
    }

    func testConfirmedRoundTripCarriesTheNegativeInferenceCaveat() async throws {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.bootProtocolOnly]

        let subject = makeSubject(fake)
        await subject.runAll()

        let result = try XCTUnwrap(subject.result(for: .bootProtocolOnly))
        XCTAssertTrue(result.roundTripConfirmed)
        XCTAssertTrue(
            result.qualifications.contains(HIDDiagnostics.roundTripCaveat),
            "A confirmed round trip is a negative inference and must say so."
        )
    }

    // MARK: Recommendation

    func testRecommendationPicksTheEarliestFullyWorkingTopology() async {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.singleCharacteristicPrefixed, .bootProtocolOnly]
        fake.startErrors[.perReportCharacteristic] = .descriptorRejected("0x2908 unsupported")

        let subject = makeSubject(fake)
        await subject.runAll()

        XCTAssertEqual(subject.recommendation, .singleCharacteristicPrefixed,
                       "The earliest passing candidate wins, not the last one probed.")
    }

    func testRecommendationIsNilWhenNothingSubscribes() async {
        let fake = FakePeripheral()
        let subject = makeSubject(fake)
        await subject.runAll()
        XCTAssertNil(subject.recommendation)
    }

    func testRecommendationIgnoresTopologiesThatOnlyPublished() async {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.bootProtocolOnly]

        let subject = makeSubject(fake)
        await subject.runAll()

        XCTAssertEqual(subject.recommendation, .bootProtocolOnly)
    }

    func testAdoptWritesTheTopologyIntoSettingsOnlyWhenAsked() async {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.bootProtocolOnly]
        let settings = AppSettings(defaults: Self.scratchDefaults())
        settings.preferredTopology = .perReportCharacteristic

        let subject = makeSubject(fake)
        await subject.runAll()

        // A completed run must not silently rewrite the user's preference.
        XCTAssertEqual(settings.preferredTopology, .perReportCharacteristic)
        XCTAssertEqual(subject.recommendation, .bootProtocolOnly)

        subject.adopt(.bootProtocolOnly, into: settings)
        XCTAssertEqual(settings.preferredTopology, .bootProtocolOnly)
    }

    // MARK: Round trip

    func testLinkDroppingAfterTheProbeReportsIsNotCountedAsConfirmed() async throws {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.perReportCharacteristic]
        fake.dropsOnSendTopologies = [.perReportCharacteristic]

        let subject = makeSubject(fake)
        await subject.runAll()

        let result = try XCTUnwrap(subject.result(for: .perReportCharacteristic))
        XCTAssertEqual(result.publishOutcome, .confirmed)
        XCTAssertTrue(result.centralSubscribed)
        XCTAssertFalse(result.roundTripConfirmed)
        XCTAssertEqual(subject.state(for: .perReportCharacteristic), .subscribed)
        XCTAssertFalse(result.qualifications.contains(HIDDiagnostics.roundTripCaveat),
                       "The round-trip caveat belongs only on rows that claim a round trip.")
    }

    func testProbeSendsOnlyHarmlessReports() async {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.perReportCharacteristic]

        let subject = makeSubject(fake)
        await subject.runAll()

        XCTAssertEqual(fake.sentMouse.count, 1)
        XCTAssertTrue(fake.sentMouse[0].isIdle, "The probe must not be able to move the cursor.")
        XCTAssertEqual(fake.sentConsumer, [ConsumerReport.released])
        XCTAssertTrue(fake.sentKeyboard.isEmpty)
        XCTAssertEqual(subject.state(for: .perReportCharacteristic), .confirmed)
    }

    func testBootProtocolTopologySkipsTheConsumerProbe() async throws {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.bootProtocolOnly]
        fake.startErrors[.perReportCharacteristic] = .serviceRejected("no")
        fake.startErrors[.singleCharacteristicPrefixed] = .serviceRejected("no")

        let subject = makeSubject(fake)
        await subject.runAll()

        XCTAssertEqual(fake.sentMouse.count, 1)
        XCTAssertTrue(fake.sentConsumer.isEmpty,
                      "boot protocol carries no consumer report, so none should be sent.")
        let result = try XCTUnwrap(subject.result(for: .bootProtocolOnly))
        XCTAssertTrue(result.notes.contains { $0.contains("no consumer report") })
    }

    // MARK: Single-topology probing

    func testRunOneProbesOnlyThatTopologyAndLeavesTheOthersUnmeasured() async throws {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.bootProtocolOnly]

        let subject = makeSubject(fake)
        await subject.runOne(.bootProtocolOnly)

        XCTAssertEqual(fake.startedTopologies, [.bootProtocolOnly])
        XCTAssertEqual(subject.lastRunScope, .single(.bootProtocolOnly))

        let measured = try XCTUnwrap(subject.result(for: .bootProtocolOnly))
        XCTAssertEqual(measured.publishOutcome, .confirmed)
        XCTAssertNotNil(measured.measuredAt)

        for topology in [ReportTopology.perReportCharacteristic, .singleCharacteristicPrefixed] {
            let untouched = try XCTUnwrap(subject.result(for: topology))
            XCTAssertEqual(untouched.publishOutcome, .notAttempted, "\(topology)")
            XCTAssertNil(untouched.measuredAt, "\(topology) was never measured and must say so.")
            XCTAssertEqual(subject.state(for: topology), .pending)
        }
    }

    func testRunOneAfterASweepReplacesOnlyThatRow() async throws {
        let fake = FakePeripheral()
        fake.subscribingTopologies = Set(ReportTopology.allCases)

        let subject = makeSubject(fake)
        await subject.runAll()
        let sweepStamp = try XCTUnwrap(subject.result(for: .perReportCharacteristic)?.measuredAt)

        await subject.runOne(.bootProtocolOnly)

        XCTAssertEqual(
            subject.result(for: .perReportCharacteristic)?.measuredAt, sweepStamp,
            "A single probe must not restamp rows it did not measure."
        )
        XCTAssertEqual(subject.lastRunScope, .single(.bootProtocolOnly))
    }

    func testRunOneIsANoOpWhileASweepIsRunning() async {
        let fake = FakePeripheral()
        let subject = makeSubject(fake)

        let sweep = Task { await subject.runAll() }
        try? await Task.sleep(for: .milliseconds(30))
        await subject.runOne(.bootProtocolOnly)
        await sweep.value

        XCTAssertEqual(fake.startedTopologies.count, ReportTopology.allCases.count)
    }

    // MARK: Teardown discipline

    func testEveryProbeStopsTheManager() async {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.singleCharacteristicPrefixed]

        let subject = makeSubject(fake)
        await subject.runAll()

        // One stop per probe plus one final stop from the run's own cleanup.
        XCTAssertEqual(fake.stopCount, ReportTopology.allCases.count + 1)
        XCTAssertFalse(subject.isRunning)
        XCTAssertNil(subject.currentTopology)
    }

    // MARK: Bounded time

    func testRunTerminatesWithinABoundedTimeEvenWhenNothingEverSubscribes() async {
        let fake = FakePeripheral()
        let subject = makeSubject(fake)

        let start = Date()
        await subject.runAll()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0, "The probe run must be bounded, took \(elapsed)s")
        XCTAssertFalse(subject.isRunning)
        XCTAssertFalse(subject.lastRunWasCancelled)
        XCTAssertNotNil(subject.lastRunFinished)
        XCTAssertEqual(subject.lastRunScope, .sweep)
    }

    func testUnresolvedPublishRunIsAlsoBounded() async {
        let fake = FakePeripheral()
        fake.unconfirmedPublishTopologies = Set(ReportTopology.allCases)
        let subject = makeSubject(fake)

        let start = Date()
        await subject.runAll()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    func testConcurrentRunAllIsANoOp() async {
        let fake = FakePeripheral()
        fake.subscribingTopologies = Set(ReportTopology.allCases)
        let subject = makeSubject(fake)

        async let first: Void = subject.runAll()
        async let second: Void = subject.runAll()
        _ = await (first, second)

        XCTAssertEqual(fake.startedTopologies.count, ReportTopology.allCases.count,
                       "A second concurrent run must not double-probe the radio.")
    }

    // MARK: Cancellation

    func testCancellationMidRunStopsTheManagerAndEndsTheRun() async {
        let fake = FakePeripheral()
        // Nothing subscribes, so the first probe sits in its 150 ms window.
        let subject = makeSubject(fake)

        let task = Task { await subject.runAll() }

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(subject.isRunning)

        task.cancel()
        await task.value

        XCTAssertFalse(subject.isRunning, "Cancellation must end the run.")
        XCTAssertNil(subject.currentTopology)
        XCTAssertTrue(subject.lastRunWasCancelled)
        XCTAssertGreaterThan(fake.stopCount, 0, "The radio must be stopped on cancellation.")
        XCTAssertEqual(fake.connectionState, .idle)
        XCTAssertLessThan(fake.startedTopologies.count, ReportTopology.allCases.count,
                          "Cancellation should have prevented the later probes from starting.")
    }

    func testCancellationBeforeAnyProbeStartsStillCleansUp() async {
        let fake = FakePeripheral()
        let subject = makeSubject(fake)

        let task = Task { await subject.runAll() }
        task.cancel()
        await task.value

        XCTAssertFalse(subject.isRunning)
        XCTAssertGreaterThan(fake.stopCount, 0)
        XCTAssertTrue(subject.lastRunWasCancelled)
    }

    func testCancellationOfASingleProbeStopsTheManager() async {
        let fake = FakePeripheral()
        let subject = makeSubject(fake)

        let task = Task { await subject.runOne(.perReportCharacteristic) }
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()
        await task.value

        XCTAssertFalse(subject.isRunning)
        XCTAssertTrue(subject.lastRunWasCancelled)
        XCTAssertGreaterThan(fake.stopCount, 0)
    }

    // MARK: Central naming

    func testConnectedCentralWithNoNameRendersAsUnknownMac() async {
        let fake = FakePeripheral()
        fake.centralName = nil
        fake.subscribingTopologies = [.perReportCharacteristic]

        let subject = makeSubject(fake)
        try? fake.start(topology: .perReportCharacteristic)

        XCTAssertEqual(
            subject.centralDisplayName, "Unknown Mac",
            "CBCentral exposes no name, so a nil must never reach the UI as a blank."
        )
    }

    func testConnectedCentralWithABlankNameAlsoRendersAsUnknownMac() {
        let fake = FakePeripheral()
        fake.connectionState = .connected(centralName: "   ")
        let subject = makeSubject(fake)
        XCTAssertEqual(subject.centralDisplayName, "Unknown Mac")
    }

    func testCentralDisplayNameIsNilWhenNotConnected() {
        let fake = FakePeripheral()
        fake.connectionState = .advertising
        XCTAssertNil(makeSubject(fake).centralDisplayName)
    }

    // MARK: Export

    func testExportReportContainsEveryTopologyAndTheVerbatimFailure() async {
        let fake = FakePeripheral()
        fake.startErrors[.perReportCharacteristic] = .descriptorRejected(
            "Descriptors with UUID 2908 are not supported"
        )
        fake.subscribingTopologies = [.singleCharacteristicPrefixed]

        let subject = makeSubject(fake)
        await subject.runAll()

        let report = subject.exportReport()

        for topology in ReportTopology.allCases {
            XCTAssertTrue(report.contains(topology.rawValue), "Missing \(topology.rawValue)")
        }
        XCTAssertTrue(report.contains("Descriptors with UUID 2908 are not supported"))
        XCTAssertTrue(report.contains("Recommendation: singleCharacteristicPrefixed"))
        XCTAssertTrue(report.contains("PERIPHERAL MANAGER LOG"))
        XCTAssertTrue(report.contains("Central subscribed for singleCharacteristicPrefixed"))
        XCTAssertTrue(report.contains("Run scope: full sweep"))
    }

    func testExportReportReproducesTheGattCacheWarningVerbatim() async {
        let subject = makeSubject(FakePeripheral())
        await subject.runAll()

        XCTAssertTrue(
            containsVerbatim(subject.exportReport(), HIDDiagnostics.gattCacheWarning),
            "A report read out of context must carry the cache warning with it."
        )
    }

    func testExportReportReproducesTheStandingCaveats() async {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.perReportCharacteristic]
        let subject = makeSubject(fake)
        await subject.runAll()

        let report = subject.exportReport()
        XCTAssertTrue(containsVerbatim(report, HIDDiagnostics.descriptorSilentFailureCaveat))
        XCTAssertTrue(containsVerbatim(report, HIDDiagnostics.roundTripCaveat))
        XCTAssertTrue(containsVerbatim(report, HIDDiagnostics.connectionIntervalCaveat))
        XCTAssertTrue(report.contains("QUALIFICATIONS"))
    }

    func testExportReportRecordsTheAsynchronousRejectionVerbatim() async {
        let fake = FakePeripheral()
        fake.asyncRejections[.singleCharacteristicPrefixed] =
            "The specified UUID is not allowed for this operation."

        let subject = makeSubject(fake)
        await subject.runAll()

        let report = subject.exportReport()
        XCTAssertTrue(report.contains("The specified UUID is not allowed for this operation."))
        XCTAssertTrue(report.contains("Refused after publish"))
    }

    func testExportReportDoesNotPresentTheConnectionIntervalAsMeasured() async {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.perReportCharacteristic]
        XCTAssertNil(fake.negotiatedConnectionInterval,
                     "The real manager can never populate this from CoreBluetooth.")

        let subject = makeSubject(fake)
        await subject.runAll()

        let report = subject.exportReport()
        XCTAssertTrue(report.contains("Connection interval: not available"))
        XCTAssertFalse(report.contains("Negotiated connection interval:"),
                       "Nothing here is a negotiated measurement.")
    }

    func testExportReportStampsUnmeasuredRows() async {
        let fake = FakePeripheral()
        let subject = makeSubject(fake)
        await subject.runOne(.bootProtocolOnly)

        let report = subject.exportReport()
        XCTAssertTrue(report.contains("NOT MEASURED in this session"))
        XCTAssertTrue(report.contains("Run scope: single probe of bootProtocolOnly"))
    }

    func testExportReportMarksACancelledRunAsIncomplete() async {
        let fake = FakePeripheral()
        let subject = makeSubject(fake)

        let task = Task { await subject.runAll() }
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()
        await task.value

        XCTAssertTrue(subject.exportReport().contains("CANCELLED"))
    }

    func testExportReportIsUsableBeforeAnyRun() {
        let subject = makeSubject(FakePeripheral())
        let report = subject.exportReport()
        XCTAssertTrue(report.contains("not yet run"))
        XCTAssertTrue(report.contains("Recommendation: none"))
        XCTAssertTrue(report.contains("Run scope: none"))
        XCTAssertTrue(containsVerbatim(report, HIDDiagnostics.gattCacheWarning))
    }

    // MARK: Helpers

    /// A throwaway `UserDefaults` domain so tests never touch the real one.
    private static func scratchDefaults() -> UserDefaults {
        let suite = "PocketTrackpadTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }
}
