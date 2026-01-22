import Foundation

struct EQSettings: Codable, Equatable {
    static let bandCount = 10
    static let maxGainDB: Float = 12.0
    static let minGainDB: Float = -12.0

    /// ISO standard frequencies for 10-band graphic EQ
    static let frequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    /// Gain in dB for each band (-12 to +12)
    var bandGains: [Float]

    /// Whether EQ processing is enabled
    var isEnabled: Bool

    init(bandGains: [Float] = Array(repeating: 0, count: 10), isEnabled: Bool = true) {
        self.bandGains = bandGains
        self.isEnabled = isEnabled
    }

    /// Returns gains clamped to valid range and padded/truncated to exactly bandCount elements.
    /// This provides defensive validation against corrupted settings files.
    var clampedGains: [Float] {
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
    static let flat = EQSettings()
}
