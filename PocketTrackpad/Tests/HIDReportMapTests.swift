//
//  HIDReportMapTests.swift
//  PocketTrackpadTests
//
//  Structural proofs about the report descriptor, and round-trip proofs about
//  the encoders.
//
//  These tests exist because the failure they guard against is invisible. A
//  descriptor with a wrong Report Count still parses, still gets accepted by
//  iOS, still lets macOS pair — and then the cursor does not move, with no error
//  anywhere in the system. The only place the mistake is detectable is here, by
//  walking the byte stream and checking it against `payloadSize`.
//
//  Nothing here touches CoreBluetooth, so the whole file runs on the Simulator
//  and in CI.
//

import XCTest
@testable import PocketTrackpad

// MARK: - A minimal HID item walker

/// One parsed short item.
private struct HIDItem {
    let offset: Int
    let tag: UInt8
    let type: UInt8      // 0 main, 1 global, 2 local
    let data: [UInt8]

    /// Unsigned little-endian interpretation of the data bytes.
    var unsigned: Int {
        var value = 0
        for (index, byte) in data.enumerated() { value |= Int(byte) << (8 * index) }
        return value
    }
}

private enum HIDWalkError: Error, CustomStringConvertible {
    case truncatedItem(offset: Int, needed: Int, available: Int)
    case longItem(offset: Int)
    case unbalancedCollection(offset: Int)
    case unclosedCollections(depth: Int)

    var description: String {
        switch self {
        case .truncatedItem(let offset, let needed, let available):
            return "Item at \(offset) declares \(needed) data bytes but only \(available) remain"
        case .longItem(let offset):
            return "Long item (0xFE) at \(offset); this builder must never emit one"
        case .unbalancedCollection(let offset):
            return "End Collection at \(offset) with no open collection"
        case .unclosedCollections(let depth):
            return "Descriptor ended with \(depth) collection(s) still open"
        }
    }
}

/// What a walk learned about one top-level Application collection.
private struct CollectionSummary {
    var reportID: Int?
    var inputBits = 0
    var outputBits = 0
    var featureBits = 0
}

private struct WalkResult {
    var items: [HIDItem] = []
    var collections: [CollectionSummary] = []
    var reportIDs: [Int] = []
    var maxDepth = 0
}

/// Step through a descriptor, validating framing and accumulating bit counts.
///
/// Deliberately written from the spec rather than reused from the builder: a
/// test that shares the production encoder cannot detect an encoder bug.
private func walkHIDDescriptor(_ bytes: [UInt8]) throws -> WalkResult {
    var result = WalkResult()
    var index = 0
    var depth = 0
    var reportSize = 0
    var reportCount = 0
    var currentCollection = -1

    while index < bytes.count {
        let prefix = bytes[index]

        // 0b1111_1110 is the long-item prefix. Long items carry a separate size
        // byte and a vendor tag; nothing in this project emits one.
        guard prefix != 0xFE else { throw HIDWalkError.longItem(offset: index) }

        let sizeCode = prefix & 0b0000_0011
        let dataLength = sizeCode == 3 ? 4 : Int(sizeCode)
        let tag = (prefix & 0b1111_0000) >> 4
        let type = (prefix & 0b0000_1100) >> 2

        let available = bytes.count - index - 1
        guard available >= dataLength else {
            throw HIDWalkError.truncatedItem(offset: index, needed: dataLength, available: available)
        }

        let data = Array(bytes[(index + 1)..<(index + 1 + dataLength)])
        let item = HIDItem(offset: index, tag: tag, type: type, data: data)
        result.items.append(item)

        switch type {
        case 1: // Global
            switch tag {
            case 0x7: reportSize = item.unsigned
            case 0x9: reportCount = item.unsigned
            case 0x8:
                result.reportIDs.append(item.unsigned)
                if currentCollection >= 0 {
                    result.collections[currentCollection].reportID = item.unsigned
                }
            default: break
            }

        case 0: // Main
            switch tag {
            case 0xA: // Collection
                if depth == 0 {
                    result.collections.append(CollectionSummary())
                    currentCollection = result.collections.count - 1
                }
                depth += 1
                result.maxDepth = max(result.maxDepth, depth)
            case 0xC: // End Collection
                guard depth > 0 else { throw HIDWalkError.unbalancedCollection(offset: index) }
                depth -= 1
            case 0x8 where currentCollection >= 0: // Input
                result.collections[currentCollection].inputBits += reportSize * reportCount
            case 0x9 where currentCollection >= 0: // Output
                result.collections[currentCollection].outputBits += reportSize * reportCount
            case 0xB where currentCollection >= 0: // Feature
                result.collections[currentCollection].featureBits += reportSize * reportCount
            default: break
            }

        default: // Local — usages; nothing to accumulate.
            break
        }

        index += 1 + dataLength
    }

    guard depth == 0 else { throw HIDWalkError.unclosedCollections(depth: depth) }
    return result
}

