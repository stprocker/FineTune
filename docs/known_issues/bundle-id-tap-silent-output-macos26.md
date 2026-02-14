# Bundle-ID Tap: Captures Audio but Aggregate Output is Dead (macOS 26)

**Date discovered:** 2026-02-07
**Status:** No workaround — root cause unknown, investigation needed
**Severity:** High — causes complete audio silence for affected apps when `.mutedWhenTapped`

---

## Symptom

When FineTune creates a process tap using the macOS 26 `bundleIDs` + `isProcessRestoreEnabled` API, the tap successfully captures audio from the process (`inPeak > 0`), but the aggregate device's output path produces no audible sound (`outPeak=0.000`).

With `.unmuted` taps, the user hears audio because the original stream plays through directly (FineTune just observes). Once `.mutedWhenTapped` activates, the original is silenced and FineTune's dead aggregate output is the only path — resulting in silence.

## Critical finding: PID-only taps don't capture on macOS 26

An A/B test with PID-only taps (disabling bundle-ID path) showed that PID-only mode **cannot capture Brave audio at all** on macOS 26:

| Mode | Input (capture) | Output (playback) |
|------|----------------|-------------------|
| Bundle-ID tap (`bundleIDs` + `isProcessRestoreEnabled`) | Works (`input > 0`, `inPeak > 0`) | **Dead** (`outPeak=0.000`, silence) |
| PID-only tap (legacy) | **Dead** (`input=0` across 11,864 callbacks) | Works (`outBuf=1x4096B`, buffers healthy) |

**Neither mode fully works.** Bundle-ID is required for capture, but breaks the output. PID-only has working output, but can't capture.

The initial "PID-only fixes it" conclusion was a false positive: the user heard Brave's original audio (`.unmuted` never silences it) and permission never upgraded to `.mutedWhenTapped` (because `shouldConfirmPermission` requires `inputHasData > 0`).

## Affected apps

Observed with Brave Browser on macOS 26. Likely affects all Chromium-based browsers and possibly others that require bundle-ID targeting.

## Evidence

### Bundle-ID mode log (audio captured, output dead):
```
callbacks=57 input=35 output=57 inPeak=0.044 outPeak=0.000
callbacks=356 input=183 output=356 inPeak=0.060 outPeak=0.000
```

### PID-only mode log (no audio captured, output buffers healthy):
```
callbacks=244 input=0 output=244 inPeak=0.000 outPeak=0.000 outBuf=1x4096B
callbacks=11864 input=0 output=11864 inPeak=0.000 outPeak=0.000 outBuf=1x4096B
```

## Code location

```swift
// ProcessTapController.swift — makeTapDescription()
if #available(macOS 26.0, *), let bundleID = app.bundleID,
   !UserDefaults.standard.bool(forKey: "FineTuneForcePIDOnlyTaps") {
    tapDesc.bundleIDs = [bundleID]
    tapDesc.isProcessRestoreEnabled = true
}
```

