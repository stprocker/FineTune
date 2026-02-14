# Safety & Reliability Fixes for FineTune

**Date:** 2026-02-08
**Session type:** Implementation (from approved plan)
**Branch:** main (uncommitted)

---

## Summary

Implemented six safety and reliability fixes identified during a comprehensive safety review. The changes address hearing safety (post-EQ clipping), resource lifecycle (leaked polling tasks), startup ordering (race between instance guard and device cleanup), data integrity (NaN in EQ settings), and thread safety (CrashGuard data race).

---

## What Was Done

### Step 1: Post-EQ Soft Limiter (Hearing Safety)

**Problem:** The signal chain was Gain -> SoftLimiter -> EQ -> Output. EQ bands at +12 dB could boost the already-limited signal well above 1.0, risking hearing damage at high volume.

**Fix:** Added `SoftLimiter.processBuffer()` after every `eqProcessor.process()` call at three insertion points:

| File | Location | Detail |
|------|----------|--------|
| `FineTune/Audio/ProcessTapController.swift` | Line ~1207 (primary tap) | `SoftLimiter.processBuffer(outputSamples, sampleCount: sampleCount)` |
| `FineTune/Audio/ProcessTapController.swift` | Line ~1369 (secondary tap) | `SoftLimiter.processBuffer(outputSamples, sampleCount: sampleCount)` |
| `FineTune/Audio/Processing/AudioFormatConverter.swift` | Line ~242 (converter path) | `SoftLimiter.processBuffer(outputSamples, sampleCount: Int(actualFrames) * 2)` |

**New test file:** `testing/tests/PostEQLimiterTests.swift` with 3 tests:
- `testBoostedSignalClampedBelowCeiling` — 0.85 x 4.0 boost, all samples <= 1.0
- `testBelowThresholdPassthroughUnchanged` — 0.5 unchanged
- `testInterleavedStereoMixedAmplitudes` — L=3.4 compressed, R=0.3 unchanged

**Package.swift** updated to include `PostEQLimiterTests.swift` in `FineTuneCoreTests` sources.

**Performance:** `SoftLimiter.apply` is `@inline(__always)`. Below-threshold fast path is one comparison + return. For 512-frame stereo (1024 samples), adds ~1024 float comparisons per callback -- negligible.

### Step 2: Store & Cancel Polling Tasks in AudioEngine.stop()

**Problem:** Two `Task {}` polling loops (diagnostic health check at 3s, pause-recovery at 1s) and `pendingCleanup` grace-period tasks were fire-and-forget in `init()`. On `stop()`, they continued running against a torn-down engine.

**Fix (AudioEngine.swift):**
- Added stored task handles: `diagnosticPollTask` and `pauseRecoveryPollTask` (alongside existing `serviceRestartTask`)
- Stored handles at creation: `diagnosticPollTask = Task { ... }` and `pauseRecoveryPollTask = Task { ... }`
- Added cancellation in `stop()` before the `switchTasks` loop:
  ```swift
  diagnosticPollTask?.cancel()
  diagnosticPollTask = nil
  pauseRecoveryPollTask?.cancel()
  pauseRecoveryPollTask = nil
  for task in pendingCleanup.values { task.cancel() }
  pendingCleanup.removeAll()
  serviceRestartTask?.cancel()
  serviceRestartTask = nil
  ```

### Step 3: Move SingleInstanceGuard Before OrphanedTapCleanup

**Problem:** In `FineTuneApp.swift`, the startup order was:
1. `OrphanedTapCleanup.destroyOrphanedDevices()` -- destroys ALL "FineTune-*" aggregate devices
2. `CrashGuard.install()`
3. Create `SettingsManager` + `AudioEngine`
4. `SingleInstanceGuard.shouldTerminateCurrentInstance()` -- checks for duplicates

If a second instance launched, it would nuke the running instance's live aggregate devices at step 1, then discover at step 4 it should terminate. Audio on the first instance dies silently.

**Fix:** Reordered `applicationDidFinishLaunching` so the single-instance check runs FIRST:
```swift
// FIRST: bail immediately if another instance is running.
if SingleInstanceGuard.shouldTerminateCurrentInstance() {
    logger.warning("Another FineTune instance detected; terminating this process.")
    NSApplication.shared.terminate(nil)
    return
}
// THEN: cleanup, crash guard, engine creation...
```

The duplicate instance no longer creates an AudioEngine or calls `engine.stopSync()` -- it just terminates immediately. No cleanup needed because nothing was created.

### Step 4: Cancel pendingCleanup Tasks in stop()

