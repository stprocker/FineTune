# Cut the Fat — Dead Code Removal, Deduplication & Cleanup

**Date:** 2026-02-08
**Session type:** Implementation (systematic cleanup plan)
**Branch:** main

---

## Summary

Executed a comprehensive "Cut the Fat" cleanup plan across the FineTune codebase. Deleted dead files, removed stale aliases, extracted duplicated patterns into helpers, consolidated mirrored input/output methods via a `DeviceScope` enum, simplified state mutation with a closure-based helper, added missing error logging, and removed an unnecessary computed property. All changes verified with SPM build, Xcode build, and full test suite (290 tests, 0 new failures).

---

## What Was Done

### Step 1: Deleted Dead Files

- Deleted `FineTune/Audio/SystemSoundsDeviceChanges.swift` -- a 200-line commented-out integration guide; all code already lives in DeviceVolumeMonitor.swift. Confirmed not referenced in pbxproj.
- Deleted `INTEGRATION_PLAN.md` -- stale planning doc from completed feature integration.

### Step 2: Removed `coreAudioListenerQueue` Aliases (3 files)

Replaced the module-level alias `private let coreAudioListenerQueue = CoreAudioQueues.listenerQueue` with direct `CoreAudioQueues.listenerQueue` usage in:

| File | Detail |
|------|--------|
| `FineTune/Audio/DeviceVolumeMonitor.swift` | Removed alias + stale comment on lines 6-7, replaced ~15 usages |
| `FineTune/Audio/AudioDeviceMonitor.swift` | Removed alias + comment on lines 7-8, replaced ~5 usages |
| `FineTune/Audio/AudioProcessMonitor.swift` | Removed alias + comment on lines 6-7, replaced ~5 usages |

### Steps 3-4: Extracted Helpers in AudioEngine.swift

Added two private helpers to eliminate duplicated patterns:

1. **`teardownTap(for pid: pid_t)`** -- consolidates the 4-line tap invalidation pattern (invalidate, remove from taps dict, remove from appliedPIDs, remove from lastHealthSnapshots). Was duplicated 6+ times.

2. **`shouldAbandonRecreation(for pid: pid_t, appName: String) -> Bool`** -- consolidates the dead-tap recreation guard that increments counter, checks max, logs warning, and cleans up. Was duplicated in `checkTapHealth()` and `ensureTapExists()`.

Replaced all occurrences:

| Method | Usage |
|--------|-------|
| `checkTapHealth()` dead-tap guard | Uses `shouldAbandonRecreation` |
| `checkTapHealth()` teardown before recreation | Uses `teardownTap` |
| `ensureTapExists()` broken tap fast health check | Uses `teardownTap` |
| `ensureTapExists()` dead tap recreation guard | Uses `shouldAbandonRecreation` |
| `ensureTapExists()` rerouting to system default | Uses `teardownTap` |
| `ensureTapExists()` recreating in place | Uses `teardownTap` |

### Step 5: Consolidated DeviceVolumeMonitor Input/Output Methods

This was the biggest change -- parameterized duplicated input/output methods by a `DeviceScope` enum.

**Added:**

- `DeviceScope` enum with `.output` and `.input` cases
- `addListener(_:scope:for:)` -- merged `addDeviceListener` + `addInputDeviceListener`
- `removeListener(_:scope:for:)` -- merged `removeDeviceListener` + `removeInputDeviceListener`
- `refreshListeners(scope:)` -- merged `refreshDeviceListeners` + `refreshInputDeviceListeners`
- `readAllStates(scope:)` -- merged `readAllStates` + `readAllInputStates` (~120 lines of duplication eliminated)
- Helper methods: `listenerDict`, `setListener`, `removeListenerEntry`, `propertyAddress`

Updated all callers in `start()`, `stop()`, `handleServiceRestarted()`, `startObservingDeviceList()`, and `startObservingInputDeviceList()`.

Fixed `@escaping` annotation needed on `setListener` parameter for `AudioObjectPropertyListenerBlock`.

### Step 6: Extracted VolumeState Update Helper

Added `modifyState(for:identifier:update:persist:)` private helper to VolumeState.swift.

Rewrote 4 methods to use it:

| Method | Before | After |
|--------|--------|-------|
| `setVolume` | ~12 lines | ~4 lines |
| `setMute` | ~12 lines | ~4 lines |
| `setDeviceSelectionMode` | ~12 lines | ~3 lines |
| `setSelectedDeviceUIDs` | ~12 lines | ~3 lines |

### Step 7: Added Sparkle Error Logging

In `FineTune/Settings/UpdateManager.swift`, replaced:

```swift
try? updaterController.updater.start()
```

