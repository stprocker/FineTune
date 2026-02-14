# Agent 2: Phase 2A - Input Device Management

**Agent ID:** a108cc2
**Date:** 2026-02-07
**Task:** Add input device monitoring, volume/mute controls, input device lock with 2s heuristic, input tab UI

---

## Files Modified

### 1. AudioDeviceMonitor.swift (+296 lines)

- Added parallel input device tracking: `inputDevices`, `inputDevicesByUID`, `inputDevicesByID`, `knownInputDeviceUIDs`
- Added `onInputDeviceConnected` and `onInputDeviceDisconnected` callbacks
- Added `hasInputStreams()` check in device discovery
- Added input device discovery in `refresh()`/`readDeviceDataFromCoreAudio()`
- Added connected/disconnected input device detection in `handleDeviceListChangedAsync()`

### 2. DeviceVolumeMonitor.swift (+371 lines)

- Init signature changed from `(deviceMonitor:)` to `(deviceMonitor:, settingsManager:)`
- Added input device state: `inputVolumes`, `inputMuteStates`, `defaultInputDeviceID`, `defaultInputDeviceUID`
- Added CoreAudio listeners for input scope properties (`kAudioDevicePropertyVolumeScalar`, `kAudioDevicePropertyMute` on `kAudioDevicePropertyScopeInput`)
- Added `setInputVolume()`, `setInputMute()`, `setDefaultInputDevice()`
- Added callbacks: `onInputVolumeChanged`, `onInputMuteChanged`, `onDefaultInputDeviceChanged`

### 3. AudioDeviceID+Volume.swift (+112 lines)

- Added `readInputVolumeScalar()`, `setInputVolumeScalar()`, `readInputMuteState()`, `setInputMuteState()` using `kAudioDevicePropertyScopeInput`

### 4. AudioObjectID+System.swift (+61 lines)

- Added `readDefaultInputDevice()`, `readDefaultInputDeviceUID()`, `setDefaultInputDevice()`

### 5. AudioDeviceID+Classification.swift (+36 lines)

- Added `suggestedInputIconSymbol()` for input device SF Symbols (mic, headphones.circle, hifispeaker, desktopcomputer, etc.)

### 6. AudioEngine.swift

- Added `inputDevices` computed property returning `deviceMonitor.inputDevices`
- Added input lock state: `didInitiateInputSwitch`, `lastInputDeviceConnectTime`, `autoSwitchGracePeriod = 2.0`
- Updated `DeviceVolumeMonitor` instantiation to pass `settingsManager`
- Wired input device callbacks in init:
  - `deviceMonitor.onInputDeviceDisconnected` -> logs + `handleInputDeviceDisconnected`
  - `deviceMonitor.onInputDeviceConnected` -> logs + records `lastInputDeviceConnectTime`
  - `deviceVolumeMonitor.onDefaultInputDeviceChanged` -> dispatches to `handleDefaultInputDeviceChanged`
- Added `restoreLockedInputDevice()` call after `applyPersistedSettings()` in startup
- Added input device lock methods:
  - `handleDefaultInputDeviceChanged(_:)` -- 2-second timing heuristic to distinguish auto-switch from user action
  - `restoreLockedInputDevice()` -- restores locked device or falls back to built-in mic
  - `lockToBuiltInMicrophone()` -- finds built-in mic via `readTransportType() == .builtIn`
  - `setLockedInputDevice(_:)` -- public method for UI (persists and applies)
  - `handleInputDeviceDisconnected(_:)` -- falls back to built-in mic if locked device disconnects

### 7. MuteButton.swift (+65 lines)

- Refactored to `BaseMuteButton` (private shared impl) + `MuteButton` (speaker) + `InputMuteButton` (mic)
- `InputMuteButton` uses `mic.slash.fill` / `mic.fill` icons
- All existing `MuteButton` behavior preserved unchanged

### 8. MenuBarPopupViewModel.swift

- Added `showingInputDevices: Bool` state (false = output tab, true = input tab)
- Added `sortedInputDevices` computed property (default first, then alphabetical)
- Added `defaultOutputDeviceName` and `defaultInputDeviceName` computed properties

### 9. MenuBarPopupView.swift (+321 lines)

- Added `@Namespace` for matchedGeometryEffect animation
- Replaced static "Output Devices" header with output/input tab toggle (speaker/mic pill) with sliding highlight
- Added `defaultDevicesStatus` showing "speaker DeviceName . mic DeviceName" in header
- Switched to tab-aware device section: shows output or input devices
- Input device rows: `InputDeviceRow` with radio button for locking, volume slider 0-100%, `InputMuteButton`

## New Files

### InputDeviceRow.swift (NEW)

- Same structure as `DeviceRow` but for input devices
- Uses `DeviceIconView(icon: device.icon, fallbackSymbol: "mic")`
- Uses `InputMuteButton` instead of `MuteButton`
- `LiquidGlassSlider` with 0-100% range (no volume boost for input)
- `.autoUnmuteOnSliderMove()` modifier
- Preview with 3 mock input devices

## Build Result

BUILD SUCCEEDED -- 18 files changed, +2,012/-197 lines.
