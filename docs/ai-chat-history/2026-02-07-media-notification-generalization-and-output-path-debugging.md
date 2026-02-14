# Media Notification Generalization + Output Path Silence Debugging

**Date:** 2026-02-07
**Session type:** Feature implementation + bug investigation + diagnostics improvement

---

## Summary

This session had three phases:
1. Generalized `MediaNotificationMonitor` from Spotify-only to table-driven multi-app support (Spotify + Apple Music)
2. Discovered and diagnosed a silence bug: aggregate device output path produces no audible audio, masked by `.unmuted` tap mode
3. Added diagnostics improvements and an A/B test toggle that confirmed bundle-ID tap mode (macOS 26) as the culprit

---

## Phase 1: MediaNotificationMonitor Generalization

### What was done

**File:** `FineTune/Audio/MediaNotificationMonitor.swift`

Replaced Spotify-only hardcoded notification monitoring with a table-driven approach supporting multiple media apps.

#### Changes:
- **Added `monitoredApps` static table** — array of tuples `(notificationName, bundleID, stateKey, playingValue)` covering:
  - Spotify: `com.spotify.client.PlaybackStateChanged`
  - Apple Music: `com.apple.Music.playerInfo`
- **Replaced `observer: NSObjectProtocol?` with `observers: [NSObjectProtocol]`** — supports multiple observers
- **`start()` loops over the table** — creates one `DistributedNotificationCenter` observer per entry
- **Replaced `handleSpotifyNotification` with `handlePlaybackNotification`** — generic handler parameterized by `bundleID`, `stateKey`, and `playingValue`
- **Updated `stop()` and `deinit`** — remove all observers from array
- **Updated log message** — logs all monitored bundle IDs instead of just "Spotify"

No other files changed. `AudioEngine.swift` already consumes `onPlaybackStateChanged` generically via PID.

### Why this matters
Instant play/pause detection via `DistributedNotificationCenter` provides near-zero-latency UI updates compared to VU-level detection (1.5s hysteresis). Browsers (Chrome, Safari, Brave, Firefox) and VLC do NOT post distributed notifications — they stay on VU-level detection.

---

## Phase 2: Silence Bug Discovery

### Symptom
After launching FineTune and playing audio in Brave Browser:
- With `.unmuted` taps (before permission confirmation): audio plays normally
- After `.mutedWhenTapped` upgrade: **complete silence from Brave**

### Root cause analysis

The investigation revealed a chain of issues:

1. **`outPeak=0.000` across the entire session** — even before permission flip. The aggregate device output path was never producing audible audio. `.unmuted` mode masked this because the original audio stream plays through directly.

2. **Diagnostic false positive in `outPeak`** — `_diagLastInputPeak` uses retain-non-zero semantics (only updated when `rawPeak > 0`), but `_diagLastOutputPeak` used last-write-wins (overwritten every callback, including zero-data ones). With ~40% of callbacks having empty audio, the last callback before diagnostic read was often zero.

3. **`outputWritten` is a false positive for health** — `_diagOutputWritten` is incremented when the code path runs, not when actual non-zero audio frames are written to the output buffer. `shouldConfirmPermission()` uses `outputWritten > 0` as part of its health check, so it false-positives into promoting to `.mutedWhenTapped`.

4. **Bundle-ID tap mode (macOS 26) suspected as culprit** — GPT analysis suggested the `bundleIDs` + `isProcessRestoreEnabled` path added for macOS 26 may produce aggregate devices with non-functional output. A/B test with PID-only taps confirmed this: **PID-only mode restores working audio**.

### External analysis (GPT findings on prior refactor)

