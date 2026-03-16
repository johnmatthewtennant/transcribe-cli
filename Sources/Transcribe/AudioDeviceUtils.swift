import CoreAudio
import AudioToolbox
import AVFoundation

/// Metadata for an audio input device.
struct AudioInputDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

/// Get the current default system input device ID.
func getDefaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

/// Get the human-readable name of an audio device.
func getDeviceName(deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
    let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CFString>.alignment)
    defer { data.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, data) == noErr else { return nil }
    return data.load(as: CFString.self) as String
}

/// Get the UID string of an audio device (stable identifier).
func getDeviceUID(deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
    let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CFString>.alignment)
    defer { data.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, data) == noErr else { return nil }
    return data.load(as: CFString.self) as String
}

/// List all audio input devices (ID, name, UID).
func listInputDevices() -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    )
    guard status == noErr, size > 0 else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
    )
    guard status == noErr else { return [] }

    var result: [AudioInputDevice] = []
    for id in deviceIDs {
        // Check if device has input channels
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        let streamStatus = AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize)
        guard streamStatus == noErr, streamSize > 0 else { continue }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(streamSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }
        var actualSize = streamSize
        let dataStatus = AudioObjectGetPropertyData(id, &streamAddress, 0, nil, &actualSize, rawBuffer)
        guard dataStatus == noErr else { continue }

        let bufferListPointer = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        let numBuffers = Int(bufferListPointer.pointee.mNumberBuffers)
        var inputChannels = 0
        withUnsafePointer(to: &bufferListPointer.pointee.mBuffers) { ptr in
            let buffers = UnsafeBufferPointer(start: ptr, count: numBuffers)
            inputChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        }
        guard inputChannels > 0 else { continue }

        if let name = getDeviceName(deviceID: id), let uid = getDeviceUID(deviceID: id) {
            result.append(AudioInputDevice(id: id, name: name, uid: uid))
        }
    }
    return result
}

/// Find a matching device by exact name, exact UID, or partial case-insensitive name.
/// Pure function -- no hardware access. Used by --device resolution and unit-testable.
func findMatchingDevice(query: String, in devices: [AudioInputDevice]) -> AudioInputDevice? {
    // Exact name or UID match
    if let match = devices.first(where: { $0.name == query || $0.uid == query }) {
        return match
    }
    // Partial case-insensitive name match
    return devices.first(where: { $0.name.localizedCaseInsensitiveContains(query) })
}
