@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MacSTTCore

private struct AudioFileDataSource {
    let address: UnsafeRawPointer
    let count: Int
}

private let audioFileReadProc: AudioFile_ReadProc = {
    clientData, position, requestCount, buffer, actualCount in
    let source = clientData.assumingMemoryBound(to: AudioFileDataSource.self).pointee
    guard position >= 0 else {
        actualCount.pointee = 0
        return kAudio_ParamError
    }
    guard position < Int64(source.count) else {
        actualCount.pointee = 0
        return noErr
    }
    let start = Int(position)
    let byteCount = min(Int(requestCount), source.count - start)
    if byteCount > 0 {
        buffer.copyMemory(from: source.address.advanced(by: start), byteCount: byteCount)
    }
    actualCount.pointee = UInt32(byteCount)
    return noErr
}

private let audioFileGetSizeProc: AudioFile_GetSizeProc = { clientData in
    Int64(clientData.assumingMemoryBound(to: AudioFileDataSource.self).pointee.count)
}

/// Synchronous bounded decoder. All borrowed bytes and native file handles stay in one scope.
enum InMemoryAudioFile {
    static func validate(_ data: Data, maximumDurationSeconds: Double) throws {
        try withExtendedFile(data) { _, description, frameCount in
            let duration = Double(frameCount) / description.mSampleRate
            guard duration.isFinite, duration > 0, duration <= maximumDurationSeconds else {
                throw failure(
                    duration > maximumDurationSeconds ? "AUDIO_FILE_TOO_LONG" : "AUDIO_FILE_DURATION_UNAVAILABLE",
                    stage: "duration", status: kAudio_ParamError)
            }
        }
    }

    static func decode(
        _ data: Data,
        outputFormat: AVAudioFormat,
        maximumDurationSeconds: Double,
        maximumDecodedBytes: Int
    ) throws -> (buffer: AVAudioPCMBuffer, durationSeconds: Double) {
        try withExtendedFile(data) { extendedFile, sourceDescription, sourceFrames in
            let sourceDuration = Double(sourceFrames) / sourceDescription.mSampleRate
            guard sourceDuration.isFinite, sourceDuration > 0,
                sourceDuration <= maximumDurationSeconds,
                outputFormat.sampleRate.isFinite, outputFormat.sampleRate > 0,
                outputFormat.channelCount > 0
            else {
                throw failure("AUDIO_FILE_DURATION_UNAVAILABLE", stage: "decode", status: kAudio_ParamError)
            }

            let estimatedFrames = (sourceDuration * outputFormat.sampleRate).rounded(.up)
            guard estimatedFrames < Double(UInt32.max - 4_096) else {
                throw failure("AUDIO_FILE_TOO_LONG", stage: "decode", status: kAudio_ParamError)
            }
            let frameCapacity = AVAudioFrameCount(max(1, Int(estimatedFrames) + 4_096))
            var outputDescription = outputFormat.streamDescription.pointee
            let formatStatus = ExtAudioFileSetProperty(
                extendedFile,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &outputDescription
            )
            guard formatStatus == noErr else {
                throw failure("AUDIO_FILE_FORMAT_UNSUPPORTED", stage: "convert", status: formatStatus)
            }

            let bytesPerFrame = Int64(outputDescription.mBytesPerFrame)
            let channels = Int64(outputFormat.isInterleaved ? 1 : Int(outputFormat.channelCount))
            let capacity = Int64(frameCapacity)
            guard bytesPerFrame > 0, channels > 0,
                capacity <= Int64(maximumDecodedBytes) / bytesPerFrame / channels
            else {
                throw failure("AUDIO_DECODED_INPUT_TOO_LARGE", stage: "decode", status: kAudio_ParamError)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
                throw failure("AUDIO_PCM_BUFFER_ALLOCATION_FAILED", stage: "decode", status: kAudio_MemFullError)
            }
            // AudioToolbox consumes the list's writable byte sizes, initially zero on a new buffer.
            // Expose the already budget-checked capacity; commit the actual length after the read.
            buffer.frameLength = frameCapacity
            var framesRead = frameCapacity
            let readStatus = ExtAudioFileRead(extendedFile, &framesRead, buffer.mutableAudioBufferList)
            guard readStatus == noErr, framesRead > 0 else {
                throw failure("AUDIO_FILE_DECODE_FAILED", stage: "decode", status: readStatus)
            }
            guard framesRead < frameCapacity else {
                throw failure("AUDIO_FILE_DURATION_UNTRUSTED", stage: "decode", status: kAudio_ParamError)
            }
            buffer.frameLength = framesRead
            let duration = Double(framesRead) / outputFormat.sampleRate
            guard duration <= maximumDurationSeconds else {
                throw failure("AUDIO_FILE_TOO_LONG", stage: "decode", status: kAudio_ParamError)
            }
            return (buffer, duration)
        }
    }

