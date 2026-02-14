# Session 3: macOS 26 Audio Routing Investigation

**Date:** 2026-02-07
**Session type:** 3-agent research team + lead synthesis
**Trigger:** Dual-mode audio routing failure on macOS 26 (Tahoe)

---

## Problem Statement

FineTune's per-app audio routing is broken on macOS 26. Two process tap modes exist, and neither fully works:

| Mode | Capture (Input) | Playback (Output) |
|------|-----------------|-------------------|
| Bundle-ID tap (`bundleIDs` + `isProcessRestoreEnabled`) | Works (inPeak > 0) | Dead (outPeak = 0.000) |
| PID-only tap (legacy) | Dead (input = 0) | Works |

When `.mutedWhenTapped` is active, the aggregate device's IOProc is the only output path. If output is dead, the user hears silence. The existing `shouldConfirmPermission()` check did not gate on output peak, allowing promotion to `.mutedWhenTapped` with a dead output path.

## Team Structure

| Agent | Role | Task |
|-------|------|------|
| **api-researcher** | External research | macOS 26 API changes, WWDC docs, Apple forums, Rogue Amoeba compatibility notes |
| **code-analyst** | Internal code analysis | Aggregate device wiring, IOProc buffer flow, `shouldConfirmPermission` gap, TapAPITestRunner coverage |
| **arch-researcher** | Architecture alternatives | Ranked alternative approaches: decoupled capture/output, ScreenCaptureKit, virtual devices, hybrid |
| **team-lead** | Synthesis | Parallel web research, Apple doc analysis, report compilation |

## Key Findings

### 1. Root Cause Hypothesis

`isProcessRestoreEnabled` changes how CoreAudio internally wires the aggregate device. The aggregate device creation dictionary is identical for both modes -- same sub-device list, same tap list, same main sub-device key. The only difference is in the `CATapDescription` properties. Yet in bundle-ID mode, output buffers are allocated and written to but never reach hardware.

### 2. PID-Only Failure on macOS 26

Chromium-based browsers (Brave, Chrome) use a multi-process audio architecture on macOS 26. The PID visible to `NSRunningApplication` is the main UI process, but audio output comes from a separate renderer process. PID-based taps target the wrong PID. The `bundleIDs` API solves this by matching all processes sharing a bundle ID.

### 3. `shouldConfirmPermission` Gap

The original implementation checked `outputWritten > 0` but not `lastOutputPeak > 0`. This allowed promotion to `.mutedWhenTapped` when the output path was dead -- the buffers existed and were written to, but the audio never reached hardware. The fix adds an output peak check with a volume-awareness exception (zero volume legitimately produces zero output peak).

### 4. Four-Flag Matrix

The untested combination -- `bundleIDs` set, `isProcessRestoreEnabled` not set -- is the critical test. If output works with that configuration, `isProcessRestoreEnabled` is the sole culprit and the fix is a one-line removal.

### 5. macOS 26.0 vs 26.1 Distinction

Rogue Amoeba documented multiple audio bugs in macOS 26.0 (sample rate mismatch silence, communication app audio loss, Safari 44.1kHz skipping), all fixed in 26.1. Testing on 26.1+ may change the behavior.

## Recommended Action Plan

1. **Remove `isProcessRestoreEnabled`** -- Keep `bundleIDs`, drop `isProcessRestoreEnabled = true`. FineTune's `AudioProcessMonitor` already handles process lifecycle. (5 minutes)
2. **Test the four-flag matrix** -- If step 1 fails, isolate which flag combination breaks output.
3. **Decoupled capture/output** -- If `bundleIDs` itself is the problem, split into a bundle-ID tap in a tap-only aggregate (capture) and a separate IOProc on the real device (playback), connected via a lock-free ring buffer. (1-2 days)
4. **Safety net fixes** -- Fix `shouldConfirmPermission` to require `outPeak > 0` (with volume awareness). Add aggregate device stream topology logging. Add `FineTuneDisableBundleIDTaps` defaults key as escape hatch.

## Outcomes

- Comprehensive investigation report written to `docs/investigation/macos26-audio-routing-investigation.md`
- `shouldConfirmPermission` updated with output peak check and volume-awareness exception
- `FineTuneDisableBundleIDTaps` defaults key added alongside existing `FineTuneForcePIDOnlyTaps`
- Test plan designed: 15 tests across 4 files covering dead-output detection, diagnostic patterns, flag matrix, and safety nets

## Key Code Locations

| File | Line | What |
|------|------|------|
| `ProcessTapController.swift` | 280 | `makeTapDescription()` -- bundle-ID toggle |
| `ProcessTapController.swift` | 287-293 | `bundleIDs` + `isProcessRestoreEnabled` conditional |
| `AudioEngine.swift` | 143 | `shouldConfirmPermission()` -- output peak + volume check |
| `TapAPITestRunner.swift` | ~361 | Test C -- bundle-ID tap (tests creation, not audio flow) |
| `TapDiagnostics.swift` | -- | 19-field diagnostic snapshot struct |

## External References

- [Rogue Amoeba: macOS 26 Audio Bug Fixes](https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/)
- [Rogue Amoeba: SoundSource macOS 26 Troubleshooting](https://rogueamoeba.com/support/knowledgebase/?showArticle=Troubleshooting-MacOS-26-Tahoe&product=SoundSource)
- [Apple: Capturing System Audio with Core Audio Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple: CATapDescription.isProcessRestoreEnabled](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled)
- [Core Audio Tap API Example (Gist)](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f)
- [AudioTee](https://github.com/makeusabrew/audiotee)

---

## Implementation Status (as of 2026-02-08)

| Recommendation | Status | Notes |
|----------------|--------|-------|
| **1. Remove `isProcessRestoreEnabled`** | **DONE** | `makeTapDescription()` now sets `bundleIDs` without `isProcessRestoreEnabled`. Tested with real audio — both capture and output work. |
| **2. Test four-flag matrix** | **DONE** | Test C (bundleIDs=yes, isProcessRestoreEnabled=no) confirmed: `inPeak=0.048, outPeak=0.043` — both capture and output working. `isProcessRestoreEnabled` was the sole culprit. |
| **3. Decoupled capture/output** | NOT NEEDED | The fix in #1 resolves the issue without architectural changes. |
| **4a. `shouldConfirmPermission` output peak check** | DONE | `AudioEngine.swift:147-162` now requires `lastOutputPeak > 0.0001` when `volume > 0.01`. |
| **4b. `FineTuneDisableBundleIDTaps` defaults key** | DONE | `ProcessTapController.swift` checks this key as escape hatch. |
| **4c. Aggregate device stream topology logging** | PARTIAL | `TapDiagnostics` provides 19-field diagnostic snapshots. |

### Summary

**Investigation complete.** `isProcessRestoreEnabled` was confirmed as the sole cause of dead aggregate output on macOS 26. The fix (setting `bundleIDs` without `isProcessRestoreEnabled`) is applied in `ProcessTapController.swift:makeTapDescription()`. All safety nets remain in place.

**Crossfade disconnection bug (mitigated):** Bundle-ID taps can lose their connection to the app after crossfade device switching. During crossfade, two taps claim the same `bundleIDs`, and CoreAudio may stop delivering audio to the surviving tap. Mitigated by adding health check Case 3 (`checkTapHealth()` in `AudioEngine.swift`) — detects frozen `inputHasData` within 10 seconds of crossfade completion and triggers tap recreation. Recovery time: ~3-6 seconds (one health check cycle).
