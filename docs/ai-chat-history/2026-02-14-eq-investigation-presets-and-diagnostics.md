# EQ Investigation: Agent-Based Root Cause Analysis, New Presets, and Diagnostic Counters

**Date:** 2026-02-14
**Session type:** Multi-agent investigation + feature additions + diagnostic instrumentation
**Project:** FineTune (macOS 26/Tahoe only)

---

## Executive Summary

A comprehensive investigation into why EQ might not be producing audible changes was conducted using 6 agents (4 code investigation + 2 web research). The investigation concluded that **no definitive code bug was found** -- the EQ pipeline is correctly implemented. Three new headphone-targeted EQ presets were added (HP: Clarity, HP: Reference, HP: Vocal Focus), and EQ diagnostic counters were added to track when EQ is applied vs bypassed per callback.

A subtle struct initialization bug was identified during this documentation phase in `TapDiagnostics.swift` where `eqApplied` and `eqBypassed` are declared with default values (`= 0`) instead of as uninitialized `let` properties, causing the values passed from the memberwise initializer in `ProcessTapController.diagnostics` to be silently ignored.

---

## Table of Contents

1. [Agent Deployment and Findings](#agent-deployment-and-findings)
2. [Code Changes Made](#code-changes-made)
3. [EQ Pipeline Architecture Analysis](#eq-pipeline-architecture-analysis)
4. [Root Cause Candidates (Why EQ Might Seem Inactive)](#root-cause-candidates)
5. [Bug Found During Documentation](#bug-found-during-documentation)
6. [Files Modified](#files-modified)
7. [Known Issues and TODO List](#known-issues-and-todo-list)

---

## Agent Deployment and Findings

### Agent Team Structure

| # | Agent Role | Focus Area | Key Finding |
|---|-----------|------------|-------------|
| 1 | Code Investigator (EQ Pipeline) | `EQProcessor.swift`, `ProcessTapController.swift` EQ call site | Pipeline is correctly wired: gain processing -> EQ -> soft limiter. Guard conditions are appropriate. |
| 2 | Code Investigator (EQ Presets) | `EQPreset.swift`, `EQSettings.swift` | Presets define band gains correctly; `isEnabled` returns `false` when all gains are zero (flat). Non-flat presets correctly enable processing. |
| 3 | Code Investigator (Tap Lifecycle) | `ProcessTapController` activation, device switching, crossfade | EQ processor is created during `activate()` and its sample rate is updated on device switch. During crossfade, EQ is intentionally bypassed to prevent artifacts. |
| 4 | Code Investigator (UI/State Flow) | `MenuBarPopupViewModel`, `AppRow`, EQ preset selection | UI correctly propagates preset selection -> `EQSettings` -> `ProcessTapController.updateEQSettings()` -> `EQProcessor.updateSettings()`. |
| 5 | Web Researcher (vDSP_biquad) | Apple vDSP documentation, biquad filter behavior | Confirmed `vDSP_biquad` with stride=2 for interleaved stereo is the correct usage pattern. Delay buffer sizing of `(2*sections)+2` matches Apple docs. |
| 6 | Web Researcher (Headphone EQ curves) | Harman target, headphone frequency response correction | Researched typical de-bass/de-muddy EQ curves for over-ear headphones. Informed the three new preset designs. |

### Consolidated Agent Conclusions

1. **The EQ processing pipeline is correctly implemented.** `EQProcessor.process()` uses `vDSP_biquad` with proper stride-2 interleaved stereo processing, correct delay buffer management, and atomic setup swaps for RT-safety.

2. **EQ is correctly gated.** The guard conditions at the call site (line ~1325 of `ProcessTapController.swift`) require:
   - `eqProcessor != nil` (created during `activate()`)
   - `!crossfadeState.isActive` (bypassed during device transitions)
   - `format.isInterleaved` (safety: vDSP_biquad stride trick requires interleaved)
   - `format.channelCount == 2` (safety: stereo only)
   - `outputBuffers.count == 1` (safety: single buffer for interleaved)
   - `outputBuffers[0].mData != nil` (safety: valid buffer pointer)

3. **No code bug was found.** If the user perceives EQ as not working, the most likely explanations are:
   - The EQ toggle is off (preset set to "Flat")
   - The tap has not yet activated for the target app
   - A crossfade is active (brief EQ bypass during device switch)
   - The audio format is non-interleaved or non-stereo (rare but possible)

---

## Code Changes Made

### 1. Three New Headphone EQ Presets

Added to `FineTune/Models/EQPreset.swift`:

**New enum cases:**
```swift
case hpClarity
case hpReference
case hpVocalFocus
```

**New category:**
```swift
case headphone = "Headphone"
```

**Preset band gains (10-band: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16kHz):**

| Preset | Design Goal | Band Gains |
|--------|------------|------------|
| HP: Clarity | Moderate bass reduction, gentle presence lift -- good starting point | `[-2, -2.5, -3.5, -3, -1.5, 0, 1, 1.5, 1, 0.5]` |
| HP: Reference | Harman-inspired flat target: aggressive bass correction, slight treble taming | `[-4, -4.5, -5, -3, -1, 0, 0, 0.5, -1, -1.5]` |
| HP: Vocal Focus | Heavy bass cut, strong 2-4kHz presence boost for max definition | `[-6, -5.5, -4.5, -3, -1.5, 1, 2.5, 3, 1, -1]` |

These target the common problem of over-ear headphones (Sony WH-1000XM series, AirPods Max, Beats, etc.) having excessive bass/low-mid emphasis ("muddy" sound). Each preset progressively increases the correction aggressiveness.

### 2. EQ Diagnostic Counters

Added to `FineTune/Audio/ProcessTapController.swift`:

**New RT-safe counters:**
```swift
private nonisolated(unsafe) var _diagEQApplied: UInt64 = 0
private nonisolated(unsafe) var _diagEQBypassed: UInt64 = 0
```

**Instrumentation at the EQ call site (primary callback only):**
- After EQ processing: `_diagEQApplied += 1`
- When EQ guard conditions fail: `_diagEQBypassed += 1`

**Added to `TapDiagnostics` struct:**
```swift
let eqApplied: UInt64 = 0   // BUG: see note below
let eqBypassed: UInt64 = 0  // BUG: see note below
```

---

## EQ Pipeline Architecture Analysis

The EQ processing occurs in the primary audio callback at the following position in the signal chain:

```
Input Buffer (from process tap)
    |
    v
Format validation (isFloat32 check)
    |
    v
GainProcessor.processFloatBuffers()    -- volume ramping + crossfade multiplier
    |
    v
EQProcessor.process()                  -- 10-band biquad (when conditions met)
    |
    v
SoftLimiter.processBuffer()            -- prevents clipping from EQ boost
    |
    v
Output Buffer (to aggregate device)
```

**EQ bypass conditions (any one causes bypass):**
1. `eqProcessor == nil` -- tap not yet activated
2. `crossfadeState.isActive` -- device switch in progress
3. `!format.isInterleaved` -- non-standard format
4. `format.channelCount != 2` -- mono or surround
5. `outputBuffers.count != 1` -- multiple buffer layout
6. `outputBuffers[0].mData == nil` -- null buffer

**EQ disable condition (inside EQProcessor.process):**
7. `_isEnabled == false` -- set when `EQSettings.isEnabled` is false (all band gains are zero, i.e., "Flat" preset)

---

## Root Cause Candidates

### Why EQ Might Not Be Working (In Order of Likelihood)

| # | Cause | How to Verify | How to Fix |
|---|-------|---------------|------------|
| 1 | Preset is "Flat" (all gains zero) | Check `EQProcessor._isEnabled` -- will be `false` | Select a non-flat preset |
| 2 | Tap not activated for target app | Check `eqProcessor != nil` in diagnostics | App must be producing audio; FineTune must have captured it |
| 3 | Crossfade active during test | Check `xfade=true` in DIAG logs | Wait for crossfade to complete (~300ms) |
| 4 | Subtle gain values too small to perceive | HP: Clarity uses modest +/-3.5dB swings | Try HP: Vocal Focus with aggressive -6dB/+3dB swings |
| 5 | Audio format non-interleaved | Check `fmt=` in DIAG logs for `planar` | Rare; would need converter path extension |
| 6 | Sample rate mismatch (biquad coefficients wrong) | Compare `_sampleRate` in EQProcessor with actual device rate | `updateSampleRate()` is called on device switch; verify it fires |

---

## Bug Found During Documentation

### TapDiagnostics.swift: Default Values Shadow Memberwise Initializer Arguments

**File:** `FineTune/Audio/Tap/TapDiagnostics.swift`

**Problem:**
```swift
struct TapDiagnostics {
    // ... other fields ...
    let eqApplied: UInt64 = 0   // <-- default value
    let eqBypassed: UInt64 = 0  // <-- default value
    // ... other fields ...
}
```

Because `eqApplied` and `eqBypassed` are declared with default values (`= 0`), the Swift memberwise initializer allows them to be passed but **the default value takes precedence when the struct is initialized**. In `ProcessTapController.diagnostics`, the computed property passes the actual counter values:

```swift
eqApplied: _diagEQApplied,
eqBypassed: _diagEQBypassed,
```

However, the struct definition with `let eqApplied: UInt64 = 0` means the initializer parameter is accepted but the stored property is initialized to `0` regardless.

**Impact:** The EQ diagnostic counters in `TapDiagnostics` will always read as `0`, even when EQ is actively being applied or bypassed. The RT-safe counters in `ProcessTapController` (`_diagEQApplied`, `_diagEQBypassed`) are correctly incremented but their values never reach the diagnostic snapshot.

**Fix:** Remove the `= 0` default values:
```swift
let eqApplied: UInt64
let eqBypassed: UInt64
```

**Additional gap:** The `logDiagnostics()` method in `AudioEngine.swift` does not yet include `eqApplied` or `eqBypassed` in its DIAG log line. After fixing the struct, add these fields to the log format string.

---

## Files Modified

### Code Changes (Uncommitted)

1. **`FineTune/Models/EQPreset.swift`** (+21 lines)
   - Added `hpClarity`, `hpReference`, `hpVocalFocus` enum cases
   - Added `headphone` category
   - Added display names and band gain definitions

2. **`FineTune/Audio/ProcessTapController.swift`** (+7 lines)
   - Added `_diagEQApplied` and `_diagEQBypassed` RT-safe counters
   - Added counter increments at EQ call site (applied vs bypassed branches)
   - Passed counters to `TapDiagnostics` memberwise init

3. **`FineTune/Audio/Tap/TapDiagnostics.swift`** (+2 lines)
   - Added `eqApplied` and `eqBypassed` fields (currently bugged with default values)

---

## Known Issues and TODO List

### Priority 0: Fix the TapDiagnostics Bug

1. **Remove default values from `eqApplied` and `eqBypassed`** in `TapDiagnostics.swift`.
   - Change `let eqApplied: UInt64 = 0` to `let eqApplied: UInt64`
   - Change `let eqBypassed: UInt64 = 0` to `let eqBypassed: UInt64`

2. **Add EQ counters to diagnostic log** in `AudioEngine.logDiagnostics()`.
   - Add `eq=\(d.eqApplied)/\(d.eqBypassed)` (applied/bypassed) to the DIAG format string.

### Priority 1: Runtime Verification

3. **Build and run with fixed diagnostics** to observe EQ applied/bypassed ratio in real time.
   - Expected: When a non-flat preset is active and audio is playing, `eqApplied` should increment rapidly and `eqBypassed` should stay at 0 (or increment only during brief crossfades).
   - If `eqBypassed` is unexpectedly high, check which guard condition is failing.

4. **A/B test the new headphone presets** with over-ear headphones.
   - HP: Clarity should produce a noticeable but subtle bass reduction.
   - HP: Vocal Focus should produce a dramatic tonal shift (heavy bass cut + presence boost).
   - If neither produces audible change, the EQ pipeline has a deeper issue.

### Priority 2: EQ Pipeline Hardening

5. **Add EQ bypass reason logging.** Currently when the EQ guard fails, we only increment `_diagEQBypassed`. Consider logging which specific condition failed (nil processor, crossfade active, wrong format, etc.) to separate counters or a reason enum.

6. **Verify sample rate propagation.** When switching from built-in speakers (44100Hz) to AirPods (48000Hz), confirm `EQProcessor.updateSampleRate()` fires and biquad coefficients are recalculated. Incorrect sample rate produces wrong filter curves (bass cut might become treble cut, etc.).

7. **Test mono/non-interleaved paths.** Some apps may produce mono or non-interleaved audio. Currently EQ is completely bypassed for these formats. Consider extending EQ support to mono (use single channel biquad) if this is common.

### Priority 3: Preset Tuning

8. **Gather user feedback on headphone presets.** The current band gains are theoretical (based on Harman target research). Real-world tuning may need adjustment based on:
   - Specific headphone models (Sony XM5 vs AirPods Max have different bass emphasis)
   - Content type (music vs voice calls vs podcasts)
   - User preference (some users like warm bass, even on headphones)

9. **Consider per-app EQ presets.** Currently EQ is set globally per app. Some users may want different EQ for different apps (e.g., Vocal Clarity for Zoom, HP: Reference for Spotify).

### Priority 4: Test Coverage

10. **Add unit tests for new presets.** Verify:
    - Each new preset has non-zero gains (not accidentally flat)
    - Category mapping is correct (all three map to `.headphone`)
    - `settings.isEnabled` returns `true` for all three

11. **Add unit test for EQ diagnostic counter flow.** Mock a `ProcessTapController`, trigger the audio callback, and verify `TapDiagnostics.eqApplied` is non-zero (after fixing the default value bug).

---

## Diagnostic Commands Reference

```bash
# Pull FineTune diagnostic logs (must include --info flag)
/usr/bin/log show --predicate 'process == "FineTune"' --last 2m --info 2>&1 | grep "DIAG"

# Filter for EQ-specific diagnostics (after adding EQ to log format)
/usr/bin/log show --predicate 'process == "FineTune"' --last 2m --info 2>&1 | grep "eq="

# Check EQ processor lifecycle events
/usr/bin/log show --predicate 'process == "FineTune"' --last 5m --info 2>&1 | grep -i "EQ"
```

---

## Session Handoff Status

- Multi-agent EQ investigation: **completed** (no code bug found)
- 3 headphone EQ presets: **added** (uncommitted)
- EQ diagnostic counters: **added** (uncommitted, with TapDiagnostics bug)
- TapDiagnostics default value bug: **identified**, not yet fixed
- Diagnostic log format update for EQ: **not yet done**
- Runtime A/B testing of new presets: **not yet done**

---

## Follow-up Update (2026-02-14, later session)

Priority 0 items from this handoff were completed:
- `TapDiagnostics` now uses an explicit initializer with `eqApplied`/`eqBypassed` parameters (defaulting to `0` only when omitted for compatibility), so passed values are preserved.
- `AudioEngine.logDiagnostics()` now prints `eq=<applied>/<bypassed>` on each `[DIAG]` line.
- Regression tests were added for EQ counters round-tripping through `TapDiagnostics`.

- Added per-reason EQ bypass counters (`noProcessor`, `crossfadeActive`, `nonInterleaved`, `channelMismatch`, `bufferCount`, `noOutputData`) and surfaced them in DIAG logs as `eqR=...`.
- Added fail-first tests for bypass reason decision logic, then implemented `ProcessTapController.eqBypassReason(...)` and passed targeted test runs.
- Added compact DIAG percentages: `eqBypassPct` (overall bypass rate) and `eqCfPct` (share of bypasses caused by crossfade).
