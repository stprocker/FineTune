# Xcode Pause on Permission Grant, Menu Bar "Unresponsive", and Post-Allow Audio Mute

**Status:** Resolved  
**Date:** 2026-02-07  
**Severity:** High (debug workflow blocked + intermittent audio mute after permission grant)  
**Primary Files:** `FineTune/Audio/AudioEngine.swift`, `FineTune/Views/MenuBar/MenuBarStatusController.swift`, `FineTune/Utilities/SingleInstanceGuard.swift`, `testing/tests/AudioEngineRoutingTests.swift`

---

## Summary

When running from Xcode on macOS 26, clicking **Allow** on the system audio permission dialog could appear to "freeze" the app (menu bar icon seemed unclickable), and in later runs audio could become muted after permission flow.  

This was a compound issue:

1. **Xcode pause behavior** made the menu bar appear dead while the process was paused.
2. A **layout recursion runtime issue** in menu bar panel sizing could trigger debugger/runtime interruption.
3. Permission confirmation logic was too permissive and could switch taps to `.mutedWhenTapped` while input was still silent.

---

## User-Visible Symptoms

1. Permission prompt appears several seconds after launch (often 2-10s under Xcode).
2. After clicking Allow, app appears paused and menu bar icon seems unresponsive.
3. After resuming, menu icon works again.
4. In some runs, audio mutes after permission interaction.
5. AppKit warning appears:
   - `It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out.`

---

## Key Diagnostic Evidence

### 1. Not a hard deadlock

Manual pause stack showed main thread in AppKit event routing and status bar button tracking:

- `NSStatusBarButtonCell trackMouse`
- `NSStatusBarButton rightMouseDown`
- `NSApplication run`

This indicates normal event-loop processing state at pause time, not a permanent deadlock.

### 2. Clicks were still being received

Logs repeatedly showed:

- `Status bar button clicked (type=1)`
- `Status bar button clicked (type=3)`

So the status item action path remained alive.

### 3. Premature permission confirmation caused mute transition risk

Before fix, logs showed:

- `input=0`, `inPeak=0.000`, while callbacks/output counters were increasing
- then immediately:
  - `[PERMISSION] System audio permission confirmed — recreating taps with .mutedWhenTapped`

This allowed a false positive confirmation, flipping taps to muted behavior before real input audio was observed.

---

## Root Causes

### Root Cause A: Runtime pause perception in Xcode

The app could be paused by runtime diagnostics (without user breakpoints), making the status item appear non-responsive until resumed.  

### Root Cause B: Layout recursion path in menu bar panel sizing

`MenuBarStatusController.showPanel()` forced layout inside layout-sensitive timing, which could trigger the AppKit recursion warning and debugger interruption.

### Root Cause C: Permission confirmation gate too weak

Permission was considered "confirmed" using only callback/output activity.  
In silent pipelines, this could be true even when no real input audio existed, causing early transition to `.mutedWhenTapped`.

---

## Fixes Implemented

### 1. Remove recursive layout trigger in menu bar controller

**File:** `FineTune/Views/MenuBar/MenuBarStatusController.swift`  
**Change:** Removed forced layout path and used `fittingSize`-based fallback sizing instead of calling `layoutSubtreeIfNeeded`.

Result:
- Eliminated direct known trigger for AppKit layout recursion warning from this controller.

### 2. Strengthen permission confirmation criteria

**File:** `FineTune/Audio/AudioEngine.swift`  
**Added helper:**
- `AudioEngine.shouldConfirmPermission(from:)`

New criteria:

- `callbackCount > 10`
- `outputWritten > 0`
- and **real input evidence**:
  - `inputHasData > 0` **or** `lastInputPeak > 0.0001`

**Updated call site:** fast health-check confirmation path now uses this helper before flipping to `.mutedWhenTapped`.

Result:
- Prevents false-positive permission confirmation during silent/no-input conditions.

### 3. Resolve remaining actor-isolation warning source in SingleInstanceGuard

**File:** `FineTune/Utilities/SingleInstanceGuard.swift`  
**Change:** Marked guard helper methods `nonisolated` to avoid main-actor isolation warning path in this utility.

Result:
- Reduced runtime-diagnostic noise and pause risk from this codepath in Xcode.

### 4. Preserve macOS 26 menu bar robustness changes

**File:** `FineTune/Views/MenuBar/MenuBarStatusController.swift`  
Kept/used the status-item rewire health timer and explicit click logging added during diagnosis.

Result:
- Helps recover if Control Center status item scene reconnect resets target/action.

---

## Tests Added (Fail-First Then Pass)

**File:** `testing/tests/AudioEngineRoutingTests.swift`

1. `testPermissionConfirmationRequiresRealInputAudio`
   - Verifies silent diagnostics do **not** confirm permission.

2. `testPermissionConfirmationSucceedsWithInputAudio`
   - Verifies diagnostics with real input evidence **do** confirm permission.

Both tests pass after implementation.

---

## Verification Performed

1. `swift test --filter AudioEngineRoutingTests/testPermissionConfirmationRequiresRealInputAudio` (pass)
2. `swift test --filter AudioEngineRoutingTests/testPermissionConfirmationSucceedsWithInputAudio` (pass)
3. Xcode Debug build/run verified:
   - Permission click no longer causes persistent unresponsive menu bar behavior.
   - Audio remains functional after permission interaction.
   - Logs show no premature permission confirmation in silent-input state.
4. Follow-up warning cleanup pass (Xcode diagnostics from screenshot) verified with clean app build:
   - `xcodebuild -project FineTune.xcodeproj -scheme FineTune -configuration Debug -destination 'platform=macOS' clean build` (pass)
   - No remaining project-source Swift actor/concurrency warnings from this incident set.

---

## Notes / Residuals

1. Permission popup timing (2s+ delay) is partially expected due to intentional startup delay before initial tap creation plus debugger overhead.
2. Actor-isolation diagnostics shown in the Xcode issue navigator were cleaned up in a follow-up pass:
   - `AudioScope` and `TransportType` members explicitly nonisolated-safe.
   - Volume/mute CoreAudio wrappers in `AudioDeviceID+Volume.swift` explicitly nonisolated.
   - `DeviceVolumeMonitor` background reads no longer `await` synchronous nonisolated methods.
   - `DeviceVolumeMonitor` captured-var concurrency warnings resolved with immutable snapshots before crossing back to MainActor.
   - `AudioDeviceMonitor` cache fields annotated with `@ObservationIgnored` to prevent `@Observable` actor-isolation interactions on cache storage.
3. If AppKit layout recursion warning reappears, capture a stack using `_NSDetectedLayoutRecursion` breakpoint to isolate any remaining source outside `MenuBarStatusController`.

---

## Final Outcome

Issue is resolved for the reported workflow:

- User can click permission prompt.
- Menu bar item remains usable.
- Audio no longer mutes as a side effect of premature permission confirmation.
