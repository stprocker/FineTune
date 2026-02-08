# FineTune Fork: Feature Integration Plan

## Overview

This plan adds 8 features from the upstream FineTune repo (ronitsingh10/FineTune) to the fork. The features are organized into 5 phases based on dependency chains. Each phase lists exact files, what changes, and why.

**Reference repo:** `/tmp/FineTune_compare` (cloned from upstream)

---

## Phase 1: Settings Infrastructure + Device Reconnect

These are foundational changes that other phases depend on. No new UI files needed.

### 1A. Expand SettingsManager (prerequisite for everything)

**Why first:** 6 of 8 features need new settings fields. Do it once, bump the version once.

**File: `FineTune/Settings/SettingsManager.swift`**
- Add `AppSettings` struct (general/audio/notification preferences):
  ```
  lockInputDevice: Bool = true
  menuBarIconStyle: MenuBarIconStyle = .default
  showDeviceDisconnectAlerts: Bool = true
  defaultNewAppVolume: Float = 0.5
  launchAtLogin: Bool = false
  ```
- Add `MenuBarIconStyle` enum (`.default`, `.speaker`, `.waveform`, `.equalizer`) with `iconName` and `isSystemSymbol` computed properties
- Add new fields to `Settings` struct:
  ```
  appSettings: AppSettings
  pinnedApps: Set<String>
  pinnedAppInfo: [String: PinnedAppInfo]
  lockedInputDeviceUID: String?
  systemSoundsFollowsDefault: Bool = true
  appDeviceSelectionMode: [String: DeviceSelectionMode]
  appSelectedDeviceUIDs: [String: [String]]
  ```
- Add `PinnedAppInfo` struct (persistenceIdentifier, displayName, bundleID)
- Add `DeviceSelectionMode` enum (`.single`, `.multi`)
- Add getter/setter methods for all new fields
- Bump settings version from 4 to 5
- Ensure backward-compatible decoding (all new fields have defaults, old v4 files decode cleanly)
- Update `resetAllSettings()` if it exists (or add it)

**File: `FineTune/Models/VolumeState.swift`**
- Add `DeviceSelectionMode` awareness (used later in Phase 3)
- Add `selectedDeviceUIDs` per-app tracking: `[pid_t: Set<String>]`
- Add `deviceSelectionMode` per-app tracking: `[pid_t: DeviceSelectionMode]`
- Add load/save bridge methods for persistence identifier mapping

### 1B. Device Reconnect Handling

**Why here:** Small, self-contained change to AudioDeviceMonitor and AudioEngine. No new views. Unblocks reliable device routing for multi-device (Phase 3).

**File: `FineTune/Audio/AudioDeviceMonitor.swift`**
- Add `onDeviceConnected: ((_ uid: String, _ name: String) -> Void)?` callback (parallel to existing `onDeviceDisconnected`)
- In `handleDeviceListChangedAsync()`: compute `connectedUIDs = currentUIDs.subtracting(previousUIDs)`, fire `onDeviceConnected` for each

**File: `FineTune/Audio/AudioEngine.swift`**
- Wire `deviceMonitor.onDeviceConnected` in `init()` to new `handleDeviceConnected(_:name:)` method
- Add `handleDeviceConnected(_:name:)`:
  - Iterate all active taps
  - For each app, check if persisted routing (`settingsManager.getDeviceRouting`) matches reconnected device UID
  - If yes AND app is currently on a different device (was displaced), switch back via `setDevice(for:deviceUID:)`
  - Show reconnect notification if `appSettings.showDeviceDisconnectAlerts` is true
- Add `showReconnectNotification(deviceName:affectedApps:)`
- **CRITICAL CHANGE to `handleDeviceDisconnected()`**: Currently (line ~1059) calls `setDevice(for:deviceUID:)` which persists the fallback routing, destroying the original preference. Change to:
  - Update `appDeviceRouting[app.id]` in memory only
  - Call `tap.switchDevice(to: fallbackUID)` directly (not through `setDevice` which persists)
  - Do NOT call `settingsManager.setDeviceRouting` -- the persisted UID stays as the user's preferred device
  - This preserves the original routing for reconnect recovery
