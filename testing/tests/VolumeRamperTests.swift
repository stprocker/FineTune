import XCTest
@testable import FineTuneCore

final class VolumeRamperTests: XCTestCase {

    // MARK: - Coefficient computation

    func testDefaultRampTime() {
        XCTAssertEqual(VolumeRamper.defaultRampTime, 0.030, accuracy: 1e-7)
    }

    func testCoefficientInValidRange() {
        let rates: [Double] = [8000, 22050, 44100, 48000, 96000, 192000]
        let rampTimes: [Float] = [0.001, 0.010, 0.030, 0.050, 0.100, 1.0]

        for rate in rates {
            for ramp in rampTimes {
                let coeff = VolumeRamper.computeCoefficient(sampleRate: rate, rampTime: ramp)
                XCTAssertGreaterThan(coeff, 0, "Coefficient should be > 0 for rate=\(rate), ramp=\(ramp)")
                XCTAssertLessThan(coeff, 1, "Coefficient should be < 1 for rate=\(rate), ramp=\(ramp)")
            }
        }
    }

    func testHigherSampleRateProducesSmallerCoefficient() {
        let coeff44 = VolumeRamper.computeCoefficient(sampleRate: 44100, rampTime: 0.030)
        let coeff96 = VolumeRamper.computeCoefficient(sampleRate: 96000, rampTime: 0.030)
        XCTAssertLessThan(coeff96, coeff44, "Higher sample rate should produce smaller per-sample coefficient")
    }

    func testShorterRampTimeProducesLargerCoefficient() {
        let coeffFast = VolumeRamper.computeCoefficient(sampleRate: 44100, rampTime: 0.010)
        let coeffSlow = VolumeRamper.computeCoefficient(sampleRate: 44100, rampTime: 0.100)
        XCTAssertGreaterThan(coeffFast, coeffSlow, "Shorter ramp time should produce larger coefficient")
    }

    func testCoefficientFormula() {
        // Verify: coefficient = 1 - exp(-1 / (sampleRate * rampTime))
        let rate: Double = 44100
        let ramp: Float = 0.030
        let expected: Float = 1 - exp(-1 / (Float(rate) * ramp))
        let actual = VolumeRamper.computeCoefficient(sampleRate: rate, rampTime: ramp)
        XCTAssertEqual(actual, expected, accuracy: 1e-7)
    }

    // MARK: - Init

    func testInitWithCoefficient() {
        let ramper = VolumeRamper(coefficient: 0.5)
        XCTAssertEqual(ramper.coefficient, 0.5)
    }

    func testInitWithSampleRate() {
        let ramper = VolumeRamper(sampleRate: 44100)
        let expected = VolumeRamper.computeCoefficient(sampleRate: 44100, rampTime: 0.030)
        XCTAssertEqual(ramper.coefficient, expected, accuracy: 1e-7)
    }

    func testInitWithSampleRateAndCustomRampTime() {
        let ramper = VolumeRamper(sampleRate: 48000, rampTime: 0.050)
        let expected = VolumeRamper.computeCoefficient(sampleRate: 48000, rampTime: 0.050)
        XCTAssertEqual(ramper.coefficient, expected, accuracy: 1e-7)
    }

    // MARK: - Step behavior

    func testStepMovesTowardTarget() {
        let ramper = VolumeRamper(coefficient: 0.1)
        var current: Float = 0.0
        ramper.step(current: &current, toward: 1.0)
        XCTAssertGreaterThan(current, 0.0, "Should move toward target")
        XCTAssertLessThan(current, 1.0, "Should not overshoot target")
    }

    func testStepMovesDownward() {
        let ramper = VolumeRamper(coefficient: 0.1)
        var current: Float = 1.0
        ramper.step(current: &current, toward: 0.0)
        XCTAssertLessThan(current, 1.0, "Should decrease toward target")
        XCTAssertGreaterThan(current, 0.0, "Should not undershoot target")
    }

    func testStepConvergesToTarget() {
        let ramper = VolumeRamper(sampleRate: 44100, rampTime: 0.030)
        var current: Float = 0.0
        let target: Float = 1.0

        // After many steps, should be very close to target
        // Float32 precision limits convergence, so use wider tolerance
        for _ in 0..<10000 {
            ramper.step(current: &current, toward: target)
        }
        XCTAssertEqual(current, target, accuracy: 1e-3, "Should converge to target after many steps")
    }

    func testStepMonotonicConvergence() {
        let ramper = VolumeRamper(coefficient: 0.05)
        var current: Float = 0.0
        let target: Float = 1.0

        var prev = current
        for _ in 0..<100 {
            ramper.step(current: &current, toward: target)
            XCTAssertGreaterThanOrEqual(current, prev, "Should monotonically approach target from below")
            prev = current
        }
    }

    func testStepMonotonicConvergenceDownward() {
        let ramper = VolumeRamper(coefficient: 0.05)
        var current: Float = 1.0
        let target: Float = 0.0

        var prev = current
        for _ in 0..<100 {
            ramper.step(current: &current, toward: target)
            XCTAssertLessThanOrEqual(current, prev, "Should monotonically approach target from above")
            prev = current
        }
    }

    func testStepNoOvershoot() {
        // Even with a large coefficient, step should never overshoot
        let ramper = VolumeRamper(coefficient: 0.99)
        var current: Float = 0.0
        let target: Float = 1.0

        for _ in 0..<10 {
            ramper.step(current: &current, toward: target)
            XCTAssertLessThanOrEqual(current, target, "Should never overshoot target")
        }
    }

    func testStepAtTargetRemainsStable() {
        let ramper = VolumeRamper(coefficient: 0.1)
        var current: Float = 0.75
        let target: Float = 0.75

        ramper.step(current: &current, toward: target)
        XCTAssertEqual(current, target, accuracy: 1e-7, "At target should remain stable")
    }

    func testExponentialDecayRate() {
        // After one time constant (sampleRate * rampTime steps), should reach ~63.2% of the way
        let sampleRate: Double = 44100
        let rampTime: Float = 0.030
        let ramper = VolumeRamper(sampleRate: sampleRate, rampTime: rampTime)

        var current: Float = 0.0
        let target: Float = 1.0
        let steps = Int(sampleRate * Double(rampTime))

        for _ in 0..<steps {
            ramper.step(current: &current, toward: target)
        }

        // After one time constant, value should be approximately 1 - 1/e ≈ 0.632
        XCTAssertEqual(current, 0.632, accuracy: 0.05, "After one time constant should be ~63.2% of the way")
    }
}
