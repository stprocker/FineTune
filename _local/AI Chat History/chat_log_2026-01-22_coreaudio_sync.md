# Chat Log: CoreAudio Background Queue + Bidirectional Sync

**Date:** 2026-01-22

## Summary

Fixed two major issues:
1. System Settings crashes/freezes when FineTune is running
2. Implemented bidirectional device sync between System Settings and FineTune

---

## Part 1: CoreAudio Background Queue Fix

### Problem
- System Settings Sound panel would crash or become unresponsive when FineTune was running
- Clicking "Output" tab was impossible
- Garbled sound when clicking through System Settings

### Root Cause
All CoreAudio property listeners were registered on `.main` dispatch queue, which blocked the main thread during HAL operations and caused contention with System Settings.

### Solution (Commit 320e44e)

1. **Created `coreAudioListenerQueue`** - Dedicated background queue for all CoreAudio listener callbacks

2. **Moved all listener registrations** from `.main` to `coreAudioListenerQueue`:
   - `DeviceVolumeMonitor`: default device, service restart, volume, mute listeners
   - `AudioDeviceMonitor`: device list listener
   - `AudioProcessMonitor`: process list, per-process listeners

3. **Made all listener callbacks async** - CoreAudio reads happen on background threads, UI updates dispatch to MainActor

4. **Made `readAllStates()` async** - Volume/mute reads for all devices now happen on background thread

5. **Added debouncing** (50ms for default device, 30ms for volume/mute)

6. **Added coreaudiod restart recovery** - Listens for `kAudioHardwarePropertyServiceRestarted`

### Files Modified
- `FineTune/Audio/DeviceVolumeMonitor.swift`
- `FineTune/Audio/AudioDeviceMonitor.swift`
- `FineTune/Audio/AudioProcessMonitor.swift`
- `FineTune/Views/MenuBarPopupView.swift`

---

## Part 2: Bidirectional Device Sync

### Problem
When user changed output device in System Settings, FineTune detected it but didn't route tapped apps to the new device. Apps stayed on their old device.

### Solution

Added callback mechanism so external default device changes trigger `routeAllApps()`:

1. **Added to `DeviceVolumeMonitor`:**
   - `onDefaultDeviceChangedExternally` callback
   - `isSettingDefaultDevice` flag to prevent feedback loops

2. **Updated `setDefaultDevice()`:**
   - Sets flag before CoreAudio call, clears after
   - Prevents our own changes from triggering the callback

3. **Updated `handleDefaultDeviceChanged()`:**
   - Skips if `isSettingDefaultDevice` is true
   - Calls `onDefaultDeviceChangedExternally` for external changes

4. **Wired up `AudioEngine`:**
   - Subscribes to callback
   - Calls `routeAllApps(to: deviceUID)` when triggered

### How It Works

**System Settings → FineTune:**
1. User changes output in System Settings
2. CoreAudio fires listener → `handleDefaultDeviceChanged()` runs
3. Since `isSettingDefaultDevice` is false, callback fires
4. `AudioEngine.routeAllApps()` switches all tapped apps

**FineTune → System Settings:**
1. User clicks device in FineTune
2. `setDefaultDevice()` sets `isSettingDefaultDevice = true`
3. CoreAudio call changes system default
4. Listener fires but sees flag is true, skips callback
5. No feedback loop

### Files Modified
- `FineTune/Audio/DeviceVolumeMonitor.swift`
- `FineTune/Audio/AudioEngine.swift`

---

## Part 3: Fixing System Settings Contention & Feedback Loops (Commit Pending)

### Problem
Despite Part 1 & 2, users reported "Still having issues with being able to click sound output on mac os settings."

### Root Cause Analysis
1.  **Feedback Loop Leak:** The `isSettingDefaultDevice` flag was cleared by `defer` *before* the async listener callback fired. This caused FineTune to react to its own changes as if they were external, triggering a redundant `routeAllApps` storm.
2.  **HAL Contention:** When System Settings changes the device, FineTune immediately (within 50ms) launched parallel tasks to destroy/recreate 10+ process taps. This hammered `coreaudiod` while System Settings was still trying to handshake with the new device, causing UI freezes.

### Solution

1.  **Timestamp-Based Loop Prevention:**
    - Added `lastSelfChangeTimestamp` to `DeviceVolumeMonitor`.
    - In `setDefaultDevice`, record the current time.
    - In `handleDefaultDeviceChanged`, ignore any changes within **1.0 second** of a self-change. This robustly filters out our own echoes.

2.  **Explicit Routing Trigger:**
    - Since we now ignore the listener callback for self-changes, `setDefaultDevice` must manually trigger `onDefaultDeviceChangedExternally` upon success. This ensures apps route instantly when clicked in FineTune, without waiting for the roundtrip.

3.  **Increased Debounce:**
    - Increased `handleDefaultDeviceChanged` debounce from **50ms** to **300ms**.
    - This gives System Settings (and `coreaudiod`) breathing room to settle its internal state before FineTune starts the heavy lifting of re-routing apps.

### Files Modified
- `FineTune/Audio/DeviceVolumeMonitor.swift`

---

## Testing Checklist

1. Launch FineTune with audio playing in an app
2. Open System Settings → Sound → Output
3. Click a different output device in System Settings
4. Verify: Audio switches to new device (FineTune routes the tapped app)
5. Verify: FineTune's UI shows the new device selected
6. Switch device in FineTune, verify System Settings reflects it
7. Repeat several times, verify no crashes or freezes

---

## Key Code Snippets

### coreAudioListenerQueue (DeviceVolumeMonitor.swift:10)
```swift
let coreAudioListenerQueue = DispatchQueue(label: "com.finetune.coreaudio-listeners", qos: .userInitiated)
```

### External change callback (DeviceVolumeMonitor.swift)
```swift
var onDefaultDeviceChangedExternally: ((_ deviceUID: String) -> Void)?
private var isSettingDefaultDevice = false
```

### AudioEngine subscription (AudioEngine.swift)
```swift
deviceVolumeMonitor.onDefaultDeviceChangedExternally = { [weak self] deviceUID in
    guard let self else { return }
    self.logger.info("System default device changed externally to: \(deviceUID)")
    self.routeAllApps(to: deviceUID)
}
```
