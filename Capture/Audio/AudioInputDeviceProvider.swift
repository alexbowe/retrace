import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }

    public var displayName: String {
        isDefault ? "\(name) (Default)" : name
    }
}

public enum AudioInputDeviceProvider {
    public static func availableInputDevices() -> [AudioInputDevice] {
        let defaultDeviceID = defaultInputDeviceID()

        return allAudioDeviceIDs()
            .compactMap { deviceID in
                guard inputChannelCount(for: deviceID) > 0,
                      let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) else {
                    return nil
                }

                return AudioInputDevice(
                    id: uid,
                    name: stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Input \(deviceID)",
                    isDefault: deviceID == defaultDeviceID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allAudioDeviceIDs().first { deviceID in
            inputChannelCount(for: deviceID) > 0
                && stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) == uid
        }
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        ) == noErr else {
            return []
        }

        return devices
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr, deviceID != 0 else {
            return nil
        }

        return deviceID
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }

        return value as String
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return 0
        }

        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { total, buffer in
            total + Int(buffer.mNumberChannels)
        }
    }
}
