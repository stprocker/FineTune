# Chat Log: Device Routing Bugs, AirPods Silence, and TDD

**Date:** 2026-02-05
**Topic:** Debugging device routing desync, AirPods silence, and writing tests

---

## Summary

This session investigated and fixed multiple device routing bugs where FineTune's UI/state diverged from actual audio routing. The user reported that Brave showed MacBook Pro Speakers in the per-app picker while audio was actually playing through AirPods, and later that FineTune was intercepting/stopping sound entirely with AirPods — closing FineTune restored audio. Four state management bugs were identified and fixed, diagnostic instrumentation was added, and comprehensive tests were written using a TDD-after approach.

---

## Timeline

### Phase 1: Initial Investigation
- **User question:** "does this program handle input devices?"
- **Answer:** No. `AudioDeviceMonitor` filters with `guard deviceID.hasOutputStreams() else { continue }` — only output devices (speakers, headphones, AirPods).

### Phase 2: UI/Audio Routing Mismatch
- **User report:** Brave showing MacBook Pro Speakers selected, but audio playing through AirPods (which was the system default).
- **Root cause investigation:** Traced `AudioEngine.setDevice()` → `ProcessTapController.switchDevice()` flow.
- **Found Bug 1:** `setDevice()` optimistically updates `appDeviceRouting[app.id]` before async `switchDevice()` completes. If `switchDevice()` throws, routing state is never reverted. The guard `appDeviceRouting[app.id] != deviceUID` also prevents retry since the stale state matches.

### Phase 3: Sound Interception (AirPods Silence)
- **User report:** "It seems to be stopping/intercepting the system sound. It either doesn't work or is slow."
- **Deep investigation** of entire device switching pipeline across 15+ files.
- **Found Bugs 2-4** (see Bugs Fixed section below).
- Applied all four fixes. Build succeeded.

### Phase 4: Fundamental Issue Persists
- **User report:** "sound is still being intercepted. When the app was running, it showed airpods connected... But no sound. Closed program, then sound came back."
- **Comprehensive code review** of format conversion pipeline: AudioFormatConverter, GainProcessor, AudioBufferProcessor, TapFormat, all extensions.
- **Processing code is correct.** No bugs found in the audio pipeline itself.
- **Theory developed:** The process tap with `muteBehavior: .mutedWhenTapped` immediately mutes the app's audio. The aggregate device with Bluetooth sub-device (AirPods) may need startup time that `activate()` doesn't account for. The crossfade path has 500ms BT warmup, but initial activation has zero warmup. If the aggregate device IO callback never fires, audio is muted with no output path.
- **Key diagnostic:** Check VU meter — if bars move, IO callback works; if dead, aggregate never started.

### Phase 5: Diagnostic Instrumentation (Committed as 1.14)
- Added `TapDiagnostics` struct and RT-safe counters to ProcessTapController
- Added 5-second diagnostic timer to AudioEngine that logs callback counts, format info, peak levels
- Added `DeviceVolumeMonitor` logging and `AudioDeviceMonitor` device disconnect handling
- These help diagnose whether the IO callback is firing at all

### Phase 6: TDD Tests
- **User request:** "Build failing tests to confirm, no?"
- Wrote **CrossfadeStateTests.swift** (31 tests) — pure state machine validation:
  - Warmup detection (Bug 2 foundation): `isWarmupComplete` correctly identifies when secondary tap hasn't processed enough samples
  - Equal-power conservation: `primary^2 + secondary^2 ≈ 1.0`
  - Dead-zone behavior: `primaryMultiplier` returns 0.0 when `isActive=false && progress >= 1.0`
  - Progress tracking, lifecycle, config
- Wrote **AudioEngineRoutingTests.swift** (5 tests) — integration tests:
  - Bug 3 revert: `setDevice` correctly reverts `appDeviceRouting` when tap creation fails
  - Independent per-app routing isolation
  - Multiple failure revert safety
- **All 36 tests pass.**

### Phase 7: Sample Rate Fix (Uncommitted)
- Discovered that `activate()` and `createSecondaryTap()` used the tap's sample rate for the aggregate device. Process taps may report the app's internal rate (e.g., Chromium uses 24000 Hz) which the output device may not support (e.g., AirPods require 48000 Hz).
- Changed to use the OUTPUT DEVICE sample rate for the aggregate. CoreAudio's drift compensation on the tap sub-device handles resampling.
- This fix is **uncommitted** in `ProcessTapController.swift`.

---

## Bugs Fixed

