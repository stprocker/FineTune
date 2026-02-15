# Adaptive EQ Redesign — Session Handoff

**Date:** 2026-02-15
**Status:** Implementation complete, runtime verified, user approved

---

## Summary

Complete redesign of FineTune's 10-band graphic EQ signal chain. Previously, moving sliders had almost no audible effect — even maxing bass sounded nearly identical to flat. Now, slider adjustments produce clearly audible tonal changes while maintaining safe output levels.

## Problem Diagnosis

Three research agents (2 web-based, 1 codebase analysis) converged on four compounding root causes:

1. **Q=1.8 was too narrow** for 1-octave-spaced bands (correct Q ~1.414). Left dead zones between bands. The RBJ Audio EQ Cookbook peaking filter formula further narrows effective bandwidth as gain increases — opposite of user expectation.

2. **Soft limiter at 0.9 threshold** with no pre-EQ headroom. Modern music peaks near 0 dBFS, so any boost immediately triggered constant gain reduction that undid the EQ effect. Math: +12 dB boost through limiter = ~+1.3 dB net audible change.

3. **No pre-EQ gain reduction.** Every serious EQ implementation (AutoEQ, SoundSource, Equalizer APO, miniDSP) attenuates before boosting to create headroom.

4. **Conservative preset values** (+6-7 dB peaks) through narrow filters with the limiter eating the boost — net audible change was ~2 dB.

## Solution Implemented (Option D — Adaptive Hybrid)

### 1. Adaptive Q (`BiquadMath.swift`)

Replaced fixed `graphicEQQ = 1.8` with per-band dynamic Q:

```swift
effectiveQ = max(0.9, 1.2 - abs(gainDB) * 0.025)
```

| Gain (dB) | Q    | Bandwidth (oct) | Feel              |
|-----------|------|-----------------|-------------------|
| 0         | 1.20 | ~1.2            | Flat, no effect   |
| +-3       | 1.13 | ~1.3            | Subtle, precise   |
| +-6       | 1.05 | ~1.4            | Clearly audible   |
| +-9       | 0.98 | ~1.5            | Dramatic          |
| +-12      | 0.90 | ~1.6            | Maximum, broad    |

### 2. Automatic Pre-EQ Gain Reduction (`EQProcessor.swift` + `ProcessTapController.swift`)

```swift
// In EQProcessor.updateSettings():
let maxBoost = settings.clampedGains.max() ?? 0
let preampDB = -max(maxBoost, 0)
_preampScalar = Float(pow(10.0, Double(preampDB) / 20.0))

// In ProcessTapController (both callback sites):
var preamp = eqProcessor.preampScalar
vDSP_vsmul(outputSamples, 1, &preamp, outputSamples, 1, vDSP_Length(sampleCount))
```

Signal chain: Input -> Pre-EQ Attenuation -> Gain -> SoftLimiter -> EQ -> SoftLimiter -> Output

### 3. Limiter Threshold 0.9 -> 0.95 (`SoftLimiter.swift`)

Now a safety net for rare adjacent-band stacking peaks, not a constantly-engaged compressor.

### 4. Gain Range +-18 -> +-12 (`EQSettings.swift`)

Industry standard (Spotify, Apple Music, API 560, dbx). Each slider increment has more perceptual impact.

### 5. All 23 Presets Recalibrated (`EQPreset.swift`)

Bolder values designed for +-12 dB with adaptive Q. Key examples:
- Bass Boost: [10, 8, 5, 2, 0, 0, 0, 0, 0, 0] (was [6, 6, 5, -1, 0, 0, 0, 0, 0, 0])
- Electronic: [10, 8, 4, 0, -3, -3, 2, 6, 8, 6]
- Hip-Hop: [10, 9, 5, 2, 0, -1, 1, 3, 5, 4]

## Files Modified

| File | Change |
|------|--------|
| `FineTune/Audio/BiquadMath.swift` | Removed fixed Q=1.8, added adaptive Q function with baseQ=1.2, minQ=0.9, qSlopePerDB=0.025 |
| `FineTune/Models/EQSettings.swift` | maxGainDB 18->12, minGainDB -18->-12 |
| `FineTune/Audio/Processing/SoftLimiter.swift` | threshold 0.9->0.95 |
| `FineTune/Audio/EQProcessor.swift` | Added `_preampScalar` property, computed from max positive band gain in `updateSettings()` |
| `FineTune/Audio/ProcessTapController.swift` | Added `vDSP_vsmul` pre-EQ attenuation at both audio callback sites (~line 1379 and ~line 1547) |
| `FineTune/Models/EQPreset.swift` | All 23 presets recalibrated with bolder values |
| `testing/tests/EQSettingsTests.swift` | Updated for +-12 range |
| `testing/tests/SoftLimiterTests.swift` | Updated for threshold=0.95, headroom=0.05 |
| `testing/tests/BiquadMathTests.swift` | Added 5 adaptive Q tests, removed graphicEQQ constant test |

## Git Commits (oldest to newest)

```
4ce52c3 feat(eq): change gain range from +-18 dB to +-12 dB (industry standard)
13ca536 feat(eq): raise limiter threshold from 0.9 to 0.95 (safety net only)
c461f36 feat(eq): implement adaptive Q — widens bandwidth as gain increases
2a74f05 feat(eq): compute pre-EQ gain scalar from max positive band gain
f70d532 feat(eq): apply automatic pre-EQ gain reduction in audio callback
95b29a0 feat(eq): recalibrate all 23 presets for +-12 dB range with bolder values
```

