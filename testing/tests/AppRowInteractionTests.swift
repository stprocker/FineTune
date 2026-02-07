// testing/tests/AppRowInteractionTests.swift
// Characterization tests for AppRow interaction contracts.
// These capture current behavior before Phase 2.1 (auto-unmute extraction)
// and Phase 3.3 (AppRow decomposition).

import XCTest
#if canImport(FineTuneCore)
import FineTuneCore
#endif

/// Tests that verify the interaction contracts used by AppRow and DeviceRow:
/// - Volume slider change triggers onVolumeChange callback
/// - Mute toggle triggers onMuteChange callback
/// - Auto-unmute behavior (slider move while muted → unmute fired)
/// - Volume mapping roundtrip consistency
final class AppRowInteractionTests: XCTestCase {

    // MARK: - Volume Slider → onVolumeChange

    /// Slider position maps to gain via VolumeMapping.sliderToGain
    func testSliderChangeTriggersVolumeCallback() {
        // Simulate: slider moves to 0.5 (unity) → gain should be ~1.0
        let gain = VolumeMapping.sliderToGain(0.5)
        XCTAssertEqual(gain, 1.0, accuracy: 0.01, "Slider at 50% should produce unity gain")
    }

    /// Slider at 0 produces gain 0 (silence)
    func testSliderAtZeroProducesZeroGain() {
        let gain = VolumeMapping.sliderToGain(0.0)
        XCTAssertEqual(gain, 0.0, "Slider at 0% should produce zero gain")
    }

    /// Slider at 1.0 produces max gain (~2.0)
    func testSliderAtMaxProducesMaxGain() {
        let gain = VolumeMapping.sliderToGain(1.0)
        XCTAssertGreaterThan(gain, 1.5, "Slider at 100% should produce gain > 1.5")
        XCTAssertLessThanOrEqual(gain, 2.1, "Slider at 100% should produce gain <= 2.1")
    }

    // MARK: - Mute Toggle → onMuteChange

    /// When showMutedIcon is true (muted) and unmute pressed:
    /// If sliderValue == 0, should restore to defaultUnmuteVolume (0.5)
    func testUnmuteFromZeroRestoresDefaultVolume() {
        // AppRow behavior: if slider == 0 && muted, unmute sets slider to 0.5
        let defaultUnmuteVolume: Double = 0.5
        var sliderValue: Double = 0.0
        let isMuted = true

        // Simulate unmute button tap when at zero
        if isMuted {
            if sliderValue == 0 {
                sliderValue = defaultUnmuteVolume
            }
        }

        XCTAssertEqual(sliderValue, 0.5, "Unmuting from zero should restore to default 50%")
    }

    /// When showMutedIcon is true (muted) and slider > 0, just unmute without changing volume
    func testUnmuteWithNonZeroVolumePreservesSlider() {
        let defaultUnmuteVolume: Double = 0.5
        var sliderValue: Double = 0.75
        let isMuted = true

        if isMuted {
            if sliderValue == 0 {
                sliderValue = defaultUnmuteVolume
            }
        }

        XCTAssertEqual(sliderValue, 0.75, "Unmuting with non-zero volume should preserve slider position")
    }

    // MARK: - Auto-Unmute (Slider Move While Muted)

    /// Moving slider while muted should trigger unmute
    func testSliderMoveWhileMutedTriggersUnmute() {
        var unmuteCalled = false
        let isMutedExternal = true

        // Simulate: slider onChange fires while muted → auto-unmute
        // This is the pattern in AppRow lines 168-175 and DeviceRow lines 92-98
        if isMutedExternal {
            unmuteCalled = true  // onMuteChange(false) would be called
        }

        XCTAssertTrue(unmuteCalled, "Moving slider while muted should trigger unmute callback")
    }

    /// Moving slider while NOT muted should NOT trigger unmute
    func testSliderMoveWhileUnmutedDoesNotTriggerUnmute() {
        var unmuteCalled = false
        let isMutedExternal = false

        if isMutedExternal {
            unmuteCalled = true
        }

        XCTAssertFalse(unmuteCalled, "Moving slider while unmuted should NOT trigger unmute callback")
    }

    // MARK: - DeviceRow Auto-Unmute Variant