Already covered in Step 2c (the `pendingCleanup` and `serviceRestartTask` cancellation). Listed separately in the original plan but implemented as part of the same `stop()` enhancement.

### Step 5: NaN Guard on EQ Settings Load (Belt-and-Suspenders)

**Problem:** If a corrupted settings file contains NaN band gains, `clampedGains` accidentally maps NaN to +12 dB (max boost) due to IEEE 754 `min`/`max` behavior with NaN. While not NaN propagation, it silently treats corruption as maximum EQ boost.

**Fix (EQSettings.swift line 27):**
```swift
// Before:
var gains = bandGains.map { max(Self.minGainDB, min(Self.maxGainDB, $0)) }
// After:
var gains = bandGains.map { $0.isNaN || $0.isInfinite ? 0 : max(Self.minGainDB, min(Self.maxGainDB, $0)) }
```

NaN and Infinity map to 0 dB (flat) instead of +12 dB.

### Step 6: CrashGuard Thread-Safe Device Tracking (Belt-and-Suspenders)

**Problem:** `TapResources.destroyAsync()` calls `CrashGuard.untrackDevice()` from `DispatchQueue.global(qos: .utility)`, while `trackDevice()` runs on MainActor. Real data race on `gDeviceCount` and slot array.

**Fix (CrashGuard.swift):**
- Added `import os` for `os_unfair_lock`
- Added `private nonisolated(unsafe) var gDeviceLock = os_unfair_lock()` alongside existing globals
- Wrapped both `trackDevice()` and `untrackDevice()` with `os_unfair_lock_lock`/`os_unfair_lock_unlock` via `defer`
- Signal handler (`crashSignalHandler`) intentionally does NOT take the lock -- it only reads. The lock's release semantics ensure prior writes are visible.

---

## Files Modified

| File | Steps |
|------|-------|
| `FineTune/Audio/ProcessTapController.swift` | 1a, 1b |
| `FineTune/Audio/Processing/AudioFormatConverter.swift` | 1c |
| `FineTune/Audio/AudioEngine.swift` | 2a, 2b, 2c (includes Step 4) |
| `FineTune/FineTuneApp.swift` | 3 |
| `FineTune/Models/EQSettings.swift` | 5 |
| `FineTune/Audio/CrashGuard.swift` | 6 |
| `Package.swift` | 1d (add test file) |
| `testing/tests/PostEQLimiterTests.swift` (NEW) | 1d |

---

## Verification Results

### Build verification
- **xcodebuild build:** PASSED -- `** BUILD SUCCEEDED **` with full Xcode project (includes Sparkle, all app code)
- **swift build --target FineTuneCoreTests:** PASSED -- test target compiles including PostEQLimiterTests

### Test verification
- **182 FineTuneCoreTests:** All PASSED (run via `swift test --skip-build --filter FineTuneCoreTests`)
- **Inline verification script:** All 4 test scenarios PASSED:
  - Boosted signal (3.4) clamped to 0.9857 (below 1.0 ceiling)
  - Below-threshold (0.5) passthrough unchanged
  - Interleaved stereo: L compressed, R passthrough
  - NaN/Infinity/negative-Infinity all mapped to 0 dB flat

### Known test infrastructure limitation
- `swift test` (full) cannot run because `FineTuneIntegrationTests` depends on `FineTuneIntegration`, which depends on `Sparkle` (an Xcode-managed SPM dependency not available to standalone SPM). This is a **pre-existing issue** unrelated to these changes.
- `xcodebuild test` fails with code signing error on `FineTuneTests.xctest` -- also pre-existing.

---

## Skipped Items (Accepted Risk)

These were evaluated during the safety review and intentionally not implemented:

- **Periodic orphan cleanup while running** -- would risk destroying devices mid-crossfade; startup-only cleanup is sufficient
- **UUID-based device naming** -- changes naming convention everywhere for low-probability collision
- **deinit assertions on monitor classes** -- existing `AudioEngine.stop()`/`stopSync()` defense is solid

---

## TODO List / Remaining Work

### High Priority (should be done before next release)

1. **Runtime test: Post-EQ limiter hearing safety**
   - Launch app, set volume to 100%, all EQ bands to +12 dB, play audio
   - Verify audio is loud but not clipped/distorted (should sound compressed, not harsh)
   - Compare peak levels in DIAG logs before and after these changes

2. **Runtime test: Double-launch safety**
   - Launch app normally, confirm audio is working
   - Launch a second instance from Xcode or Finder
   - Verify: second instance terminates immediately, first instance's audio is uninterrupted
   - Before this fix, the first instance would lose audio silently

