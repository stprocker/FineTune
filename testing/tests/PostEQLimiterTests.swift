import XCTest
@testable import FineTuneCore

final class PostEQLimiterTests: XCTestCase {

    // MARK: - Post-EQ limiting clamps boosted signal

    func testBoostedSignalClampedBelowCeiling() {
        // Simulate signal at 0.85 (above soft-limiter threshold) boosted by +12 dB (~×4)
        let baseLevel: Float = 0.85
        let boostFactor: Float = 4.0
        let sampleCount = 1024  // 512 stereo frames
        var buffer = [Float](repeating: baseLevel * boostFactor, count: sampleCount)

        buffer.withUnsafeMutableBufferPointer { ptr in
            SoftLimiter.processBuffer(ptr.baseAddress!, sampleCount: sampleCount)
        }

        for (i, sample) in buffer.enumerated() {
            XCTAssertLessThanOrEqual(sample, SoftLimiter.ceiling,
                "Sample \(i) = \(sample) exceeds ceiling after post-EQ limiting")
        }
    }

    // MARK: - Below-threshold passthrough

    func testBelowThresholdPassthroughUnchanged() {
        let baseLevel: Float = 0.5
        let sampleCount = 1024
        var buffer = [Float](repeating: baseLevel, count: sampleCount)
        let original = buffer

        buffer.withUnsafeMutableBufferPointer { ptr in
            SoftLimiter.processBuffer(ptr.baseAddress!, sampleCount: sampleCount)
        }

        for (i, (actual, expected)) in zip(buffer, original).enumerated() {
            XCTAssertEqual(actual, expected, accuracy: 1e-7,
                "Sample \(i) should be unchanged when below threshold")
        }
    }

    // MARK: - Interleaved stereo with mixed amplitudes

    func testInterleavedStereoMixedAmplitudes() {
        // Left channel: boosted above ceiling, Right channel: below threshold
        // Pattern: [L, R, L, R, ...]
        let sampleCount = 512
        var buffer = [Float](repeating: 0, count: sampleCount)
        for i in stride(from: 0, to: sampleCount, by: 2) {
            buffer[i]     = 3.4   // Left: well above ceiling (simulates +12 dB boost)
            buffer[i + 1] = 0.3   // Right: well below threshold
        }

        buffer.withUnsafeMutableBufferPointer { ptr in
            SoftLimiter.processBuffer(ptr.baseAddress!, sampleCount: sampleCount)
        }

        for i in stride(from: 0, to: sampleCount, by: 2) {
            XCTAssertLessThanOrEqual(buffer[i], SoftLimiter.ceiling,
                "Left sample \(i) = \(buffer[i]) exceeds ceiling")
            XCTAssertGreaterThan(buffer[i], SoftLimiter.threshold,
                "Left sample \(i) should be compressed, not zeroed")
            XCTAssertEqual(buffer[i + 1], 0.3, accuracy: 1e-7,
                "Right sample \(i + 1) should pass through unchanged")
        }
    }
}
