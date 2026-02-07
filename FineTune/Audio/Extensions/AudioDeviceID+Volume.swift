// FineTune/Audio/Extensions/AudioDeviceID+Volume.swift
import AudioToolbox

// MARK: - Device Volume

extension AudioDeviceID {
    /// Reads the scalar volume (0.0 to 1.0) for the device.
    /// Tries multiple strategies to find the most representative volume:
    /// 1. Virtual main volume via AudioHardwareService (matches system volume slider)
    /// 2. Master volume scalar (element 0)
    /// 3. Left channel volume (element 1)
    /// Returns 1.0 for devices without volume control.
    nonisolated func readOutputVolumeScalar() -> Float {
        // Try multiple strategies in priority order:
        // 1. Virtual main volume (matches system slider)
        // 2. Master volume scalar (element 0)
        // 3. Left channel volume (element 1, common for stereo devices)
        let strategies: [(selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement)] = [
            (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
        ]

        for strategy in strategies {
            var address = AudioObjectPropertyAddress(
                mSelector: strategy.selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: strategy.element
            )
            if AudioObjectHasProperty(self, &address) {
                var volume: Float32 = 1.0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume) == noErr {
                    return volume
                }
            }
        }

        // No volume control available
        return 1.0
    }

    /// Sets the scalar volume (0.0 to 1.0) for the device.
    /// Uses VirtualMainVolume via AudioHardwareService to match system volume slider behavior.
    /// Returns true if successful, false otherwise.
    nonisolated func setOutputVolumeScalar(_ volume: Float) -> Bool {
        let clampedVolume = Swift.max(0.0, Swift.min(1.0, volume))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(self, &address, &isSettable)
        guard settableStatus == noErr, isSettable.boolValue else {
            return false
        }

        var volumeValue: Float32 = clampedVolume
        let size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &volumeValue)
        return err == noErr
    }
}

// MARK: - Device Mute

extension AudioDeviceID {
    /// Reads the mute state for the device.
    /// Returns true if muted, false if unmuted or if mute is not supported.
    nonisolated func readMuteState() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &muted)
        return err == noErr && muted != 0
    }

    /// Sets the mute state for the device.
    /// Returns true if successful, false otherwise.
    nonisolated func setMuteState(_ muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(self, &address, &isSettable)
        guard settableStatus == noErr, isSettable.boolValue else {
            return false
        }

        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &value)
        return err == noErr
    }
}