With proper error handling using `do/try/catch` and `NSLog` (kept minimal since UpdateManager doesn't have a Logger instance).

### Step 8: Removed `displayedApps` Computed Property

- Deleted the `displayedApps` computed property from `AudioEngine.swift`
- Updated `routeAllApps()` to use `lastDisplayedApp` directly instead of iterating `displayedApps`
- Updated 2 test methods in `AudioEngineRoutingTests.swift`:
  - `testDisplayedAppsFallsBackToLastActiveAppWhenPlaybackStops` renamed to `testPausedFallbackWhenPlaybackStops`, uses `engine.apps` and `isPausedDisplayApp` instead of `displayedApps`
  - `testDisplayedAppsPrefersCurrentActiveAppsOverPausedFallback` renamed to `testActiveAppsPrecedeOverPausedFallback`, same approach

---

## Files Modified

| File | Change |
|------|--------|
| `FineTune/Audio/SystemSoundsDeviceChanges.swift` | **DELETED** |
| `INTEGRATION_PLAN.md` | **DELETED** |
| `FineTune/Audio/DeviceVolumeMonitor.swift` | Removed alias, consolidated input/output methods via `DeviceScope` |
| `FineTune/Audio/AudioDeviceMonitor.swift` | Removed `coreAudioListenerQueue` alias |
| `FineTune/Audio/AudioProcessMonitor.swift` | Removed `coreAudioListenerQueue` alias |
| `FineTune/Audio/AudioEngine.swift` | Extracted `teardownTap`/`shouldAbandonRecreation` helpers, removed `displayedApps` |
| `FineTune/Models/VolumeState.swift` | Extracted `modifyState` helper |
| `FineTune/Settings/UpdateManager.swift` | Added error logging for Sparkle updater start |
| `testing/tests/AudioEngineRoutingTests.swift` | Updated tests for `displayedApps` removal |

---

## Verification Results

- **SPM build** (`swift build`): Clean -- no errors, no warnings in changed files
- **Xcode build** (`xcodebuild -scheme FineTune`): `BUILD SUCCEEDED`
- **Tests** (`swift test`): 290 tests, 19 failures (0 unexpected) -- all pre-existing failures in CrossfadeState, CrossfadeInterruption, and Startup tests, completely unrelated to our changes. Our 3 renamed/updated tests all pass.
- **Grep sanity checks:**
  - `coreAudioListenerQueue` in FineTune/ -- 0 hits
  - `SystemSoundsDeviceChanges` -- only CHANGELOG.md reference
  - `displayedApps` in FineTune/ -- 0 hits

---

## Known Issues / TODO for Follow-up

### Pre-existing Test Failures (19 tests, NOT caused by this PR)

These existed before this work and are unrelated:

1. **CrossfadeStateTests** (5 failures): Tests expect 50ms crossfade duration but code uses 200ms. Tests: `testDefaultDuration`, `testTotalSamplesAt44100Hz`, `testTotalSamplesAt48kHz`, `testTotalSamplesAt96kHz`, `testUpdateProgressAccumulatesSamples`

2. **CrossfadeInterruptionTests** (4 failures): Related to crossfade sample count mismatches (same root cause as above). Tests: `testAbortMidCrossfadeAndRestart`, `testCrossfadeAcrossSampleRateChange`, `testProgressScalesWithSampleRate`, `testRapidTripleSwitch`

3. **CrossfadeConcurrencyTests** (2 failures): Dead zone behavior and warmup/progress independence. Tests: `testDeadZoneBehavior`, `testWarmupAndProgressAreIndependent`

4. **StartupAudioInterruptionTests** (1 failure): `testStartupPreservesExplicitDeviceRouting` -- expects explicit device routing to survive startup, but startup currently always routes to system default.

### Remaining Cleanup Opportunities

- The CHANGELOG.md still references `SystemSoundsDeviceChanges.swift` as dead code (line 114) -- this is now outdated since the file was deleted. Should be updated in the CHANGELOG entry for this release.
- `handleServiceRestarted()` in AudioEngine.swift still uses a bulk `taps.removeAll()` / `appliedPIDs.removeAll()` / `lastHealthSnapshots.removeAll()` pattern rather than calling `teardownTap` per-PID. The plan noted keeping this bulk pattern, which is correct since it's more efficient for the "destroy everything" case.
- The `createAudioDevices(from:)` method in AudioDeviceMonitor.swift (line 467) appears unused (only `createAudioDevicesWithInput` is called). Could be removed in a future cleanup pass.

### Architecture Notes

- The `DeviceScope` enum and scope-parameterized methods in DeviceVolumeMonitor use `switch` statements to select the right dictionaries and CoreAudio calls. An alternative approach would be to use stored property key paths, but Swift's current limitations with mutable key paths on `@Observable` classes make the switch approach more practical.
- The `modifyState` helper in VolumeState uses a closure-based approach for persistence, which keeps the helper generic while allowing each caller to specify its own persistence logic (some check `rememberVolumeMute`, others don't).
