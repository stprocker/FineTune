import Foundation

/// Audio EQ Cookbook biquad coefficient calculations
/// Reference: Robert Bristow-Johnson's Audio EQ Cookbook
public enum BiquadMath {
    /// Base Q for adaptive graphic EQ (at 0 dB gain)
    public static let baseQ: Double = 1.2

    /// Minimum Q floor (at maximum gain)
    public static let minQ: Double = 0.9

    /// Q reduction rate per dB of absolute gain
    public static let qSlopePerDB: Double = 0.025

    /// Compute adaptive Q for a given band gain.
    /// Q widens (decreases) as gain increases, counteracting the RBJ peaking EQ's
    /// natural bandwidth narrowing at higher gains.
    public static func adaptiveQ(forGainDB gain: Float) -> Double {
        return max(minQ, baseQ - Double(abs(gain)) * qSlopePerDB)
    }

    /// Compute peaking EQ biquad coefficients
    /// Returns [b0, b1, b2, a1, a2] normalized by a0 for vDSP_biquad
    public static func peakingEQCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)

        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cosW
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cosW
        let a2 = 1.0 - alpha / A

        // Normalize by a0 for vDSP_biquad format
        // Note: vDSP uses difference equation y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] + a1*y[n-1] + a2*y[n-2]
        return [
            b0 / a0,
            b1 / a0,
            b2 / a0,
            a1 / a0,
            a2 / a0
        ]
    }

    /// Compute coefficients for all 10 bands
    /// Returns 50 Doubles: [band0: b0,b1,b2,a1,a2, band1: ..., ...]
    public static func coefficientsForAllBands(
        gains: [Float],
        sampleRate: Double
    ) -> [Double] {
        precondition(gains.count == EQSettings.bandCount)

        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(50)

        for (index, frequency) in EQSettings.frequencies.enumerated() {
            let q = adaptiveQ(forGainDB: gains[index])
            let bandCoeffs = peakingEQCoefficients(
                frequency: frequency,
                gainDB: gains[index],
                q: q,
                sampleRate: sampleRate
            )
            allCoeffs.append(contentsOf: bandCoeffs)
        }

        return allCoeffs
    }
}