Two additional code quality issues identified (not the direct trigger for this session's silence, but real risks):

- **P1: Recreation state sequencing race** — `handleServiceRestarted()` calls `upgradeTapsToMutedWhenTapped()`. If any tap fails, it calls `recreateAllTaps()` (fire-and-forget Task). The restart flow then immediately clears recreation state, which can re-enable notifications before recreation finishes.

- **P2: Live mute upgrade only updates primary tap** — `updateMuteBehavior()` uses `primaryResources` only. If permission confirmation occurs during crossfade, a secondary tap keeps old `.unmuted` behavior and later gets promoted to primary.

---

## Phase 3: Changes Implemented

### 1. Diagnostic: `outPeak` retain-non-zero (ProcessTapController.swift)

Changed all 4 sites where `_diagLastOutputPeak` / `_diagSecondaryLastOutputPeak` is written to only update when `peak > 0`, matching `_diagLastInputPeak` semantics:

```swift
// Before:
_diagLastOutputPeak = computeOutputPeak(outputBuffers)

// After:
let outPeak = computeOutputPeak(outputBuffers)
if outPeak > 0 { _diagLastOutputPeak = outPeak }
```

### 2. Diagnostic: Output buffer metadata (ProcessTapController.swift, TapDiagnostics.swift, AudioEngine.swift)

Added two new diagnostic counters recorded every callback in `processAudio`:
- `_diagOutputBufCount` — `outputBuffers.count`
- `_diagOutputBuf0ByteSize` — `outputBuffers[0].mDataByteSize`

These appear in DIAG logs as `outBuf=NxMB` (e.g., `outBuf=1x4096B` = 1 buffer, 4096 bytes).

If this shows `outBuf=0x0B` or `outBuf=1x0B`, it confirms the aggregate device is giving the IOProc empty output buffers.

### 3. A/B test toggle: PID-only tap mode (ProcessTapController.swift)

Added `FineTuneForcePIDOnlyTaps` UserDefaults key that skips the macOS 26 `bundleIDs` + `isProcessRestoreEnabled` path:

```swift
if #available(macOS 26.0, *), let bundleID = app.bundleID,
   !UserDefaults.standard.bool(forKey: "FineTuneForcePIDOnlyTaps") {
```

Toggle via:
```bash
defaults write com.finetuneapp.FineTune FineTuneForcePIDOnlyTaps -bool true   # PID-only
defaults delete com.finetuneapp.FineTune FineTuneForcePIDOnlyTaps              # bundle-ID (default)
```

**Status: NOT currently active.** See Phase 4 below for why this is not a valid workaround.

---

## Phase 4: A/B Test Result — PID-Only Was a False Positive

### What happened

After enabling PID-only mode and relaunching, the user reported "that's working." However, follow-up logging revealed the truth:

**PID-only mode log:**
```
callbacks=11864 input=0 output=11864 inPeak=0.000 outPeak=0.000 outBuf=1x4096B
```

- `input=0` across 11,864 callbacks — **PID-only taps cannot capture Brave audio on macOS 26**
- `outBuf=1x4096B` — output buffers exist and are healthy, but contain only zeros (nothing to output)
- Permission never upgraded to `.mutedWhenTapped` because `shouldConfirmPermission` requires `inputHasData > 0`
- User heard Brave's original audio playing through (`.unmuted` never silences it)

### Corrected understanding

| Mode | Input (capture) | Output (playback) |
|------|----------------|-------------------|
| Bundle-ID tap | **Works** (`input > 0`, `inPeak > 0`) | **Dead** (`outPeak=0.000`, silence when `.mutedWhenTapped`) |
| PID-only tap | **Dead** (`input=0`, can't capture Brave) | **Works** (`outBuf=1x4096B`, healthy buffers) |

**Neither mode fully works.** Bundle-ID is required for capture on macOS 26, but breaks the aggregate output. PID-only has healthy output buffers but can't capture. The `FineTuneForcePIDOnlyTaps` workaround was removed.

---

## Files Modified

| File | Changes |
|------|---------|
| `FineTune/Audio/MediaNotificationMonitor.swift` | Table-driven multi-app notification monitoring (Spotify + Apple Music) |
| `FineTune/Audio/ProcessTapController.swift` | outPeak retain-non-zero fix, output buffer metadata diagnostics, PID-only toggle |
| `FineTune/Audio/Tap/TapDiagnostics.swift` | Added `outputBufCount` and `outputBuf0ByteSize` fields |
| `FineTune/Audio/AudioEngine.swift` | Added `outBuf=NxMB` to DIAG log format |

---

## TODO List / Handoff

### Must Do (blocking)

- [ ] **Fix bundle-ID tap aggregate output** — Bundle-ID taps are REQUIRED for capture on macOS 26 (PID-only can't capture Brave), but their aggregate device output is dead. This is the central blocking issue. Investigation plan:
  1. Test with `bundleIDs` set but `isProcessRestoreEnabled = false` — isolate which flag breaks output
  2. Test with `isProcessRestoreEnabled = true` but no `bundleIDs` — isolate further
  3. Dump and compare aggregate device properties (stream count, format, active output streams) between bundle-ID and PID-only modes
  4. Check Apple developer forums / file Feedback Assistant if this is a macOS 26 beta bug
- [ ] **Fix `shouldConfirmPermission` false positive** — `outputWritten > 0` doesn't mean real audio data was written. Should require `outPeak > 0` (now retain-non-zero) to confirm actual output. Without this fix, permission can promote to `.mutedWhenTapped` even when the output path is dead — this is the mechanism that exposes the silence.

### Should Do (code quality)

- [ ] **Fix P1: Recreation state sequencing race** — `handleServiceRestarted()` at AudioEngine.swift clears `isRecreatingTaps` synchronously, but `recreateAllTaps()` (the fallback path in `upgradeTapsToMutedWhenTapped`) runs as a fire-and-forget Task. Notifications can re-enable before recreation finishes. Fix: await recreation completion before clearing state.
- [ ] **Fix P2: Secondary tap mute behavior during crossfade** — `updateMuteBehavior()` only updates `primaryResources.tapID`. If permission is confirmed during an active crossfade, the secondary tap retains `.unmuted` and gets promoted with wrong mute behavior. Fix: also update secondary tap if `secondaryResources.tapID.isValid`.
- [ ] **Verify Apple Music notification path** — The generalized `MediaNotificationMonitor` now registers for `com.apple.Music.playerInfo`, but this was not tested in this session. Need to confirm: correct notification name, `userInfo` key, and PID resolution via `com.apple.Music` bundle ID.

### Nice to Have

- [ ] **Add `outPeak` to HEALTH-FAST log** — Currently only DIAG logs show `outPeak`. Adding it to the fast health checks would give earlier signal during permission confirmation.
- [ ] **Consider adding `outBuf` check to health/broken-tap detection** — If `outBuf=0x0B` persists, the tap should be considered broken and recreated, rather than waiting for the current broken-tap heuristic (`callbackCount > 10 && outputWritten == 0`).
- [ ] **Clean up `FineTuneForcePIDOnlyTaps` toggle** — Keep for future debugging but document clearly that it's diagnostic-only, not a workaround.

---

## Known Issues (as of end of session)

1. **Bundle-ID tap aggregate output is dead on macOS 26** — `bundleIDs` + `isProcessRestoreEnabled` creates taps that successfully capture audio, but the aggregate device output doesn't reach the physical device. PID-only taps have healthy output but can't capture. **No workaround exists** — the issue manifests as silence when `.mutedWhenTapped` activates. See `docs/known_issues/bundle-id-tap-silent-output-macos26.md`.

2. **`shouldConfirmPermission` can false-positive** — Uses `outputWritten > 0` which just means the code path executed, not that real audio was produced. Can promote to `.mutedWhenTapped` and expose the dead output path.

3. **Recreation state race in `handleServiceRestarted`** — P1 from GPT analysis. The fallback `recreateAllTaps()` is async but state is cleared synchronously.

4. **Secondary tap keeps old mute behavior during crossfade** — P2 from GPT analysis. `updateMuteBehavior()` only touches primary tap.

5. **`outPeak` diagnostic was previously unreliable** — Fixed in this session to retain-non-zero, but historical diagnostic data showing `outPeak=0.000` is untrustworthy.
