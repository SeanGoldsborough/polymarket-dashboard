//
//  HIDDiagnosticsTests.swift
//  PocketTrackpadTests
//
//  `StubHIDSender` is a success-path stub — it never throws and always reports
//  a full subscription — so it cannot exercise any of the paths that matter
//  here. `FakePeripheral` below adds failure injection: per-topology start
//  errors, per-topology subscription behaviour, and a "host drops the link when
//  we send" mode.
//
//  Every timeout in these tests comes from `ProbeTiming.fast` (150 ms window,
//  10 ms poll, 20 ms settle), so a full three-topology run costs under half a
//  second even in the worst case where nothing ever subscribes.
//

import XCTest
@testable import PocketTrackpad

// MARK: - Fake

@MainActor
final class FakePeripheral: HIDPeripheralControlling {

    // MARK: Injection

    /// Topologies whose `start(topology:)` throws, and with what.
    var startErrors: [ReportTopology: HIDError] = [:]

    /// Topologies for which a central connects and subscribes immediately.
    var subscribingTopologies: Set<ReportTopology> = []

    /// Topologies for which a central connects but never subscribes.
    var connectingButSilentTopologies: Set<ReportTopology> = []

    /// Topologies where the host drops the link as soon as we send a report —
    /// the "published, subscribed, but the report map was rejected" case.
    var dropsOnSendTopologies: Set<ReportTopology> = []

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
    var negotiatedConnectionInterval: TimeInterval?

    func start(topology: ReportTopology) throws {
        startedTopologies.append(topology)
        activeTopology = topology

        if let error = startErrors[topology] {
            log.append(HIDLogEntry(level: .failure, message: "start(\(topology.rawValue)) threw"))
            throw error
        }

        if subscribingTopologies.contains(topology) {
            connectionState = .connected(centralName: "Fake Mac")
            subscribedReports = Set(topology.supportedReports)
            negotiatedConnectionInterval = 0.015
            log.append(HIDLogEntry(level: .success, message: "Central subscribed for \(topology.rawValue)"))
        } else if connectingButSilentTopologies.contains(topology) {
            connectionState = .connected(centralName: "Fake Mac")
            subscribedReports = []
            log.append(HIDLogEntry(level: .warning, message: "Central connected but did not subscribe"))
        } else {
            connectionState = .advertising
            subscribedReports = []
            log.append(HIDLogEntry(level: .info, message: "Advertising for \(topology.rawValue)"))
        }
    }

    func stop() {
        stopCount += 1
        connectionState = .idle
        subscribedReports = []
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

    // MARK: Rejection

    func testTopologyThatThrowsOnStartIsRecordedAsRejectedAndTheRunContinues() async throws {
        let fake = FakePeripheral()
        fake.startErrors[.perReportCharacteristic] = .descriptorRejected(
            "Descriptors with UUID 2908 are not supported"
        )
        fake.subscribingTopologies = [.singleCharacteristicPrefixed]

        let subject = makeSubject(fake)
        await subject.runAll()

        let rejected = try XCTUnwrap(subject.result(for: .perReportCharacteristic))
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
        XCTAssertTrue(next.servicePublished)
        XCTAssertTrue(next.centralSubscribed)
    }

    func testRejectedTopologyIsNeverProbedForSubscription() async throws {
        let fake = FakePeripheral()
        // Every topology throws; nothing should ever be sent.
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

    // MARK: Published but unsubscribed

    func testTopologyThatPublishesWithoutASubscriberIsRecordedAsPublished() async throws {
        let fake = FakePeripheral()
        // Nothing subscribes anywhere: every probe must time out cleanly.
        let subject = makeSubject(fake)
        await subject.runAll()

        for topology in ReportTopology.allCases {
            let result = try XCTUnwrap(subject.result(for: topology))
            XCTAssertTrue(result.servicePublished, "\(topology) should have published")
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
        // The first two publish but nobody subscribes; only the last works.
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
        XCTAssertTrue(result.servicePublished)
        XCTAssertTrue(result.centralSubscribed)
        XCTAssertFalse(result.roundTripConfirmed)
        XCTAssertEqual(subject.state(for: .perReportCharacteristic), .subscribed)
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
        // Make the other two throw so only the boot probe sends anything.
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

    // MARK: Teardown discipline

    func testEveryProbeStopsTheManager() async {
        let fake = FakePeripheral()
        fake.subscribingTopologies = [.singleCharacteristicPrefixed]

        let subject = makeSubject(fake)
        await subject.runAll()

        // One stop per probe plus one final stop from `runAll`'s own cleanup.
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

        // Worst case is three full 150 ms windows. A generous ceiling still
        // catches an unbounded await, which is the failure this guards.
        XCTAssertLessThan(elapsed, 2.0, "The probe run must be bounded, took \(elapsed)s")
        XCTAssertFalse(subject.isRunning)
        XCTAssertFalse(subject.lastRunWasCancelled)
        XCTAssertNotNil(subject.lastRunFinished)
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

        // Let the first probe get as far as its bounded wait.
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
        // The manager's own log has to make it into the export.
        XCTAssertTrue(report.contains("Central subscribed for singleCharacteristicPrefixed"))
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
    }

    // MARK: Helpers

    /// A throwaway `UserDefaults` domain so tests never touch the real one.
    private static func scratchDefaults() -> UserDefaults {
        let suite = "PocketTrackpadTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }
}
