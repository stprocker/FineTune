import XCTest
@testable import FineTuneCore

final class EQSettingsTests: XCTestCase {

    // MARK: - Constants

    func testBandCount() {
        XCTAssertEqual(EQSettings.bandCount, 10)
    }

    func testGainRange() {
        XCTAssertEqual(EQSettings.maxGainDB, 18.0)
        XCTAssertEqual(EQSettings.minGainDB, -18.0)
    }

    func testFrequencies() {
        let expected: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        XCTAssertEqual(EQSettings.frequencies, expected)
        XCTAssertEqual(EQSettings.frequencies.count, EQSettings.bandCount)
    }

    // MARK: - Default init

    func testDefaultInit() {
        let settings = EQSettings()
        XCTAssertEqual(settings.bandGains.count, 10)
        XCTAssertTrue(settings.bandGains.allSatisfy { $0 == 0 })
        XCTAssertTrue(settings.isEnabled)
    }

    func testFlatPreset() {
        let flat = EQSettings.flat
        XCTAssertEqual(flat.bandGains, Array(repeating: Float(0), count: 10))
        XCTAssertTrue(flat.isEnabled)
    }

    // MARK: - clampedGains

    func testClampedGainsPassthroughForValidGains() {
        let gains: [Float] = [0, 3, -3, 6, -6, 12, -18, 18, 0, 0]
        let settings = EQSettings(bandGains: gains)
        XCTAssertEqual(settings.clampedGains, gains)
    }

    func testClampedGainsClampsAboveMax() {
        let settings = EQSettings(bandGains: [15, 20, 100, 0, 0, 0, 0, 0, 0, 0])
        let clamped = settings.clampedGains
        XCTAssertEqual(clamped[0], 15.0)
        XCTAssertEqual(clamped[1], 18.0)
        XCTAssertEqual(clamped[2], 18.0)
    }

    func testClampedGainsClampsBelow() {
        let settings = EQSettings(bandGains: [-15, -20, -100, 0, 0, 0, 0, 0, 0, 0])
        let clamped = settings.clampedGains
        XCTAssertEqual(clamped[0], -15.0)
        XCTAssertEqual(clamped[1], -18.0)
        XCTAssertEqual(clamped[2], -18.0)
    }

    func testClampedGainsPadsTooFew() {
        let settings = EQSettings(bandGains: [1, 2, 3])
        let clamped = settings.clampedGains
        XCTAssertEqual(clamped.count, 10)
        XCTAssertEqual(clamped[0], 1)
        XCTAssertEqual(clamped[1], 2)
        XCTAssertEqual(clamped[2], 3)
        // Padded with zeros
        for i in 3..<10 {
            XCTAssertEqual(clamped[i], 0, "Padded element \(i) should be 0")
        }
    }

    func testClampedGainsTruncatesTooMany() {
        let gains: [Float] = Array(repeating: 5.0, count: 15)
        let settings = EQSettings(bandGains: gains)
        let clamped = settings.clampedGains
        XCTAssertEqual(clamped.count, 10)
        XCTAssertTrue(clamped.allSatisfy { $0 == 5.0 })
    }

    func testClampedGainsEmptyArray() {
        let settings = EQSettings(bandGains: [])
        let clamped = settings.clampedGains
        XCTAssertEqual(clamped.count, 10)
        XCTAssertTrue(clamped.allSatisfy { $0 == 0 })
    }

    func testClampedGainsSingleElement() {
        let settings = EQSettings(bandGains: [6])
        let clamped = settings.clampedGains
        XCTAssertEqual(clamped.count, 10)
        XCTAssertEqual(clamped[0], 6)
        for i in 1..<10 {
            XCTAssertEqual(clamped[i], 0)
        }
    }

    // MARK: - Equatable

    func testEquatableIdentical() {
        let a = EQSettings(bandGains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let b = EQSettings(bandGains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(a, b)
    }

    func testEquatableDifferentGains() {
        let a = EQSettings(bandGains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let b = EQSettings(bandGains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 0])
        XCTAssertNotEqual(a, b)
    }

    func testEquatableDifferentEnabled() {
        let a = EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], isEnabled: true)
        let b = EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], isEnabled: false)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = EQSettings(bandGains: [1, -2, 3.5, 0, -6, 18, -18, 0.5, 0, -0.5])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testCodableWithDisabledEQ() throws {
        let original = EQSettings(bandGains: [6, 6, 5, -1, 0, 0, 0, 0, 0, 0], isEnabled: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertFalse(decoded.isEnabled)
    }

    func testCodableFlat() throws {
        let data = try JSONEncoder().encode(EQSettings.flat)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        XCTAssertEqual(decoded, EQSettings.flat)
    }

    func testDecodingFromJSON() throws {
        let json = """
        {"bandGains":[1,2,3,4,5,6,7,8,9,10],"isEnabled":true}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        XCTAssertEqual(decoded.bandGains, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertTrue(decoded.isEnabled)
    }
}