### Bug 1: setDevice async failure doesn't revert routing
**File:** `AudioEngine.swift:172-215` (committed in 1.13)
**Problem:** `appDeviceRouting[app.id]` updated optimistically before async `tap.switchDevice(to:)`. On failure, never reverted. Also prevents retry (guard short-circuits).
**Fix:** Capture `previousDeviceUID`, revert in catch block.

### Bug 2: Crossfade promotes non-functioning secondary tap
**File:** `ProcessTapController.swift:442-447` (committed in 1.13)
**Problem:** After polling timeout in `performCrossfadeSwitch`, primary tap was destroyed and secondary promoted regardless of whether secondary produced audio. If BT device wasn't ready, result is silence.
**Fix:** Check `crossfadeState.isWarmupComplete` after polling loop. If incomplete, throw to trigger destructive fallback.

### Bug 3: setDevice else-branch doesn't revert on tap failure
**File:** `AudioEngine.swift:201-214` (committed in 1.13)
**Problem:** When no existing tap and `ensureTapExists` fails, `appDeviceRouting[app.id]` left pointing at non-functional device.
**Fix:** Check `taps[app.id] == nil` after `ensureTapExists`, revert to `previousDeviceUID` or remove key.

### Bug 4: applyPersistedSettings leaves stale routing
**File:** `AudioEngine.swift:276-280` (committed in 1.13)
**Problem:** `appDeviceRouting[app.id]` set before `ensureTapExists`, left stale if tap creation fails.
**Fix:** `appDeviceRouting.removeValue(forKey: app.id)` when `taps[app.id] == nil`.

### Sample Rate Fix (uncommitted)
**File:** `ProcessTapController.swift` — `activate()` and `createSecondaryTap()`
**Problem:** Aggregate device sample rate set to tap's rate, which may differ from output device's supported rate (e.g., Chromium 24kHz tap → AirPods 48kHz device).
**Fix:** Use `fallbackSampleRate` (from output device stream format) for aggregate, not `primaryFormat?.sampleRate`.

---

## Files Modified

| File | Commit | Changes |
|------|--------|---------|
| `AudioEngine.swift` | 1.13 | Bug 1, 3, 4 routing revert fixes |
| `AudioEngine.swift` | 1.14 | Diagnostic timer, `logDiagnostics()` |
| `ProcessTapController.swift` | 1.13 | Bug 2 warmup check in crossfade |
| `ProcessTapController.swift` | 1.14 | `TapDiagnostics` struct + RT-safe counters in callbacks |
| `ProcessTapController.swift` | **uncommitted** | Sample rate fix: use device rate for aggregate |
| `AudioDeviceMonitor.swift` | 1.14 | Device disconnect handling |
| `DeviceVolumeMonitor.swift` | 1.14 | Enhanced logging |
| `AudioDeviceID+Volume.swift` | 1.14 | Volume read helper |
| `MenuBarPopupView.swift` | 1.14 | Simplified device display |
| `DeviceRow.swift` | 1.14 | UI tweak |

## Files Created (local only, gitignored)

| File | Tests | Purpose |
|------|-------|---------|
| `FineTuneTests/CrossfadeStateTests.swift` | 31 | CrossfadeState state machine validation |
| `FineTuneTests/AudioEngineRoutingTests.swift` | 5 | Routing revert on tap creation failure |

---

## Architecture Notes

### Audio Pipeline
```
App Audio → CATapDescription (muteBehavior: .mutedWhenTapped)
         → Process Tap (intercepts audio, mutes original)
         → Aggregate Device (tap + output sub-device)
         → IO Proc Callback (processAudio)
             → Format conversion (if needed)
             → Gain processing (volume ramp + crossfade multiplier + soft limiting)
             → EQ processing (biquad filters)
         → Output Device (speakers/AirPods/etc.)
```

### Key Classes
- **AudioEngine** (`@MainActor`): Orchestrates taps, routing, settings. Owns `appDeviceRouting` dictionary.
- **ProcessTapController**: One per app. Creates tap + aggregate + IO proc. Manages crossfade.
- **CrossfadeState**: RT-safe struct. Lock-free. Drives equal-power crossfade via sample counting.
- **SettingsManager** (`@MainActor`): Persists routing, volume, mute, EQ to JSON. Accepts `directory:` for testing.