// MARK: - Descriptor structure

final class HIDReportMapTests: XCTestCase {

    private let multiReportTopologies: [ReportTopology] = [
        .perReportCharacteristic, .singleCharacteristicPrefixed
    ]

    // MARK: Framing

    func testEveryTopologyProducesAWellFormedItemStream() throws {
        for topology in ReportTopology.allCases {
            let bytes = HIDReportMap.descriptor(for: topology)
            XCTAssertFalse(bytes.isEmpty, "\(topology.rawValue) produced an empty descriptor")
            // Throws on truncation, long items, or unbalanced collections.
            let walk = try walkHIDDescriptor(bytes)
            XCTAssertGreaterThan(walk.items.count, 20, "\(topology.rawValue) is implausibly short")
        }
    }

    func testTruncatedDescriptorIsRejectedByTheWalker() {
        // Proves the walker can actually fail — a validator that never rejects
        // anything is worse than no validator, because it reads as a passing test.
        // 0x07 is a Usage Page prefix with size code 3, i.e. "four data bytes
        // follow"; appending it with nothing after it is a truncated item.
        var bytes = HIDReportMap.descriptor(for: .perReportCharacteristic)
        bytes.append(0x07)
        XCTAssertThrowsError(try walkHIDDescriptor(bytes))
    }

    func testUnbalancedDescriptorIsRejectedByTheWalker() {
        // Drop the final End Collection (0xC0) and the stream must fail to close.
        var bytes = HIDReportMap.descriptor(for: .perReportCharacteristic)
        XCTAssertEqual(bytes.last, UInt8(0xC0), "Descriptor should end with End Collection")
        bytes.removeLast()
        XCTAssertThrowsError(try walkHIDDescriptor(bytes))
    }

    // MARK: Report IDs

    func testMultiReportTopologiesDeclareExactlyThreeReportIDs() throws {
        for topology in multiReportTopologies {
            let walk = try walkHIDDescriptor(HIDReportMap.descriptor(for: topology))
            XCTAssertEqual(walk.reportIDs, [1, 2, 3], "\(topology.rawValue)")
            XCTAssertEqual(walk.collections.count, 3, "\(topology.rawValue) top-level collections")
            XCTAssertEqual(
                walk.reportIDs.sorted(),
                HIDReportID.allCases.map { Int($0.rawValue) }.sorted(),
                "Descriptor report IDs must match HIDReportID"
            )
        }
    }

    func testBootTopologyDeclaresNoReportIDs() throws {
        let walk = try walkHIDDescriptor(HIDReportMap.descriptor(for: .bootProtocolOnly))
        XCTAssertEqual(walk.reportIDs, [], "Boot reports are un-prefixed and must carry no Report ID item")
        XCTAssertEqual(walk.collections.count, 2, "Boot descriptor is mouse + keyboard only")
    }

    func testPerReportAndPrefixedTopologiesShareOneDescriptor() {
        // They differ only in transport framing; a divergence here would mean the
        // host parses one layout and receives another.
        XCTAssertEqual(
            HIDReportMap.descriptor(for: .perReportCharacteristic),
            HIDReportMap.descriptor(for: .singleCharacteristicPrefixed)
        )
    }

    // MARK: Bit counts — the assertion this whole file exists for

