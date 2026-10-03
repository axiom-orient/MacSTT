@preconcurrency import AVFoundation
import Foundation
import MacSTTCore
import Synchronization

/// The Objective-C input block needs a copyable reference to its one-shot atomic state.
private final class ConverterInputSupply: Sendable {
    private let supplied = Atomic(false)
    func claim() -> Bool {
        supplied.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
    }
}

struct AudioFormatIdentity: Equatable, Sendable {
    private let stream: StreamDescription
    private let commonFormat: AVAudioCommonFormat
    private let interleaved: Bool
    private let layout: ChannelLayout?

    init(_ format: AVAudioFormat) {
        stream = StreamDescription(format.streamDescription.pointee)
        commonFormat = format.commonFormat
        interleaved = format.isInterleaved
        layout = format.channelLayout.map(ChannelLayout.init)
    }

    private struct StreamDescription: Equatable, Sendable {
        let sampleRate: Double
        let formatID: UInt32
        let formatFlags: UInt32
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
        let bytesPerFrame: UInt32
        let channelsPerFrame: UInt32
        let bitsPerChannel: UInt32
        let reserved: UInt32

        init(_ value: AudioStreamBasicDescription) {
            sampleRate = value.mSampleRate
            formatID = value.mFormatID
            formatFlags = value.mFormatFlags
            bytesPerPacket = value.mBytesPerPacket
            framesPerPacket = value.mFramesPerPacket
            bytesPerFrame = value.mBytesPerFrame
            channelsPerFrame = value.mChannelsPerFrame
            bitsPerChannel = value.mBitsPerChannel
            reserved = value.mReserved
        }
    }

    private struct ChannelLayout: Equatable, Sendable {
        let tag: AudioChannelLayoutTag
        let bitmap: UInt32?
        let descriptions: [ChannelDescription]

        init(_ value: AVAudioChannelLayout) {
            let pointer = value.layout
            // Layouts without descriptions allocate only the 12-byte header,
            // not Swift's full C struct containing its one-element tail.
            let bytes = UnsafeRawPointer(pointer)
            let layoutTag = bytes.load(fromByteOffset: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelLayoutTag)!,
                as: AudioChannelLayoutTag.self)
            tag = layoutTag
            bitmap = layoutTag == kAudioChannelLayoutTag_UseChannelBitmap
                ? bytes.load(fromByteOffset: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelBitmap)!,
                    as: AudioChannelBitmap.self).rawValue : nil
            descriptions = withExtendedLifetime(value) {
                guard layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions else { return [] }
                let count = bytes.load(fromByteOffset: MemoryLayout<AudioChannelLayout>.offset(of: \.mNumberChannelDescriptions)!,
                    as: UInt32.self)
                // The native object owns its complete variable-length description array.
                // This C struct's stored member has a fixed ABI offset, not a copied first element.
                let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
                let first = UnsafeRawPointer(pointer).advanced(by: offset)
                    .assumingMemoryBound(to: AudioChannelDescription.self)
                return UnsafeBufferPointer(start: first, count: Int(count))
                    .map(ChannelDescription.init)
            }
        }
    }

    private struct ChannelDescription: Equatable, Sendable {
        let label: AudioChannelLabel
        let flags: UInt32
        let x: Float
        let y: Float
        let z: Float

        init(_ value: AudioChannelDescription) {
            label = value.mChannelLabel
            flags = value.mChannelFlags.rawValue
            x = value.mCoordinates.0
            y = value.mCoordinates.1
            z = value.mCoordinates.2
        }
    }
}

final class AudioBufferConverter {
    private struct CachedConversion {
        let source: AudioFormatIdentity
        let destination: AudioFormatIdentity
        let converter: AVAudioConverter
    }
    private var cachedConversion: CachedConversion?

    func reset() { cachedConversion = nil }

    func convert(_ input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = AudioFormatIdentity(input.format)
        let destination = AudioFormatIdentity(outputFormat)
        guard source != destination else { return try copy(input) }

        let converter: AVAudioConverter
        if let cachedConversion,
           cachedConversion.source == source, cachedConversion.destination == destination {
            converter = cachedConversion.converter
        } else {
            guard let created = AVAudioConverter(from: input.format, to: outputFormat) else {
                throw failure("AUDIO_CONVERTER_CREATE_FAILED", detail: nil)
            }
            created.primeMethod = .none
            cachedConversion = CachedConversion(source: source, destination: destination, converter: created)
            converter = created
        }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let estimated = (Double(input.frameLength) * ratio).rounded(.up) + 32
        guard ratio.isFinite, ratio > 0, estimated.isFinite,
              let capacity = AVAudioFrameCount(exactly: max(1, estimated)),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else {
            throw failure("AUDIO_CONVERTER_BUFFER_FAILED", detail: nil)
        }

        var conversionError: NSError?
        let suppliedInput = ConverterInputSupply()
        let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
            if !suppliedInput.claim() {
                statusPointer.pointee = .noDataNow
                return nil
            }
            statusPointer.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else {
            throw failure("AUDIO_CONVERSION_FAILED", detail: conversionError?.localizedDescription)
        }
        return output
    }

    private func copy(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            throw failure("AUDIO_COPY_BUFFER_FAILED", detail: nil)
        }
        output.frameLength = input.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            throw failure("AUDIO_COPY_LAYOUT_MISMATCH", detail: nil)
        }

        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData
            else {
                throw failure("AUDIO_COPY_DATA_MISSING", detail: nil)
            }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            guard byteCount <= Int(destinationBuffers[index].mDataByteSize) else {
                throw failure("AUDIO_COPY_BUFFER_TOO_SMALL", detail: nil)
            }
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return output
    }

    private func failure(_ code: String, detail: String?) -> MacSTTFailure {
        MacSTTFailure(
            code: code, domain: .audio, stage: "convert",
            recoverability: .terminalForSession, messageKey: code.lowercased(), redactedDetail: detail
        )
    }
}
