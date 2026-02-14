You are a **Staff macOS Audio Engineer** with deep expertise in CoreAudio HAL, process taps, aggregate devices, and real-time audio routing on macOS 26 (Tahoe). You are debugging a critical audio routing failure.

## Problem Description

**FineTune** is a macOS menu bar app that provides per-application volume control, EQ, and device routing using CoreAudio process taps. It captures audio from individual apps via `CATapDescription` + `AudioHardwareCreateProcessTap`, routes it through an aggregate device with an IOProc callback (gain, EQ, format conversion), and outputs to the user's selected device.

On **macOS 26 (Tahoe)**, two complementary failure modes make the app non-functional for Chromium-based browsers (Brave, Chrome):

### Failure Mode 1: Bundle-ID Tap (capture works, output dead)

When using the macOS 26 `bundleIDs` + `isProcessRestoreEnabled` API on `CATapDescription`:
- **Capture succeeds**: `inPeak > 0`, `inputHasData > 0` — the IOProc receives real audio samples from the process
- **Output is dead**: `outPeak = 0.000` — writing to the aggregate device's output buffers produces no audible sound
- With `.unmuted` taps, user hears audio (original stream plays through). With `.mutedWhenTapped`, original is silenced and the dead output path = silence.

Evidence:
```
callbacks=57  input=35  output=57  inPeak=0.044  outPeak=0.000
callbacks=356 input=183 output=356 inPeak=0.060  outPeak=0.000
```

### Failure Mode 2: PID-only Tap (output works, capture dead)

Legacy PID-only taps (no `bundleIDs`, no `isProcessRestoreEnabled`):
- **Capture dead**: `input=0` across 11,864 callbacks — IOProc fires but receives no audio from the process
- **Output path healthy**: `outBuf=1x4096B` — output buffer structure is valid

Evidence:
```
callbacks=244   input=0  output=244   inPeak=0.000 outPeak=0.000 outBuf=1x4096B
callbacks=11864 input=0  output=11864 inPeak=0.000 outPeak=0.000 outBuf=1x4096B
```

### The Paradox

**Neither mode fully works.** Bundle-ID is required for capture on macOS 26 (Chromium browsers), but it breaks the aggregate device's output path. PID-only has a working output path but can't capture.

## Observed Behavior

1. Bundle-ID taps: IOProc receives input audio samples (`Float32` with non-zero peaks), processes them correctly through gain/EQ/format conversion, writes them to output buffers — but no sound comes out of the speakers
2. PID-only taps: IOProc fires at expected rate, output buffers are correctly structured, but input buffers contain only silence (all zeros)
3. The aggregate device is configured identically in both cases (same `kAudioAggregateDevice*` keys, same sub-device, same tap list)
4. The only difference is whether `CATapDescription.bundleIDs` and `.isProcessRestoreEnabled` are set

## Expected Behavior

Audio captured from the process should flow through the IOProc, get written to output buffers, and play through the aggregate device's sub-device (the user's output device).

## What's Been Tried

1. Confirmed volume/mute state is not the issue (`silMute=0`, `vol=1.00`, device volume=1.0)
2. Added `outBuf=NxMB` diagnostics to verify output buffer structure is valid
3. Fixed `outPeak` tracking (was being overwritten to 0 by empty callbacks)
4. Verified the same aggregate device configuration works with PID-only taps (output is audible when input has data)
5. `FineTuneForcePIDOnlyTaps` UserDefaults key exists but is NOT a valid workaround (PID-only can't capture on macOS 26)

## Key Code Locations

- **Tap creation with bundle-ID flag**: `ProcessTapController.swift` lines 280-295 (`makeTapDescription()`)
- **Aggregate device creation**: `ProcessTapController.swift` lines 389-407 (`activate()`)
- **IOProc callback (primary)**: `ProcessTapController.swift` lines 1107-1256 (`processAudio()`)
- **Permission confirmation logic**: `AudioEngine.swift` lines 140-144 (`shouldConfirmPermission()`)
- **Known issue writeup**: `bundle-id-tap-silent-output-macos26.md`

## Relevant Files

See `MANIFEST.md` in the uploaded context for file listing and architecture overview.

## Investigation Questions

1. **Is `isProcessRestoreEnabled` changing the aggregate device topology?** Do bundle-ID taps create aggregates with a different stream configuration (e.g., different output stream count or format) than PID-only taps?

2. **Is there a known macOS 26 bug with `isProcessRestoreEnabled` + aggregate device output?** This API is new and sparsely documented.

3. **Should we try `bundleIDs` WITHOUT `isProcessRestoreEnabled`?** The two flags are currently set together (line 289-290). Isolating them could reveal which one breaks output.

4. **Is the aggregate device's output sub-device actually receiving the IOProc's output?** Could the aggregate be routing output to a different stream than expected?

5. **Are there alternative architectures that avoid this issue?** For example:
   - Tap-only aggregates (no sub-device) — tested in `TapAPITestRunner` Test B
   - Using `AudioUnit` render callbacks instead of IOProc
   - Using `AVAudioEngine` with tap nodes
   - Separate capture tap + output device (not aggregated)

6. **What are open-source macOS audio routing apps doing on macOS 26?** Check projects like:
   - **BackgroundMusic** (github.com/kyleneideck/BackgroundMusic) — virtual audio device approach
   - **BlackHole** (github.com/ExistentialAudio/BlackHole) — virtual audio driver
   - **eqMac** (github.com/bitgapp/eqMac) — system-wide EQ with audio routing
   - **SoundSource** by Rogue Amoeba (commercial, but their blog posts discuss CoreAudio internals)
   - Any other projects using `CATapDescription` / process taps on macOS 14+

   How are they handling per-app audio capture and output on Tahoe? Are they hitting the same bundle-ID tap issue? What aggregate device configurations are they using?

## Deliverables

1. **Root Cause Analysis**: What's causing the aggregate device output to be dead when bundle-ID flags are set on the tap? Is this a macOS 26 bug or a configuration issue?
2. **Evidence**: Specific `file:line` references supporting your analysis
3. **Fix Recommendation**: Concrete code changes to resolve the issue — or a workaround architecture if this is an Apple bug
4. **Architecture Alternatives**: If the current aggregate-device approach is fundamentally broken on macOS 26 with bundle-ID taps, what architecture should we migrate to? Consider what open-source projects are doing.
5. **Prevention**: How to make the permission confirmation logic (`shouldConfirmPermission`) safe against dead output paths — it currently allows promotion to `.mutedWhenTapped` even when output is broken

## Constraints

- **macOS 26 (Tahoe) only** — we do NOT need backwards compatibility with older macOS versions
- **Per-app audio control is required** — system-wide approaches (virtual audio device) are insufficient
- **Real-time safety** — the IOProc callback runs on CoreAudio's HAL I/O thread, no locks/allocations allowed
- **Big changes are acceptable** — we're willing to rearchitect the audio pipeline if needed

---

## Response Guidelines

- **Cite file paths**: Reference specific `file:line` locations
- **Be concrete**: Provide actual code snippets for fixes, not just descriptions
- **Prioritize**: Start with most critical issues
- **No preamble**: Skip "Great question!" — go straight to analysis
- **Correctness per token**: Every sentence should add value
- **Check open source**: Investigate how BackgroundMusic, eqMac, BlackHole, and other macOS audio tools handle this on macOS 26