    func testMultiReportBitCountsMatchPayloadSizes() throws {
        let expected: [Int: Int] = [
            Int(HIDReportID.mouse.rawValue):    MouseReport.payloadSize * 8,
            Int(HIDReportID.keyboard.rawValue): KeyboardReport.payloadSize * 8,
            Int(HIDReportID.consumer.rawValue): ConsumerReport.payloadSize * 8
        ]

        for topology in multiReportTopologies {
            let walk = try walkHIDDescriptor(HIDReportMap.descriptor(for: topology))
            for collection in walk.collections {
                let reportID = try XCTUnwrap(collection.reportID, "\(topology.rawValue): collection with no Report ID")
                let want = try XCTUnwrap(expected[reportID], "Unexpected report ID \(reportID)")
                XCTAssertEqual(
                    collection.inputBits, want,
                    "Report \(reportID) declares \(collection.inputBits) input bits, encoder emits \(want)"
                )
                XCTAssertEqual(collection.inputBits % 8, 0, "Report \(reportID) is not byte-aligned")
            }
            // No output or feature reports in the report-protocol topologies; see
            // `appendKeyboardCollection` for why the LED report is boot-only.
            XCTAssertEqual(walk.collections.map(\.outputBits), [0, 0, 0])
            XCTAssertEqual(walk.collections.map(\.featureBits), [0, 0, 0])
        }
    }

    func testBootBitCountsMatchPayloadSizes() throws {
        let walk = try walkHIDDescriptor(HIDReportMap.descriptor(for: .bootProtocolOnly))
        XCTAssertEqual(walk.collections.count, 2)

        // Order is mouse then keyboard, matching `ReportTopology.supportedReports`.
        XCTAssertEqual(walk.collections[0].inputBits, MouseReport.payloadSize * 8)
        XCTAssertEqual(walk.collections[0].outputBits, 0)

        XCTAssertEqual(walk.collections[1].inputBits, KeyboardReport.payloadSize * 8)
        // Exactly one byte of LED output: 5 LED bits + 3 bits of padding.
        XCTAssertEqual(walk.collections[1].outputBits, 8, "Boot keyboards must declare the LED output report")
    }

    // MARK: Byte counts
    //
    // Exact sizes are asserted as a change detector. A deliberate descriptor edit
    // is expected to update these numbers *and* to re-check the bit-count tests
    // above, which are the ones that actually protect correctness.

    func testDescriptorByteCounts() {
        XCTAssertEqual(HIDReportMap.descriptor(for: .perReportCharacteristic).count, 142)
        XCTAssertEqual(HIDReportMap.descriptor(for: .singleCharacteristicPrefixed).count, 142)
        XCTAssertEqual(HIDReportMap.descriptor(for: .bootProtocolOnly).count, 135)
    }

    func testDescriptorFitsInASingleAttributeRead() {
        // A GATT characteristic value is capped at 512 bytes. Larger report maps
        // are legal on paper and are read with ATT Read Blob, but CoreBluetooth's
        // peripheral role silently truncates a cached value past 512, and the
        // resulting half-descriptor parses as valid garbage on the host.
        for topology in ReportTopology.allCases {
            XCTAssertLessThanOrEqual(HIDReportMap.descriptor(for: topology).count, 512, "\(topology.rawValue)")
        }
    }

    // MARK: Consumer range

    func testEveryConsumerUsageIsRepresentable() throws {
        let walk = try walkHIDDescriptor(HIDReportMap.descriptor(for: .perReportCharacteristic))
        // Logical Maximum is global tag 0x2; the largest one in the descriptor is
        // the consumer collection's.
        let logicalMaxima = walk.items
            .filter { $0.type == 1 && $0.tag == 0x2 }
            .map(\.unsigned)
        let declaredMax = try XCTUnwrap(logicalMaxima.max())

        for usage in ConsumerUsage.allCases {
            XCTAssertLessThanOrEqual(
                Int(usage.rawValue), declaredMax,
                "\(usage) (0x\(String(usage.rawValue, radix: 16))) exceeds the declared consumer range"
            )
        }
        XCTAssertEqual(declaredMax, 0x029F)
        let largestUsage = Int(ConsumerUsage.allCases.map(\.rawValue).max() ?? 0)
        XCTAssertEqual(
            largestUsage, 0x029F,
            "If a larger ConsumerUsage is added, the descriptor's maximum must move with it"
        )
    }

    // MARK: - Encoders

    func testMouseEncodesFiveBytesInDescriptorOrder() {
        let report = MouseReport(buttons: [.left, .middle], dx: 10, dy: -20, wheel: 3, pan: -4)
        let bytes = Array(report.encodePayload())
        XCTAssertEqual(bytes.count, MouseReport.payloadSize)
        XCTAssertEqual(bytes[0], 0b0000_0101)                 // left | middle
        XCTAssertEqual(Int8(bitPattern: bytes[1]), 10)
        XCTAssertEqual(Int8(bitPattern: bytes[2]), -20)
        XCTAssertEqual(Int8(bitPattern: bytes[3]), 3)
        XCTAssertEqual(Int8(bitPattern: bytes[4]), -4)
    }

