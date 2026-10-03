import XCTest
@testable import MacSTTCore

final class TranscriptAssemblerTests: XCTestCase {
    func testSameStartProgressiveRangeSupersedesProvisionalRange() throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(TranscriptSegment(generation: 1, startSample: 0, durationSamples: 100, revision: 0, isFinal: false, text: "hel"))
        try assembler.apply(TranscriptSegment(generation: 1, startSample: 0, durationSamples: 200, revision: 0, isFinal: true, text: "hello"))
        let frozen = try assembler.freeze()
        XCTAssertEqual(frozen.raw, "hello")
        XCTAssertEqual(frozen.segments.count, 1)
    }

    func testManySameStartRevisionsKeepOneSegment() throws {
        var assembler = TranscriptAssembler(generation: 1)
        for duration in 1...4_096 {
            try assembler.apply(TranscriptSegment(generation: 1, startSample: 0, durationSamples: Int64(duration), revision: 0, isFinal: false, text: "value-\(duration)"))
        }
        XCTAssertEqual(assembler.segmentCount, 1)
        assembler.finalize(throughSample: 4_096)
        XCTAssertEqual(try assembler.freeze().raw, "value-4096")
    }

    func testFinalizationWatermarkPromotesWithoutMutationScan() throws {
        var assembler = TranscriptAssembler(generation: 2)
        for index in 0..<1_000 {
            try assembler.apply(TranscriptSegment(generation: 2, startSample: Int64(index * 100), durationSamples: 100, revision: 0, isFinal: false, text: "x"))
        }
        assembler.finalize(throughSample: 100_000)
        let frozen = try assembler.freeze()
        XCTAssertEqual(frozen.segments.count, 1_000)
        XCTAssertTrue(frozen.segments.allSatisfy(\.isFinal))
    }

    func testOverlappingFinalSegmentsFail() throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(TranscriptSegment(generation: 1, startSample: 0, durationSamples: 100, revision: 0, isFinal: true, text: "A"))
        try assembler.apply(TranscriptSegment(generation: 1, startSample: 50, durationSamples: 100, revision: 0, isFinal: true, text: "B"))
        XCTAssertThrowsError(try assembler.freeze()) { XCTAssertEqual($0 as? ContractError, .overlappingFinalSegments) }
    }

    func testStaleGenerationDoesNotMutate() throws {
        var assembler = TranscriptAssembler(generation: 7)
        let accepted = try assembler.apply(TranscriptSegment(generation: 6, startSample: 0, durationSamples: 1, revision: 0, isFinal: true, text: "stale"))
        XCTAssertFalse(accepted)
        XCTAssertEqual(assembler.segmentCount, 0)
    }

    func testNonFinalSegmentCannotFreezeByDefault() throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(TranscriptSegment(generation: 1, startSample: 0, durationSamples: 100, revision: 0, isFinal: false, text: "volatile"))
        XCTAssertThrowsError(try assembler.freeze()) { XCTAssertEqual($0 as? ContractError, .nonFinalSegmentAtFreeze) }
    }

    func testZeroDurationContract() throws {
        var assembler = TranscriptAssembler(generation: 1)
        XCTAssertThrowsError(try assembler.apply(TranscriptSegment(generation: 1, startSample: 0, durationSamples: 0, revision: 0, isFinal: true, text: "invalid"))) {
            XCTAssertEqual($0 as? ContractError, .invalidSegmentRange)
        }
        let accepted = try assembler.apply(TranscriptSegment(generation: 1, startSample: 0, durationSamples: 0, revision: 0, isFinal: true, text: ""))
        XCTAssertFalse(accepted)
        XCTAssertEqual(assembler.segmentCount, 0)
    }

    func testOverflowingRangeIsRejected() {
        var assembler = TranscriptAssembler(generation: 1)
        XCTAssertThrowsError(try assembler.apply(TranscriptSegment(generation: 1, startSample: Int64.max, durationSamples: 1, revision: 0, isFinal: true, text: "invalid"))) {
            XCTAssertEqual($0 as? ContractError, .invalidSegmentRange)
        }
    }

    func testTranscriptSegmentCountIsBounded() throws {
        var assembler = TranscriptAssembler(generation: 1)
        for index in 0..<TranscriptAssembler.maxSegmentCount {
            try assembler.apply(TranscriptSegment(generation: 1, startSample: Int64(index * 2), durationSamples: 1, revision: 0, isFinal: false, text: "x"))
        }
        XCTAssertThrowsError(try assembler.apply(TranscriptSegment(generation: 1, startSample: Int64(TranscriptAssembler.maxSegmentCount * 2), durationSamples: 1, revision: 0, isFinal: false, text: "x"))) {
            XCTAssertEqual($0 as? ContractError, .transcriptTooLarge)
        }
    }

    func testFinalSegmentIsImmutable() throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(TranscriptSegment(generation: 1, startSample: 0, durationSamples: 1, revision: 0, isFinal: true, text: "final"))
        XCTAssertThrowsError(try assembler.apply(TranscriptSegment(generation: 1, startSample: 0, durationSamples: 1, revision: 1, isFinal: true, text: "changed"))) {
            XCTAssertEqual($0 as? ContractError, .transcriptFinalMutation)
        }
    }

    func testPreviewFinalizesEachRangeExactlyOnce() {
        var preview = BoundedTranscriptPreview()
        let first = SegmentKey(startSample: 0, durationSamples: 100)
        let second = SegmentKey(startSample: 100, durationSamples: 100)
        XCTAssertEqual(preview.appendFinal("하나 ", key: first), "하나 ")
        XCTAssertEqual(preview.replace(with: "둘", key: second), "하나 둘")
        XCTAssertEqual(preview.appendFinal("둘", key: second), "하나 둘")
        XCTAssertEqual(preview.appendFinal("둘", key: second), "하나 둘")
    }
}
