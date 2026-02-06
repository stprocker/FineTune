// FineTune/Models/VolumeMapping.swift
import Foundation

/// Utility for converting between slider position and audio gain.
/// Uses dB-based curve: 50% slider = 0dB = unity gain (passthrough).
public enum VolumeMapping {
    /// Minimum dB for slider at 0% (effectively -infinity, but use finite value)
    private static let minDB: Float = -60

    /// Maximum dB for slider at 100% (+6dB = 2x amplitude)
    private static let maxDB: Float = 6

    /// Convert slider position (0-1) to linear gain
    /// Uses dB-based curve: 50% slider = 0dB = unity gain
    /// - Parameter slider: Normalized slider position 0.0 to 1.0
    /// - Returns: Linear gain multiplier (0 to ~2.0)
    public static func sliderToGain(_ slider: Double) -> Float {
        guard slider > 0 else { return 0 }

        // Map slider 0-1 to dB range, with 0.5 = 0dB (unity)
        let dB: Float
        if slider <= 0.5 {
            // 0 to 0.5 maps to minDB to 0dB
            let t = Float(slider) / 0.5
            dB = minDB + t * (0 - minDB)
        } else {
            // 0.5 to 1.0 maps to 0dB to maxDB
            let t = (Float(slider) - 0.5) / 0.5
            dB = t * maxDB
        }

        return pow(10, dB / 20)
    }

    /// Convert linear gain to slider position (0-1)
    /// - Parameter gain: Linear gain multiplier
    /// - Returns: Normalized slider position 0.0 to 1.0
    public static func gainToSlider(_ gain: Float) -> Double {
        guard gain > 0 else { return 0 }

        let dB = 20 * log10(gain)

        if dB <= 0 {
            // Map minDB to 0dB → slider 0 to 0.5
            let t = (dB - minDB) / (0 - minDB)
            return Double(max(0, t * 0.5))
        } else {
            // Map 0dB to maxDB → slider 0.5 to 1.0
            let t = dB / maxDB
            return Double(min(1, 0.5 + t * 0.5))
        }
    }
}
