import MacSTTCore
import Testing

struct TranscriptFinalizationTests {
    @Test func higherRevisionCannotRewriteWatermarkFinalText() throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(segment(text: "confirmed", revision: 0))
        assembler.finalize(throughSample: 100)

        #expect(throws: ContractError.transcriptFinalMutation) {
            try assembler.apply(segment(text: "rewritten", revision: 1))
        }
        #expect(try assembler.freeze().raw == "confirmed")
        #expect(assembler.segmentCount == 1)
    }

    @Test func sameRevisionCannotRewriteWatermarkFinalText() throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(segment(text: "confirmed", revision: 0))
        assembler.finalize(throughSample: 100)

        #expect(throws: ContractError.transcriptFinalConflict) {
            try assembler.apply(segment(text: "conflicting", revision: 0))
        }
        #expect(try assembler.freeze().raw == "confirmed")
    }

    @Test(arguments: [false, true])
    func differentDurationPreservesFinalRangeAndFailsOverlap(explicitFinal: Bool) throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(segment(text: "confirmed", revision: 0, isFinal: explicitFinal))
        assembler.finalize(throughSample: 100)
        try assembler.apply(segment(text: "new range", duration: 200, revision: 0, isFinal: true))

        #expect(assembler.segmentCount == 2)
        #expect(throws: ContractError.overlappingFinalSegments) {
            try assembler.freeze()
        }
    }

    @Test(arguments: [false, true])
    func identicalFinalDuplicateIsIgnored(explicitFinal: Bool) throws {
        var assembler = TranscriptAssembler(generation: 1)
        let original = segment(text: "confirmed", revision: 2, isFinal: explicitFinal)
        try assembler.apply(original)
        assembler.finalize(throughSample: 100)

        #expect(try assembler.apply(original) == false)
        #expect(try assembler.freeze().raw == "confirmed")
        #expect(assembler.segmentCount == 1)
    }

    @Test(arguments: [false, true])
    func lowerRevisionCannotReplaceFinalText(explicitFinal: Bool) throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(segment(text: "confirmed", revision: 2, isFinal: explicitFinal))
        assembler.finalize(throughSample: 100)

        #expect(try assembler.apply(segment(text: "stale", revision: 1)) == false)
        #expect(try assembler.freeze().raw == "confirmed")
    }

    @Test func provisionalRangeCanStillBeSupersededBeforeWatermark() throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(segment(text: "partial", revision: 0))
        assembler.finalize(throughSample: 99)
        try assembler.apply(segment(text: "complete", duration: 200, revision: 0, isFinal: true))

        #expect(assembler.segmentCount == 1)
        #expect(try assembler.freeze().raw == "complete")
    }

    private func segment(
        text: String, duration: Int64 = 100, revision: UInt32, isFinal: Bool = false
    ) -> TranscriptSegment {
        TranscriptSegment(
            generation: 1, startSample: 0, durationSamples: duration,
            revision: revision, isFinal: isFinal, text: text
        )
    }
}
