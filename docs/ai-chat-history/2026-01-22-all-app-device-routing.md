# Chat Log: All-App Device Routing Feature

**Date:** 2026-01-22
**Feature:** Route all apps to selected output device (like native macOS behavior)

---

## Problem Statement

User reported that changing output devices in FineTune did not work. When clicking on AirPods in the OUTPUT DEVICES section, Brave/YouTube continued playing through MacBook Pro speakers.

## Root Cause Investigation

### Initial Analysis
- Clicking an output device only called `deviceVolumeMonitor.setDefaultDevice()` which sets the macOS **system default**
- It did NOT route already-playing apps to the new device
- Per-app routing only happened through the per-app dropdown, calling `audioEngine.setDevice(for:deviceUID:)`

### Data Flow (Before Fix)
```
OUTPUT DEVICES click → DeviceVolumeMonitor.setDefaultDevice()
                              ↓
                      Sets macOS system default ONLY
                      (does NOT route existing apps)
```

## Implementation

### Plan Created
Saved to: `docs/plans/2026-01-22-all-app-device-routing.md`

### Commits Made

1. **`4e75212`** - feat(audio): add routeAllApps method for bulk device switching
   - Added `routeAllApps(to:)` method to AudioEngine.swift
   - Loops through all apps and calls `setDevice(for:deviceUID:)` for each

2. **`9270f81`** - feat(ui): route all apps when selecting output device
   - Modified `onSetDefault` callback in MenuBarPopupView.swift
   - Now calls both `setDefaultDevice()` AND `routeAllApps()`

3. **`45d3c8e`** - perf(audio): optimize routeAllApps with edge case handling and skip logic
   - Handle empty apps list gracefully
   - Skip apps already on target device
   - Better logging (shows count being switched)

4. **`1cd9922`** - fix(ui): ensure device picker updates immediately via direct dictionary access
   - Fixed bug where UI didn't update until second click
   - Changed `appDeviceRouting` from `private` to `private(set)`
   - View now accesses dictionary directly for proper SwiftUI observation

## Bug Fix: UI Not Updating on First Click

### Symptom
Audio switched correctly but device picker "bubble" didn't update until clicking twice.

### Root Cause
SwiftUI's `@Observable` macro wasn't tracking changes to `appDeviceRouting` dictionary when accessed through `getDeviceUID(for:)` function indirection.

### Fix
- Exposed `appDeviceRouting` as `private(set)`
- Changed view to access `audioEngine.appDeviceRouting[app.id]` directly
- This allows SwiftUI observation system to properly track dictionary changes

## Files Modified

| File | Changes |
|------|---------|
| `FineTune/Audio/AudioEngine.swift` | Added `routeAllApps(to:)`, changed `appDeviceRouting` to `private(set)` |
| `FineTune/Views/MenuBarPopupView.swift` | Modified `onSetDefault` callback, direct dictionary access |

## Final Behavior

```
OUTPUT DEVICES click → MenuBarPopupView callback
                              ↓
                      1. DeviceVolumeMonitor.setDefaultDevice() (system)
                      2. AudioEngine.routeAllApps(to:) (all apps)
                              ↓
                      All apps routed + system default set + UI updates immediately

Per-app dropdown → (unchanged - still routes individual app)
```

## Testing Notes

- Click device in OUTPUT DEVICES → all apps route there
- Per-app dropdown → single app override still works
- Click same device already selected → no-op (optimized)
- Empty apps list → graceful handling with debug log
