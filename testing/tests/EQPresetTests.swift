import XCTest
@testable import FineTuneCore

final class EQPresetTests: XCTestCase {

    // MARK: - All presets data validation

    func testAllPresetsHaveExactly10Bands() {
        for preset in EQPreset.allCases {
            XCTAssertEqual(preset.settings.bandGains.count, 10,
                           "Preset \(preset.name) should have exactly 10 band gains, got \(preset.settings.bandGains.count)")
        }
    }

    func testAllPresetsGainsWithinRange() {
        for preset in EQPreset.allCases {
            for (i, gain) in preset.settings.bandGains.enumerated() {
                XCTAssertGreaterThanOrEqual(gain, EQSettings.minGainDB,
                    "Preset \(preset.name) band \(i) gain \(gain) below min \(EQSettings.minGainDB)")
                XCTAssertLessThanOrEqual(gain, EQSettings.maxGainDB,
                    "Preset \(preset.name) band \(i) gain \(gain) above max \(EQSettings.maxGainDB)")
            }
        }
    }

    func testAllPresetsAreEnabled() {
        for preset in EQPreset.allCases {
            XCTAssertTrue(preset.settings.isEnabled,
                          "Preset \(preset.name) settings should be enabled by default")
        }
    }

    func testTotalPresetCount() {
        XCTAssertEqual(EQPreset.allCases.count, 23, "Should have exactly 23 presets")
    }

    // MARK: - Flat preset

    func testFlatPresetIsAllZeros() {
        let flat = EQPreset.flat.settings
        XCTAssertTrue(flat.bandGains.allSatisfy { $0 == 0 }, "Flat preset should have all zero gains")
    }

    // MARK: - Category mapping

    func testEveryPresetHasACategory() {
        for preset in EQPreset.allCases {
            // This will fail to compile if switch is non-exhaustive, but verifying at runtime too
            let _ = preset.category
        }
    }

    func testUtilityCategoryPresets() {
        let presets = EQPreset.presets(for: .utility)
        let expected: Set<EQPreset> = [.flat, .bassBoost, .bassCut, .trebleBoost]
        XCTAssertEqual(Set(presets), expected)
    }

    func testSpeechCategoryPresets() {
        let presets = EQPreset.presets(for: .speech)
        let expected: Set<EQPreset> = [.vocalClarity, .podcast, .spokenWord]
        XCTAssertEqual(Set(presets), expected)
    }

    func testListeningCategoryPresets() {
        let presets = EQPreset.presets(for: .listening)
        let expected: Set<EQPreset> = [.loudness, .lateNight, .smallSpeakers]
        XCTAssertEqual(Set(presets), expected)
    }

    func testMusicCategoryPresets() {
        let presets = EQPreset.presets(for: .music)
        let expected: Set<EQPreset> = [.rock, .pop, .electronic, .jazz, .classical, .hipHop, .rnb, .deep, .acoustic]
        XCTAssertEqual(Set(presets), expected)
        XCTAssertEqual(presets.count, 9)
    }

    func testMediaCategoryPresets() {
        let presets = EQPreset.presets(for: .media)
        let expected: Set<EQPreset> = [.movie]
        XCTAssertEqual(Set(presets), expected)
    }

    func testHeadphoneCategoryPresets() {
        let presets = EQPreset.presets(for: .headphone)
        let expected: Set<EQPreset> = [.hpClarity, .hpReference, .hpVocalFocus]
        XCTAssertEqual(Set(presets), expected)
        XCTAssertEqual(presets.count, 3)
    }

    func testHeadphonePresetsAreEnabledAndNonFlat() {
        let presets: [EQPreset] = [.hpClarity, .hpReference, .hpVocalFocus]
        for preset in presets {
            XCTAssertTrue(preset.settings.isEnabled, "\(preset.name) should be enabled")
            XCTAssertTrue(
                preset.settings.bandGains.contains { $0 != 0 },
                "\(preset.name) should not be flat"
            )
        }
    }

