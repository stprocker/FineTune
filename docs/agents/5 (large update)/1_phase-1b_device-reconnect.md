# Agent 1: Phase 1B - Device Reconnect Handling

**Agent ID:** ad1dfbe
**Date:** 2026-02-07
**Task:** Implement device reconnect handling with "follow default" pattern from upstream

---

## Files Modified

### 1. AudioDeviceMonitor.swift

**Added `onDeviceConnected` callback** (line 29):
```swift
var onDeviceConnected: ((_ uid: String, _ name: String) -> Void)?
```

**Added connected device detection in `handleDeviceListChangedAsync()`:**
After detecting disconnected devices, computes `connectedUIDs = knownDeviceUIDs.subtracting(previousUIDs)` and fires `onDeviceConnected?(uid, device.name)` for each newly connected device.

**Added connected device detection in `handleServiceRestartedAsync()`:**
Same pattern for coreaudiod restart handler -- newly appearing devices after a service restart also fire the callback.

### 2. AudioEngine.swift

**Added `followsDefault: Set<pid_t>` property:**
Tracks PIDs of apps involuntarily displaced to the default device during a disconnect. Distinguishes "user chose default" from "temporarily on default because their device disappeared."

**Wired `deviceMonitor.onDeviceConnected`** in init:
```swift
deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
    self?.handleDeviceConnected(deviceUID, name: deviceName)
}
```

**Added `followsDefault.remove(app.id)` to `setDevice(for:deviceUID:)`:**
Explicit user-initiated routing clears the temporary follow-default state for that app.

**Rewrote `handleDeviceDisconnected` to NOT persist fallback routing:**
- No longer calls `setDevice(for:deviceUID:)` which would persist the fallback
- Instead updates `appDeviceRouting[app.id]` in memory only
- Adds displaced apps to `followsDefault` set
- Switches taps directly via `tap.switchDevice(to:)`, managing `switchTasks` for serialization
- Gates the disconnect notification on `settingsManager.appSettings.showDeviceDisconnectAlerts`

**Added `handleDeviceConnected` method:**
- Iterates all active taps
- Skips apps where `settingsManager.isFollowingDefault(for:)` returns true
- Checks if app's PERSISTED routing matches the reconnected device UID
- If yes AND app's current in-memory routing differs, switches back
- Removes app from `followsDefault` set
- Gates reconnect notification on `showDeviceDisconnectAlerts`

**Added `showReconnectNotification` method:**
- Uses `UNUserNotificationCenter`
- Title: "Audio Device Reconnected"
- Body: `"deviceName" is back. N app(s) switched back.`

**Added `followsDefault` cleanup in `cleanupStaleTaps`:**
- Per-PID cleanup inside grace period task
- Bulk cleanup via `followsDefault = followsDefault.intersection(pidsToKeep)`

## Build Result

BUILD SUCCEEDED -- zero errors, zero warnings in modified files. Test runner had pre-existing code signing issue (unrelated).
