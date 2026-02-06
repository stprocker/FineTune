// FineTune/Audio/Processing/VolumeRamper.swift
import Foundation

/// RT-safe volume ramping with exponential smoothing.
/// Provides smooth volume transitions to avoid clicks/pops.
public struct VolumeRamper: Sendable {

    /// Smoothing coefficient (computed from sample rate and ramp time)
    public let coefficient: Float

    /// Default ramp time in seconds (30ms provides smooth transitions)
    public static let defaultRampTime: Float = 0.030

    /// Creates a ramper with the given coefficient.
    /// - Parameter coefficient: Pre-computed ramp coefficient (1 - exp(-1 / (sampleRate * rampTime)))
    public init(coefficient: Float) {
        self.coefficient = coefficient
    }

    /// Creates a ramper for the given sample rate and ramp time.
    /// - Parameters:
    ///   - sampleRate: Audio sample rate in Hz
    ///   - rampTime: Ramp time in seconds (default: 30ms)
    public init(sampleRate: Double, rampTime: Float = defaultRampTime) {
        self.coefficient = Self.computeCoefficient(sampleRate: sampleRate, rampTime: rampTime)
    }

    /// Computes the ramp coefficient for given parameters.
    /// Formula: 1 - exp(-1 / (sampleRate * rampTimeSeconds))
    /// - Parameters:
    ///   - sampleRate: Audio sample rate in Hz
    ///   - rampTime: Ramp time in seconds
    /// - Returns: Coefficient for exponential smoothing (0.0 to 1.0)
    @inline(__always)
    public static func computeCoefficient(sampleRate: Double, rampTime: Float) -> Float {
        1 - exp(-1 / (Float(sampleRate) * rampTime))
    }

    /// Steps the current volume toward the target by one sample.
    /// Call once per frame (not per sample for interleaved audio).
    /// - Parameters:
    ///   - current: Current volume value (modified in place)
    ///   - target: Target volume to approach
    @inline(__always)
    public func step(current: inout Float, toward target: Float) {
        current += (target - current) * coefficient
    }
}