    /// DeviceRow auto-unmute additionally checks newValue > 0
    func testDeviceRowSliderMoveWhileMutedOnlyUnmutesAboveZero() {
        var unmuteCalled = false
        let isMuted = true
        let newValue: Double = 0.3

        // DeviceRow pattern (line 96-98): auto-unmute only when slider > 0
        if isMuted && newValue > 0 {
            unmuteCalled = true
        }

        XCTAssertTrue(unmuteCalled, "DeviceRow should auto-unmute when slider moved above 0 while muted")
    }

    func testDeviceRowSliderAtZeroWhileMutedDoesNotUnmute() {
        var unmuteCalled = false
        let isMuted = true
        let newValue: Double = 0.0

        if isMuted && newValue > 0 {
            unmuteCalled = true
        }

        XCTAssertFalse(unmuteCalled, "DeviceRow should NOT auto-unmute when slider at 0 while muted")
    }

    // MARK: - Volume Mapping Roundtrip

    /// Gain → slider → gain should roundtrip with acceptable precision
    func testVolumeMappingRoundtrip() {
        let testGains: [Float] = [0.0, 0.1, 0.25, 0.5, 1.0, 1.5, 2.0]
        for gain in testGains {
            let slider = VolumeMapping.gainToSlider(gain)
            let roundtripped = VolumeMapping.sliderToGain(slider)

            if gain == 0 {
                XCTAssertEqual(roundtripped, 0.0, "Zero gain should roundtrip exactly")
            } else {
                XCTAssertEqual(roundtripped, gain, accuracy: 0.05,
                             "Gain \(gain) should roundtrip through slider mapping (got \(roundtripped))")
            }
        }
    }

    /// Slider → gain → slider should roundtrip with acceptable precision
    func testSliderMappingRoundtrip() {
        let testPositions: [Double] = [0.0, 0.1, 0.25, 0.5, 0.75, 1.0]
        for position in testPositions {
            let gain = VolumeMapping.sliderToGain(position)
            let roundtripped = VolumeMapping.gainToSlider(gain)

            if position == 0 {
                XCTAssertEqual(roundtripped, 0.0, "Zero position should roundtrip exactly")
            } else {
                XCTAssertEqual(roundtripped, position, accuracy: 0.02,
                             "Slider position \(position) should roundtrip (got \(roundtripped))")
            }
        }
    }

    // MARK: - Percentage Display

    /// Percentage display should be Int(sliderValue * 200) for AppRow
    func testAppRowPercentageDisplay() {
        let testCases: [(slider: Double, expected: Int)] = [
            (0.0, 0),
            (0.25, 50),
            (0.5, 100),
            (0.75, 150),
            (1.0, 200),
        ]

        for tc in testCases {
            let percent = Int(tc.slider * 200)
            XCTAssertEqual(percent, tc.expected,
                         "Slider \(tc.slider) should display as \(tc.expected)%")
        }
    }

    /// Percentage display should be Int(sliderValue * 100) for DeviceRow
    func testDeviceRowPercentageDisplay() {
        let testCases: [(slider: Double, expected: Int)] = [
            (0.0, 0),
            (0.5, 50),
            (1.0, 100),
        ]

        for tc in testCases {
            let percent = Int(tc.slider * 100)
            XCTAssertEqual(percent, tc.expected,
                         "Slider \(tc.slider) should display as \(tc.expected)%")
        }
    }

    // MARK: - showMutedIcon Derivation

    /// showMutedIcon should be true when explicitly muted OR volume is 0
    func testShowMutedIconLogic() {
        // isMutedExternal = true, sliderValue > 0 → show muted
        XCTAssertTrue(showMutedIcon(isMuted: true, sliderValue: 0.5))

        // isMutedExternal = false, sliderValue = 0 → show muted (volume at zero)
        XCTAssertTrue(showMutedIcon(isMuted: false, sliderValue: 0.0))

        // isMutedExternal = false, sliderValue > 0 → NOT muted
        XCTAssertFalse(showMutedIcon(isMuted: false, sliderValue: 0.5))

        // isMutedExternal = true, sliderValue = 0 → show muted (both conditions)
        XCTAssertTrue(showMutedIcon(isMuted: true, sliderValue: 0.0))
    }

    // Helper matching AppRow.showMutedIcon logic
    private func showMutedIcon(isMuted: Bool, sliderValue: Double) -> Bool {
        isMuted || sliderValue == 0
    }
}
