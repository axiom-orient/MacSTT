import AVFoundation
import Foundation
import MacSTTCore
import XCTest
@testable import MacSTTApple

final class InMemoryAudioFileTests: XCTestCase {
    func testPCM16MonoDecodesExpectedFramesDurationAndOwnedSamples() throws {
        var data = wave()
        try InMemoryAudioFile.validate(data, maximumDurationSeconds: 1)
        let decoded = try InMemoryAudioFile.decode(
            data, outputFormat: outputFormat(), maximumDurationSeconds: 1,
            maximumDecodedBytes: 256 * 1_024
        )
        XCTAssertEqual(decoded.buffer.frameLength, 1_600)
        XCTAssertEqual(decoded.buffer.format.sampleRate, 16_000)
        XCTAssertEqual(decoded.durationSeconds, 0.1, accuracy: 0.000_001)
        let samples = try XCTUnwrap(decoded.buffer.floatChannelData?[0])
        XCTAssertEqual(samples[0], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(samples[1], -0.5, accuracy: 0.000_001)
        XCTAssertEqual(samples[1_599], -0.5, accuracy: 0.000_001)

        // Native handles and the borrowed Data scope have ended. The output must own its bytes.
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            bytes[44] = 0
            bytes[45] = 0
        }
        XCTAssertEqual(samples[0], 0.5, accuracy: 0.000_001)
        let changed = try InMemoryAudioFile.decode(
            data, outputFormat: outputFormat(), maximumDurationSeconds: 1,
            maximumDecodedBytes: 256 * 1_024
        )
        XCTAssertEqual(changed.buffer.floatChannelData?[0][0] ?? .nan, 0, accuracy: 0.000_001)
    }

    func testEmptyAndMalformedInputRejectWithTypedAudioFailures() throws {
        for data in [Data(), Data("This is not an audio container".utf8)] {
            let expected = data.isEmpty ? "AUDIO_FILE_EMPTY" : "AUDIO_FILE_FORMAT_UNSUPPORTED"
            assertAudioFailure(codes: [expected]) {
                try InMemoryAudioFile.validate(data, maximumDurationSeconds: 1)
            }
            assertAudioFailure(codes: [expected]) {
                _ = try InMemoryAudioFile.decode(
                    data, outputFormat: self.outputFormat(), maximumDurationSeconds: 1,
                    maximumDecodedBytes: 256 * 1_024
                )
            }
        }
    }

    func testDurationLimitRejectsAnOtherwiseValidWave() throws {
        let data = wave()
        assertAudioFailure(codes: ["AUDIO_FILE_TOO_LONG"]) {
            try InMemoryAudioFile.validate(data, maximumDurationSeconds: 0.05)
        }
        assertAudioFailure(codes: ["AUDIO_FILE_TOO_LONG", "AUDIO_FILE_DURATION_UNAVAILABLE"]) {
            _ = try InMemoryAudioFile.decode(
                data, outputFormat: self.outputFormat(), maximumDurationSeconds: 0.05,
                maximumDecodedBytes: 256 * 1_024
            )
        }
    }

    func testDecodedByteBudgetRejectsBeforeReturningNativeOutput() throws {
        let data = wave()
        for budget in [0, 1_024] {
            assertAudioFailure(codes: ["AUDIO_DECODED_INPUT_TOO_LARGE"]) {
                _ = try InMemoryAudioFile.decode(
                    data, outputFormat: self.outputFormat(), maximumDurationSeconds: 1,
                    maximumDecodedBytes: budget
                )
            }
        }
    }

    private func outputFormat() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    }

    private func assertAudioFailure(
        codes: Set<String>, file: StaticString = #filePath, line: UInt = #line,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let failure = error as? MacSTTFailure else {
                XCTFail("Expected a typed audio failure; received \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(failure.domain, .audio, file: file, line: line)
            XCTAssertEqual(failure.recoverability, .requiresUserAction, file: file, line: line)
            XCTAssertTrue(codes.contains(failure.code), "Unexpected code: \(failure.code)", file: file, line: line)
        }
    }

    private func wave() -> Data {
        let frameCount = 1_600
        let payloadBytes = UInt32(frameCount * MemoryLayout<Int16>.size)
        var data = Data("RIFF".utf8)
        data.append(littleEndian(UInt32(36) + payloadBytes))
        data.append(Data("WAVEfmt ".utf8))
        data.append(littleEndian(UInt32(16)))
        data.append(littleEndian(UInt16(1))) // Linear PCM.
        data.append(littleEndian(UInt16(1))) // Mono.
        data.append(littleEndian(UInt32(16_000)))
        data.append(littleEndian(UInt32(32_000)))
        data.append(littleEndian(UInt16(2)))
        data.append(littleEndian(UInt16(16)))
        data.append(Data("data".utf8))
        data.append(littleEndian(payloadBytes))
        for frame in 0..<frameCount {
            data.append(littleEndian(Int16(frame.isMultiple(of: 2) ? 16_384 : -16_384)))
        }
        return data
    }

    private func littleEndian<Value: FixedWidthInteger>(_ value: Value) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
