// FineTune/Audio/Types/TransportType.swift
import AudioToolbox

/// Represents how an audio device connects to the system.
///
/// Future additions if needed:
/// - `displayPort` (kAudioDeviceTransportTypeDisplayPort)
/// - `pci` (kAudioDeviceTransportTypePCI)
/// - `fireWire` (kAudioDeviceTransportTypeFireWire)
/// - See kAudioDeviceTransportType* constants in AudioHardware.h
nonisolated enum TransportType: Sendable {
    case builtIn
    case usb
    case bluetooth
    case bluetoothLE
    case airPlay
    case virtual
    case thunderbolt
    case hdmi
    case aggregate
    case unknown

    nonisolated init(rawValue: UInt32) {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn:     self = .builtIn
        case kAudioDeviceTransportTypeUSB:         self = .usb
        case kAudioDeviceTransportTypeBluetooth:   self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeAirPlay:     self = .airPlay
        case kAudioDeviceTransportTypeVirtual:     self = .virtual
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeHDMI:        self = .hdmi
        case kAudioDeviceTransportTypeAggregate:   self = .aggregate
        default:                                    self = .unknown
        }
    }

    /// Default SF Symbol for this transport type.
    /// Used as fallback when device-specific icon unavailable.
    nonisolated var defaultIconSymbol: String {
        switch self {
        case .builtIn:     return "hifispeaker"
        case .usb:         return "headphones"
        case .bluetooth:   return "headphones"
        case .bluetoothLE: return "headphones"
        case .airPlay:     return "airplayaudio"
        case .virtual:     return "waveform"
        case .thunderbolt: return "bolt.horizontal"
        case .hdmi:        return "tv"
        case .aggregate:   return "speaker.wave.2"
        case .unknown:     return "hifispeaker"
        }
    }
}