## Test Status

- **364 tests passing, 0 failures** (`swift test`)
- Runtime diagnostic logs confirm pre-EQ gain reduction active
- User listening test: "sounds pretty good!"

## Design Documents

- `docs/plans/2026-02-15-adaptive-eq-redesign.md` — Full problem diagnosis and solution specification
- `docs/plans/2026-02-15-adaptive-eq-redesign-plan.md` — 7-task implementation plan

## Research Sources

- Rane Note 101: Constant-Q Graphic Equalizers
- Rane Note 154: Perfect-Q
- Sengpiel Audio: Q Factor vs Bandwidth Calculator
- Robert Bristow-Johnson: Audio EQ Cookbook
- AutoEQ: Automatic negative preamp methodology
- SoundSource: Preamp field in headphone EQ profiles
- Equalizer APO: Pre-gain recommendation of -6 dB
- miniDSP: Gain Structure 101
- Signalsmith Audio: Limiter design guide
- API 560, dbx 231s, Klark Teknik DN360 specifications

---

## TODO List

### High Priority — Listening & Tuning

- [ ] **Genre-wide listening test**: Verify presets across rock, electronic, hip-hop, classical, podcasts, spoken word, and acoustic recordings. Some presets may need fine-tuning based on real-world listening.
- [ ] **Volume perception on boost presets**: If Bass Boost, Electronic, or Hip-Hop feel too quiet (due to full preamp attenuation), consider fractional preamp — e.g., attenuate by 75% of max boost instead of 100%. Would trade some clipping safety for perceived loudness.
- [ ] **Headphone preset tuning**: HP: Clarity, HP: Reference, and HP: Vocal Focus were converted from fractional to integer gain values. May need fine-tuning with specific headphone models (AirPods, AirPods Max, Sony WH-1000XM series, etc.)

### Medium Priority — UX Polish

- [ ] **Custom preset migration notification**: Users with custom presets saved at gains 12-18 dB will have them silently clamped to +-12. Consider showing a one-time "your presets have been adjusted" notification.
- [ ] **A/B testing toggle**: Consider adding a hidden/debug toggle to quickly switch between old (Q=1.8, no preamp, threshold=0.9) and new EQ behavior for direct comparison during tuning.

### Low Priority — Future Enhancements

- [ ] **Proportional-Q or Perfect-Q**: The adaptive Q is a good approximation of constant-bandwidth behavior, but Rane's Perfect-Q (iterative inter-band interaction matrix) would be the true gold standard. Only worth pursuing if users report specific inter-band artifacts.
- [ ] **Post-EQ makeup gain**: Currently the preamp only attenuates. A post-EQ gain stage could restore overall perceived loudness while preserving spectral shape. Trades safety margin for perceived loudness.
- [ ] **Adjacent-band constructive interference**: The preamp uses simple `max(gains)` which doesn't account for constructive interference when adjacent bands are boosted (e.g., Bass Boost: 31Hz=+10, 62Hz=+8 could stack to >+10 at intermediate frequencies). The limiter at 0.95 catches these cases but a smarter preamp could be more precise.
- [ ] **Per-band preamp weighting**: Instead of global attenuation from max positive gain, could weight preamp by number and proximity of boosted bands for more nuanced headroom management.

---

## Known Issues

### SourceKit False Diagnostics (IDE Only)
SourceKit reports "Cannot find type" errors for cross-module references (e.g., `BiquadMath` in `ProcessTapController`, `EQProcessor` type references). These are stale IDE indexing issues — actual `swift build` and `swift test` succeed. Workaround: clean build folder in Xcode (Cmd+Shift+K).

### Pre-EQ Gain Reduction is Global
The `vDSP_vsmul` pre-EQ attenuation applies equally to all frequencies. This means unboosted frequencies are attenuated without being boosted back. The spectral shape is preserved (bass is louder *relative* to mids) but overall perceived loudness decreases on heavy-boost presets. This is the standard approach used by AutoEQ, Equalizer APO, and SoundSource.

### Custom Presets with Out-of-Range Gains
Custom presets saved when the range was +-18 dB will have gains >12 or <-12 silently clamped by `EQSettings.clampedGains`. No data migration or user notification is implemented.

### Pre-existing Issues (Unrelated to EQ Changes)
- `HALC_ShellObject::SetPropertyData: call to the proxy failed` — Core Audio HAL noise in logs, benign
- `AddInstanceForFactory: No factory registered for id` — macOS audio framework noise, benign
- SourceKit indexing issues for cross-module types in the SPM multi-target setup

---

## Key Technical Decisions

1. **Adaptive Q over fixed Q=1.414**: While Q=1.414 is mathematically correct for 1-octave constant bandwidth, it doesn't account for the RBJ cookbook's gain-dependent bandwidth narrowing. Adaptive Q dynamically compensates, giving wider bandwidth at higher gains where users expect more dramatic effect.

2. **Full preamp (100% of max boost) over fractional**: Chose maximum safety. If presets feel too quiet, reduce to 75% or 50% — this is a single-line change in `EQProcessor.updateSettings()`.

3. **+-12 dB over +-18 dB**: Industry standard range. Each slider increment has ~50% more perceptual impact at +-12 than at +-18.

4. **Threshold 0.95 over 1.0**: Kept a small safety margin rather than removing the limiter entirely. At 0.95, the limiter rarely engages with proper preamp headroom, but still catches edge cases from adjacent-band stacking.
