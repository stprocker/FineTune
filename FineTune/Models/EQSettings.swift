import Foundation

public struct EQSettings: Codable, Equatable, Sendable {
    public static let bandCount = 10
    public static let maxGainDB: Float = 12.0
    public static let minGainDB: Float = -12.0

    /// ISO standard frequencies for 10-band graphic EQ
    public static let frequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    /// Gain in dB for each band (-12 to +12)
    public var bandGains: [Float]

    /// Whether EQ processing is enabled
    public var isEnabled: Bool

    public init(bandGains: [Float] = Array(repeating: 0, count: 10), isEnabled: Bool = true) {
        self.bandGains = bandGains
        self.isEnabled = isEnabled
    }

    /// Returns gains clamped to valid range and padded/truncated to exactly bandCount elements.
    /// This provides defensive validation against corrupted settings files.
    public var clampedGains: [Float] {
        var gains = bandGains.map { max(Self.minGainDB, min(Self.maxGainDB, $0)) }
        // Ensure exactly bandCount elements (defensive against corrupted settings)
        if gains.count < Self.bandCount {
            gains.append(contentsOf: Array(repeating: Float(0), count: Self.bandCount - gains.count))
        } else if gains.count > Self.bandCount {
            gains = Array(gains.prefix(Self.bandCount))
        }
        return gains
    }

    /// Flat EQ preset
    public static let flat = EQSettings()
}
