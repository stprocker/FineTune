# FineTune Code Review - 2026-01-22

## Overview
Comprehensive review of the FineTune macOS audio app focusing on critical bugs, performance issues, and anything that could crash or corrupt user audio.

---

## Critical Issues Found & Fixed

### 1. Deadlock on App Quit
**File:** `AudioEngine.swift:116-128`

**Problem:** `stopSync()` called `DispatchQueue.main.sync` but was invoked from a notification observer already on main queue (`NSApplication.willTerminateNotification`). This caused a guaranteed deadlock - the app would hang every time a user quit.

**Fix:** Added `Thread.isMainThread` check before calling `DispatchQueue.main.sync`:
```swift
nonisolated func stopSync() {
    if Thread.isMainThread {
        MainActor.assumeIsolated { self.stop() }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { self.stop() }
        }
    }
}
```

---

### 2. Ramp Coefficient Mismatch After Tap Promotion
**File:** `ProcessTapController.swift:919`

**Problem:** After a tap is promoted from secondary to primary, it continues running `processAudioSecondary` callback which always used `secondaryRampCoefficient`. When a NEW secondary tap was created during the next device switch, `secondaryRampCoefficient` got overwritten, causing the promoted callback to use the wrong smoothing coefficient.

**Fix:** Use `rampCoefficient` when not crossfading (after promotion):
```swift
let activeRampCoef = _isCrossfading ? secondaryRampCoefficient : rampCoefficient
```

---

### 3. Bluetooth Warmup Timing Too Short
**File:** `ProcessTapController.swift:359, 368`

**Problem:** Bluetooth A2DP connections can take 500ms+ to fully establish. Previous warmup of 300ms and timeout of +400ms could cause brief silence during BT device switching.

**Fix:** Increased timings:
- Warmup: 300ms → 500ms
- Extended timeout: +400ms → +600ms

---

### 4. Memory Barriers for Critical Audio Flags
**File:** `ProcessTapController.swift` (6 locations)

**Problem:** Variables like `_forceSilence` and `_isCrossfading` are written from main thread and read from audio callback thread. Without memory barriers, writes could be delayed in CPU write buffers, causing the audio thread to see stale values. This could result in clicks/pops during device switching.

**Fix:** Added `OSMemoryBarrier()` after all critical flag writes:
- After `_forceSilence = true` (line 614)
- After `_forceSilence = false` (line 628)
- After `_isCrossfading = true` (line 348)
- After `_isCrossfading = false` (lines 392, 521, 1016)

---

### 5. SettingsManager.flushSync() Not Explicitly Synchronous
**File:** `SettingsManager.swift:93-108`

**Problem:** `flushSync()` was called from the same termination handler as `stopSync()`, but wasn't marked `nonisolated`. This could cause issues with Swift concurrency semantics during app termination.

**Fix:** Made `nonisolated` with main thread check (matching `stopSync()` pattern):
```swift
nonisolated func flushSync() {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            saveTask?.cancel()
            saveTask = nil
            writeToDisk()
        }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.saveTask?.cancel()
                self.saveTask = nil
                self.writeToDisk()
            }
        }
    }
}
```

---

### 6. Corrupted Settings Could Crash App
**File:** `EQSettings.swift:25-34`

**Problem:** If `settings.json` contained EQ settings with wrong band count (corrupted file), the `precondition(gains.count == EQSettings.bandCount)` in `BiquadMath.coefficientsForAllBands()` would crash the app.

**Fix:** `clampedGains` now defensively pads/truncates to exactly 10 bands:
```swift
var clampedGains: [Float] {
    var gains = bandGains.map { max(Self.minGainDB, min(Self.maxGainDB, $0)) }
    if gains.count < Self.bandCount {
        gains.append(contentsOf: Array(repeating: Float(0), count: Self.bandCount - gains.count))
    } else if gains.count > Self.bandCount {
        gains = Array(gains.prefix(Self.bandCount))
    }
    return gains
}
```

---

## Verified Safe (No Issues)

| Area | Status |
|------|--------|
| Force unwraps | None in codebase |
| `try!` or `fatalError` | None in codebase |
| VolumeMapping math | Handles edge cases (0 values, log of small numbers) |
| BiquadMath | Division by zero not possible with fixed Q and frequencies |
| EQProcessor `@unchecked Sendable` | Justified - uses atomic-safe patterns |
| vDSP_biquad setup swap | 200ms delayed destruction provides safe margin |
| Weak self in callbacks | Properly handled throughout |
| CoreAudio listener cleanup | Handled via `stopSync()` on app termination |

---

## Minor Issues (Not Fixed - Acceptable)

1. **EQ skipped during crossfade** - 50ms of flat EQ during device switch is intentional and imperceptible
2. **Orphaned CoreAudio listeners on crash** - Systemic issue; macOS cleans up process resources on crash

---

## Files Modified

1. `FineTune/Audio/AudioEngine.swift`
2. `FineTune/Audio/ProcessTapController.swift`
3. `FineTune/Settings/SettingsManager.swift`
4. `FineTune/Models/EQSettings.swift`

---

## Build Status
All changes compile successfully with `xcodebuild -configuration Debug`.
