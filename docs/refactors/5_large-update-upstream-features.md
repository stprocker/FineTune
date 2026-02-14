# Large Update: Upstream Feature Integration

**Date:** 2026-02-07
**Session:** 5 (Large Update)
**Agents:** 5 parallel implementation agents + team lead coordination

---

## Overview

Integrated 8 features from the upstream FineTune repo (ronitsingh10/FineTune) into the local fork while preserving local robust backends (CrossfadeState state machine, TapResources encapsulation, AudioFormatConverter, decomposed processing pipeline, MVVM pattern, nonisolated flushSync, listener helpers).

## Features Implemented

| # | Feature | Phase | Status |
|---|---------|-------|--------|
| 1 | Device Reconnect Handling | 1A + 1B | Complete |
| 2 | Input Device Management | 2A | Complete |
| 3 | System Sound Effects Device | 2B | Partial (UI + API done, DeviceVolumeMonitor wiring documented) |
| 4 | Multi-Device Output Per App | 3 | Pending (model infrastructure ready) |
| 5 | Pinned Apps | 4A | Complete |
| 6 | Settings Panel | 4B | Complete |
| 7 | Customizable Menu Bar Icon | 4C | Complete |
| 8 | URL Scheme API | 5A | Complete |
| 9 | Auto-Update (Sparkle) | 5B | Pending |
| 10 | Homebrew Cask | 5C | Pending |

**Explicitly excluded:** Max volume boost increase to 400% (kept at 200%).

## Change Statistics

- **18 files modified**, **13 new files created**
- **+2,012 lines** added, **-197 lines** removed
- Build result: **zero errors, zero warnings**

## Files Changed

### Modified Files

| File | Lines Changed | Description |
|------|--------------|-------------|
| `SettingsManager.swift` | +213 | AppSettings, MenuBarIconStyle, PinnedAppInfo, pinning/inactive methods |
| `VolumeState.swift` | +154/-43 | AppAudioState, DeviceSelectionMode, multi-device tracking |
| `AudioDeviceMonitor.swift` | +296/-27 | Input device tracking, onDeviceConnected callback |
| `AudioEngine.swift` | +360/-6 | Input lock, reconnect, pinned apps, displayableApps |
| `DeviceVolumeMonitor.swift` | +371/-18 | Input volume/mute, settingsManager parameter |
| `AudioDeviceID+Volume.swift` | +112 | Input volume read/write |
| `AudioDeviceID+Classification.swift` | +36 | Input icon symbols |
| `AudioObjectID+System.swift` | +61 | Input/system device read/write/set |
| `MuteButton.swift` | +65 | BaseMuteButton + InputMuteButton |
| `MenuBarStatusController.swift` | +43/-7 | Live icon switching, applyIcon() |
| `MenuBarPopupView.swift` | +321/-120 | Input/output tab toggle, pinned apps |
| `MenuBarPopupViewModel.swift` | +41/-5 | Input tab state, EQ ID type change |
| `AppRow.swift` | +79/-3 | Pin star button with hover |
| `DesignTokens.swift` | +14 | Settings dimensions |
| `FineTuneApp.swift` | +11 | URL scheme handling |
| `Info.plist` | +11 | URL scheme registration |
| `Info-Debug.plist` | +11 | URL scheme registration |
| `project.pbxproj` | +10/-1 | Xcode project references |

### New Files

| File | Purpose |
|------|---------|
| `DisplayableApp.swift` | Enum for active + pinned inactive apps |
| `URLHandler.swift` | 6-action URL scheme handler |
| `InputDeviceRow.swift` | Input device UI row |
| `InactiveAppRow.swift` | Pinned inactive app UI row |
| `EditablePercentage.swift` | Click-to-edit inline percentage |
| `SettingsView.swift` | Main settings panel |
| `SettingsRowView.swift` | Generic settings row base |
| `SettingsToggleRow.swift` | Toggle settings row |
| `SettingsSliderRow.swift` | Slider settings row |
| `SettingsButtonRow.swift` | Button settings row |
| `SettingsIconPickerRow.swift` | 4-option icon picker |
| `SoundEffectsDeviceRow.swift` | Sound effects device picker |
| `SystemSoundsDeviceChanges.swift` | Integration documentation |

