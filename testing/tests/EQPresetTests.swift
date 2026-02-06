import XCTest
@testable import FineTune

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
        XCTAssertEqual(EQPreset.allCases.count, 20, "Should have exactly 20 presets")
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
        XCTAssertEqual(EQPreset.Category.allCases.count, 5)
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
