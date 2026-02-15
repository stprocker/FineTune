# Adaptive EQ Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the 10-band graphic EQ produce clearly audible, dramatic tonal changes with no volume shift, using adaptive Q, automatic pre-EQ gain reduction, and recalibrated presets.

**Architecture:** Four independent changes that work together: (1) adaptive Q per band in BiquadMath, (2) automatic pre-EQ gain scalar in the audio callback, (3) limiter threshold raised to safety-net-only, (4) gain range and presets recalibrated. All changes are in FineTuneCore except the ProcessTapController audio callback.

**Tech Stack:** Swift 6, Accelerate/vDSP, XCTest via `swift test`

**Test command:** `swift test --filter FineTuneCoreTests` from the project root.

---

### Task 1: Update gain range constants and fix tests

**Files:**
- Modify: `FineTune/Models/EQSettings.swift:5-6`
- Modify: `testing/tests/EQSettingsTests.swift:12-14,47-49,54-59`

**Step 1: Update EQSettings gain range**

In `FineTune/Models/EQSettings.swift`, change:
```swift
public static let maxGainDB: Float = 18.0
public static let minGainDB: Float = -18.0
```
to:
```swift
public static let maxGainDB: Float = 12.0
public static let minGainDB: Float = -12.0
```

**Step 2: Update EQSettingsTests for new range**

In `testing/tests/EQSettingsTests.swift`:

`testGainRange` — change expected values:
```swift
func testGainRange() {
    XCTAssertEqual(EQSettings.maxGainDB, 12.0)
    XCTAssertEqual(EQSettings.minGainDB, -12.0)
}
```

`testClampedGainsClampsAboveMax` — update test data and expectations. Values 15 and 20 now both exceed 12:
```swift
func testClampedGainsClampsAboveMax() {
    let settings = EQSettings(bandGains: [11, 15, 100, 0, 0, 0, 0, 0, 0, 0])
    let clamped = settings.clampedGains
    XCTAssertEqual(clamped[0], 11.0)
    XCTAssertEqual(clamped[1], 12.0)
    XCTAssertEqual(clamped[2], 12.0)
}
```

`testClampedGainsClampsBelow` — same pattern:
```swift
func testClampedGainsClampsBelow() {
    let settings = EQSettings(bandGains: [-11, -15, -100, 0, 0, 0, 0, 0, 0, 0])
    let clamped = settings.clampedGains
    XCTAssertEqual(clamped[0], -11.0)
    XCTAssertEqual(clamped[1], -12.0)
    XCTAssertEqual(clamped[2], -12.0)
}
```

`testClampedGainsPassthroughForValidGains` — values 18 and -18 are now out of range. Replace with values within +-12:
```swift
func testClampedGainsPassthroughForValidGains() {
    let gains: [Float] = [0, 3, -3, 6, -6, 12, -12, 0.5, 0, 0]
    let settings = EQSettings(bandGains: gains)
    XCTAssertEqual(settings.clampedGains, gains)
}
```

`testCodableRoundTrip` — values 18 and -18 will be clamped on `clampedGains` but raw bandGains survive encoding. The test encodes/decodes raw values, so it still passes. But use in-range values to be clean:
```swift
func testCodableRoundTrip() throws {
    let original = EQSettings(bandGains: [1, -2, 3.5, 0, -6, 12, -12, 0.5, 0, -0.5])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
    XCTAssertEqual(original, decoded)
}
```

**Step 3: Run tests to verify**

Run: `swift test --filter FineTuneCoreTests`
Expected: All EQSettingsTests pass. Some BiquadMathTests or EQPresetTests may fail (we fix those in later tasks).

**Step 4: Commit**

```bash
git add FineTune/Models/EQSettings.swift testing/tests/EQSettingsTests.swift
git commit -m "feat(eq): change gain range from +-18 dB to +-12 dB (industry standard)"
```

---

