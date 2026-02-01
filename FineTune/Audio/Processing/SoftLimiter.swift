// FineTune/Audio/Processing/SoftLimiter.swift
import Foundation

/// RT-safe soft-knee limiter using asymptotic compression.
/// Prevents harsh clipping when audio is boosted above unity gain.
enum SoftLimiter {

    /// Threshold where limiting begins (below this, audio passes through)
    static let threshold: Float = 0.8

    /// Maximum output level (asymptotic ceiling)
    static let ceiling: Float = 1.0

    /// Available headroom above threshold
    @inline(__always)
    static var headroom: Float { ceiling - threshold }  // 0.2

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
    static func apply(_ sample: Float) -> Float {
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
    static func processBuffer(_ buffer: UnsafeMutablePointer<Float>, sampleCount: Int) {
        for i in 0..<sampleCount {
            buffer[i] = apply(buffer[i])
        }
    }
}
