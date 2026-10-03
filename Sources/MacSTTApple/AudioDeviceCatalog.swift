import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import MacSTTCore

public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public enum AudioDeviceCatalog {
    public static func inputDevices() throws -> [AudioInputDevice] {
        let defaultID = try defaultInputDeviceID()
        let deviceIDs = try allDeviceIDs()
        var devices: [AudioInputDevice] = []
        devices.reserveCapacity(deviceIDs.count)

        for deviceID in deviceIDs where inputChannelCount(deviceID) > 0 {
            guard let uid = try stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = try stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { continue }
            devices.append(AudioInputDevice(id: uid, name: name, isDefault: deviceID == defaultID))
        }
        return devices.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func configure(engine: AVAudioEngine, deviceUID: String?) throws {
        guard let deviceUID else { return }
        let deviceID = try deviceID(forUID: deviceUID)
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw audioFailure("AUDIO_UNIT_UNAVAILABLE", stage: "device-select")
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw audioFailure("AUDIO_DEVICE_SELECT_FAILED", stage: "device-select", detail: "osstatus=\(status)")
        }
    }

    private static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw audioFailure("AUDIO_DEVICE_ENUM_FAILED", stage: "device-enumerate", detail: "osstatus=\(status)") }
        let stride = UInt32(MemoryLayout<AudioDeviceID>.stride)
        guard size % stride == 0 else {
            throw audioFailure(
                "AUDIO_DEVICE_ENUM_INVALID_SIZE",
                stage: "device-enumerate",
                detail: "bytes=\(size) stride=\(stride)"
            )
        }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size / stride))
        status = ids.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        guard status == noErr else {
            throw audioFailure(
                "AUDIO_DEVICE_ENUM_FAILED",
                stage: "device-enumerate",
                detail: "osstatus=\(status)"
            )
        }
        guard size % stride == 0, Int(size / stride) <= ids.count else {
            throw audioFailure(
                "AUDIO_DEVICE_ENUM_INVALID_SIZE",
                stage: "device-enumerate",
                detail: "returnedBytes=\(size) stride=\(stride) capacity=\(ids.count)"
            )
        }
        return Array(ids.prefix(Int(size / stride)))
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr else { throw audioFailure("AUDIO_DEFAULT_DEVICE_FAILED", stage: "device-enumerate", detail: "osstatus=\(status)") }
        return id
    }

    private static func deviceID(forUID uid: String) throws -> AudioDeviceID {
        for deviceID in try allDeviceIDs() {
            if try stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) == uid {
                return deviceID
            }
        }
        throw audioFailure("AUDIO_DEVICE_NOT_FOUND", stage: "device-select")
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr else { return 0 }
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let allocatedBytes = size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(allocatedBytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
        guard status == noErr, size <= allocatedBytes,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        // The C struct includes one trailing buffer; additional buffers must fit the returned bytes.
        let bufferCapacity = 1 + (Int(size) - MemoryLayout<AudioBufferList>.size)
            / MemoryLayout<AudioBuffer>.stride
        guard Int(list.pointee.mNumberBuffers) <= bufferCapacity else { return 0 }
        var channels: UInt32 = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            let (total, overflow) = channels.addingReportingOverflow(buffer.mNumberChannels)
            guard !overflow else { return 0 }
            channels = total
        }
        return channels
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func audioFailure(_ code: String, stage: String, detail: String? = nil) -> MacSTTFailure {
        MacSTTFailure(
            code: code, domain: .audio, stage: stage,
            recoverability: .terminalForSession, messageKey: code.lowercased(), redactedDetail: detail
        )
    }
}
