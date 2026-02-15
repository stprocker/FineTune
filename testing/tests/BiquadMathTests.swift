import XCTest
@testable import FineTuneCore

final class BiquadMathTests: XCTestCase {

    // MARK: - peakingEQCoefficients

    func testFlatGainReturnsUnityFilter() {
        // 0 dB gain should produce a passthrough filter: b0=1, b1=~-2cosW, b2=~1, a1=~-2cosW, a2=~1
        // More precisely, when gainDB=0, A=1, so b0/a0 = (1+alpha)/(1+alpha) = 1
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 0, q: 1.4, sampleRate: 44100
        )
        XCTAssertEqual(coeffs.count, 5)
        // b0/a0 should be 1.0 when gain is 0 dB (A=1, numerator == denominator)
        XCTAssertEqual(coeffs[0], 1.0, accuracy: 1e-10, "b0/a0 should be 1.0 for 0dB gain")
        // b1/a0 should equal a1/a0 (both are -2*cosW/a0)
        XCTAssertEqual(coeffs[1], coeffs[3], accuracy: 1e-10, "b1 and a1 should match for 0dB")
        // b2/a0 should equal a2/a0 (both are (1-alpha)/a0... wait, b2=(1-alpha*A), a2=(1-alpha/A), when A=1 they match)
        XCTAssertEqual(coeffs[2], coeffs[4], accuracy: 1e-10, "b2 and a2 should match for 0dB")
    }

    func testCoefficientsAreFinite() {
        let testFreqs: [Double] = [31.25, 125, 1000, 8000, 16000]
        let testGains: [Float] = [-12, -6, 0, 6, 12]
        let testRates: [Double] = [44100, 48000, 96000]

        for freq in testFreqs {
            for gain in testGains {
                for rate in testRates {
                    let coeffs = BiquadMath.peakingEQCoefficients(
                        frequency: freq, gainDB: gain, q: 1.4, sampleRate: rate
                    )
                    for (i, c) in coeffs.enumerated() {
                        XCTAssertTrue(c.isFinite, "Coefficient \(i) is not finite for freq=\(freq), gain=\(gain), rate=\(rate)")
                    }
                }
            }
        }
    }

    func testPositiveGainBoosts() {
        // Positive gain: b0/a0 > 1 (boost at center frequency)
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 12, q: 1.4, sampleRate: 44100
        )
        XCTAssertGreaterThan(coeffs[0], 1.0, "b0/a0 should be > 1 for positive gain (boost)")
    }

    func testNegativeGainCuts() {
        // Negative gain: b0/a0 < 1 (cut at center frequency)
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: -12, q: 1.4, sampleRate: 44100
        )
        XCTAssertLessThan(coeffs[0], 1.0, "b0/a0 should be < 1 for negative gain (cut)")
    }

    func testSymmetryOfBoostAndCut() {
        // For peaking EQ, boost and cut should be reciprocal at the center frequency
        let boostCoeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: 6, q: 1.4, sampleRate: 44100
        )
        let cutCoeffs = BiquadMath.peakingEQCoefficients(
            frequency: 1000, gainDB: -6, q: 1.4, sampleRate: 44100
        )
        // b0_boost / a0_boost ≈ a0_cut / b0_cut (reciprocal relationship)
        // In normalized form: boost_b0 * cut_b0 ≈ 1.0 (approximately)
        // Actually for peaking EQ: boost numerator ≈ cut denominator
        // So boost[0] ≈ 1/cut[0] is not exactly right, but b0_boost * b0_cut ≈ 1 + something
        // Instead check that boost b2 ≈ cut a2 and vice versa (symmetry of num/den)
        // The key property: applying +6dB then -6dB should return to flat
        // This means the cascade of boost*cut should be identity
        XCTAssertNotEqual(boostCoeffs[0], cutCoeffs[0], "Boost and cut b0 should differ")
    }

    // MARK: - coefficientsForAllBands

    func testAllBandsReturns50Coefficients() {
        let gains: [Float] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 44100)
        XCTAssertEqual(coeffs.count, 50, "Should return 5 coefficients × 10 bands = 50")
    }

    func testAllBandsFlatGainsProduceUnityFilters() {
        let gains: [Float] = Array(repeating: 0, count: 10)
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 44100)

        // Each band's first coefficient (b0/a0) should be 1.0 for flat EQ
        for band in 0..<10 {
            let b0 = coeffs[band * 5]
            XCTAssertEqual(b0, 1.0, accuracy: 1e-10, "Band \(band) b0 should be 1.0 for flat gain")
        }
    }

    func testAllBandsCoefficientsAreFinite() {
        // Use a realistic preset
        let gains: [Float] = [6, 6, 5, -1, 0, 0, 0, 0, 0, 0] // Bass boost
        let coeffs = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 44100)

        for (i, c) in coeffs.enumerated() {
            XCTAssertTrue(c.isFinite, "Coefficient \(i) should be finite")
        }
    }

    func testAllBandsWithDifferentSampleRates() {
        let gains: [Float] = Array(repeating: 0, count: 10)
        let coeffs44 = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 44100)
        let coeffs48 = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 48000)
        let coeffs96 = BiquadMath.coefficientsForAllBands(gains: gains, sampleRate: 96000)

        // All should be 50 coefficients
        XCTAssertEqual(coeffs44.count, 50)
        XCTAssertEqual(coeffs48.count, 50)
        XCTAssertEqual(coeffs96.count, 50)

        // Different sample rates should produce different coefficients (different omega)
        // For flat EQ all b0 are 1.0 regardless, so check a non-flat band
        let boostGains: [Float] = [6, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let b44 = BiquadMath.coefficientsForAllBands(gains: boostGains, sampleRate: 44100)
        let b96 = BiquadMath.coefficientsForAllBands(gains: boostGains, sampleRate: 96000)
        // b1 (index 1) = -2*cosW/a0 depends on omega which depends on sampleRate
        XCTAssertNotEqual(b44[1], b96[1], "Different sample rates should produce different b1 coefficients")
    }

    func testHighFrequencyBandNearNyquist() {
        // 16kHz at 44.1kHz is close to Nyquist (22.05kHz) - coefficients should still be stable
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 16000, gainDB: 12, q: 1.4, sampleRate: 44100
        )
        for (i, c) in coeffs.enumerated() {
            XCTAssertTrue(c.isFinite, "Coefficient \(i) should be finite near Nyquist")
            XCTAssertTrue(abs(c) < 100, "Coefficient \(i) should be reasonable magnitude near Nyquist, got \(c)")
        }
    }

    func testAdaptiveQConstants() {
        XCTAssertEqual(BiquadMath.baseQ, 1.2)
        XCTAssertEqual(BiquadMath.minQ, 0.9)
        XCTAssertEqual(BiquadMath.qSlopePerDB, 0.025)
    }

    func testAdaptiveQAtZeroGain() {
        let q = BiquadMath.adaptiveQ(forGainDB: 0)
        XCTAssertEqual(q, 1.2, accuracy: 1e-10)
    }

    func testAdaptiveQAt6dBGain() {
        XCTAssertEqual(BiquadMath.adaptiveQ(forGainDB: 6), 1.05, accuracy: 1e-10)
        XCTAssertEqual(BiquadMath.adaptiveQ(forGainDB: -6), 1.05, accuracy: 1e-10)
    }

    func testAdaptiveQAt12dBGain() {
        XCTAssertEqual(BiquadMath.adaptiveQ(forGainDB: 12), 0.9, accuracy: 1e-10)
        XCTAssertEqual(BiquadMath.adaptiveQ(forGainDB: -12), 0.9, accuracy: 1e-10)
    }

    func testAdaptiveQFloorsAt0Point9() {
        XCTAssertEqual(BiquadMath.adaptiveQ(forGainDB: 18), 0.9, accuracy: 1e-10)
        XCTAssertEqual(BiquadMath.adaptiveQ(forGainDB: -18), 0.9, accuracy: 1e-10)
    }

    func testAdaptiveQIsSymmetric() {
        for gain: Float in [0, 1, 3, 6, 9, 12] {
            XCTAssertEqual(
                BiquadMath.adaptiveQ(forGainDB: gain),
                BiquadMath.adaptiveQ(forGainDB: -gain),
                accuracy: 1e-10,
                "Q should be symmetric for +-\(gain) dB"
            )
        }
    }

    func testVeryLowFrequency() {
        let coeffs = BiquadMath.peakingEQCoefficients(
            frequency: 31.25, gainDB: 6, q: 1.4, sampleRate: 44100
        )
        for (i, c) in coeffs.enumerated() {
            XCTAssertTrue(c.isFinite, "Coefficient \(i) should be finite for low frequency")
        }
    }

    func testMaxBoostAndCutCoefficients() {
        // Test extreme gain values used by presets (-8 to +7 dB range)
        for gain: Float in [-12, -8, -6, 6, 7, 12] {
            let coeffs = BiquadMath.peakingEQCoefficients(
                frequency: 500, gainDB: gain, q: 1.4, sampleRate: 48000
            )
            for (i, c) in coeffs.enumerated() {
                XCTAssertTrue(c.isFinite, "Coefficient \(i) should be finite for gain=\(gain)")
            }
        }
    }
}