### Task 2: Update SoftLimiter threshold and fix tests

**Files:**
- Modify: `FineTune/Audio/Processing/SoftLimiter.swift:10`
- Modify: `testing/tests/SoftLimiterTests.swift`
- Modify: `testing/tests/PostEQLimiterTests.swift`

**Step 1: Change threshold constant**

In `FineTune/Audio/Processing/SoftLimiter.swift`, change:
```swift
public static let threshold: Float = 0.9
```
to:
```swift
public static let threshold: Float = 0.95
```

**Step 2: Update SoftLimiterTests**

`testThresholdIs0Point9` — rename and update:
```swift
func testThresholdIs0Point95() {
    XCTAssertEqual(SoftLimiter.threshold, 0.95)
}
```

`testHeadroomIs0Point1` — update:
```swift
func testHeadroomIs0Point05() {
    XCTAssertEqual(SoftLimiter.headroom, 0.05, accuracy: 1e-7)
}
```

`testPassthroughAtExactThreshold` — update:
```swift
func testPassthroughAtExactThreshold() {
    XCTAssertEqual(SoftLimiter.apply(0.95), 0.95)
    XCTAssertEqual(SoftLimiter.apply(-0.95), -0.95)
}
```

`testPassthroughForAllValuesBelowThreshold` — update loop bound from 90 to 95:
```swift
func testPassthroughForAllValuesBelowThreshold() {
    for i in 0...95 {
        let sample = Float(i) / 100.0
        XCTAssertEqual(SoftLimiter.apply(sample), sample, accuracy: 1e-7,
                       "Sample \(sample) should pass through unchanged")
        XCTAssertEqual(SoftLimiter.apply(-sample), -sample, accuracy: 1e-7,
                       "Sample \(-sample) should pass through unchanged")
    }
}
```

`testLimitingAboveThreshold` — update:
```swift
func testLimitingAboveThreshold() {
    let result = SoftLimiter.apply(0.98)
    XCTAssertGreaterThan(result, 0.95, "Should be above threshold")
    XCTAssertLessThan(result, 1.0, "Should be below ceiling")
}
```

`testLimitingJustAboveThreshold` — update:
```swift
func testLimitingJustAboveThreshold() {
    let result = SoftLimiter.apply(0.96)
    XCTAssertGreaterThan(result, 0.95)
    XCTAssertLessThan(result, 0.96, "Compressed output should be less than input above threshold")
}
```

`testMonotonicIncreaseAboveThreshold` — update start from 91 to 96:
```swift
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
```

`testKnownCompressionValue` — recalculate for threshold=0.95, headroom=0.05. Input 1.0: overshoot=0.05, compressed = 0.95 + 0.05 * (0.05 / (0.05 + 0.05)) = 0.95 + 0.05 * 0.5 = 0.975:
```swift
func testKnownCompressionValue() {
    // For input = 1.0: overshoot = 0.05, compressed = 0.95 + 0.05 * (0.05 / (0.05 + 0.05)) = 0.975
    let result = SoftLimiter.apply(1.0)
    XCTAssertEqual(result, 0.975, accuracy: 1e-6, "apply(1.0) should equal 0.975")
}
```

`testKnownCompressionValue2` — recalculate for input 1.2: overshoot=0.25, compressed = 0.95 + 0.05 * (0.25 / (0.25 + 0.05)) = 0.95 + 0.05 * (0.25/0.30) = 0.95 + 0.04167 = 0.99167:
```swift
func testKnownCompressionValue2() {
    // For input = 1.2: overshoot = 0.25, compressed = 0.95 + 0.05 * (0.25 / (0.25 + 0.05))
    let result = SoftLimiter.apply(1.2)
    let expected: Float = 0.95 + 0.05 * (0.25 / 0.30)
    XCTAssertEqual(result, expected, accuracy: 1e-6)
}
```

