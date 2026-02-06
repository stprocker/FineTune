// FineTune/Audio/Processing/GainProcessor.swift
import AudioToolbox
import Accelerate

/// RT-safe gain processing with volume ramping and soft limiting.
/// Handles both interleaved and non-interleaved audio formats.
enum GainProcessor {

    /// Processes Float32 audio buffers with ramped gain and optional soft limiting.
    ///
    /// **RT SAFETY CONSTRAINTS - This function is called from CoreAudio's HAL I/O thread:**
    /// - No memory allocation
    /// - No locks or mutexes
    /// - No Objective-C messaging
    /// - No logging or I/O
    ///
    /// - Parameters:
    ///   - channelCount: Number of audio channels (1 or 2)
    ///   - isInterleaved: Whether samples are interleaved (LRLRLR) or planar (LLL...RRR...)
    ///   - inputBuffers: Source audio buffers
    ///   - outputBuffers: Destination audio buffers
    ///   - targetVolume: Target volume level (may exceed 1.0)
    ///   - currentVolume: Current ramped volume (modified in place)
    ///   - rampCoefficient: Smoothing coefficient for volume ramping
    ///   - crossfadeMultiplier: Additional multiplier for crossfade transitions (0.0-1.0)
    ///   - compensation: Device volume compensation scalar
    @inline(__always)
    static func processFloatBuffers(
        channelCount: Int,
        isInterleaved: Bool,
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        targetVolume: Float,
        currentVolume: inout Float,
        rampCoefficient: Float,
        crossfadeMultiplier: Float,
        compensation: Float
    ) {
        let bufferCount = min(inputBuffers.count, outputBuffers.count)
        guard bufferCount > 0 else { return }

        let channels = max(1, channelCount)
        let shouldLimit = targetVolume > 1.0

        // Fast path: volume has converged and no limiting needed.
        // Use vDSP_vsmul for SIMD-accelerated scalar multiply instead of per-sample ramping.
        // This is the common steady-state path (volume only ramps for ~30ms after a change).
        let volumeConverged = abs(currentVolume - targetVolume) < 1e-6
        if volumeConverged && !shouldLimit {
            var gain = targetVolume * crossfadeMultiplier * compensation
            currentVolume = targetVolume
            for index in 0..<bufferCount {
                let inputBuffer = inputBuffers[index]
                let outputBuffer = outputBuffers[index]
                guard let inputData = inputBuffer.mData,
                      let outputData = outputBuffer.mData else { continue }
                let inputSamples = inputData.assumingMemoryBound(to: Float.self)
                let outputSamples = outputData.assumingMemoryBound(to: Float.self)
                let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
                guard sampleCount > 0 else { continue }
                vDSP_vsmul(inputSamples, 1, &gain, outputSamples, 1, vDSP_Length(sampleCount))
            }
            return
        }

        if isInterleaved {
            processInterleaved(
                channels: channels,
                bufferCount: bufferCount,
                inputBuffers: inputBuffers,
                outputBuffers: outputBuffers,
                targetVolume: targetVolume,
                currentVolume: &currentVolume,
                rampCoefficient: rampCoefficient,
                crossfadeMultiplier: crossfadeMultiplier,
                compensation: compensation,
                shouldLimit: shouldLimit
            )
        } else {
            processNonInterleaved(
                channels: channels,
                bufferCount: bufferCount,
                inputBuffers: inputBuffers,
                outputBuffers: outputBuffers,
                targetVolume: targetVolume,
                currentVolume: &currentVolume,
                rampCoefficient: rampCoefficient,
                crossfadeMultiplier: crossfadeMultiplier,
                compensation: compensation,
                shouldLimit: shouldLimit
            )
        }
    }

    // MARK: - Private Helpers

    @inline(__always)
    private static func processInterleaved(
        channels: Int,
        bufferCount: Int,
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        targetVolume: Float,
        currentVolume: inout Float,
        rampCoefficient: Float,
        crossfadeMultiplier: Float,
        compensation: Float,
        shouldLimit: Bool
    ) {
        for index in 0..<bufferCount {
            let inputBuffer = inputBuffers[index]
            let outputBuffer = outputBuffers[index]
            guard let inputData = inputBuffer.mData,
                  let outputData = outputBuffer.mData else { continue }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

            var channelIndex = 0
            var frameGain: Float = currentVolume * crossfadeMultiplier * compensation

            for i in 0..<sampleCount {
                // Update gain once per frame (at start of each frame)
                if channelIndex == 0 {
                    currentVolume += (targetVolume - currentVolume) * rampCoefficient
                    frameGain = currentVolume * crossfadeMultiplier * compensation
                }

                var sample = inputSamples[i] * frameGain
                if shouldLimit {
                    sample = SoftLimiter.apply(sample)
                }
                outputSamples[i] = sample

                channelIndex += 1
                if channelIndex >= channels {
                    channelIndex = 0
                }
            }
        }
    }

    @inline(__always)
    private static func processNonInterleaved(
        channels: Int,
        bufferCount: Int,
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        targetVolume: Float,
        currentVolume: inout Float,
        rampCoefficient: Float,
        crossfadeMultiplier: Float,
        compensation: Float,
        shouldLimit: Bool
    ) {
        let channelCount = min(channels, bufferCount)

        // Find minimum frame count across all channels
        var frameCount = Int.max
        for channel in 0..<channelCount {
            let inputBuffer = inputBuffers[channel]
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            frameCount = min(frameCount, sampleCount)
        }
        guard frameCount != Int.max else { return }

        // Process frame by frame across all channels
        for frame in 0..<frameCount {
            currentVolume += (targetVolume - currentVolume) * rampCoefficient
            let frameGain = currentVolume * crossfadeMultiplier * compensation

            for channel in 0..<channelCount {
                let inputBuffer = inputBuffers[channel]
                let outputBuffer = outputBuffers[channel]
                guard let inputData = inputBuffer.mData,
                      let outputData = outputBuffer.mData else { continue }

                let inputSamples = inputData.assumingMemoryBound(to: Float.self)
                let outputSamples = outputData.assumingMemoryBound(to: Float.self)

                var sample = inputSamples[frame] * frameGain
                if shouldLimit {
                    sample = SoftLimiter.apply(sample)
                }
                outputSamples[frame] = sample
            }
        }
    }
}
