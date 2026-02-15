// FineTune/Audio/Processing/SoftLimiter.swift
import Foundation
import Accelerate

/// RT-safe soft-knee limiter using asymptotic compression.
/// Prevents harsh clipping when audio is boosted above unity gain.
public enum SoftLimiter {

    /// Threshold where limiting begins (below this, audio passes through)
    public static let threshold: Float = 0.9

    /// Maximum output level (asymptotic ceiling)
    public static let ceiling: Float = 1.0

    /// Available headroom above threshold
    @inline(__always)
    public static var headroom: Float { ceiling - threshold }  // 0.1

    /// Applies soft-knee limiting to a single sample.
    /// - Below threshold: passes through unchanged
    /// - Above threshold: smooth compression toward ceiling
    ///
    /// Output is guaranteed <= ceiling for any finite input.
    /// Transparent for musical material; only engages on peaks.
    ///
    /// - Parameter sample: Input sample (may exceed ±1.0 when boosted)
    /// - Returns: Limited sample in range approximately ±ceiling
    @inline(__always)
    public static func apply(_ sample: Float) -> Float {
        let absSample = abs(sample)

        // Below threshold: pass through unchanged
        if absSample <= threshold {
            return sample
        }

        // Above threshold: asymptotic compression
        let overshoot = absSample - threshold
        // Smooth approach to ceiling: threshold + headroom * (overshoot / (overshoot + headroom))
        let compressed = threshold + headroom * (overshoot / (overshoot + headroom))

        return sample >= 0 ? compressed : -compressed
    }

    /// Applies soft limiting to an entire buffer of interleaved stereo samples.
    /// - Parameters:
    ///   - buffer: Pointer to interleaved Float32 samples
    ///   - sampleCount: Total number of samples (frames * channels)
    @inline(__always)
    public static func processBuffer(_ buffer: UnsafeMutablePointer<Float>, sampleCount: Int) {
        // Fast path: if peak is at or below threshold, no limiting needed
        var bufferPeak: Float = 0
        vDSP_maxmgv(buffer, 1, &bufferPeak, vDSP_Length(sampleCount))
        guard bufferPeak > threshold else { return }

        for i in 0..<sampleCount {
            buffer[i] = apply(buffer[i])
        }
    }
}