`testContinuityAtThreshold` — update:
```swift
func testContinuityAtThreshold() {
    let atThreshold = SoftLimiter.apply(0.95)
    let justAbove = SoftLimiter.apply(0.951)
    XCTAssertEqual(atThreshold, 0.95, accuracy: 1e-7)
    XCTAssertEqual(justAbove, 0.95, accuracy: 0.01, "Just above threshold should be close to threshold value")
}
```

`testSymmetryForPositiveAndNegative` — update test values to include new threshold:
```swift
func testSymmetryForPositiveAndNegative() {
    let testValues: [Float] = [0.95, 0.98, 1.0, 1.5, 2.0, 5.0]
    for value in testValues {
        let positive = SoftLimiter.apply(value)
        let negative = SoftLimiter.apply(-value)
        XCTAssertEqual(positive, -negative, accuracy: 1e-7,
                       "apply(\(value)) should equal -apply(\(-value))")
    }
}
```

**Step 3: Update PostEQLimiterTests**

The `testInterleavedStereoMixedAmplitudes` test checks that left channel values (3.4) are above `threshold`. With new threshold 0.95, the compressed value of 3.4 is: overshoot=2.45, compressed=0.95+0.05*(2.45/2.50)=0.95+0.049=0.999. Still above 0.95. Test passes without change.

The `testBoostedSignalClampedBelowCeiling` also works — it only checks <= ceiling. No change needed.

**Step 4: Run tests**

Run: `swift test --filter FineTuneCoreTests`
Expected: All SoftLimiterTests and PostEQLimiterTests pass.

**Step 5: Commit**

```bash
git add FineTune/Audio/Processing/SoftLimiter.swift testing/tests/SoftLimiterTests.swift
git commit -m "feat(eq): raise limiter threshold from 0.9 to 0.95 (safety net only)"
```

---

### Task 3: Implement adaptive Q in BiquadMath

**Files:**
- Modify: `FineTune/Audio/BiquadMath.swift`
- Modify: `testing/tests/BiquadMathTests.swift`

**Step 1: Write the failing test for adaptive Q**

Add to `testing/tests/BiquadMathTests.swift`:

```swift
func testAdaptiveQAtZeroGain() {
    // At 0 dB gain, Q should be the base Q of 1.2
    let q = BiquadMath.adaptiveQ(forGainDB: 0)
    XCTAssertEqual(q, 1.2, accuracy: 1e-10)
}

func testAdaptiveQAt6dBGain() {
    // At +-6 dB, Q = max(0.9, 1.2 - 6*0.025) = max(0.9, 1.05) = 1.05
    XCTAssertEqual(BiquadMath.adaptiveQ(forGainDB: 6), 1.05, accuracy: 1e-10)
    XCTAssertEqual(BiquadMath.adaptiveQ(forGainDB: -6), 1.05, accuracy: 1e-10)
}

func testAdaptiveQAt12dBGain() {
    // At +-12 dB, Q = max(0.9, 1.2 - 12*0.025) = max(0.9, 0.9) = 0.9
    XCTAssertEqual(BiquadMath.adaptiveQ(forGainDB: 12), 0.9, accuracy: 1e-10)
    XCTAssertEqual(BiquadMath.adaptiveQ(forGainDB: -12), 0.9, accuracy: 1e-10)
}

func testAdaptiveQFloorsAt0Point9() {
    // Beyond 12 dB (if clamped gains ever reach it), Q should floor at 0.9
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
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter FineTuneCoreTests/BiquadMathTests`
Expected: FAIL — `adaptiveQ(forGainDB:)` does not exist.

**Step 3: Implement adaptive Q and update coefficientsForAllBands**

In `FineTune/Audio/BiquadMath.swift`:

Replace `graphicEQQ` constant with the adaptive function:

