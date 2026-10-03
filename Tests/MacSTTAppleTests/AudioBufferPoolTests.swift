@preconcurrency import AVFoundation
import XCTest
@testable import MacSTTApple

final class AudioBufferPoolTests: XCTestCase {
    func testExhaustionDoesNotLoseReleasedSlots() throws {
        let source = try makeBuffer()
        let pool = try makePool()

        let held = try (0..<4).map { _ in try pool.copy(source) }
        XCTAssertThrowsError(try pool.copy(source)) { error in
            XCTAssertEqual(error as? AudioBufferPoolError, .exhausted)
        }

        held.forEach { $0.release() }
        let recovered = try pool.copy(source)
        recovered.release()
    }

    func testCopiedLeaseCannotReleaseANewlyReusedSlot() throws {
        let source = try makeBuffer()
        let pool = try makePool()
        let original = try pool.copy(source)
        let copy = original
        let otherSlots = try (0..<3).map { _ in try pool.copy(source) }
        defer { otherSlots.forEach { $0.release() } }

        original.release()
        source.floatChannelData?[0][0] = 0.75
        let replacement = try pool.copy(source)
        defer { replacement.release() }
        // Only the original slot was free, so the replacement necessarily owns that slot.
        XCTAssertTrue(replacement.buffer === original.buffer)
        copy.release()
        original.release()
        source.floatChannelData?[0][0] = 0.5
        XCTAssertThrowsError(try pool.copy(source)) { error in
            XCTAssertEqual(error as? AudioBufferPoolError, .exhausted)
        }
        XCTAssertEqual(replacement.buffer.floatChannelData?[0][0], 0.75)
    }

    func testDiscardingPacketsAutomaticallyReturnsPoolSlots() throws {
        let source = try makeBuffer()
        let pool = try makePool()
        func consumeAndDiscard() throws {
            let packet = try pool.copy(source)
            XCTAssertEqual(packet.buffer.frameLength, source.frameLength)
        }
        for _ in 0..<16 { try consumeAndDiscard() }
    }

    func testAutomaticReturnWaitsForTheLastPacketCopy() throws {
        let source = try makeBuffer()
        let pool = try makePool()
        var originals = try (0..<4).map { _ in try pool.copy(source) }
        var remainingCopy: CapturedAudioBuffer? = originals[0]
        originals.removeAll()

        let reclaimed = try (0..<3).map { _ in try pool.copy(source) }
        defer { reclaimed.forEach { $0.release() } }
        XCTAssertThrowsError(try pool.copy(source)) { error in
            XCTAssertEqual(error as? AudioBufferPoolError, .exhausted)
        }
        XCTAssertNotNil(remainingCopy)
        remainingCopy = nil
        let finalSlot = try pool.copy(source)
        finalSlot.release()
    }

    func testMismatchedSampleRateCannotBeRelabeledAsPoolFormat() throws {
        let pool = try makePool()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        source.frameLength = 64
        XCTAssertThrowsError(try pool.copy(source)) { error in
            XCTAssertEqual(error as? AudioBufferPoolError, .layoutMismatch)
        }
    }

    @available(macOS 27.0, *)
    func testReadOnlyTapBufferCopiesIntoOwnedPoolSlot() throws {
        let source = try makeBuffer()
        source.floatChannelData?[0][0] = 0.5
        let readOnly = AVReadOnlyAudioPCMBuffer(copying: source)
        let pool = try makePool()
        let packet = try pool.copy(readOnly)
        defer { packet.release() }
        source.floatChannelData?[0][0] = 0
        XCTAssertEqual(packet.buffer.frameLength, 64)
        XCTAssertEqual(packet.buffer.floatChannelData?[0][0], 0.5)
    }

    func testTapDurationMatchesHardwareRates() throws {
        for rate in [8_000.0, 16_000, 44_100, 48_000, 96_000, 192_000] {
            let frames = try AudioCaptureDriver.tapFrameCapacity(sampleRate: rate, hardwareFrames: 512)
            XCTAssertGreaterThanOrEqual(Double(frames) / rate, 0.1)
            XCTAssertLessThanOrEqual(Double(frames) / rate, 0.4)
            XCTAssertLessThanOrEqual(frames, 32_768)
        }
        XCTAssertThrowsError(try AudioCaptureDriver.tapFrameCapacity(sampleRate: 0, hardwareFrames: 0))
        XCTAssertThrowsError(try AudioCaptureDriver.tapFrameCapacity(sampleRate: .infinity, hardwareFrames: 512))
    }

    private func makePool() throws -> AudioBufferPool {
        let format = try makeFormat()
        guard let pool = AudioBufferPool(format: format, frameCapacity: 64, capacity: 4) else {
            throw XCTSkip("AVAudioPCMBuffer allocation is unavailable")
        }
        return pool
    }

    private func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try makeFormat()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64) else {
            throw XCTSkip("AVAudioPCMBuffer allocation is unavailable")
        }
        buffer.frameLength = 64
        return buffer
    }

    private func makeFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw XCTSkip("AVAudioFormat is unavailable")
        }
        return format
    }
}
