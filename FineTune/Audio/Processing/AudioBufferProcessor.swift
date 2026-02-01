// FineTune/Audio/Processing/AudioBufferProcessor.swift
import AudioToolbox
import Accelerate

/// RT-safe audio buffer operations.
/// All methods are allocation-free and lock-free for real-time audio safety.
enum AudioBufferProcessor {

    /// Zeroes all output buffers (for silence during mute or device switching).
    /// - Parameter outputBuffers: The output buffer list to zero
    @inline(__always)
    static func zeroOutputBuffers(_ outputBuffers: UnsafeMutableAudioBufferListPointer) {
        for outputBuffer in outputBuffers {
            guard let outputData = outputBuffer.mData else { continue }
            memset(outputData, 0, Int(outputBuffer.mDataByteSize))
        }
    }

    /// Copies input buffers to output buffers (passthrough).
    /// - Parameters:
    ///   - inputBuffers: Source buffer list
    ///   - outputBuffers: Destination buffer list
    @inline(__always)
    static func copyInputToOutput(
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer
    ) {
        let bufferCount = min(inputBuffers.count, outputBuffers.count)
        guard bufferCount > 0 else { return }
        for index in 0..<bufferCount {
            let inputBuffer = inputBuffers[index]
            let outputBuffer = outputBuffers[index]
            guard let inputData = inputBuffer.mData,
                  let outputData = outputBuffer.mData else { continue }
            let byteCount = min(Int(inputBuffer.mDataByteSize), Int(outputBuffer.mDataByteSize))
            memcpy(outputData, inputData, byteCount)
        }
    }

    /// Computes peak absolute sample value across all buffers (for VU meters).
    /// Uses vDSP for SIMD-optimized magnitude calculation.
    /// - Parameter inputBuffers: Float32 buffer list to scan
    /// - Returns: Maximum absolute sample value (0.0 to potentially >1.0)
    @inline(__always)
    static func computePeak(inputBuffers: UnsafeMutableAudioBufferListPointer) -> Float {
        var maxPeak: Float = 0.0
        for inputBuffer in inputBuffers {
            guard let inputData = inputBuffer.mData else { continue }
            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let sampleCount = vDSP_Length(inputBuffer.mDataByteSize) / vDSP_Length(MemoryLayout<Float>.size)
            guard sampleCount > 0 else { continue }

            var bufferPeak: Float = 0.0
            vDSP_maxmgv(inputSamples, 1, &bufferPeak, sampleCount)

            if bufferPeak > maxPeak {
                maxPeak = bufferPeak
            }
        }
        return maxPeak
    }

    /// Returns frame count from a buffer list given bytes per frame.
    /// - Parameters:
    ///   - bufferList: Audio buffer list pointer
    ///   - bytesPerFrame: Bytes per audio frame
    /// - Returns: Number of frames in the first buffer, or 0 if invalid
    @inline(__always)
    static func frameCount(
        bufferList: UnsafeMutableAudioBufferListPointer,
        bytesPerFrame: Int
    ) -> Int {
        guard bufferList.count > 0, bytesPerFrame > 0 else { return 0 }
        let buffer = bufferList[0]
        return Int(buffer.mDataByteSize) / bytesPerFrame
    }
}