- Add `followsDefault: Set<pid_t>` to track apps temporarily displaced to default (used by reconnect handler to skip apps that the user intentionally set to default)

---

## Phase 2: Input Devices + System Sound Effects

Two device-related features. Both modify `DeviceVolumeMonitor` and the device section of the UI. Do them together to avoid merge conflicts.

### 2A. Input Device Management

**File: `FineTune/Audio/AudioDeviceMonitor.swift`**
- Add parallel tracking for input devices:
  - `inputDevices: [AudioDevice]`
  - `inputDevicesByUID: [String: AudioDevice]`
  - `inputDevicesByID: [AudioDeviceID: AudioDevice]`
  - `knownInputDeviceUIDs: Set<String>`
- Add callbacks: `onInputDeviceDisconnected`, `onInputDeviceConnected`
- In `refresh()` / `readDeviceDataFromCoreAudio()`: add `hasInputStreams()` path, create input `AudioDevice` instances with `suggestedInputIconSymbol()` fallback
- In `handleDeviceListChangedAsync()`: diff input UIDs for connect/disconnect

**File: `FineTune/Audio/Extensions/AudioDeviceID+Volume.swift`**
- Add `readInputVolumeScalar()` -- same multi-strategy as output but with `kAudioDevicePropertyScopeInput`
- Add `setInputVolumeScalar(_:)` -- `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` + input scope
- Add `readInputMuteState()` -- `kAudioDevicePropertyMute` + input scope
- Add `setInputMuteState(_:)` -- `kAudioDevicePropertyMute` + input scope

**File: `FineTune/Audio/Extensions/AudioObjectID+System.swift`**
- Add `readDefaultInputDevice()` -- reads `kAudioHardwarePropertyDefaultInputDevice`
- Add `readDefaultInputDeviceUID()` -- reads device then gets UID
- Add `setDefaultInputDevice(_:)` -- writes `kAudioHardwarePropertyDefaultInputDevice`

**File: `FineTune/Audio/Extensions/AudioDeviceID+Classification.swift`**
- Add `suggestedInputIconSymbol()` -- SF Symbols for input devices (mic, iPhone, iPad, AirPods, etc.)

**File: `FineTune/Audio/DeviceVolumeMonitor.swift`**
- Add input device state: `inputVolumes`, `inputMuteStates`, `defaultInputDeviceID`, `defaultInputDeviceUID`
- Add CoreAudio property addresses for input scope
- Add listener for `kAudioHardwarePropertyDefaultInputDevice`
- Add `refreshInputDeviceListeners()` -- registers per-device volume/mute listeners for input devices
- Add `startObservingInputDeviceList()` -- watches for input device list changes
- Add methods: `setInputVolume(for:to:)`, `setInputMute(for:to:)`, `setDefaultInputDevice(_:)`
- Add callbacks: `onInputVolumeChanged`, `onInputMuteChanged`, `onDefaultInputDeviceChanged`
- Note: Pass `settingsManager` to init (currently only takes `deviceMonitor`) -- needed for system sounds too

**File: `FineTune/Audio/AudioEngine.swift`**
- Add `inputDevices` computed property (from `deviceMonitor.inputDevices`)
- Add input device lock state: `didInitiateInputSwitch`, `lastInputDeviceConnectTime`, `autoSwitchGracePeriod = 2.0`
- Wire `deviceMonitor.onInputDeviceConnected` to record `lastInputDeviceConnectTime`
- Wire `deviceVolumeMonitor.onDefaultInputDeviceChanged` to `handleDefaultInputDeviceChanged(_:)`
- Add `handleDefaultInputDeviceChanged(_:)`:
  - If `didInitiateInputSwitch`, reset flag and return
  - If lock disabled, do nothing
  - If within 2s of device connect (auto-switch), call `restoreLockedInputDevice()`
  - Otherwise, user intentionally changed it -- update `settingsManager.lockedInputDeviceUID`