The `FineTuneForcePIDOnlyTaps` defaults key exists for testing but is **not a valid workaround** (PID-only can't capture).

## Diagnostics available

Added in this session:
- **`outBuf=NxMB`** in DIAG logs — shows output buffer count and byte size from the IOProc callback
- **`outPeak` retain-non-zero** — now shows last non-zero output peak (was previously overwritten to 0 by empty callbacks, making diagnostics unreliable)

## Investigation plan

The problem is specifically: bundle-ID taps create aggregate devices where the output sub-device doesn't produce audible audio, even though the IOProc writes to valid output buffers (`outBuf=1x4096B`).

### Step 1: Isolate which bundle-ID flag causes the output failure
- Test with `bundleIDs` set but `isProcessRestoreEnabled = false`
- Test with `isProcessRestoreEnabled = true` but `bundleIDs` empty (PID-only + restore)

### Step 2: Compare aggregate device properties
- Dump stream count, active streams, and format for aggregates created with bundle-ID vs PID-only
- Check if bundle-ID taps create a different aggregate topology (e.g., different output stream configuration)

### Step 3: Check if it's a known macOS 26 issue
- Search Apple developer forums for `isProcessRestoreEnabled` + aggregate device issues
- Test on different macOS 26 beta builds if available

### Step 4: If macOS bug, file Feedback Assistant
- Include A/B test data and minimal reproducer

### Step 5: Fix regardless
- Fix `shouldConfirmPermission` to require `outPeak > 0` (not just `outputWritten > 0`) so it can't promote to `.mutedWhenTapped` with a dead output path — this is a safety net regardless of root cause

## Related issues

- **`shouldConfirmPermission` false positive:** Uses `outputWritten > 0` as health signal, which doesn't detect dead output. Allows promotion to `.mutedWhenTapped` even when output is broken.
- **P1: Recreation state sequencing race** in AudioEngine.swift (see chat history)
- **P2: Secondary tap mute behavior during crossfade** in ProcessTapController.swift (see chat history)

---

## Resolution (2026-02-08)

**Status: RESOLVED** — `isProcessRestoreEnabled` was the culprit. Removing it fixes both capture and output.

### Root Cause

`isProcessRestoreEnabled` changes how CoreAudio internally wires the aggregate device's output stream. When set, the output buffers exist and are written to, but are not connected to the physical output device. Setting `bundleIDs` alone (without `isProcessRestoreEnabled`) produces working capture AND working output.

### Test Results

The critical Test C (bundleIDs=yes, isProcessRestoreEnabled=no) was run with real audio on 2026-02-08:

```
Brave Browser DIAG after fix:
  callbacks=2775  input=2774  output=2775  inPeak=0.048  outPeak=0.043
```

| # | `bundleIDs` set? | `isProcessRestoreEnabled`? | Capture | Output | Status |
|---|------------------|---------------------------|---------|--------|--------|
| A | No (PID-only) | No | Dead | Works | Confirmed |
| B | Yes | Yes | Works | **Dead** | Confirmed |
| **C** | **Yes** | **No** | **Works** | **Works** | **Confirmed 2026-02-08** |
| D | No (PID-only) | Yes | Unknown | Unknown | Not tested (unnecessary) |

### Fix Applied

`ProcessTapController.swift — makeTapDescription()` now sets `bundleIDs` on macOS 26+ but does NOT set `isProcessRestoreEnabled`. FineTune's `AudioProcessMonitor` already handles process lifecycle, so process restore is not needed.

```swift
if #available(macOS 26.0, *), let bundleID = app.bundleID,
   !UserDefaults.standard.bool(forKey: "FineTuneForcePIDOnlyTaps"),
   !UserDefaults.standard.bool(forKey: "FineTuneDisableBundleIDTaps") {
    tapDesc.bundleIDs = [bundleID]
    // Do NOT set isProcessRestoreEnabled — it causes dead aggregate output
}
```

### Investigation Plan Final Status

| Step | Status | Notes |
|------|--------|-------|
| **Step 1: Isolate which flag** | **DONE** | `isProcessRestoreEnabled` confirmed as sole culprit. |
| **Step 2: Compare aggregate properties** | SKIPPED | Not needed — root cause identified. |
| **Step 3: Check macOS version / known issues** | RESEARCHED | Rogue Amoeba documented 26.0 bugs fixed in 26.1. |
| **Step 4: File Feedback Assistant** | NOT DONE | Could still file re: `isProcessRestoreEnabled` breaking output. |
| **Step 5: Fix `shouldConfirmPermission`** | DONE | `AudioEngine.swift:147-162` requires `lastOutputPeak > 0.0001`. |

### Known Remaining Issue

After device switching (crossfade) with bundle-ID taps, the tap can lose its connection to the app — input count freezes while callbacks continue. This is a separate issue from the dead output bug and needs investigation.
