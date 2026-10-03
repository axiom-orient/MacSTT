import AVFoundation
import MacSTTCore
import Testing
@testable import MacSTTApple

@Suite("Audio format identity")
struct AudioFormatIdentityTests {
    @Test("source format differences invalidate converter cache identity")
    func identityTracksInputAndOutputProperties() throws {
        let mono16 = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let mono48 = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let stereo48 = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))

        #expect(AudioFormatIdentity(mono16) != AudioFormatIdentity(mono48))
        #expect(AudioFormatIdentity(mono48) != AudioFormatIdentity(stereo48))
        #expect(AudioFormatIdentity(mono16) == AudioFormatIdentity(mono16))
    }

    @Test("channel layout is part of the identity, not just the channel count")
    func identityDistinguishesLayoutsWithEqualChannelCounts() throws {
        let stereo = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo))
        let binaural = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Binaural))
        let stereoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            interleaved: false, channelLayout: stereo
        )
        let binauralFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            interleaved: false, channelLayout: binaural
        )

        // Both are 2-channel float32 at 48 kHz. Comparing on channel count alone
        // would treat them as identical and skip conversion entirely.
        #expect(stereoFormat.channelCount == binauralFormat.channelCount)
        #expect(AudioFormatIdentity(stereoFormat) != AudioFormatIdentity(binauralFormat))
    }

    @Test("converter gives the analyzer an independently owned matching-format buffer")
    func matchingFormatConversionDoesNotAliasCaptureBuffer() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        input.frameLength = 4
        input.floatChannelData?[0][0] = 0.25

        let converted = try AudioBufferConverter().convert(input, to: format)
        #expect(converted !== input)
        #expect(converted.floatChannelData?[0][0] == 0.25)

        input.floatChannelData?[0][0] = 0.75
        #expect(converted.floatChannelData?[0][0] == 0.25)
    }

    @Test("range assembly is preferred for failure recovery")
    func transcriptRecoveryPrefersRangeAssembly() throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(TranscriptSegment(
            generation: 1,
            startSample: 0,
            durationSamples: 100,
            revision: 0,
            isFinal: false,
            text: "범위 데이터"
        ))

        let result = TranscriptRecovery.capture(
            assembler: assembler,
            preview: "preview fallback"
        )

        #expect(result.transcript == "범위 데이터")
        #expect(result.freezeError == nil)
    }

    @Test("preview is retained when range assembly cannot freeze")
    func transcriptRecoveryFallsBackToPreviewWhenRangesCannotFreeze() throws {
        var assembler = TranscriptAssembler(generation: 1)
        try assembler.apply(TranscriptSegment(
            generation: 1,
            startSample: 0,
            durationSamples: 100,
            revision: 0,
            isFinal: true,
            text: "첫째"
        ))
        try assembler.apply(TranscriptSegment(
            generation: 1,
            startSample: 50,
            durationSamples: 100,
            revision: 0,
            isFinal: true,
            text: "둘째"
        ))

        let result = TranscriptRecovery.capture(
            assembler: assembler,
            preview: "preview fallback"
        )

        #expect(result.transcript == "preview fallback")
        #expect(result.freezeError != nil)
    }
}
