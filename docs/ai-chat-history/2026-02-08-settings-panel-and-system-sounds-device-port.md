# Settings Panel Restoration + System Sounds Device Port

**Date:** 2026-02-08
**Status:** Complete (build verified)
**Runtime tested:** No

## Summary

Restored the missing Settings gear button and settings panel to the menu bar popup, and ported the system sounds device tracking feature from the original developer's codebase into the fork's `DeviceVolumeMonitor`.

## Problem

The fork's `MenuBarPopupView` had no way to access the Settings panel. During the Phase 4 ViewModel extraction refactoring (2026-02-07), the settings gear button, settings panel transition, `Cmd+,` keyboard shortcut, and all `SettingsView` wiring were stripped from `MenuBarPopupView`. The `SettingsView.swift` file existed with full UI code, but nothing in the app could open it.

Additionally, the original developer's codebase had full system sounds device tracking (allowing users to route macOS alerts/notifications/Siri to a specific output device), but this was never ported to the fork. The fork had a documentation stub (`SystemSoundsDeviceChanges.swift`) describing the integration plan, but no executable code.

## What Was Done

### Part 1: Settings Panel Restoration

#### Files Modified

**`FineTune/Views/MenuBarPopupViewModel.swift`**
- Added `isSettingsOpen` state (Bool)
- Added `isSettingsAnimating` debounce flag
- Added `localAppSettings: AppSettings` for settings binding
- Added `updateManager: UpdateManager` (Sparkle integration) - instantiated in init
- Added `onIconChanged: ((MenuBarIconStyle) -> Void)?` callback for live menu bar icon switching
- Added `toggleSettings()` method with animation debounce
- Added `syncSettings()` method to push `localAppSettings` changes back to `SettingsManager`

**`FineTune/Views/MenuBarPopupView.swift`**
- Added gear icon button (`gearshape.fill`) in the header that morphs to `xmark` when settings are open, with spring rotation animation
- Added `settingsButton` computed property with the full animated button implementation
- Extracted main popup content into `mainContent` computed property to support slide transitions
- Added conditional rendering: when `isSettingsOpen`, shows `SettingsView` with slide-from-right transition; otherwise shows `mainContent` with slide-from-left transition
- Header shows "Settings" title when settings are open, device tabs + default device status when closed
- Added `onChange(of: viewModel.localAppSettings)` to sync settings changes back to storage
- Added hidden `Cmd+,` keyboard shortcut button for settings toggle
- Wired `SettingsView` with all required parameters:
  - `settings` binding to `viewModel.localAppSettings`
  - `updateManager` from viewModel
  - `onResetAll` callback that resets settings + syncs system sounds to follow default
  - `outputDevices` from audioEngine
  - System sounds device properties from `deviceVolumeMonitor` (see Part 2)
  - `currentIconStyle` from settings manager
  - `onIconChanged` callback from viewModel

**`FineTune/Views/MenuBar/MenuBarStatusController.swift`**
- Added `popupViewModel: MenuBarPopupViewModel?` stored reference
- In `createPanel()`: stores viewModel reference and wires `onIconChanged` callback to `updateIcon(to:)` so icon changes from Settings update the actual menu bar icon live

### Part 2: System Sounds Device Tracking Port

#### Files Modified

**`FineTune/Audio/DeviceVolumeMonitor.swift`** - Major additions:

**New State Properties:**
- `systemDeviceID: AudioDeviceID` - current system output device ID (for alerts, notifications, system sounds)
- `systemDeviceUID: String?` - cached system output device UID
- `isSystemFollowingDefault: Bool` - whether system sounds follow the macOS default output device

**New Listener Infrastructure:**
- `systemDeviceListenerBlock: AudioObjectPropertyListenerBlock?` - CoreAudio listener for `kAudioHardwarePropertyDefaultSystemOutputDevice`
- `systemDeviceDebounceTask: Task<Void, Never>?` - debounce task for system device changes
- `systemDeviceAddress: AudioObjectPropertyAddress` - property address for system output device

**New Methods:**
- `refreshSystemDevice()` - reads current system output device from CoreAudio via `AudioDeviceID.readDefaultSystemOutputDevice()`
- `validateSystemSoundState()` - on startup, if "follow default" is persisted but system device differs from default, enforces the preference by setting the system device
- `handleSystemDeviceChanged()` - handles system device change listener notifications; detects external changes that break "follow default" state and persists the new state
- `setSystemFollowDefault()` - public method: sets system sounds to follow default, persists via `SettingsManager.setSystemSoundsFollowDefault(true)`, immediately syncs to current default
- `setSystemDeviceExplicit(_ deviceID:)` - public method: sets system sounds to a specific device, stops following default, persists

**Modified Methods:**
- `init()` - now loads `isSystemFollowingDefault` from `settingsManager.isSystemSoundsFollowingDefault` and calls `refreshSystemDevice()`
- `start()` - now calls `refreshSystemDevice()`, `validateSystemSoundState()`, and registers the system device listener with debouncing
- `stop()` - now removes system device listener, cancels debounce task, clears `systemDeviceID`/`systemDeviceUID`
- `applyDefaultDeviceChange()` - now syncs system sounds to new default when `isSystemFollowingDefault` is true
- `handleServiceRestarted()` - now calls `refreshSystemDevice()` in the recovery block

