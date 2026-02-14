# Agent 3: Phase 2B + 4B + 4C - System Sounds, Settings Panel, Menu Bar Icon

**Agent ID:** aa2fd2b
**Date:** 2026-02-07
**Task:** System sound effects device routing, complete settings panel, customizable menu bar icon with live switching

---

## Phase 2B: System Sound Effects Device

### AudioObjectID+System.swift - Modified

Added `setSystemOutputDevice(_:)` as a new `extension AudioDeviceID` block (MARK: System Output Device). Writes `kAudioHardwarePropertyDefaultSystemOutputDevice` via `AudioObjectSetPropertyData`.

### SystemSoundsDeviceChanges.swift - Created (Documentation)

Documentation-only Swift file with comprehensive integration guide for DeviceVolumeMonitor:
- New state properties: `systemDeviceID`, `systemDeviceUID`, `isSystemFollowingDefault`
- Listener for `kAudioHardwarePropertyDefaultSystemOutputDevice`
- Methods: `refreshSystemDevice()`, `validateSystemSoundState()`, `handleSystemDeviceChanged()`
- Public API: `setSystemFollowDefault()`, `setSystemDeviceExplicit(_:)`
- Wiring instructions for connecting to SettingsView

### SoundEffectsDeviceRow.swift - Created

Settings row with bell icon, "Sound Effects" title, device picker with "Follow Default" option + device list using native SwiftUI `Menu`.

---

## Phase 4B: Settings Panel

### Prerequisites Created

The local codebase had no Settings views, so created all building blocks:

1. **DesignTokens.swift** - Added `settingsIconWidth`, `settingsSliderWidth`, `settingsPercentageWidth`, `settingsPickerWidth` to Dimensions enum
2. **EditablePercentage.swift** - Inline percentage editor with click-to-edit, text field with `%` suffix, click-outside detection
3. **SettingsRowView.swift** - Generic base row with icon, title, description, and `@ViewBuilder` control slot
4. **SettingsToggleRow.swift** - Row with native `.switch` toggle
5. **SettingsSliderRow.swift** - Row with `Slider` + `EditablePercentage`
6. **SettingsButtonRow.swift** - Row with action button, supporting destructive appearance

### SettingsView.swift - Created

Main settings panel with sections:
- **General:** Launch at Login toggle, Menu Bar Icon picker (with live callback)
- **Audio:** Default volume slider (10%-100%), Max volume boost slider, Input Device Lock toggle, Sound Effects Device picker
- **Notifications:** Show device disconnect alerts toggle
- **Data:** Reset all settings with inline confirmation (not system dialog)
- **About Footer:** Version display, GitHub link, copyright

**Design decision:** Since DeviceVolumeMonitor doesn't have system sound properties yet, SettingsView accepts system sound state through explicit parameters (`systemDeviceUID`, `isSystemFollowingDefault`, `onSystemDeviceSelected`, etc.) rather than directly referencing DeviceVolumeMonitor.

**Note:** The upstream uses `UpdateManager` (Sparkle dependency) which doesn't exist locally, so auto-update row was omitted.

---

## Phase 4C: Customizable Menu Bar Icon

### SettingsIconPickerRow.swift - Created

- 4 icon options as selectable tiles (Default asset, Speaker, Waveform, Equalizer)
- Uses `MenuBarIconStyle` enum from SettingsManager
- `onIconChanged` callback for live switching (no restart needed)
- Accent-colored selection indicator with border highlight

### MenuBarStatusController.swift - Modified

- In `start()`: reads icon style from `audioEngine.settingsManager.appSettings.menuBarIconStyle` instead of hardcoded "MenuBarIcon"
- Added `updateIcon(to:)` public method for live switching
- Added `applyIcon(style:to:)` helper handling both SF Symbols and asset catalog icons with fallbacks

---

## Files Modified (3)

| File | Change |
|------|--------|
| `AudioObjectID+System.swift` | Added `setSystemOutputDevice(_:)` |
| `MenuBarStatusController.swift` | Live icon switching |
| `DesignTokens.swift` | Settings dimensions |

## Files Created (9)

| File | Purpose |
|------|---------|
| `SystemSoundsDeviceChanges.swift` | Integration guide for DeviceVolumeMonitor |
| `EditablePercentage.swift` | Inline percentage editor |
| `SettingsRowView.swift` | Base settings row |
| `SettingsToggleRow.swift` | Toggle row |
| `SettingsSliderRow.swift` | Slider row |
| `SettingsButtonRow.swift` | Button row |
| `SoundEffectsDeviceRow.swift` | Sound effects device picker |
| `SettingsIconPickerRow.swift` | Menu bar icon picker |
| `SettingsView.swift` | Main settings panel |
