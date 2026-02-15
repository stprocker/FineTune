import XCTest
@testable import FineTuneCore

final class SoftLimiterTests: XCTestCase {

    // MARK: - Constants

    func testThresholdIs0Point95() {
        XCTAssertEqual(SoftLimiter.threshold, 0.95)
    }

    func testCeilingIs1Point0() {
        XCTAssertEqual(SoftLimiter.ceiling, 1.0)
    }

    func testHeadroomIs0Point05() {
        XCTAssertEqual(SoftLimiter.headroom, 0.05, accuracy: 1e-7)
    }

    // MARK: - Passthrough below threshold

    func testPassthroughForZero() {
        XCTAssertEqual(SoftLimiter.apply(0), 0)
    }

    func testPassthroughForSmallPositive() {
        let sample: Float = 0.3
        XCTAssertEqual(SoftLimiter.apply(sample), sample)
    }

    func testPassthroughForSmallNegative() {
        let sample: Float = -0.5
        XCTAssertEqual(SoftLimiter.apply(sample), sample)
    }

    func testPassthroughAtExactThreshold() {
        XCTAssertEqual(SoftLimiter.apply(0.95), 0.95)
        XCTAssertEqual(SoftLimiter.apply(-0.95), -0.95)
    }

    func testPassthroughForAllValuesBelowThreshold() {
        for i in 0...95 {
            let sample = Float(i) / 100.0
            XCTAssertEqual(SoftLimiter.apply(sample), sample, accuracy: 1e-7,
                           "Sample \(sample) should pass through unchanged")
            XCTAssertEqual(SoftLimiter.apply(-sample), -sample, accuracy: 1e-7,
                           "Sample \(-sample) should pass through unchanged")
        }
    }

    // MARK: - Limiting above threshold

    func testLimitingAboveThreshold() {
        let result = SoftLimiter.apply(0.98)
        XCTAssertGreaterThan(result, 0.95, "Should be above threshold")
        XCTAssertLessThan(result, 1.0, "Should be below ceiling")
    }

    func testLimitingJustAboveThreshold() {
        let result = SoftLimiter.apply(0.96)
        XCTAssertGreaterThan(result, 0.95)
        XCTAssertLessThan(result, 0.96, "Compressed output should be less than input above threshold")
    }

    func testCeilingNeverExceeded() {
        let extremeInputs: [Float] = [1.0, 2.0, 5.0, 10.0, 100.0, 1000.0]
        for input in extremeInputs {
            let result = SoftLimiter.apply(input)
            XCTAssertLessThanOrEqual(result, SoftLimiter.ceiling,
                                      "Output \(result) should not exceed ceiling for input \(input)")
        }
    }

    func testCeilingNeverExceededNegative() {
        let extremeInputs: [Float] = [-1.0, -2.0, -5.0, -10.0, -100.0]
        for input in extremeInputs {
            let result = SoftLimiter.apply(input)
            XCTAssertGreaterThanOrEqual(result, -SoftLimiter.ceiling,
                                         "Output \(result) should not be below -ceiling for input \(input)")
        }
    }

    // MARK: - Symmetry

    func testSymmetryForPositiveAndNegative() {
        let testValues: [Float] = [0.95, 0.98, 1.0, 1.5, 2.0, 5.0]
        for value in testValues {
            let positive = SoftLimiter.apply(value)
            let negative = SoftLimiter.apply(-value)
            XCTAssertEqual(positive, -negative, accuracy: 1e-7,
                           "apply(\(value)) should equal -apply(\(-value))")
        }
    }

    // MARK: - Monotonicity

    func testMonotonicIncreaseAboveThreshold() {
        var prev = SoftLimiter.apply(0.95)
        for i in 96...200 {
            let sample = Float(i) / 100.0
            let result = SoftLimiter.apply(sample)
            XCTAssertGreaterThanOrEqual(result, prev,
                                         "Output should monotonically increase: apply(\(sample))=\(result) should >= \(prev)")
            prev = result
        }
    }

    // MARK: - Asymptotic behavior

    func testAsymptoticApproachToCeiling() {
        let result1 = SoftLimiter.apply(1.0)
        let result10 = SoftLimiter.apply(10.0)
        let result100 = SoftLimiter.apply(100.0)

        // Should get progressively closer to 1.0
        XCTAssertLessThan(result1, result10)
        XCTAssertLessThan(result10, result100)
        XCTAssertGreaterThan(result100, 0.99, "Very large input should be very close to ceiling")
    }

    // MARK: - Continuity at threshold

    func testContinuityAtThreshold() {
        let atThreshold = SoftLimiter.apply(0.95)
        let justAbove = SoftLimiter.apply(0.951)
        XCTAssertEqual(atThreshold, 0.95, accuracy: 1e-7)
        XCTAssertEqual(justAbove, 0.95, accuracy: 0.01, "Just above threshold should be close to threshold value")
    }

    // MARK: - Known values

    func testKnownCompressionValue() {
        // For input = 1.0: overshoot = 0.05, compressed = 0.95 + 0.05 * (0.05 / (0.05 + 0.05)) = 0.975
        let result = SoftLimiter.apply(1.0)
        XCTAssertEqual(result, 0.975, accuracy: 1e-6, "apply(1.0) should equal 0.975")
    }

    func testKnownCompressionValue2() {
        // For input = 1.2: overshoot = 0.25, compressed = 0.95 + 0.05 * (0.25 / (0.25 + 0.05))
        let result = SoftLimiter.apply(1.2)
        let expected: Float = 0.95 + 0.05 * (0.25 / 0.30)
        XCTAssertEqual(result, expected, accuracy: 1e-6)
    }

    // MARK: - processBuffer

    func testProcessBufferAppliesLimitingToAllSamples() {
        var buffer: [Float] = [0.5, 0.9, 0.95, 1.0, -0.5, -0.95, -1.0, 2.0]
        let expected = buffer.map { SoftLimiter.apply($0) }

        buffer.withUnsafeMutableBufferPointer { ptr in
            SoftLimiter.processBuffer(ptr.baseAddress!, sampleCount: ptr.count)
        }

        for (i, (actual, exp)) in zip(buffer, expected).enumerated() {
            XCTAssertEqual(actual, exp, accuracy: 1e-7, "Sample \(i) mismatch")
        }
    }

    func testProcessBufferWithAllBelowThreshold() {
        var buffer: [Float] = [0.1, 0.2, 0.3, -0.1, -0.2, -0.3]
        let original = buffer

        buffer.withUnsafeMutableBufferPointer { ptr in
            SoftLimiter.processBuffer(ptr.baseAddress!, sampleCount: ptr.count)
        }

        for (i, (actual, orig)) in zip(buffer, original).enumerated() {
            XCTAssertEqual(actual, orig, accuracy: 1e-7, "Sample \(i) should be unchanged")
        }
    }

    func testProcessBufferEmptyIsNoOp() {
        var buffer: [Float] = [1.5]
        let original = buffer[0]

        buffer.withUnsafeMutableBufferPointer { ptr in
            SoftLimiter.processBuffer(ptr.baseAddress!, sampleCount: 0)
        }

        XCTAssertEqual(buffer[0], original, "Zero-count processing should not modify buffer")
    }
}