```swift
/// Base Q for adaptive graphic EQ (at 0 dB gain)
public static let baseQ: Double = 1.2

/// Minimum Q floor (at maximum gain)
public static let minQ: Double = 0.9

/// Q reduction rate per dB of absolute gain
public static let qSlopePerDB: Double = 0.025

/// Compute adaptive Q for a given band gain.
/// Q widens (decreases) as gain increases, counteracting the RBJ peaking EQ's
/// natural bandwidth narrowing at higher gains.
public static func adaptiveQ(forGainDB gain: Float) -> Double {
    return max(minQ, baseQ - Double(abs(gain)) * qSlopePerDB)
}
```

Update `coefficientsForAllBands` to use adaptive Q per band instead of a fixed Q:

```swift
public static func coefficientsForAllBands(
    gains: [Float],
    sampleRate: Double
) -> [Double] {
    precondition(gains.count == EQSettings.bandCount)

    var allCoeffs: [Double] = []
    allCoeffs.reserveCapacity(50)

    for (index, frequency) in EQSettings.frequencies.enumerated() {
        let q = adaptiveQ(forGainDB: gains[index])
        let bandCoeffs = peakingEQCoefficients(
            frequency: frequency,
            gainDB: gains[index],
            q: q,
            sampleRate: sampleRate
        )
        allCoeffs.append(contentsOf: bandCoeffs)
    }

    return allCoeffs
}
```

Remove the old `graphicEQQ` constant (it is no longer used).

**Step 4: Update existing BiquadMathTests**

`testGraphicEQQConstant` — replace with tests for the new constants:
```swift
func testAdaptiveQConstants() {
    XCTAssertEqual(BiquadMath.baseQ, 1.2)
    XCTAssertEqual(BiquadMath.minQ, 0.9)
    XCTAssertEqual(BiquadMath.qSlopePerDB, 0.025)
}
```

`testAllBandsFlatGainsProduceUnityFilters` — still valid (0 dB gain produces b0=1 regardless of Q). No change.

`testAllBandsCoefficientsAreFinite` — the preset gains used `[6, 6, 5, -1, 0, 0, 0, 0, 0, 0]` which are within +-12. No change.

**Step 5: Run tests**

Run: `swift test --filter FineTuneCoreTests/BiquadMathTests`
Expected: All pass.

**Step 6: Commit**

```bash
git add FineTune/Audio/BiquadMath.swift testing/tests/BiquadMathTests.swift
git commit -m "feat(eq): implement adaptive Q — widens bandwidth as gain increases"
```

---

### Task 4: Add pre-EQ gain reduction to EQProcessor

**Files:**
- Modify: `FineTune/Audio/EQProcessor.swift`

**Step 1: Add preamp scalar property and computation**

In `FineTune/Audio/EQProcessor.swift`, add an atomic preamp scalar that is updated alongside the biquad setup:

Add property after the existing `_isEnabled`:
```swift
/// Pre-EQ gain scalar for headroom management (linear, not dB).
/// Computed as: pow(10, -maxBoost / 20) where maxBoost is the maximum positive gain.
/// 1.0 means no attenuation (flat EQ or cuts only).
private nonisolated(unsafe) var _preampScalar: Float = 1.0
```

Add a public read accessor:
```swift
/// Current pre-EQ gain scalar (linear)
var preampScalar: Float { _preampScalar }
```

In `updateSettings(_:)`, after `_currentSettings = settings`, compute and store the preamp:
```swift
let maxBoost = settings.clampedGains.max() ?? 0
let preampDB = -max(maxBoost, 0)
_preampScalar = Float(pow(10.0, Double(preampDB) / 20.0))
```

The property is read from the audio thread (same as `_isEnabled` and `_eqSetup`), so it follows the same `nonisolated(unsafe)` pattern.

**Step 2: Run existing tests to verify nothing breaks**

Run: `swift test --filter FineTuneCoreTests`
Expected: All pass. The preamp is stored but not yet applied in the audio path.

**Step 3: Commit**

