# Adaptive EQ Redesign

## Problem

The 10-band graphic EQ has very little audible effect. Moving sliders barely changes the sound. Presets sound nearly identical. Maxing out the bass slider should sound terrible but doesn't.

Four compounding causes:
1. **Q=1.8 is too narrow** for 1-octave-spaced bands (correct Q is 1.414). Leaves dead zones between bands. The RBJ cookbook formula narrows bandwidth further as gain increases — the opposite of what users expect.
2. **Soft limiter at 0.9 threshold** with no pre-EQ headroom. Modern music peaks near 0 dBFS, so any boost triggers constant gain reduction that undoes the EQ.
3. **No pre-EQ gain reduction**. Every serious EQ (AutoEQ, SoundSource, Equalizer APO, miniDSP) attenuates before boosting.
4. **Conservative preset values** (peaks at +6-7 dB) through narrow filters with the limiter eating the boost — net audible change is ~2 dB.

## Solution: Option D — Adaptive Hybrid

### 1. Adaptive Q

Replace the fixed Q=1.8 with a per-band dynamic Q computed from that band's gain:

```
effectiveQ = max(0.9, 1.2 - abs(gainDB) * 0.025)
```

| Gain (dB) | Q    | Bandwidth (oct) | Feel              |
|-----------|------|-----------------|-------------------|
| 0         | 1.20 | ~1.2            | Flat, no effect   |
| +-3       | 1.13 | ~1.3            | Subtle, precise   |
| +-6       | 1.05 | ~1.4            | Clearly audible   |
| +-9       | 0.98 | ~1.5            | Dramatic          |
| +-12      | 0.90 | ~1.6            | Maximum, broad    |

At low gains, Q=1.2 gives slightly wider than 1-octave bandwidth for smooth overlap. At high gains, Q drops to 0.9 (~1.6 octaves), counteracting the RBJ narrowing behavior and giving broad, powerful tonal shifts.

Computed on the main thread during existing coefficient recalculation. Zero RT cost.

### 2. Automatic Pre-EQ Gain Reduction

Before EQ processing, attenuate the signal by the maximum positive gain across all bands:

```
preGainDB = -max(band0, band1, ..., band9, 0)
preGainScalar = pow(10, preGainDB / 20)
```

Applied as `vDSP_vsmul` on the buffer before `eqProcessor.process()`. The scalar is precomputed on the main thread when EQ settings change and stored atomically — same pattern as the existing gain processor.

- Bass Boost [10, 8, 5, 2, 0, 0, 0, 0, 0, 0] -> preamp = -10 dB
- Late Night [-6, -4, -2, 0, 0, 0, 0, 0, 0, 0] -> preamp = 0 dB (cuts only)
- Flat [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] -> preamp = 0 dB

After attenuation, a +10 dB boost at 125 Hz brings that band back to original level. Unboosted bands stay quieter. The spectral shape is preserved — bass is louder relative to mids — but absolute peaks never exceed the original. The limiter almost never engages.

### 3. Limiter Threshold: 0.9 -> 0.95

Change `SoftLimiter.threshold` from 0.9 to 0.95. With the preamp handling gain management, the limiter becomes a safety net for rare peaks from adjacent-band stacking, not a constantly-engaged compressor.

### 4. Gain Range: +-18 dB -> +-12 dB

Change `EQSettings.maxGainDB` to 12.0 and `minGainDB` to -12.0. This is the industry standard (Spotify, Apple Music, API 560, dbx hardware). Each slider increment has more perceptual impact, and the preamp doesn't need to attenuate as aggressively.

Existing saved settings with gains outside +-12 are silently clamped via the existing `clampedGains` computed property. No data migration needed.

### 5. Updated Presets

All presets recalibrated for +-12 dB with adaptive Q. Bolder values that produce clearly audible tonal shifts:

```
Bands: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz

Flat:           [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
Bass Boost:     [10, 8, 5, 2, 0, 0, 0, 0, 0, 0]
Bass Cut:       [-8, -6, -4, -2, 0, 0, 0, 0, 0, 0]
Treble Boost:   [0, 0, 0, 0, 0, 0, 2, 5, 8, 10]
Vocal Clarity:  [-4, -3, -1, -2, 0, 3, 5, 5, 2, 0]
Podcast:        [-6, -4, -2, -1, 0, 3, 5, 4, 2, 0]
Spoken Word:    [-8, -6, -3, -2, 0, 3, 5, 5, 2, 0]
Loudness:       [8, 6, 3, 0, -2, -2, 0, 3, 6, 8]
Late Night:     [-6, -4, -2, 0, 0, 1, 2, 2, 1, 0]
Small Speakers: [4, 5, 6, 3, 0, 1, 3, 3, 2, 0]
Rock:           [6, 4, 0, -2, -1, 2, 4, 6, 4, 3]
Pop:            [4, 4, 2, 0, -1, 2, 3, 4, 4, 5]
Electronic:     [10, 8, 4, 0, -3, -3, 2, 6, 8, 6]
Jazz:           [4, 3, 1, 0, 0, 0, 1, 3, 3, 2]
Classical:      [0, 0, 0, 0, 0, 0, 1, 3, 3, 3]
Hip-Hop:        [10, 9, 5, 2, 0, -1, 1, 3, 5, 4]
R&B:            [6, 5, 4, 1, -1, 0, 3, 4, 4, 3]
Deep:           [8, 8, 5, 1, -3, -3, 0, 2, 3, 2]
Acoustic:       [0, 1, 3, 3, 1, 0, 2, 3, 3, 2]
Movie:          [6, 5, 4, -1, -1, 2, 4, 4, 3, 2]
HP: Clarity:    [-3, -3, -4, -3, -2, 0, 2, 2, 1, 1]
HP: Reference:  [-5, -5, -6, -4, -1, 0, 0, 1, -1, -2]
HP: Vocal Focus:[-7, -6, -5, -3, -2, 2, 4, 4, 1, -1]
```

## Files Changed

| File | Change |
|------|--------|
| `BiquadMath.swift` | Replace fixed Q with adaptive Q formula per band |
| `EQSettings.swift` | Change gain range constants to +-12 |
| `SoftLimiter.swift` | Change threshold from 0.9 to 0.95 |
| `ProcessTapController.swift` | Add pre-EQ gain scalar (vDSP_vsmul before EQ) at both processing sites |
| `EQProcessor.swift` | Store/expose preamp scalar computed from current settings |
| `EQPreset.swift` | Update all preset gain values |
| Existing tests | Update expected values for new gain range and limiter threshold |

No new files. No UI changes (slider UI auto-adapts to new gain range). No API changes. Custom presets silently clamped via existing `clampedGains`.

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
