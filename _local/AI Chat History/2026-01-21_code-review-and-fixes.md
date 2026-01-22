# FineTune Code Review and Bug Fixes
**Date:** 2026-01-21
**Model:** Claude Opus 4.5

## Summary

Comprehensive code review of the FineTune macOS audio app, focusing on audio system stability issues that caused System Settings audio to become unresponsive (requiring restart).

## User's Initial Issue

> When I ran it, it seemed to screw up my audio where I couldn't even select output from sound settings in system settings. Had to restart.

---

## Root Cause Analysis

**Primary Issue: Orphaned CoreAudio Property Listeners**

The app registers multiple CoreAudio property listeners (`AudioObjectAddPropertyListenerBlock`) but fails to remove them on app termination because:

1. Monitor classes (`AudioDeviceMonitor`, `DeviceVolumeMonitor`, `AudioProcessMonitor`) have `deinit` methods that cannot call `stop()` due to MainActor isolation
2. No termination handler called `audioEngine.stop()` to clean up listeners
3. The `FineTune.entitlements` file was emptied (removed sandbox and audio entitlements)

When listeners aren't removed, CoreAudio's `coreaudiod` daemon maintains stale references that corrupt its state, preventing System Settings from properly controlling audio devices.

---

## Critical Fixes (Audio System)

### 1. App Termination Cleanup
**File:** `FineTuneApp.swift`

Added call to `engine.stopSync()` in the termination notification handler:
```swift
NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil,
    queue: .main
) { [engine, settings] _ in
    engine.stopSync()  // NEW: Clean up CoreAudio listeners
    settings.flushSync()
}
```

### 2. Synchronous Stop Method
**File:** `AudioEngine.swift`

Added `stopSync()` nonisolated method for termination handlers:
```swift
nonisolated func stopSync() {
    DispatchQueue.main.sync {
        MainActor.assumeIsolated {
            self.stop()
        }
    }
}
```

Also added `deviceVolumeMonitor.stop()` to the `stop()` method.

### 3. Restored Entitlements
**File:** `FineTune.entitlements`

Restored from empty `<dict/>` to:
```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
```

### 4. Secondary Tap Cleanup on Crossfade Failure
**File:** `ProcessTapController.swift`

Added `cleanupSecondaryTap()` helper to properly clean up resources when crossfade fails:
```swift
private func cleanupSecondaryTap() {
    _isCrossfading = false
    _crossfadeProgress = 0
    // ... cleanup secondary tap/aggregate resources
}
```

Called in the catch block when crossfade fails.

### 5. Fixed Invalid Device ID Handling
**File:** `ProcessTapController.swift`

In `invalidate()`, now checks both aggregate ID and procID are valid before calling `AudioDeviceStop()`:
```swift
if primaryAggregate.isValid, let procID = primaryProcID {
    AudioDeviceStop(primaryAggregate, procID)
    // ...
}
```

### 6. Task-Based Observation Loop
**File:** `DeviceVolumeMonitor.swift`

Replaced recursive `withObservationTracking` pattern with cancellable Task:
```swift
observationTask = Task { @MainActor [weak self] in
    while !Task.isCancelled {
        guard let strongSelf = self, strongSelf.isObservingDeviceList else { break }
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = strongSelf.deviceMonitor.outputDevices
            } onChange: {
                continuation.resume()
            }
        }
        // ...
    }
}
```

### 7. Bluetooth Device Validity Check
**File:** `DeviceVolumeMonitor.swift`

Added `deviceID.isValid` check before delayed Bluetooth volume re-read to prevent reading from unplugged devices.

### 8. Private API Caching
**File:** `AudioProcessMonitor.swift`

Added caching for the private `responsibility_get_pid_responsible_for_pid` API to avoid repeated `dlsym` calls:
```swift
private static var responsibilityFuncCache: ResponsibilityFunc??
```

### 9. Increased Cleanup Grace Period
**File:** `AudioEngine.swift`

Increased stale tap cleanup grace period from 500ms to 1 second.

---

## Non-Audio Fixes

### Timer Memory Leaks
**Files:** `VUMeter.swift`, `AppRow.swift`

Converted `Timer.scheduledTimer` to Task-based approach for better SwiftUI lifecycle integration:

**VUMeter.swift:**
```swift
@State private var peakDecayTask: Task<Void, Never>?

private func startPeakDecayTimer() {
    peakDecayTask?.cancel()
    peakDecayTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(DesignTokens.Timing.vuMeterPeakHold))
        guard !Task.isCancelled else { return }
        // ... decay loop
    }
}
```

**AppRow.swift:**
```swift
@State private var levelPollingTask: Task<Void, Never>?

private func startLevelPolling() {
    let pollLevel = getAudioLevel
    levelPollingTask = Task { @MainActor in
        while !Task.isCancelled {
            displayLevel = pollLevel()
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}
```

### Silent App Row Skipping
**File:** `MenuBarPopupView.swift`

Apps without explicit device routing are now shown with a fallback to the default output device:
```swift
let deviceUID = audioEngine.getDeviceUID(for: app)
    ?? audioEngine.deviceVolumeMonitor.defaultDeviceUID
    ?? audioEngine.outputDevices.first?.uid
    ?? ""
```

### EQ Preset Lookup Optimization
**File:** `EQPanelView.swift`

Cached preset lookup to avoid O(n) iteration on every view update:
```swift
@State private var cachedPreset: EQPreset?

.onAppear { updateCachedPreset() }
.onChange(of: settings.bandGains) { _, _ in updateCachedPreset() }

private func updateCachedPreset() {
    cachedPreset = EQPreset.allCases.first { $0.settings.bandGains == settings.bandGains }
}
```

---

## Files Modified

### Audio System
- `FineTune/FineTuneApp.swift`
- `FineTune/FineTune.entitlements`
- `FineTune/Audio/AudioEngine.swift`
- `FineTune/Audio/AudioDeviceMonitor.swift`
- `FineTune/Audio/AudioProcessMonitor.swift`
- `FineTune/Audio/DeviceVolumeMonitor.swift`
- `FineTune/Audio/ProcessTapController.swift`

### Views
- `FineTune/Views/Components/VUMeter.swift`
- `FineTune/Views/Rows/AppRow.swift`
- `FineTune/Views/MenuBarPopupView.swift`
- `FineTune/Views/EQPanelView.swift`

---

## Issues Reviewed But Not Changed

1. **PopoverHost.swift** - Event monitors already use `[weak self]` correctly
2. **SettingsManager.swift** - "Race condition" is not real due to `@MainActor` serialization
3. **FineTuneApp termination observer** - Strong captures are intentional for cleanup
4. **Sample rate mismatch during crossfade** - Acceptable for 50ms crossfade duration

---

## Testing Recommendations

1. Run app normally, use audio features, then quit with Cmd+Q
2. Verify System Settings > Sound works correctly after quit
3. Force quit app (Activity Monitor) and verify restart clears any stale state
4. Test with multiple audio devices and Bluetooth devices
5. Test EQ switching between presets for performance

---

## Build Status

All changes compile successfully with `xcodebuild -scheme FineTune -configuration Debug build`.