- Add `restoreLockedInputDevice()` -- looks up locked UID, sets default if found, falls back to built-in mic
- Add `setLockedInputDevice(_:)` -- persists choice and applies
- Add `handleInputDeviceDisconnected(_:)` -- falls back to built-in mic if locked device disappears

**File: `FineTune/Views/Components/MuteButton.swift`**
- Refactor existing `MuteButton` into `BaseMuteButton` (shared icon rendering)
- Add `InputMuteButton` using `mic.slash.fill` / `mic.fill` icons

**New File: `FineTune/Views/Rows/InputDeviceRow.swift`**
- Input device row: radio button (default selector), device icon, name, `InputMuteButton`, `LiquidGlassSlider`, editable percentage
- Volume range: 0-100% (no boost, unlike output)
- Auto-unmute when slider moved while muted

**File: `FineTune/Views/MenuBarPopupView.swift`**
- Replace static "Output Devices" header with tab toggle (output/input pill toggle with speaker/mic icons)
- Add `sortedInputDevices` state, sync via `onChange(of: audioEngine.inputDevices)`
- Add input device list rendering using `InputDeviceRow`
- Add default input/output device display in header area
- Wire input volume/mute/default callbacks through to `DeviceVolumeMonitor` and `AudioEngine`

**File: `FineTune/Views/MenuBarPopupViewModel.swift`**
- Add `showingInputDevices: Bool` state for tab toggle
- Add input device sorting logic

### 2B. System Sound Effects Device

**File: `FineTune/Audio/Extensions/AudioObjectID+System.swift`**
- Add `setSystemOutputDevice(_:)` -- writes `kAudioHardwarePropertyDefaultSystemOutputDevice`
  (Note: `readDefaultSystemOutputDevice()` and `readDefaultSystemOutputDeviceUID()` already exist)

**File: `FineTune/Audio/DeviceVolumeMonitor.swift`**
- Add state: `systemDeviceID`, `systemDeviceUID`, `isSystemFollowingDefault`
- Add listener for `kAudioHardwarePropertyDefaultSystemOutputDevice`
- On startup: load `isSystemFollowingDefault` from settingsManager, call `refreshSystemDevice()`, call `validateSystemSoundState()`
- Add `refreshSystemDevice()` -- reads current system output device
- Add `validateSystemSoundState()` -- enforces saved preference if diverged
- Add `handleSystemDeviceChanged()` -- detects external changes, updates `isSystemFollowingDefault` if needed
- Modify existing `handleDefaultDeviceChanged()` -- if `isSystemFollowingDefault`, also update system device
- Add `setSystemFollowDefault()` -- sets flag, persists, syncs to current default
- Add `setSystemDeviceExplicit(_:)` -- sets flag false, persists, sets explicit device

**New File: `FineTune/Views/Settings/SoundEffectsDeviceRow.swift`**
- Settings row with `DevicePicker` showing output devices
- Shows "Sound Effects" with bell icon
- Supports selecting explicit device or "Follow Default" mode

**Note:** This feature's settings UI will be integrated into the Settings panel created in Phase 4.

---

## Phase 3: Multi-Device Output Per App

The most architecturally complex feature. Depends on Phase 1 (settings infrastructure, VolumeState changes, device reconnect).

**File: `FineTune/Audio/ProcessTapController.swift`**
- Change `targetDeviceUID: String` to `targetDeviceUIDs: [String]`
- Add `currentDeviceUIDs: [String]` read-only property
- Extract aggregate creation into `buildAggregateDescription(outputUIDs:tapUUID:name:)`:
  - For multi-device: set `kAudioAggregateDeviceIsStackedKey: true`
  - First device = `kAudioAggregateDeviceMainSubDeviceKey` and `kAudioAggregateDeviceClockDeviceKey`
  - Non-clock devices get `kAudioSubDeviceDriftCompensationKey: true`
  - Build sub-device list array from all UIDs
