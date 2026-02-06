import XCTest
@testable import FineTuneCore

final class VolumeMappingTests: XCTestCase {

    // MARK: - sliderToGain boundary values

    func testSliderZeroReturnsMute() {
        let gain = VolumeMapping.sliderToGain(0)
        XCTAssertEqual(gain, 0, "Slider at 0 should return zero gain (mute)")
    }

    func testSliderHalfReturnsUnity() {
        let gain = VolumeMapping.sliderToGain(0.5)
        XCTAssertEqual(gain, 1.0, accuracy: 0.001, "Slider at 0.5 should return unity gain (1.0)")
    }

    func testSliderOneReturnsMaxBoost() {
        let gain = VolumeMapping.sliderToGain(1.0)
        // maxDB = 6 dB → gain = 10^(6/20) ≈ 1.9953
        let expected = pow(10, Float(6) / 20)
        XCTAssertEqual(gain, expected, accuracy: 0.001, "Slider at 1.0 should return ~2x gain (+6dB)")
    }

    func testSliderNegativeReturnsMute() {
        // Guard clause: slider <= 0 returns 0
        let gain = VolumeMapping.sliderToGain(-0.5)
        XCTAssertEqual(gain, 0, "Negative slider should return mute")
    }

    // MARK: - gainToSlider boundary values

    func testGainZeroReturnsSliderZero() {
        let slider = VolumeMapping.gainToSlider(0)
        XCTAssertEqual(slider, 0, "Gain 0 should return slider 0")
    }

    func testGainUnityReturnsSliderHalf() {
        let slider = VolumeMapping.gainToSlider(1.0)
        XCTAssertEqual(slider, 0.5, accuracy: 0.001, "Unity gain should return slider 0.5")
    }

    func testGainMaxReturnsSliderOne() {
        let maxGain = pow(10, Float(6) / 20) // +6dB
        let slider = VolumeMapping.gainToSlider(maxGain)
        XCTAssertEqual(slider, 1.0, accuracy: 0.001, "Max gain (+6dB) should return slider 1.0")
    }

    func testGainNegativeReturnsSliderZero() {
        let slider = VolumeMapping.gainToSlider(-1.0)
        XCTAssertEqual(slider, 0, "Negative gain should return slider 0")
    }

    // MARK: - Round-trip accuracy

    func testRoundTripSliderToGainToSlider() {
        let testValues = stride(from: 0.01, through: 1.0, by: 0.01)
        for slider in testValues {
            let gain = VolumeMapping.sliderToGain(slider)
            let recovered = VolumeMapping.gainToSlider(gain)
            XCTAssertEqual(recovered, slider, accuracy: 0.01,
                           "Round-trip failed for slider=\(slider): gain=\(gain), recovered=\(recovered)")
        }
    }

    func testRoundTripGainToSliderToGain() {
        let testGains: [Float] = [0.001, 0.01, 0.1, 0.5, 0.75, 1.0, 1.5, 1.99]
        for gain in testGains {
            let slider = VolumeMapping.gainToSlider(gain)
            let recovered = VolumeMapping.sliderToGain(slider)
            XCTAssertEqual(recovered, gain, accuracy: 0.02,
                           "Round-trip failed for gain=\(gain): slider=\(slider), recovered=\(recovered)")
        }
    }

    // MARK: - Monotonicity

    func testSliderToGainIsMonotonicallyIncreasing() {
        var prevGain = VolumeMapping.sliderToGain(0.001)
        for i in 2...1000 {
            let slider = Double(i) / 1000.0
            let gain = VolumeMapping.sliderToGain(slider)
            XCTAssertGreaterThanOrEqual(gain, prevGain,
                                         "Gain should increase monotonically: slider=\(slider), gain=\(gain), prev=\(prevGain)")
            prevGain = gain
        }
    }

    func testGainToSliderIsMonotonicallyIncreasing() {
        var prevSlider = VolumeMapping.gainToSlider(0.001)
        for i in 2...200 {
            let gain = Float(i) / 100.0
            let slider = VolumeMapping.gainToSlider(gain)
            XCTAssertGreaterThanOrEqual(slider, prevSlider,
                                         "Slider should increase monotonically: gain=\(gain), slider=\(slider), prev=\(prevSlider)")
            prevSlider = slider
        }
    }

    // MARK: - Output range

    func testSliderToGainOutputRange() {
        for i in 0...100 {
            let slider = Double(i) / 100.0
            let gain = VolumeMapping.sliderToGain(slider)
            XCTAssertGreaterThanOrEqual(gain, 0, "Gain should be >= 0 for slider=\(slider)")
        }
    }

    func testGainToSliderOutputRange() {
        let testGains: [Float] = [0, 0.001, 0.5, 1.0, 1.5, 2.0, 5.0, 10.0]
        for gain in testGains {
            let slider = VolumeMapping.gainToSlider(gain)
            XCTAssertGreaterThanOrEqual(slider, 0, "Slider should be >= 0 for gain=\(gain)")
            XCTAssertLessThanOrEqual(slider, 1, "Slider should be <= 1 for gain=\(gain)")
        }
    }

    // MARK: - Logarithmic curve shape

    func testLowerHalfSliderCoversWideDBRange() {
        // Slider 0 to 0.5 covers -60dB to 0dB (huge perceptual range)
        // Slider 0.5 to 1.0 covers 0dB to +6dB (small boost)
        let gainAtQuarter = VolumeMapping.sliderToGain(0.25)
        let gainAtHalf = VolumeMapping.sliderToGain(0.5)
        let gainAtThreeQuarter = VolumeMapping.sliderToGain(0.75)

        // Quarter slider should be much less than half (logarithmic curve)
        XCTAssertLessThan(gainAtQuarter, gainAtHalf * 0.5,
                          "Quarter slider should be well below half of unity gain")
        // Three-quarter should be between unity and max
        XCTAssertGreaterThan(gainAtThreeQuarter, 1.0, "Three-quarter slider should be above unity")
        XCTAssertLessThan(gainAtThreeQuarter, 2.0, "Three-quarter slider should be below max boost")
    }

    // MARK: - Very small gains

    func testVerySmallGainMapsToNearZeroSlider() {
        let slider = VolumeMapping.gainToSlider(0.001) // ≈ -60dB
        XCTAssertLessThan(slider, 0.05, "Very small gain should map to near-zero slider")
        XCTAssertGreaterThanOrEqual(slider, 0, "Non-zero gain should map to >= 0 slider")
    }
}