#### Pre-existing Dependencies Used (no changes needed)
- `AudioDeviceID.readDefaultSystemOutputDevice()` in `AudioObjectID+System.swift`
- `AudioDeviceID.setSystemOutputDevice(_:)` in `AudioObjectID+System.swift`
- `SettingsManager.isSystemSoundsFollowingDefault` / `.setSystemSoundsFollowDefault(_:)` in `SettingsManager.swift`
- `SoundEffectsDeviceRow.swift` - existing UI component for device picker in settings
- `SettingsView.swift` - existing settings panel with all system sounds parameters

## Architecture

The settings panel uses an inline slide-in pattern within the menu bar popup (not a separate window):

```
MenuBarPopupView
  -> Header: [Device Tabs | Default Devices Status | Gear Button]
  -> if isSettingsOpen:
       SettingsView (slide from right)
     else:
       mainContent (devices + apps + quit) (slide from left)
```

System sounds device tracking follows the same pattern as default output device tracking:
```
CoreAudio Listener -> debounce -> handleSystemDeviceChanged() -> refreshSystemDevice()
                                                              -> detect external "follow default" break
User action (Settings UI) -> setSystemFollowDefault() or setSystemDeviceExplicit()
                          -> CoreAudio write -> refreshSystemDevice() -> persist to SettingsManager
Default device change -> applyDefaultDeviceChange() -> if following, sync system device too
```

## Build Verification

Build succeeds with `xcodebuild -scheme FineTune -configuration Debug build` after all changes.

## TODO / Known Issues

### Must Fix Before Release

1. **Runtime test settings panel** - The settings gear button, transitions, and all wiring are compile-verified only. Need to launch the app and verify:
   - Gear button appears in popup header
   - Clicking gear slides in settings panel
   - Clicking X slides back to main view
   - `Cmd+,` keyboard shortcut works
   - Settings changes persist (toggle launch at login, change icon, etc.)
   - Menu bar icon changes live when selecting a new icon style
   - "Reset All Settings" works and resets system sounds to follow default

2. **Runtime test system sounds device** - The system sounds device tracking is compile-verified only. Need to verify:
   - Sound Effects device row appears in Settings > Audio section
   - "Follow Default" is selected by default
   - Selecting an explicit device routes system sounds correctly (test with `afplay /System/Library/Sounds/Ping.aiff`)
   - Selecting "Follow Default" again syncs back to default
   - Changing default output device also changes system sounds device when following
   - External change (via System Settings > Sound) properly breaks "follow default" state
   - State persists across app restarts

3. **`SystemSoundsDeviceChanges.swift` cleanup** - This file is now a dead documentation stub (200 lines of comments, no executable code). Should be deleted since the integration is complete.

### Known Issues (Pre-existing, Not Introduced by This Change)

4. **Per-app volume fix is compile-verified only** - stereo mixdown constructor builds successfully but has not been runtime-tested yet (from 2026-02-07 session)

5. **Dead code in `AudioEngine.swift`** - `permissionConfirmed`, `upgradeTapsToMutedWhenTapped()`, `shouldConfirmPermission()` are unreachable but not yet removed (from 2026-02-07 session)

6. **Bundle-ID tap aggregate output dead on macOS 26** - bundle-ID taps (required for capture on macOS 26) create aggregate devices where the output path doesn't reach the physical device. Root cause under investigation. (from 2026-02-07 session)

### Future Enhancements

7. **Device disconnect handling for system sounds** - The integration guide's `validateSystemSoundState()` includes logic to detect when the explicit system sound device is disconnected and fall back to "follow default". This is partially implemented in the startup validation but could be wired into the device list observation loop for runtime disconnect handling.

8. **`SettingsView` parameter cleanup** - The fork's `SettingsView` takes 11 individual parameters. The OG version takes `@Bindable var deviceVolumeMonitor` directly, which is cleaner. Consider refactoring to pass the monitor object instead of individual properties.

9. **Settings panel doesn't reset to closed on popup dismiss** - When the popup is dismissed (click outside), `isSettingsOpen` remains true. Next time the popup opens, it shows settings instead of the main view. The OG may have the same behavior, but it could be improved by resetting `isSettingsOpen = false` on `windowDidResignKey`.

## Files Changed (Summary)

| File | Change |
|------|--------|
| `FineTune/Views/MenuBarPopupViewModel.swift` | Added settings state, UpdateManager, icon callback, toggleSettings/syncSettings |
| `FineTune/Views/MenuBarPopupView.swift` | Added settings button, panel, transitions, Cmd+, shortcut, full SettingsView wiring |
| `FineTune/Views/MenuBar/MenuBarStatusController.swift` | Stored viewModel reference, wired onIconChanged to updateIcon |
| `FineTune/Audio/DeviceVolumeMonitor.swift` | Added system device state, listener, refresh/validate/handle/set methods, wired into init/start/stop/default-change/service-restart |