    private static func withExtendedFile<Value>(
        _ data: Data,
        operation: (ExtAudioFileRef, AudioStreamBasicDescription, Int64) throws -> Value
    ) throws -> Value {
        guard !data.isEmpty else {
            throw failure("AUDIO_FILE_EMPTY", stage: "open", status: kAudio_ParamError)
        }
        return try data.withUnsafeBytes { rawBytes in
            guard let address = rawBytes.baseAddress else {
                throw failure("AUDIO_FILE_EMPTY", stage: "open", status: kAudio_ParamError)
            }
            var source = AudioFileDataSource(address: address, count: rawBytes.count)
            return try withUnsafeMutablePointer(to: &source) { context in
                var audioFile: AudioFileID?
                let openStatus = AudioFileOpenWithCallbacks(
                    UnsafeMutableRawPointer(context), audioFileReadProc, nil,
                    audioFileGetSizeProc, nil, 0, &audioFile)
                guard openStatus == noErr, let audioFile else {
                    throw failure("AUDIO_FILE_FORMAT_UNSUPPORTED", stage: "open", status: openStatus)
                }
                defer { AudioFileClose(audioFile) }

                var extendedFile: ExtAudioFileRef?
                let wrapStatus = ExtAudioFileWrapAudioFileID(audioFile, false, &extendedFile)
                guard wrapStatus == noErr, let extendedFile else {
                    throw failure("AUDIO_FILE_FORMAT_UNSUPPORTED", stage: "wrap", status: wrapStatus)
                }
                defer { ExtAudioFileDispose(extendedFile) }

                var description = AudioStreamBasicDescription()
                var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                let formatStatus = ExtAudioFileGetProperty(
                    extendedFile, kExtAudioFileProperty_FileDataFormat, &descriptionSize, &description)
                guard formatStatus == noErr,
                    description.mSampleRate.isFinite,
                    description.mSampleRate > 0,
                    description.mChannelsPerFrame > 0
                else {
                    throw failure("AUDIO_FILE_FORMAT_UNSUPPORTED", stage: "format", status: formatStatus)
                }

                var frameCount: Int64 = 0
                var frameCountSize = UInt32(MemoryLayout<Int64>.size)
                let lengthStatus = ExtAudioFileGetProperty(
                    extendedFile, kExtAudioFileProperty_FileLengthFrames, &frameCountSize, &frameCount)
                guard lengthStatus == noErr, frameCount > 0 else {
                    throw failure("AUDIO_FILE_DURATION_UNAVAILABLE", stage: "duration", status: lengthStatus)
                }
                return try operation(extendedFile, description, frameCount)
            }
        }
    }

    private static func failure(_ code: String, stage: String, status: OSStatus) -> MacSTTFailure {
        MacSTTFailure(
            code: code, domain: .audio, stage: stage, recoverability: .requiresUserAction,
            messageKey: code.lowercased(), redactedDetail: "osstatus=\(status)"
        )
    }
}
