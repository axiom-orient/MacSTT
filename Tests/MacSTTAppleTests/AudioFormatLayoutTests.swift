import AudioToolbox
import AVFoundation
import XCTest
@testable import MacSTTApple

final class AudioFormatLayoutTests: XCTestCase {
    func testCustomDescriptionCoordinatesDistinguishOtherwiseMatchingFormats() throws {
        let first = format(layout: try descriptions(x: -1))
        let second = format(layout: try descriptions(x: -2))
        XCTAssertEqual(first.channelCount, second.channelCount)
        XCTAssertEqual(first.channelLayout?.layoutTag, second.channelLayout?.layoutTag)
        XCTAssertFalse(first.isEqual(second))
        XCTAssertNotEqual(AudioFormatIdentity(first), AudioFormatIdentity(second))
    }

    func testDescriptionCoordinateFlagsArePartOfTheIdentity() throws {
        let first = format(layout: try descriptions(x: 1, flags: .rectangularCoordinates))
        let second = format(layout: try descriptions(x: 1, flags: .sphericalCoordinates))
        XCTAssertEqual(first.channelCount, second.channelCount)
        XCTAssertEqual(first.channelLayout?.layoutTag, second.channelLayout?.layoutTag)
        XCTAssertFalse(first.isEqual(second))
        XCTAssertNotEqual(AudioFormatIdentity(first), AudioFormatIdentity(second))
    }

    func testDifferentChannelBitmapsWithEqualCountsDoNotReuseAFormatIdentity() {
        // Native bitmap bits 0/1/2 identify left/right/center in CoreAudioBaseTypes.h.
        let first = format(layout: bitmap(AudioChannelBitmap(rawValue: 0b011)))
        let second = format(layout: bitmap(AudioChannelBitmap(rawValue: 0b101)))
        XCTAssertEqual(first.channelCount, second.channelCount)
        XCTAssertEqual(first.channelLayout?.layoutTag, second.channelLayout?.layoutTag)
        XCTAssertFalse(first.isEqual(second))
        XCTAssertNotEqual(AudioFormatIdentity(first), AudioFormatIdentity(second))
    }

    func testEquivalentCompleteNativeFormatsKeepEqualIdentities() throws {
        let first = format(layout: try descriptions(x: -1))
        let second = format(layout: try descriptions(x: -1))
        XCTAssertTrue(first.isEqual(second))
        XCTAssertEqual(AudioFormatIdentity(first), AudioFormatIdentity(second))
    }

    private func format(layout: AVAudioChannelLayout) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
    }

    private func bitmap(_ bitmap: AudioChannelBitmap) -> AVAudioChannelLayout {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
        layout.mChannelBitmap = bitmap
        return withUnsafePointer(to: &layout) { AVAudioChannelLayout(layout: $0) }
    }

    private func descriptions(
        x: Float, flags: AudioChannelFlags = .rectangularCoordinates
    ) throws -> AVAudioChannelLayout {
        let count = 2
        let offset = try XCTUnwrap(MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions))
        let byteCount = offset + count * MemoryLayout<AudioChannelDescription>.stride
        let storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let layout = storage.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(count)
        let channels = storage.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        for index in 0..<count {
            channels[index].mChannelLabel = kAudioChannelLabel_UseCoordinates
            channels[index].mChannelFlags = flags
            channels[index].mCoordinates = (index == 0 ? x : -x, 0, 1)
        }
        return AVAudioChannelLayout(layout: layout)
    }
}