```bash
git add FineTune/Audio/EQProcessor.swift
git commit -m "feat(eq): compute pre-EQ gain scalar from max positive band gain"
```

---

### Task 5: Apply pre-EQ gain in ProcessTapController audio callback

**Files:**
- Modify: `FineTune/Audio/ProcessTapController.swift` (two sites: ~line 1379 and ~line 1547)

**Step 1: Add pre-EQ attenuation before eqProcessor.process() at both sites**

There are two places in `ProcessTapController.swift` where `eqProcessor.process()` is called, followed by `SoftLimiter.processBuffer()`. At both sites, add a `vDSP_vsmul` call before the EQ:

At the first site (around line 1379), before `eqProcessor.process(...)`:
```swift
// Pre-EQ gain reduction for headroom management
var preamp = eqProcessor.preampScalar
vDSP_vsmul(outputSamples, 1, &preamp, outputSamples, 1, vDSP_Length(sampleCount))
```

At the second site (around line 1547), add the same block before `eqProcessor.process(...)`:
```swift
// Pre-EQ gain reduction for headroom management
var preamp = eqProcessor.preampScalar
vDSP_vsmul(outputSamples, 1, &preamp, outputSamples, 1, vDSP_Length(sampleCount))
```

Note: When `preampScalar` is 1.0 (flat EQ or cuts only), `vDSP_vsmul` by 1.0 is effectively a no-op — the compiler and vDSP implementation handle this efficiently.

**Step 2: Build to verify compilation**