- Modify `activate()` to use `buildAggregateDescription()` instead of inline dict
- Add `updateDevices(to: [String])` public method:
  - If device set changed, perform crossfade switch to new aggregate with updated sub-device list
  - Reuse existing `performCrossfadeSwitch` mechanism (create secondary tap with new device set, crossfade, destroy primary)
- Modify `createSecondaryTap(for:)` to accept `[String]` device UIDs
- Keep `switchDevice(to: String)` as convenience for single-device (wraps `updateDevices(to: [uid])`)

**File: `FineTune/Audio/AudioEngine.swift`**
- Add methods:
  - `getDeviceSelectionMode(for:) -> DeviceSelectionMode`
  - `setDeviceSelectionMode(for:to:)` -- updates VolumeState, persists, calls `updateTapForCurrentMode`
  - `getSelectedDeviceUIDs(for:) -> Set<String>`
  - `setSelectedDeviceUIDs(for:to:)` -- updates VolumeState, persists, calls `updateTapForCurrentMode` if in multi mode
  - `updateTapForCurrentMode(for:)` -- resolves device UIDs based on mode (single vs multi), calls `tap.updateDevices(to:)`
  - `ensureTapWithDevices(for:deviceUIDs:)` -- creates new tap with specified device list
- Modify `handleDeviceDisconnected()` for multi-mode:
  - If multi-mode and >1 device remaining: remove disconnected device from set, call `tap.updateDevices(to: remaining)`, update in-memory state only (don't persist -- device may reconnect)
  - If all multi-mode devices gone: fall back to single-device default behavior
- Modify `handleDeviceConnected()` for multi-mode:
  - Check if reconnected device was in persisted multi-device set
  - If yes, add it back and call `tap.updateDevices(to: updatedSet)`
- Modify `applyPersistedSettings()` to restore multi-device mode and UIDs

**New File: `FineTune/Views/Components/ModeToggle.swift`**
- Simple segmented control: "Single" / "Multi" bound to `DeviceSelectionMode`
- Compact pill style matching existing design tokens

**File: `FineTune/Views/Components/DevicePicker.swift`**
- Add `showModeToggle: Bool` parameter
- When `showModeToggle` is true, render `ModeToggle` at top of dropdown
- In multi mode: device taps toggle checkbox selection (dropdown stays open), "System Audio" disabled
- In single mode: device taps select single device (dropdown closes) -- current behavior
- Add callbacks: `onModeChange`, `onDevicesSelected` (for multi)

**File: `FineTune/Views/Rows/AppRow.swift`**
- Add multi-device props: `selectedDeviceUIDs`, `deviceSelectionMode`, `onDevicesSelected`, `onDeviceModeChange`
- Wire through to `DevicePicker` with `showModeToggle: true`

**File: `FineTune/Views/MenuBarPopupView.swift`**
- Wire multi-device callbacks from AudioEngine to AppRow

**Known limitation:** The local repo has a macOS 26 guard that disables per-app device routing entirely (PID-only taps get zero callbacks on non-default devices). Multi-device output inherits this limitation on macOS 26. No workaround until Apple fixes `CATapDescription`.

---

## Phase 4: Pinned Apps + Settings Panel + Menu Bar Icon

These features are related through the settings UI and can be built together.

### 4A. Pinned Apps

**New File: `FineTune/Models/DisplayableApp.swift`**
- Enum: `.active(AudioApp)` | `.pinnedInactive(PinnedAppInfo)`
- Computed properties: `id` (persistenceIdentifier), `displayName`, `icon`, `isPinnedInactive`, `isActive`
- `loadIcon()` resolves app icon from bundle ID via `NSWorkspace`

**File: `FineTune/Audio/AudioEngine.swift`**
- Replace `displayedApps: [AudioApp]` with `displayableApps: [DisplayableApp]`
- Sort order: pinned-active (alphabetical) -> pinned-inactive (alphabetical) -> unpinned-active (alphabetical)
- Add methods:
  - `pinApp(_:)` -- creates `PinnedAppInfo`, delegates to settingsManager
  - `unpinApp(_:)` -- delegates to settingsManager
  - `isPinned(_:)` / `isPinned(identifier:)`
- Add inactive app settings methods (operate on persistence identifiers, not PIDs):
  - `getVolumeForInactive(identifier:)` / `setVolumeForInactive(identifier:to:)`
  - `getMuteForInactive(identifier:)` / `setMuteForInactive(identifier:to:)`
  - `getEQSettingsForInactive(identifier:)` / `setEQSettingsForInactive(_:identifier:)`
  - `getDeviceRoutingForInactive(identifier:)` / `setDeviceRoutingForInactive(identifier:deviceUID:)`
  - These read/write directly to SettingsManager by persistence identifier
  - When app starts producing audio, `applyPersistedSettings()` reads the same keys -- pre-configured settings apply automatically

**New File: `FineTune/Views/Rows/InactiveAppRow.swift`**
- Takes `PinnedAppInfo` and `NSImage` instead of `AudioApp`
- Star button always filled (always pinned), action = unpin
- App icon at 0.6 opacity, name in secondary text color (dimmed)
- VU meter always shows level 0
- No app activation on icon click
- Same control bar for volume/mute/EQ/device (reads/writes via inactive methods)

**File: `FineTune/Views/Rows/AppRow.swift`**
- Add `isPinned: Bool` and `onPinToggle: () -> Void` properties
- Add star button left of app icon (filled when pinned, outline when not)
- Star visibility: always visible when pinned; only on hover when not pinned
- Add `isRowHovered` state for hover tracking

**File: `FineTune/Views/MenuBarPopupView.swift`**
- Switch from `ForEach(audioEngine.displayedApps)` to `ForEach(audioEngine.displayableApps)`
- Pattern match on `DisplayableApp` enum to render `AppRow` or `InactiveAppRow`
- Pass `isPinned` and `onPinToggle` to AppRow

**File: `FineTune/Views/MenuBarPopupViewModel.swift`**
- Change `expandedEQAppID` from `pid_t?` to `String?` (works with both active PIDs and inactive identifiers)
- Update `toggleEQ` signature accordingly

**Coexistence with `isPaused`:** When an app is both pinned and in the paused state (recently stopped audio), show it as active-pinned (not inactive). Only apps not in `processMonitor.activeApps` at all should appear as `pinnedInactive`.

### 4B. Settings Panel

Currently the local repo has NO settings UI. The remote has a full settings panel. Create a minimal settings panel that houses controls for all new features.

**New File: `FineTune/Views/Settings/SettingsView.swift`**
- Sections:
  - **General:** Launch at Login toggle, Menu Bar Icon picker
  - **Audio:** Default volume for new apps, Input Device Lock toggle, Sound Effects Device picker
  - **Notifications:** Show device disconnect/reconnect alerts toggle
  - **Updates:** (Phase 5) Check for updates, auto-check toggle, version info
  - **Reset:** Reset all settings button with inline confirmation

**File: `FineTune/Views/MenuBarPopupView.swift`**
- Add gear icon button in the header/footer that expands/navigates to SettingsView
- Or: add settings as a section within the popup (collapsible)

**File: `FineTune/Views/MenuBar/MenuBarStatusController.swift`**
- Add "Settings" item to the right-click context menu (or Cmd+, shortcut)

### 4C. Customizable Menu Bar Icon

**File: `FineTune/Views/MenuBar/MenuBarStatusController.swift`**
- In `start()` (line ~31): read `settingsManager.appSettings.menuBarIconStyle` instead of hardcoded "MenuBarIcon"
- For SF Symbols: `NSImage(systemSymbolName: style.iconName, accessibilityDescription:)?.withTemplate(true)`
- For asset: `NSImage(named: style.iconName)` (current behavior)
- Add `updateIcon(to style: MenuBarIconStyle)` method -- can change live without restart (advantage of NSStatusItem over FluidMenuBarExtra)
- Wire settings change to call `updateIcon` immediately

**New File: `FineTune/Views/Settings/SettingsIconPickerRow.swift`**
- Shows 4 icon options as selectable tiles with highlight ring
- Changes take effect immediately (no restart needed -- simpler than upstream)

**(SettingsManager changes already done in Phase 1A)**

---

## Phase 5: URL Scheme + Auto-Update + Homebrew

External integration features. No dependency on Phases 2-4 (only Phase 1 settings).

### 5A. URL Scheme API

**File: `FineTune/Info.plist`**
- Add:
  ```xml
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLSchemes</key>
    <array><string>finetune</string></array>
    <key>CFBundleURLName</key>
    <string>com.finetuneapp.FineTune</string>
  </dict></array>
  ```

**File: `FineTune/Info-Debug.plist`**
- Same URL scheme registration

**New File: `FineTune/Utilities/URLHandler.swift`**
- Takes `AudioEngine` as dependency
- Parses `URLComponents`: `host` = action, `queryItems` = parameters
- 6 actions:

| Action | URL | Behavior |
|--------|-----|----------|
| `set-volumes` | `finetune://set-volumes?app=com.a&volume=100&app=com.b&volume=50` | Batch volume set. Paired app/volume query items. Range 0-200 (percentage). Falls back to inactive setter if app not active (requires Pinned Apps). |
| `step-volume` | `finetune://step-volume?app=com.a&direction=up` | 5% slider position increment. Only works for active apps. |
| `set-mute` | `finetune://set-mute?app=com.a&muted=true` | Batch mute set. Paired app/muted items. Falls back to inactive setter. |
| `toggle-mute` | `finetune://toggle-mute?app=com.a&app=com.b` | Toggle mute for listed apps. Falls back to inactive setter. |
| `set-device` | `finetune://set-device?app=com.a&device=<deviceUID>` | Route app to device. Active apps only. |
| `reset` | `finetune://reset` or `finetune://reset?app=com.a` | Reset to 100% volume + unmuted. No args = all apps. |

- App lookup by `persistenceIdentifier` (bundleID or "name:AppName")
- Boolean parsing: true/false, 1/0, yes/no (case-insensitive)
- All operations logged via `Logger`
- Fire-and-forget (no response to caller)

**File: `FineTune/FineTuneApp.swift` (AppDelegate)**
- Add `func application(_ application: NSApplication, open urls: [URL])`:
  ```swift
  let urlHandler = URLHandler(audioEngine: audioEngine)
  for url in urls { urlHandler.handleURL(url) }
  ```

**Adaptation notes:**
- Volume mapping: `volume=100` -> gain 1.0, `volume=200` -> gain 2.0. Cap at 200 (our max, not 400).
- `VolumeMapping.gainToSlider` in local repo takes single parameter (hardcoded 2.0 max). Use directly for `step-volume`.
- If Pinned Apps (Phase 4) is not yet integrated, inactive app fallbacks simply log a warning and skip.

### 5B. Auto-Update (Sparkle)

**Xcode Project (finetune_fork.xcodeproj/project.pbxproj)**
- Add Sparkle SPM dependency:
  - Repository: `https://github.com/sparkle-project/Sparkle`
  - Version requirement: up to next major from 2.0.0
- Add `Sparkle` framework to main app target

**New File: `FineTune/Settings/UpdateManager.swift`**
- Wraps `SPUStandardUpdaterController`:
  - Init with `startingUpdater: false` (prevents auto-popup on launch)
  - `start()` calls `updaterController.updater.start()`
  - Publishes `canCheckForUpdates` via Combine
  - `checkForUpdates()` triggers manual check
  - Exposes `automaticallyChecksForUpdates` and `automaticallyDownloadsUpdates` as read/write

**File: `FineTune/Info.plist`**
- Add `SUFeedURL` -- URL to your appcast.xml (e.g., `https://raw.githubusercontent.com/YOURNAME/finetune_fork/main/appcast.xml`)
- Add `SUPublicEDKey` -- your EdDSA public key (generate with Sparkle's `generate_keys` tool)

**File: `FineTune/FineTune.entitlements`**
- Add `com.apple.security.network.client = true` (Sparkle needs HTTP access)
- Add Sparkle mach-lookup exceptions:
  ```xml
  <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
  <array>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
  </array>
  ```

**File: `FineTune/FineTuneApp.swift` (AppDelegate)**
- Create `UpdateManager` in `applicationDidFinishLaunching`
- Call `updateManager.start()`
- Store reference for settings UI access

**File: `FineTune/Views/MenuBar/MenuBarStatusController.swift`**
- Add "Check for Updates..." to right-click context menu

**New File: `FineTune/Views/Settings/SettingsUpdateRow.swift`**
- Toggle: "Check for updates automatically"
- "Check for Updates" button with last-checked date
- Version display

**New File: `appcast.xml`** (repo root)
- Initial empty appcast template

**File: `.github/workflows/release.yml`**
- Add steps after DMG notarization:
  1. Download Sparkle 2.8.x tools archive
  2. Run `generate_appcast` with `SPARKLE_PRIVATE_KEY` secret
  3. Commit updated `appcast.xml` back to `main`
- Add `SPARKLE_PRIVATE_KEY` to GitHub secrets (generate with `sparkle_tools/bin/generate_keys`)

### 5C. Homebrew Cask

**New Repository: `github.com/YOURNAME/homebrew-finetune`** (separate repo)
- Contains cask file `Casks/finetune-fork.rb`:
  ```ruby
  cask "finetune-fork" do
    version "X.X.X"
    sha256 "SHA256_OF_DMG"
    url "https://github.com/YOURNAME/finetune_fork/releases/download/v#{version}/FineTune-#{version}.dmg"
    name "FineTune"
    desc "Per-app volume control for macOS"
    homepage "https://github.com/YOURNAME/finetune_fork"
    auto_updates true
    depends_on macos: ">= :sonoma"
    app "FineTune.app"
  end
  ```
- Install via: `brew tap YOURNAME/finetune && brew install --cask finetune-fork`

**File: `.github/workflows/release.yml`** (optional automation)
- Add step after GitHub Release creation: update cask sha256 and version in the tap repo via GitHub API

---

## Dependency Graph

```
Phase 1A: Settings Infrastructure ──────────────────────────────┐
Phase 1B: Device Reconnect ─────────────────────────────────────┤
                                                                 │
Phase 2A: Input Device Management ──── depends on 1A ───────────┤
Phase 2B: System Sound Effects ──────── depends on 1A ──────────┤
                                                                 │
Phase 3:  Multi-Device Output ───────── depends on 1A, 1B ──────┤
                                                                 │
Phase 4A: Pinned Apps ───────────────── depends on 1A ──────────┤
Phase 4B: Settings Panel ────────────── depends on 2A, 2B, 4A, 4C
Phase 4C: Menu Bar Icon ─────────────── depends on 1A ──────────┤
                                                                 │
Phase 5A: URL Scheme ────────────────── depends on 1A (4A optional)
Phase 5B: Auto-Update (Sparkle) ─────── independent ────────────┤
Phase 5C: Homebrew Cask ─────────────── depends on 5B ──────────┘
```

**Parallelizable work within each phase:**
- Phase 2: 2A and 2B can be developed in parallel (different CoreAudio scopes), merged together
- Phase 4: 4A and 4C can be developed in parallel, 4B depends on both
- Phase 5: 5A and 5B are fully independent; 5C follows 5B

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| macOS 26 blocks per-app device routing (PID-only taps get zero callbacks on non-default devices) | Multi-device output (Phase 3) won't work on macOS 26 | Feature-gate behind OS version check; same guard already exists in AppRow |
| Settings migration (v4 -> v5) corrupts user data | All user preferences lost | Backward-compatible Codable defaults; all new fields optional or have defaults; test migration with v4 fixture |
| Aggregate device creation fails with unavailable sub-device (multi-device) | App loses audio output | Validate sub-device availability before creation; fall back to single-device if aggregate creation fails |
| Clock source device disconnects in multi-device mode | All sub-devices lose clock reference, audible glitch | Remove disconnected device, rebuild aggregate with next device as clock source |
| `handleDeviceDisconnected` persistence change (Phase 1B) changes existing behavior | Apps don't remember device routing after restart if device was disconnected at quit time | Only skip persistence for the fallback routing; the original preferred routing stays persisted |
| Sparkle sandbox requirements | Updates fail silently | Add all required entitlements (network.client, mach-lookup exceptions); test in sandboxed release build |
| Input device lock reverts user's intentional mic change | User frustration | 2-second grace period heuristic; if change happens >2s after device connect, treat as intentional |

---

## File Change Summary

### New Files (13)
1. `FineTune/Models/DisplayableApp.swift`
2. `FineTune/Views/Rows/InputDeviceRow.swift`
3. `FineTune/Views/Rows/InactiveAppRow.swift`
4. `FineTune/Views/Components/ModeToggle.swift`
5. `FineTune/Views/Settings/SettingsView.swift`
6. `FineTune/Views/Settings/SettingsIconPickerRow.swift`
7. `FineTune/Views/Settings/SettingsUpdateRow.swift`
8. `FineTune/Views/Settings/SoundEffectsDeviceRow.swift`
9. `FineTune/Utilities/URLHandler.swift`
10. `FineTune/Settings/UpdateManager.swift`
11. `appcast.xml`
12. Homebrew tap repo (external)
13. (Optional) `FineTune/Views/Settings/SettingsToggleRow.swift` -- reusable settings row component

### Modified Files (17)
1. `FineTune/Settings/SettingsManager.swift` -- major expansion (settings v5, AppSettings, all new fields)
2. `FineTune/Models/VolumeState.swift` -- multi-device state tracking
3. `FineTune/Audio/AudioDeviceMonitor.swift` -- input devices, device connect callback
4. `FineTune/Audio/DeviceVolumeMonitor.swift` -- input monitoring, system sound device
5. `FineTune/Audio/AudioEngine.swift` -- input lock, reconnect, multi-device, pinned apps, URL scheme wiring
6. `FineTune/Audio/ProcessTapController.swift` -- multi-device aggregates
7. `FineTune/Audio/Extensions/AudioDeviceID+Volume.swift` -- input volume/mute
8. `FineTune/Audio/Extensions/AudioDeviceID+Classification.swift` -- input icon
9. `FineTune/Audio/Extensions/AudioObjectID+System.swift` -- input/system device read/write
10. `FineTune/Views/MenuBarPopupView.swift` -- input tab, pinned apps, multi-device wiring, settings
11. `FineTune/Views/MenuBarPopupViewModel.swift` -- input tab state, EQ ID type change
12. `FineTune/Views/Rows/AppRow.swift` -- pin button, multi-device props
13. `FineTune/Views/Components/DevicePicker.swift` -- multi-select mode
14. `FineTune/Views/Components/MuteButton.swift` -- InputMuteButton
15. `FineTune/Views/MenuBar/MenuBarStatusController.swift` -- icon customization, context menu items
16. `FineTune/FineTuneApp.swift` -- URL handling, UpdateManager
17. `FineTune/Info.plist` + `Info-Debug.plist` -- URL scheme, Sparkle keys
18. `FineTune/FineTune.entitlements` -- network, Sparkle mach-lookup
19. `.github/workflows/release.yml` -- Sparkle appcast generation

### Estimated Scope
- ~13 new files, ~19 modified files
- Largest changes: AudioEngine.swift, SettingsManager.swift, ProcessTapController.swift, DeviceVolumeMonitor.swift, MenuBarPopupView.swift
- Most complex feature: Multi-Device Output (Phase 3) -- touches audio pipeline, aggregate devices, crossfade
- Most files touched: Pinned Apps (Phase 4A) -- adds new model type that ripples through views