    func testMouseClampsToDeclaredLogicalRange() {
        let report = MouseReport(buttons: .none, dx: 5_000, dy: -5_000, wheel: 128, pan: -128)
        let bytes = Array(report.encodePayload())
        // The descriptor declares -127...127, not -128...127.
        XCTAssertEqual(Int8(bitPattern: bytes[1]), 127)
        XCTAssertEqual(Int8(bitPattern: bytes[2]), -127)
        XCTAssertEqual(Int8(bitPattern: bytes[3]), 127)
        XCTAssertEqual(Int8(bitPattern: bytes[4]), -127)
    }

    func testMouseClampBoundariesAreInclusive() {
        let bytes = Array(MouseReport(dx: 127, dy: -127, wheel: 126, pan: -126).encodePayload())
        XCTAssertEqual(Int8(bitPattern: bytes[1]), 127)
        XCTAssertEqual(Int8(bitPattern: bytes[2]), -127)
        XCTAssertEqual(Int8(bitPattern: bytes[3]), 126)
        XCTAssertEqual(Int8(bitPattern: bytes[4]), -126)
    }

    func testMouseMasksButtonsBeyondTheDeclaredThreeBits() {
        // Bits 3...7 are declared constant padding; letting a caller's stray bits
        // reach the wire would make the host read a padding field it was told never
        // changes.
        let report = MouseReport(buttons: MouseButtons(rawValue: 0xFF))
        XCTAssertEqual(Array(report.encodePayload())[0], 0x07)
    }

    func testIdleMouseEncodesAllZeroes() {
        XCTAssertEqual(Array(MouseReport().encodePayload()), [0, 0, 0, 0, 0])
        XCTAssertTrue(MouseReport().isIdle)
    }

    func testKeyboardEncodesEightBytesWithReservedByte() {
        let report = KeyboardReport(modifiers: [.leftShift, .leftCommand], keys: [HIDKeyCode.a, HIDKeyCode.b])
        let bytes = Array(report.encodePayload())
        XCTAssertEqual(bytes.count, KeyboardReport.payloadSize)
        XCTAssertEqual(bytes[0], KeyModifiers([.leftShift, .leftCommand]).rawValue)
        XCTAssertEqual(bytes[1], 0, "Byte 1 is reserved and must always be zero")
        XCTAssertEqual(bytes[2], HIDKeyCode.a)
        XCTAssertEqual(bytes[3], HIDKeyCode.b)
        XCTAssertEqual(Array(bytes[4...]), [0, 0, 0, 0])
    }

    func testKeyboardPadsShortKeyArrays() {
        XCTAssertEqual(Array(KeyboardReport.released.encodePayload()), [0, 0, 0, 0, 0, 0, 0, 0])
        let single = Array(KeyboardReport(keys: [HIDKeyCode.z]).encodePayload())
        XCTAssertEqual(single, [0, 0, HIDKeyCode.z, 0, 0, 0, 0, 0])
    }