Run: `swift build`
Expected: Compiles. (ProcessTapController is in FineTuneIntegration, not FineTuneCore, so unit tests don't cover it directly.)

**Step 3: Commit**

```bash
git add FineTune/Audio/ProcessTapController.swift
git commit -m "feat(eq): apply automatic pre-EQ gain reduction in audio callback"
```

---

### Task 6: Update all presets

**Files:**
- Modify: `FineTune/Models/EQPreset.swift:99-182`
- Modify: `testing/tests/EQPresetTests.swift`

**Step 1: Replace all preset gain values**

In `FineTune/Models/EQPreset.swift`, replace the entire `settings` computed property switch body with the new preset values. Every case is listed below:

```swift
public var settings: EQSettings {
    switch self {
    // MARK: - Utility
    case .flat:
        return EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    case .bassBoost:
        return EQSettings(bandGains: [10, 8, 5, 2, 0, 0, 0, 0, 0, 0])
    case .bassCut:
        return EQSettings(bandGains: [-8, -6, -4, -2, 0, 0, 0, 0, 0, 0])
    case .trebleBoost:
        return EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 2, 5, 8, 10])

    // MARK: - Speech
    case .vocalClarity:
        return EQSettings(bandGains: [-4, -3, -1, -2, 0, 3, 5, 5, 2, 0])
    case .podcast:
        return EQSettings(bandGains: [-6, -4, -2, -1, 0, 3, 5, 4, 2, 0])
    case .spokenWord:
        return EQSettings(bandGains: [-8, -6, -3, -2, 0, 3, 5, 5, 2, 0])

    // MARK: - Listening
    case .loudness:
        return EQSettings(bandGains: [8, 6, 3, 0, -2, -2, 0, 3, 6, 8])
    case .lateNight:
        return EQSettings(bandGains: [-6, -4, -2, 0, 0, 1, 2, 2, 1, 0])
    case .smallSpeakers:
        return EQSettings(bandGains: [4, 5, 6, 3, 0, 1, 3, 3, 2, 0])

    // MARK: - Music
    case .rock:
        return EQSettings(bandGains: [6, 4, 0, -2, -1, 2, 4, 6, 4, 3])
    case .pop:
        return EQSettings(bandGains: [4, 4, 2, 0, -1, 2, 3, 4, 4, 5])
    case .electronic:
        return EQSettings(bandGains: [10, 8, 4, 0, -3, -3, 2, 6, 8, 6])
    case .jazz:
        return EQSettings(bandGains: [4, 3, 1, 0, 0, 0, 1, 3, 3, 2])
    case .classical:
        return EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 1, 3, 3, 3])
    case .hipHop:
        return EQSettings(bandGains: [10, 9, 5, 2, 0, -1, 1, 3, 5, 4])
    case .rnb:
        return EQSettings(bandGains: [6, 5, 4, 1, -1, 0, 3, 4, 4, 3])
    case .deep:
        return EQSettings(bandGains: [8, 8, 5, 1, -3, -3, 0, 2, 3, 2])
    case .acoustic:
        return EQSettings(bandGains: [0, 1, 3, 3, 1, 0, 2, 3, 3, 2])

    // MARK: - Media
    case .movie:
        return EQSettings(bandGains: [6, 5, 4, -1, -1, 2, 4, 4, 3, 2])

    // MARK: - Headphone
    case .hpClarity:
        return EQSettings(bandGains: [-3, -3, -4, -3, -2, 0, 2, 2, 1, 1])
    case .hpReference:
        return EQSettings(bandGains: [-5, -5, -6, -4, -1, 0, 0, 1, -1, -2])
    case .hpVocalFocus:
        return EQSettings(bandGains: [-7, -6, -5, -3, -2, 2, 4, 4, 1, -1])
    }
}
```

**Step 2: Update EQPresetTests**

Most tests are structural (count, categories, names) and pass unchanged. Tests that check specific gain values need updating:

`testBassBoostHasPositiveLowFreqs` — still valid (10, 8 are positive). No change.

`testBassCutHasNegativeLowFreqs` — still valid (-8, -6 are negative). No change.

`testTrebleBoostHasPositiveHighFreqs` — still valid (8, 10 are positive). No change.

`testHeadphonePresetABBassCutProgression` — verify the new values maintain the ordering:
- 31 Hz: Clarity=-3, Reference=-5, VocalFocus=-7. -5 < -3 and -7 < -5. OK.
- 62 Hz: Clarity=-3, Reference=-5, VocalFocus=-6. -5 < -3 and -6 < -5. OK.
No change needed.

`testHeadphonePresetABPresenceProgression` — verify:
- 2 kHz (index 6): Clarity=2, Reference=0, VocalFocus=4. Clarity(2) > Reference(0) OK. VocalFocus(4) > Clarity(2) OK.
- 4 kHz (index 7): Clarity=2, Reference=1, VocalFocus=4. Clarity(2) > Reference(1) OK. VocalFocus(4) > Clarity(2) OK.
No change needed.

`testHeadphonePresetABHasLargeOverallDifference` — compute delta between Clarity and VocalFocus with new values:
|[-3,-3,-4,-3,-2,0,2,2,1,1] vs [-7,-6,-5,-3,-2,2,4,4,1,-1]| = 4+3+1+0+0+2+2+2+0+2 = 16. > 10. OK. No change.

**Step 3: Run tests**

Run: `swift test --filter FineTuneCoreTests`
Expected: All pass.

**Step 4: Commit**

```bash
git add FineTune/Models/EQPreset.swift testing/tests/EQPresetTests.swift
git commit -m "feat(eq): recalibrate all 23 presets for +-12 dB range with bolder values"
```

---

### Task 7: Final verification — run full test suite

**Step 1: Run all FineTuneCore tests**

Run: `swift test --filter FineTuneCoreTests`
Expected: All pass.

**Step 2: Run integration tests (if they compile without Xcode-only dependencies)**

Run: `swift test --filter FineTuneIntegrationTests`
Expected: Pass or skip gracefully if hardware-dependent.

**Step 3: Commit any remaining test fixes**

If any tests failed, fix and commit individually with descriptive messages.

**Step 4: Final commit (if all clean)**

```bash
git add -A
git commit -m "chore: adaptive EQ redesign complete — all tests passing"
```