## Key Design Decisions

### 1. "Follow Default" Pattern (Phase 1B)
Replaced the old `routeAllApps(to:)` approach with `followsDefault: Set<pid_t>`. During disconnect, apps are displaced to the default device IN MEMORY ONLY -- the persisted routing is preserved. On reconnect, persisted routings are checked against the reconnected device UID to restore routing automatically.

### 2. Input Device Lock Heuristic (Phase 2A)
Uses a 2-second timing heuristic (`autoSwitchGracePeriod = 2.0`) to distinguish between macOS auto-switching input devices (when Bluetooth connects) and intentional user changes. If a new input device connects and the default changes within 2 seconds, it's treated as auto-switch and restored.

### 3. Settings Panel Decoupling (Phase 4B)
SettingsView accepts system sound state through explicit parameters rather than directly referencing DeviceVolumeMonitor, so it compiles without the pending DeviceVolumeMonitor system sound integration.

### 4. EQ ID Type Change (Phase 4A)
Changed `expandedEQAppID` from `pid_t?` to `String?` to support both active apps (identified by PID) and inactive pinned apps (identified by persistence identifier).

### 5. URL Scheme Volume Cap (Phase 5A)
Volume range capped at 200 (local max boost), not upstream's 400. Uses local `VolumeMapping` dB curve for step operations.

## Known Issues

### Menu Bar Icon Not Appearing
After the `MenuBarStatusController` changes to support live icon switching, the menu bar icon doesn't appear despite logs showing "Menu bar status item created". The `applyIcon(style: .default, to: button)` code path is functionally identical to the original hardcoded approach. Under investigation.

## Remaining Work

### Phase 3: Multi-Device Output Per App
Model infrastructure is ready (`DeviceSelectionMode`, `selectedDeviceUIDs` in VolumeState and SettingsManager). Still needs:
- ProcessTapController changes (multi-device aggregates with `kAudioAggregateDeviceIsStackedKey`)
- ModeToggle view (single/multi switch)
- DevicePicker multi-select mode
- AudioEngine orchestration methods

### Phase 5B: Auto-Update (Sparkle)
- SPM dependency addition
- UpdateManager.swift
- EdDSA key generation
- CI/CD appcast step
- Entitlements changes

### Phase 5C: Homebrew Cask
- Separate tap repo creation

### System Sounds DeviceVolumeMonitor Integration
Documented in `SystemSoundsDeviceChanges.swift`. Needs to be applied to DeviceVolumeMonitor for full system sounds support.

## Agent Assignments

| Agent | Phases | Files Touched |
|-------|--------|---------------|
| Team Lead | 1A (SettingsManager + VolumeState) | 2 files |
| Agent ad1dfbe | 1B (Device reconnect) | 2 files |
| Agent a108cc2 | 2A (Input devices) | 9 files + 1 new |
| Agent aa2fd2b | 2B + 4B + 4C (System sounds, settings, icon) | 3 files + 9 new |
| Agent a5d22d0 | 4A (Pinned apps) | 4 files + 2 new |
| Agent a4619fe | 5A (URL scheme) | 3 files + 1 new |

## Build Errors Encountered and Fixed

1. **CoreAudioTypes import** -- SettingsView initially had `import CoreAudioTypes` which doesn't expose `AudioDeviceID`. Fixed with `import CoreAudio`.
2. **SoundEffectsDeviceRow API mismatch** -- Agent created SoundEffectsDeviceRow calling DevicePicker with parameters it doesn't accept (`isFollowingDefault`, `defaultDeviceUID`, `onSelectFollowDefault`). Fixed by rewriting to use native SwiftUI `Menu` instead.
3. **File contention between agents** -- Agents editing the same files hit "File has been modified since read" errors. Agents recovered by re-reading files before writing.