### Testing Constraints
- `FineTuneTests/` is **gitignored** (`.gitignore` line 16: `FineTuneTests/`)
- Project uses `PBXFileSystemSynchronizedRootGroup` — new `.swift` files in `FineTuneTests/` auto-included in Xcode
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set on the app target only, not the test target
- No protocols exist for ProcessTapController or SettingsManager — mocking requires protocol extraction
- AudioEngine integration tests work because CoreAudio tap creation fails in test env (no real audio), triggering revert paths

---

## TODO List

### Critical (Sound Interception Issue)
- [ ] **Diagnose whether IO callback fires on AirPods aggregate:** Run the app with AirPods, check diagnostic logs. If `callbacks=0` after 5 seconds, the aggregate device never started. If callbacks > 0 but `outPeak=0.000`, the pipeline isn't producing output.
- [ ] **Add Bluetooth warmup delay to initial `activate()`:** Crossfade path has 500ms BT warmup; initial activation has zero. After `AudioDeviceStart()`, poll for first callback before considering activation complete. This may require making `activate()` async.
- [ ] **Commit the sample rate fix** in ProcessTapController.swift (currently uncommitted). This ensures aggregate devices use the output device's native rate, not the tap's potentially incompatible rate.
- [ ] **Test with AirPods after sample rate fix:** The 24kHz-to-48kHz mismatch may have been the actual cause of the silence.

### Important (Reliability)
- [ ] **Add format mismatch recovery:** If the aggregate device and tap have incompatible formats, log clearly and consider fallback to destructive switch rather than silently failing.
- [ ] **Monitor aggregate device `kAudioDevicePropertyDeviceIsRunning`:** After `AudioDeviceStart()`, verify the device actually transitions to running state. If it doesn't within a timeout, tear down and retry.
- [ ] **Add VU meter check for silence detection:** If VU meter shows zero for > 2 seconds while `appDeviceRouting` claims a device is active, log a warning and consider re-creating the tap.

### Testing
- [ ] **Un-gitignore `FineTuneTests/`** when ready to include tests in the repo
- [ ] **Extract protocols for AudioEngine unit testing:** Create `TapControlling` protocol for ProcessTapController to enable mock injection. This would allow testing Bug 1 (async switchDevice failure) and Bug 4 (applyPersistedSettings with known apps).
- [ ] **Add integration test for crossfade warmup timeout:** Requires mock that simulates a secondary tap that never produces audio.
- [ ] **Add test for handleDeviceDisconnected:** Verify routing falls back correctly when a device disappears.

### Nice to Have
- [ ] **Remove diagnostic timer before release:** The 5-second diagnostic logging (commit 1.14) is for debugging; should be removed or gated behind a debug flag for production.
- [ ] **Consider `activate()` → async with BT detection:** Read `transportType` before activation. If BT, add warmup delay and verify IO callback fires.
- [ ] **Add telemetry for aggregate device startup time:** Measure time from `AudioDeviceStart()` to first IO callback to understand real-world BT latency.

---

## Known Issues

1. **AirPods silence on initial activation** — The fundamental issue. Process tap mutes app audio immediately, but aggregate device with BT sub-device may not start outputting in time (or at all). Closing FineTune releases the tap and restores audio. Diagnostic instrumentation added in 1.14 to help isolate.

2. **Sample rate mismatch** — Uncommitted fix addresses tap-vs-device sample rate mismatch. May be the root cause of #1 for apps like Chromium that use non-standard internal sample rates.

3. **Test files are gitignored** — 36 passing tests exist locally but won't be committed until `FineTuneTests/` is removed from `.gitignore`.

4. **No mock infrastructure** — AudioEngine and ProcessTapController are tightly coupled. Bug 1 (async revert) and Bug 4 (applyPersistedSettings) can't be fully unit-tested without protocol extraction.

5. **Diagnostic timer runs in production** — The 5-second log timer from 1.14 should be gated or removed before release.

---

## Commits Made This Session

| Hash | Message | Key Changes |
|------|---------|-------------|
| `a4c0f94` | 1.13 (bugs) | Bug 1-4 fixes: routing revert in setDevice, warmup check in crossfade, stale routing cleanup |
| `cc13bb3` | 1.14 | Diagnostic instrumentation: TapDiagnostics, callback counters, 5-sec timer, device disconnect handling |

## Uncommitted Changes

- `ProcessTapController.swift` — Sample rate fix: use output device rate for aggregate instead of tap rate
- `FineTuneTests/CrossfadeStateTests.swift` — 31 crossfade state machine tests (gitignored)
- `FineTuneTests/AudioEngineRoutingTests.swift` — 5 routing revert tests (gitignored)
