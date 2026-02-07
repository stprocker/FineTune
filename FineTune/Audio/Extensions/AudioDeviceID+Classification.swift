// FineTune/Audio/Extensions/AudioDeviceID+Classification.swift
import AppKit
import AudioToolbox

// MARK: - Device Classification

extension AudioDeviceID {
    nonisolated func isAggregateDevice() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var classID: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &classID)
        guard err == noErr else { return false }
        return classID == kAudioAggregateDeviceClassID
    }

    nonisolated func isVirtualDevice() -> Bool {
        readTransportType() == .virtual
    }
}

// MARK: - Device Icon

extension AudioDeviceID {
    nonisolated func readDeviceIcon() -> NSImage? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIcon,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = UInt32(MemoryLayout<Unmanaged<CFURL>?>.size)
        var iconURL: Unmanaged<CFURL>?
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &iconURL)

        guard err == noErr, let url = iconURL?.takeRetainedValue() as URL? else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    /// Returns an appropriate SF Symbol name based on device name and transport type.
    /// Used as fallback when kAudioDevicePropertyIcon is not available.
    nonisolated func suggestedIconSymbol() -> String {
        let name = (try? readDeviceName()) ?? ""
        let transport = readTransportType()

        // AirPods variants
        if name.contains("AirPods Pro") { return "airpodspro" }
        if name.contains("AirPods Max") { return "airpodsmax" }
        if name.contains("AirPods") { return "airpods.gen3" }

        // HomePod variants
        if name.contains("HomePod mini") { return "homepodmini" }
        if name.contains("HomePod") { return "homepod" }

        // Apple TV
        if name.contains("Apple TV") { return "appletv" }

        // Beats
        if name.contains("Beats") { return "beats.headphones" }

        // Fall back to transport type default
        return transport.defaultIconSymbol
    }
}