    func testHeadphonePresetABBassCutProgression() {
        let clarity = EQPreset.hpClarity.settings.bandGains
        let reference = EQPreset.hpReference.settings.bandGains
        let vocal = EQPreset.hpVocalFocus.settings.bandGains

        XCTAssertLessThan(reference[0], clarity[0], "Reference should cut 31Hz more than Clarity")
        XCTAssertLessThan(vocal[0], reference[0], "Vocal Focus should cut 31Hz more than Reference")
        XCTAssertLessThan(reference[1], clarity[1], "Reference should cut 62Hz more than Clarity")
        XCTAssertLessThan(vocal[1], reference[1], "Vocal Focus should cut 62Hz more than Reference")
    }

    func testHeadphonePresetABPresenceProgression() {
        let clarity = EQPreset.hpClarity.settings.bandGains
        let reference = EQPreset.hpReference.settings.bandGains
        let vocal = EQPreset.hpVocalFocus.settings.bandGains

        XCTAssertGreaterThan(clarity[6], reference[6], "Clarity should boost 2kHz more than Reference")
        XCTAssertGreaterThan(vocal[6], clarity[6], "Vocal Focus should boost 2kHz more than Clarity")
        XCTAssertGreaterThan(clarity[7], reference[7], "Clarity should boost 4kHz more than Reference")
        XCTAssertGreaterThan(vocal[7], clarity[7], "Vocal Focus should boost 4kHz more than Clarity")
    }

    func testHeadphonePresetABHasLargeOverallDifference() {
        let clarity = EQPreset.hpClarity.settings.bandGains
        let vocal = EQPreset.hpVocalFocus.settings.bandGains
        let totalAbsoluteDelta = zip(clarity, vocal).reduce(Float(0)) { partial, pair in
            partial + abs(pair.0 - pair.1)
        }

        XCTAssertGreaterThan(
            totalAbsoluteDelta,
            10.0,
            "Clarity vs Vocal Focus should be a clearly distinct A/B profile"
        )
    }

    func testAllCategoriesCoverAllPresets() {
        var allFromCategories: Set<EQPreset> = []
        for category in EQPreset.Category.allCases {
            allFromCategories.formUnion(EQPreset.presets(for: category))
        }
        XCTAssertEqual(allFromCategories, Set(EQPreset.allCases),
                       "All categories combined should cover all presets")
    }

    // MARK: - Names

    func testEveryPresetHasNonEmptyName() {
        for preset in EQPreset.allCases {
            XCTAssertFalse(preset.name.isEmpty, "Preset \(preset) should have a non-empty name")
        }
    }

    func testAllNamesAreUnique() {
        let names = EQPreset.allCases.map { $0.name }
        XCTAssertEqual(names.count, Set(names).count, "All preset names should be unique")
    }

    // MARK: - Identifiable

    func testIdMatchesRawValue() {
        for preset in EQPreset.allCases {
            XCTAssertEqual(preset.id, preset.rawValue)
        }
    }

    func testCategoryIdMatchesRawValue() {
        for category in EQPreset.Category.allCases {
            XCTAssertEqual(category.id, category.rawValue)
        }
    }

    // MARK: - Category count

    func testCategoryCount() {
        XCTAssertEqual(EQPreset.Category.allCases.count, 6)
    }

    // MARK: - Specific preset characteristics

    func testBassBoostHasPositiveLowFreqs() {
        let gains = EQPreset.bassBoost.settings.bandGains
        XCTAssertGreaterThan(gains[0], 0, "31Hz should be boosted")
        XCTAssertGreaterThan(gains[1], 0, "62Hz should be boosted")
    }

    func testBassCutHasNegativeLowFreqs() {
        let gains = EQPreset.bassCut.settings.bandGains
        XCTAssertLessThan(gains[0], 0, "31Hz should be cut")
        XCTAssertLessThan(gains[1], 0, "62Hz should be cut")
    }

    func testTrebleBoostHasPositiveHighFreqs() {
        let gains = EQPreset.trebleBoost.settings.bandGains
        XCTAssertGreaterThan(gains[8], 0, "8kHz should be boosted")
        XCTAssertGreaterThan(gains[9], 0, "16kHz should be boosted")
    }
}
