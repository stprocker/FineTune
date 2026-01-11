import Foundation
import Accelerate

/// RT-safe 10-band graphic EQ processor using vDSP_biquad
final class EQProcessor: @unchecked Sendable {
    /// Number of delay samples per channel: (2 * sections) + 2
    /// Per Apple docs: Delay array should have length (2*M)+2 where M is sections
    private static let delayBufferSize = (2 * EQSettings.bandCount) + 2  // 22

    private let sampleRate: Double

    // Atomic setup pointer for RT-safe swapping
    private var eqSetup: vDSP_biquad_Setup?

    // Delay buffers (filter state) - one per channel
    private var delayBufferL: [Float]
    private var delayBufferR: [Float]

    // Current settings (for bypass check)
    private(set) var isEnabled: Bool = true

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.delayBufferL = [Float](repeating: 0, count: Self.delayBufferSize)
        self.delayBufferR = [Float](repeating: 0, count: Self.delayBufferSize)

        // Initialize with flat EQ
        updateSettings(EQSettings.flat)
    }

    deinit {
        if let setup = eqSetup {
            vDSP_biquad_DestroySetup(setup)
        }
    }

    /// Update EQ settings (call from main thread)
    func updateSettings(_ settings: EQSettings) {
        isEnabled = settings.isEnabled

        let coefficients = BiquadMath.coefficientsForAllBands(
            gains: settings.clampedGains,
            sampleRate: sampleRate
        )

        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(EQSettings.bandCount))
        }

        // Swap setup atomically
        let oldSetup = eqSetup
        eqSetup = newSetup

        // Destroy old setup on background queue
        if let old = oldSetup {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                vDSP_biquad_DestroySetup(old)
            }
        }

        // Reset delay buffers to prevent transient click
        delayBufferL = [Float](repeating: 0, count: Self.delayBufferSize)
        delayBufferR = [Float](repeating: 0, count: Self.delayBufferSize)
    }

    /// Process stereo interleaved audio (RT-safe)
    /// - Parameters:
    ///   - input: Input buffer (stereo interleaved Float32)
    ///   - output: Output buffer (stereo interleaved Float32)
    ///   - frameCount: Number of stereo frames (samples / 2)
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Bypass: copy input to output
        guard isEnabled, let setup = eqSetup else {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            return
        }

        // Copy input to output first (in-place processing)
        memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)

        // Process left channel (stride=2, starts at index 0)
        delayBufferL.withUnsafeMutableBufferPointer { delayPtr in
            vDSP_biquad(
                setup,
                delayPtr.baseAddress!,
                output,           // Input: left samples at indices 0, 2, 4...
                2,                // Stride
                output,           // Output: same positions
                2,
                vDSP_Length(frameCount)
            )
        }

        // Process right channel (stride=2, starts at index 1)
        delayBufferR.withUnsafeMutableBufferPointer { delayPtr in
            vDSP_biquad(
                setup,
                delayPtr.baseAddress!,
                output.advanced(by: 1),  // Input: right samples at indices 1, 3, 5...
                2,
                output.advanced(by: 1),  // Output: same positions
                2,
                vDSP_Length(frameCount)
            )
        }
    }
}
