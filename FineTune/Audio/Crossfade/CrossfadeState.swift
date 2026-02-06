// FineTune/Audio/Crossfade/CrossfadeState.swift
import Foundation

/// Configuration for crossfade behavior.
public enum CrossfadeConfig {
    public static let defaultDuration: TimeInterval = 0.050  // 50ms

    public static var duration: TimeInterval {
        let custom = UserDefaults.standard.double(forKey: "FineTuneCrossfadeDuration")
        return custom > 0 ? custom : defaultDuration
    }

    public static func totalSamples(at sampleRate: Double) -> Int64 {
        Int64(sampleRate * duration)
    }
}

/// State machine phases for device switching crossfade.
public enum CrossfadePhase: Equatable {
    /// No crossfade in progress
    case idle
    /// Secondary tap created, waiting for warmup
    case warmingUp
    /// Crossfade in progress (0 → 1)
    case crossfading
    /// Crossfade complete, promoting secondary to primary
    case completing
}

/// RT-safe crossfade state container.
/// All fields are designed for lock-free access from audio callbacks.
///
/// **Memory ordering:** Uses aligned Float/Int reads which are atomic on Apple platforms.
/// The main thread writes, audio thread reads. Slight staleness is acceptable.
public struct CrossfadeState: @unchecked Sendable {
    /// Current crossfade progress (0 = full primary, 1 = full secondary)
    nonisolated(unsafe) public var progress: Float = 0

    /// Whether a crossfade is currently active
    nonisolated(unsafe) public var isActive: Bool = false

    /// Sample count from secondary callback (drives timing)
    nonisolated(unsafe) public var secondarySampleCount: Int64 = 0

    /// Total samples for the crossfade duration
    nonisolated(unsafe) public var totalSamples: Int64 = 0

    /// Samples processed by secondary (for warmup tracking)
    nonisolated(unsafe) public var secondarySamplesProcessed: Int = 0

    /// Minimum samples secondary must process before destroying primary
    public static let minimumWarmupSamples: Int = 2048  // ~43ms at 48kHz

    public init() {}

    /// Resets all state for a new crossfade
    public mutating func beginCrossfade(at sampleRate: Double) {
        progress = 0
        secondarySampleCount = 0
        secondarySamplesProcessed = 0
        totalSamples = CrossfadeConfig.totalSamples(at: sampleRate)
        isActive = true
        OSMemoryBarrier()  // Ensure audio callbacks see all state before isActive
    }

    /// Updates progress based on samples processed (called from secondary callback)
    /// - Parameter samples: Number of samples just processed
    /// - Returns: New progress value (0.0 to 1.0)
    @inline(__always)
    public mutating func updateProgress(samples: Int) -> Float {
        secondarySamplesProcessed += samples
        if isActive {
            secondarySampleCount += Int64(samples)
            progress = min(1.0, Float(secondarySampleCount) / Float(max(1, totalSamples)))
        }
        return progress
    }

    /// Completes the crossfade and resets all state
    public mutating func complete() {
        isActive = false
        progress = 0
        secondarySampleCount = 0
        secondarySamplesProcessed = 0
        totalSamples = 0
        OSMemoryBarrier()
    }

    /// Checks if warmup is complete (enough samples processed)
    public var isWarmupComplete: Bool {
        secondarySamplesProcessed >= Self.minimumWarmupSamples
    }

    /// Checks if the crossfade animation is complete
    public var isCrossfadeComplete: Bool {
        progress >= 1.0
    }

    /// Computes equal-power fade-out multiplier for primary tap.
    /// cos(0) = 1.0, cos(π/2) = 0.0
    @inline(__always)
    public var primaryMultiplier: Float {
        if isActive {
            return cos(progress * .pi / 2.0)
        } else if progress >= 1.0 {
            // Crossfade complete but not yet reset - stay silent
            return 0.0
        }
        return 1.0
    }

    /// Computes equal-power fade-in multiplier for secondary tap.
    /// sin(0) = 0.0, sin(π/2) = 1.0
    @inline(__always)
    public var secondaryMultiplier: Float {
        if isActive {
            return sin(progress * .pi / 2.0)
        }
        return 1.0  // After promotion, full volume
    }
}