3. **Runtime test: Clean shutdown**
   - Launch app, play audio through it
   - Quit the app (Cmd+Q or "Quit FineTune" context menu)
   - Check Console.app logs for clean shutdown sequence
   - Verify no "AudioEngine stopped" messages appear AFTER polling task logs

4. **Thread Sanitizer validation for CrashGuard**
   - Build with Thread Sanitizer enabled (`-sanitize=thread`)
   - Exercise device switching (triggers `trackDevice`/`untrackDevice` from different queues)
   - Verify no TSan warnings on `gDeviceCount`/`gDeviceSlots`

### Medium Priority

5. **Fix `swift test` infrastructure**
   - The `FineTuneIntegration` SPM target cannot build without Sparkle
   - Options: (a) add Sparkle as SPM dependency in Package.swift, (b) conditionally compile UpdateManager, (c) exclude UpdateManager from FineTuneIntegration target
   - This blocks running integration tests via `swift test`

6. **Fix `xcodebuild test` code signing**
   - `FineTuneTests.xctest` bundle fails code signing validation
   - Pre-existing issue, not introduced by these changes

7. **Commit these changes**
   - All changes are currently uncommitted on the `main` branch
   - 8 files modified, 1 new file created

### Low Priority / Future Hardening

8. **Add NaN guard tests to EQSettingsTests**
   - The existing `EQSettingsTests.swift` doesn't test NaN/Infinity inputs
   - Add test cases for: `[Float.nan]`, `[.infinity]`, `[-.infinity]`, mixed arrays
   - Verified working via inline script but no formal XCTest yet

9. **Consider post-EQ limiter in additional paths**
   - If new audio processing paths are added in the future, they need post-EQ limiting too
   - Document this requirement in a code comment near the EQ processing

10. **Audit `stopSync()` for the same task cancellation**
    - `stop()` now cancels all tasks, but `stopSync()` (used in signal handlers and `applicationWillTerminate`) may not
    - Signal handlers call `stopSync()` which is nonisolated -- it may not be able to cancel MainActor-isolated tasks
    - Low risk since process is exiting anyway, but worth auditing

---

## Known Issues (Comprehensive)

### From this session
- **PostEQLimiterTests not runnable via `swift test`** -- compiles but can't execute due to pre-existing Sparkle dependency issue blocking `--build-tests`. Verified via standalone compilation and inline script.
- **Changes are uncommitted** -- all modifications are on the working tree of `main`

### Pre-existing (not introduced by these changes)
- **`swift test` broken by Sparkle dependency** -- `FineTuneIntegration` target imports `UpdateManager.swift` which requires Sparkle (Xcode-managed SPM dep)
- **`xcodebuild test` code signing failure** -- `FineTuneTests.xctest` bundle fails codesign validation
- **All prior changes compile-verified only** -- settings panel, system sounds device tracking, CATapDescription constructor fix, etc. have not been runtime-tested
- **`SystemSoundsDeviceChanges.swift` is dead code** -- 200-line documentation stub that should be deleted
- **Settings panel doesn't auto-close on popup dismiss**
- **Bundle-ID tap aggregate output dead on macOS 26** -- neither PID-only nor bundle-ID taps fully work
- **Dead code in AudioEngine.swift** -- `permissionConfirmed`, `upgradeTapsToMutedWhenTapped()`, `shouldConfirmPermission()` are unreachable

---

## Architecture Notes

### Signal chain after this change
```
App Audio -> Process Tap -> Gain/Volume Ramp -> SoftLimiter(1) -> EQ -> SoftLimiter(2) -> Output
```

The first SoftLimiter (pre-EQ) prevents extreme gain from exceeding reasonable levels before EQ. The second SoftLimiter (post-EQ, added in this session) ensures EQ boost cannot push the final output above 1.0.

### CrashGuard lock design
- `os_unfair_lock` protects `gDeviceCount` and `gDeviceSlots` mutations in `trackDevice`/`untrackDevice`
- The crash signal handler does NOT acquire the lock (would deadlock if crash occurred while lock held)
- Lock release semantics provide memory ordering guarantee that prior writes are visible to the signal handler
- This is a standard pattern for signal-safe data structures

### Startup ordering after this change
```
1. SingleInstanceGuard check (bail if duplicate)
2. OrphanedTapCleanup (safe: no running instance to interfere with)
3. CrashGuard.install()
4. Create SettingsManager + AudioEngine
5. installSignalHandlers()
6. Rest of startup...
```
