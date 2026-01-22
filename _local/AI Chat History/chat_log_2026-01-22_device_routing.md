# Chat Log: Device Routing Bug Fix

**Date:** 2026-01-22

## Issue Reported

User reported that FineTune was starting up with the wrong audio device selection. Apps (Brave Browser, CoreSpeech) were routing to MacBook Pro Speakers even though AirPods were shown as selected in the UI.

## Root Cause Analysis

### Bug 1: Wrong Core Audio Property for New App Routing

**Location:** `AudioEngine.swift:231` and `AudioObjectID+System.swift:64`

**Problem:** When new apps started playing audio, `applyPersistedSettings()` would fall back to `readDefaultSystemOutputDeviceUID()` which reads `kAudioHardwarePropertyDefaultSystemOutputDevice` (where system sounds go).

However, when the user clicks a device in FineTune, it sets `kAudioHardwarePropertyDefaultOutputDevice` (where apps play).

These are **different properties** in macOS:
- `DefaultOutputDevice` - where apps play audio by default
- `DefaultSystemOutputDevice` - where system sounds (alerts, beeps) go

**Fix:** Added new functions `readDefaultOutputDevice()` and `readDefaultOutputDeviceUID()` that read the correct property, and updated `AudioEngine.swift` to use them.

### Bug 2: UI Checkmark Not Reflecting System Default on Startup

**Location:** `DeviceVolumeMonitor.swift:59-61`

**Problem:** The `defaultDeviceID` was initialized to `.unknown` and only populated when `start()` was called. But `start()` runs inside an async `Task`, so the SwiftUI view rendered before the default device was read.

**Fix:** Call `refreshDefaultDevice()` in the `DeviceVolumeMonitor` init so the correct value is available before first render.

## Files Modified

### `FineTune/Audio/Extensions/AudioObjectID+System.swift`

Added new functions:
```swift
static func readDefaultOutputDevice() throws -> AudioDeviceID {
    try AudioObjectID.system.read(
        kAudioHardwarePropertyDefaultOutputDevice,
        defaultValue: AudioDeviceID.unknown
    )
}

static func readDefaultOutputDeviceUID() throws -> String {
    let deviceID = try readDefaultOutputDevice()
    return try deviceID.readDeviceUID()
}
```

### `FineTune/Audio/AudioEngine.swift`

Changed `applyPersistedSettings()` (line 231) and `handleDeviceDisconnected()` (line 297) to use `readDefaultOutputDeviceUID()` instead of `readDefaultSystemOutputDeviceUID()`.

### `FineTune/Audio/DeviceVolumeMonitor.swift`

Added `refreshDefaultDevice()` call in init:
```swift
init(deviceMonitor: AudioDeviceMonitor) {
    self.deviceMonitor = deviceMonitor
    // Read default device synchronously so UI has correct value before first render
    refreshDefaultDevice()
}
```

## Testing

Both fixes compile successfully. User should test by:
1. Setting a specific output device in macOS System Settings
2. Opening FineTune
3. Verifying the checkmark shows on the correct device
4. Starting a new audio app and verifying it routes to the selected device