    func testKeyboardTruncatesToSixKeys() {
        let keys: [UInt8] = [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B]
        let bytes = Array(KeyboardReport(modifiers: .leftControl, keys: keys).encodePayload())
        XCTAssertEqual(bytes.count, KeyboardReport.payloadSize)
        XCTAssertEqual(Array(bytes[2...]), [0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
    }

    func testKeyboardExactlySixKeysFits() {
        let keys: [UInt8] = [0x04, 0x05, 0x06, 0x07, 0x08, 0x09]
        let bytes = Array(KeyboardReport(keys: keys).encodePayload())
        XCTAssertEqual(Array(bytes[2...]), keys)
    }

    func testConsumerEncodesLittleEndian() {
        XCTAssertEqual(Array(ConsumerReport(.volumeUp).encodePayload()), [0xE9, 0x00])
        XCTAssertEqual(Array(ConsumerReport(.acDesktopShowAll).encodePayload()), [0x9F, 0x02])
        XCTAssertEqual(Array(ConsumerReport.released.encodePayload()), [0x00, 0x00])
    }

    func testEveryConsumerUsageRoundTrips() {
        for usage in ConsumerUsage.allCases {
            let bytes = Array(ConsumerReport(usage).encodePayload())
            XCTAssertEqual(bytes.count, ConsumerReport.payloadSize)
            let decoded = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            XCTAssertEqual(decoded, usage.rawValue, "\(usage)")
        }
    }

    func testPrefixedEncodingPrependsTheReportID() {
        // `.singleCharacteristicPrefixed` sends the ID as byte 0; every other
        // topology must not.
        let mouse = MouseReport(dx: 1)
        XCTAssertEqual(Array(mouse.encodePrefixed()).first, HIDReportID.mouse.rawValue)
        XCTAssertEqual(mouse.encodePrefixed().count, MouseReport.payloadSize + 1)
        XCTAssertEqual(Array(mouse.encodePrefixed().dropFirst()), Array(mouse.encodePayload()))

        let keyboard = KeyboardReport(keys: [HIDKeyCode.q])
        XCTAssertEqual(Array(keyboard.encodePrefixed()).first, HIDReportID.keyboard.rawValue)
        XCTAssertEqual(keyboard.encodePrefixed().count, KeyboardReport.payloadSize + 1)

        let consumer = ConsumerReport(.mute)
        XCTAssertEqual(Array(consumer.encodePrefixed()).first, HIDReportID.consumer.rawValue)
        XCTAssertEqual(consumer.encodePrefixed().count, ConsumerReport.payloadSize + 1)
    }

    // MARK: - GATT payloads

    func testHIDInformationValue() {
        XCTAssertEqual(Array(HIDInformation.value), [0x11, 0x01, 0x00, 0x02])
        // bcdHID little-endian == 0x0111 == "HID 1.11".
        let bcd = UInt16(HIDInformation.value[0]) | (UInt16(HIDInformation.value[1]) << 8)
        XCTAssertEqual(bcd, 0x0111)
        XCTAssertEqual(HIDInformation.value[2], 0x00, "Country code: not localised")
    }

    func testPnPIDValueIsSevenLittleEndianBytes() {
        let bytes = Array(PnPID.value)
        XCTAssertEqual(bytes.count, 7)
        XCTAssertEqual(bytes[0], 0x02, "Vendor ID Source must be 0x02 (USB Implementer's Forum)")

        func le16(_ low: Int) -> UInt16 { UInt16(bytes[low]) | (UInt16(bytes[low + 1]) << 8) }
        XCTAssertEqual(le16(1), PnPID.vendorID)
        XCTAssertEqual(le16(3), PnPID.productID)
        XCTAssertEqual(le16(5), PnPID.productVersion)

        // Explicit byte-order check: 0x1D6B on the wire is 6B 1D.
        XCTAssertEqual(bytes[1], 0x6B)
        XCTAssertEqual(bytes[2], 0x1D)
        XCTAssertNotEqual(PnPID.vendorID, 0x05AC, "Deliberately not Apple's vendor ID")
    }

    // MARK: - Keycodes

    func testAsciiLettersMapToContiguousUsages() {
        // NOTE: every modifier comparison spells out `KeyModifiers.none`. Written
        // as bare `.none` against an Optional the compiler resolves it to
        // `Optional.none` — i.e. the assertion becomes "is nil" and silently
        // passes for the wrong reason. This is the single nastiest trap in
        // OptionSet testing.
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "a")?.usage, 0x04)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "z")?.usage, 0x1D)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "a")?.modifiers, KeyModifiers.none)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "A")?.usage, 0x04)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "A")?.modifiers, KeyModifiers.leftShift)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "Z")?.usage, 0x1D)
    }

    func testDigitZeroIsAtTheEndOfTheDigitRun() {
        // The classic HID trap.
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "1")?.usage, 0x1E)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "9")?.usage, 0x26)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "0")?.usage, 0x27)
    }

    func testShiftedSymbolsMapToBaseKeyPlusShift() {
        let cases: [(Character, UInt8)] = [
            ("!", HIDKeyCode.one), ("@", HIDKeyCode.two), ("#", HIDKeyCode.three),
            ("$", HIDKeyCode.four), ("%", HIDKeyCode.five), ("^", HIDKeyCode.six),
            ("&", HIDKeyCode.seven), ("*", HIDKeyCode.eight), ("(", HIDKeyCode.nine),
            (")", HIDKeyCode.zero), ("_", HIDKeyCode.minus), ("+", HIDKeyCode.equal),
            ("{", HIDKeyCode.leftBracket), ("}", HIDKeyCode.rightBracket),
            ("|", HIDKeyCode.backslash), (":", HIDKeyCode.semicolon),
            ("\"", HIDKeyCode.quote), ("~", HIDKeyCode.grave),
            ("<", HIDKeyCode.comma), (">", HIDKeyCode.period), ("?", HIDKeyCode.slash)
        ]
        for (character, usage) in cases {
            let stroke = HIDKeyCode.keystrokes(for: character)
            XCTAssertEqual(stroke?.usage, usage, "\(character)")
            XCTAssertEqual(stroke?.modifiers, KeyModifiers.leftShift, "\(character)")
        }
    }

    func testUnshiftedPunctuationCarriesNoModifier() {
        let cases: [(Character, UInt8)] = [
            ("-", HIDKeyCode.minus), ("=", HIDKeyCode.equal),
            ("[", HIDKeyCode.leftBracket), ("]", HIDKeyCode.rightBracket),
            ("\\", HIDKeyCode.backslash), (";", HIDKeyCode.semicolon),
            ("'", HIDKeyCode.quote), ("`", HIDKeyCode.grave),
            (",", HIDKeyCode.comma), (".", HIDKeyCode.period),
            ("/", HIDKeyCode.slash), (" ", HIDKeyCode.space)
        ]
        for (character, usage) in cases {
            let stroke = HIDKeyCode.keystrokes(for: character)
            XCTAssertEqual(stroke?.usage, usage, "\(character)")
            XCTAssertEqual(stroke?.modifiers, KeyModifiers.none, "\(character)")
        }
    }

    func testControlCharactersMapToPhysicalKeys() {
        let returnKey = HIDKeyCode.`return`
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "\n")?.usage, returnKey)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "\r")?.usage, returnKey)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "\t")?.usage, HIDKeyCode.tab)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "\u{08}")?.usage, HIDKeyCode.delete)
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "\u{1B}")?.usage, HIDKeyCode.escape)
        // CRLF is a single Character in Swift; it must not be silently skipped.
        XCTAssertEqual(HIDKeyCode.keystrokes(for: "\r\n")?.usage, returnKey)
    }

    func testUnmappableCharactersReturnNilRatherThanCrashing() {
        for character in ["é", "€", "🙂", "字", "\u{0}", "\u{7F}", "ñ"] as [Character] {
            XCTAssertNil(HIDKeyCode.keystrokes(for: character), "\(character)")
        }
    }

    func testStringMappingPreservesOrderAndSkipsUnmappable() {
        let strokes = HIDKeyCode.keystrokes(for: "Hi!é")
        XCTAssertEqual(strokes.count, 3, "é has no US-layout key and must be dropped")
        XCTAssertEqual(strokes[0].0, HIDKeyCode.h)
        XCTAssertEqual(strokes[0].1, KeyModifiers.leftShift)
        XCTAssertEqual(strokes[1].0, HIDKeyCode.i)
        XCTAssertEqual(strokes[1].1, KeyModifiers.none)
        XCTAssertEqual(strokes[2].0, HIDKeyCode.one)
        XCTAssertEqual(strokes[2].1, KeyModifiers.leftShift)

        XCTAssertEqual(HIDKeyCode.unmappableCharacters(in: "Hi!é"), ["é"])
        XCTAssertTrue(HIDKeyCode.unmappableCharacters(in: "plain ascii 123").isEmpty)
    }

    func testEveryPrintableAsciiCharacterIsMapped() {
        // 0x20 (space) through 0x7E (~) must all be typeable; a gap here is a
        // character the user can enter but the Mac will never receive.
        for value in 0x20...0x7E {
            let character = Character(UnicodeScalar(UInt8(value)))
            XCTAssertNotNil(HIDKeyCode.keystrokes(for: character), "0x\(String(value, radix: 16))")
        }
    }

    func testEveryMappedUsageIsInsideTheDeclaredKeyArrayRange() throws {
        // The keyboard collection declares Logical/Usage 0...255, so this is a
        // weak bound — but it is the bound the descriptor actually promises.
        for value in 0x20...0x7E {
            let character = Character(UnicodeScalar(UInt8(value)))
            let stroke = try XCTUnwrap(HIDKeyCode.keystrokes(for: character))
            XCTAssertGreaterThan(stroke.usage, 0, "Usage 0 means 'no key' and must never be emitted")
        }
    }
}
