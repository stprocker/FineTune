// FineTune/Audio/CoreAudioExtensions.swift
import AppKit
import AudioToolbox
import Foundation

// MARK: - AudioObjectID Extensions

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    var isValid: Bool { self != Self.unknown }
}

extension AudioObjectID {
    func read<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, defaultValue: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
        return value
    }

    func readBool(_ selector: AudioObjectPropertySelector) throws -> Bool {
        let value: UInt32 = try read(selector, defaultValue: 0)
        return value != 0
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }

        var cfString: CFString = "" as CFString
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &cfString)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
        return cfString as String
    }
}

// MARK: - System Device Helpers

extension AudioDeviceID {
    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID(kAudioObjectSystemObject).read(
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            defaultValue: AudioDeviceID.unknown
        )
    }

    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    func readNominalSampleRate() throws -> Float64 {
        try read(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(48000))
    }
}

// MARK: - Process List

extension AudioObjectID {
    static func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: .unknown, count: count)
        err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
        return objectIDs
    }

    func readProcessPID() throws -> pid_t {
        try read(kAudioProcessPropertyPID, defaultValue: pid_t(0))
    }

    func readProcessIsRunning() -> Bool {
        (try? readBool(kAudioProcessPropertyIsRunning)) ?? false
    }

    func readProcessBundleID() -> String? {
        try? readString(kAudioProcessPropertyBundleID)
    }
}

// MARK: - Audio Tap

extension AudioObjectID {
    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }
}

// MARK: - Device List

extension AudioObjectID {
    static func readDeviceList() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: .unknown, count: count)
        err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
        return deviceIDs
    }
}

// MARK: - Device Properties

extension AudioDeviceID {
    func readDeviceName() throws -> String {
        try readString(kAudioObjectPropertyName)
    }

    func hasOutputStreams() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else { return false }
        return size > 0
    }

    func readDeviceIcon() -> NSImage? {
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

    func isAggregateDevice() -> Bool {
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

    /// Returns true if this device is a virtual audio device (not real hardware).
    /// Virtual devices include app-created audio routing devices like Microsoft Teams Audio, BlackHole, etc.
    func isVirtualDevice() -> Bool {
        readTransportType() == kAudioDeviceTransportTypeVirtual
    }

    /// Returns the transport type of the device (Bluetooth, USB, BuiltIn, Virtual, etc.)
    func readTransportType() -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(self, &address, 0, nil, &size, &transportType)
        return transportType
    }

    /// Returns an appropriate SF Symbol name based on device name and transport type.
    /// Used as fallback when kAudioDevicePropertyIcon is not available (Apple devices).
    func suggestedIconSymbol() -> String {
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

        // By transport type
        switch transport {
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return "hifispeaker"
        case kAudioDeviceTransportTypeUSB:
            return "headphones"
        default:
            return "hifispeaker"
        }
    }
}

// MARK: - Device Volume

extension AudioDeviceID {
    /// Reads the scalar volume (0.0 to 1.0) for the device.
    /// Tries multiple strategies to find the most representative volume:
    /// 1. Virtual main volume via AudioHardwareService (matches system volume slider)
    /// 2. Master volume scalar (element 0)
    /// 3. Left channel volume (element 1)
    /// Returns 1.0 for devices without volume control.
    func readOutputVolumeScalar() -> Float {
        // Strategy 1: Try virtual main volume (preferred - matches system slider)
        // Use AudioHardwareServiceGetPropertyData for this property as per Apple docs
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioHardwareServiceGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // Strategy 2: Try master volume scalar (element 0)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // Strategy 3: Try left channel (element 1) - common for stereo devices
        address.mElement = 1
        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // No volume control available
        return 1.0
    }

    /// Sets the scalar volume (0.0 to 1.0) for the device.
    /// Uses VirtualMainVolume via AudioHardwareService to match system volume slider behavior.
    /// Returns true if successful, false otherwise.
    func setOutputVolumeScalar(_ volume: Float) -> Bool {
        let clampedVolume = Swift.max(0.0, Swift.min(1.0, volume))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var volumeValue: Float32 = clampedVolume
        let size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioHardwareServiceSetPropertyData(self, &address, 0, nil, size, &volumeValue)
        return err == noErr
    }
}

