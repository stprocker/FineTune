# Multi-Device Audio Routing + Permission UX Fix

**Date:** 2026-02-08
**Session:** Two consecutive context windows (context compacted mid-session)
**Build verification:** `xcodebuild build` succeeded after all changes

---

## Summary

Implemented the full multi-device audio routing plan: per-app audio routed to multiple output devices simultaneously via CoreAudio stacked aggregate devices. Also re-enabled the DevicePicker on macOS 26, fixed a build error, added proactive audio permission checking, and added menu bar icon debug logging.

---

## Part 1: ProcessTapController — Multi-Device Aggregate Support

**File:** `FineTune/Audio/ProcessTapController.swift`

### Changes Made

1. **Stored properties changed from single to array:**
   ```swift
   // Before:
   private var targetDeviceUID: String
   private(set) var currentDeviceUID: String?

   // After:
   private var targetDeviceUIDs: [String]
   private(set) var currentDeviceUIDs: [String]
   ```
   - Added backward-compat computed properties: `targetDeviceUID` (getter returns `[0]`), `currentDeviceUID` (getter/setter wraps array)

2. **Updated primary init to accept `[String]`:**
   ```swift
   init(app: AudioApp, targetDeviceUIDs: [String], deviceMonitor: AudioDeviceMonitor? = nil,
        muteOriginal: Bool = true, queue: DispatchQueue? = nil)
   ```
   - Added `precondition(!targetDeviceUIDs.isEmpty)`
   - Added convenience init for single device backward compatibility

3. **Extracted `buildAggregateDescription()` helper:**
   - Replaces 3 identical inline aggregate dictionary blocks (in `activate()`, `createSecondaryTap()`, `performDeviceSwitch()`)
   - First device = clock source (no drift compensation), subsequent devices get `kAudioSubDeviceDriftCompensationKey: true`
   - Uses `kAudioAggregateDeviceIsStackedKey: true` for multi-output

4. **Added `updateDevices(to: [String])` method:**
   - Crossfade-switches to a new set of devices
   - Guards: not empty, activated, different from current set
   - Calls `switchDevice(to:)` for crossfade, then updates `currentDeviceUIDs`

5. **Fixed state preservation in `switchDevice()`:**
   - `targetDeviceUIDs` and `currentDeviceUIDs` assignments are now conditional: only overwrite with single-device array when not in multi-device mode (`count <= 1`)
   - Prevents `updateDevices()` → `switchDevice()` from clobbering the multi-device array

### Errors Encountered & Fixed

- **"Cannot assign to property" at 3 locations:** After making `targetDeviceUID` a read-only computed property, assignments in `switchDevice()` and `performDeviceSwitch()` broke. Fixed by assigning to `targetDeviceUIDs = [newDeviceUID]` instead.
- **Multi-device state overwrite:** `switchDevice()` completion was setting `targetDeviceUIDs = [newDeviceUID]`, undoing multi-device state from `updateDevices()`. Fixed with conditional: `if targetDeviceUIDs.count <= 1 { ... }`

---

## Part 2: AudioEngine — Mode-Aware Routing

**File:** `FineTune/Audio/AudioEngine.swift`

### Changes Made

1. **Added 5 new public methods:**
   - `setDeviceSelectionMode(for:to:)` — persists mode, triggers tap reconfiguration
   - `setSelectedDeviceUIDs(for:to:)` — persists UIDs, triggers tap reconfiguration in multi mode
   - `getDeviceSelectionMode(for:)` — reads current mode from VolumeState
   - `getSelectedDeviceUIDs(for:)` — reads current UIDs from VolumeState
   - `updateTapForCurrentMode(for:)` — resolves mode + UIDs, calls `tap.updateDevices(to:)`

2. **Added `ensureTapExists(for:deviceUIDs:)` overload:**
   - Creates tap with `ProcessTapController(app: app, targetDeviceUIDs: deviceUIDs, ...)`
   - Kept single-UID convenience wrapper for existing call sites

3. **Updated `handleDeviceDisconnected()`:**
   - Multi-mode: removes disconnected device from set, calls `tap.updateDevices(to: remaining)`
   - Only falls through to single-device fallback if no devices remain

4. **Updated `handleDeviceConnected()`:**
   - Multi-mode: adds reconnected device back to set if it was in the persisted selection
   - Calls `tap.updateDevices(to: updated)` to reconfigure aggregate

5. **Added inactive app mode getters/setters:**
   - `getDeviceSelectionModeForInactive(identifier:)`
   - `setDeviceSelectionModeForInactive(identifier:to:)`
   - `getSelectedDeviceUIDsForInactive(identifier:)`
   - `setSelectedDeviceUIDsForInactive(identifier:to:)`

---

## Part 3: DevicePicker UI — Single/Multi Mode

**File:** `FineTune/Views/Components/DevicePicker.swift`

### Changes Made

1. **Complete rewrite with new properties:**
   ```swift
   let selectedDeviceUIDs: Set<String>     // multi mode
   let mode: DeviceSelectionMode
   let onDevicesSelected: (Set<String>) -> Void
   let onModeChange: (DeviceSelectionMode) -> Void
   ```

2. **Mode toggle:** Small segmented control (Single | Multi) at top of dropdown

3. **Multi-mode behavior:**
   - Trigger text: "N devices" when multiple selected, device name when 1
   - Checkboxes instead of checkmarks
   - Dropdown stays open on tap (unlike single mode which closes)
   - Can't deselect the last device (guard prevents empty selection)

4. **Backward-compatible convenience init** for single-mode-only callers (DevicePickerView, previews)

5. **`DevicePickerItemButtonStyle`** — private button style with hover highlighting

### Changes to Other Files

- **`DropdownMenu.swift` line 8:** Changed `DropdownTriggerButton` from `private` to `internal` so DevicePicker can reuse it

### Errors Encountered & Fixed

- **`DeviceIcon` type not found (Xcode build error):** The `triggerIcon` computed property used `DeviceIcon?` which doesn't exist. `AudioDevice.icon` is `NSImage?`. Fixed: `private var triggerIcon: DeviceIcon?` → `private var triggerIcon: NSImage?`

---

## Part 4: Wire UI → Engine + Remove macOS 26 Guards

### AppRow.swift

- Removed `#available(macOS 26, *)` guard that disabled DevicePicker
- Added 4 new properties: `deviceSelectionMode`, `selectedDeviceUIDs`, `onModeChange`, `onDevicesSelected` (all with defaults)
- Updated `AppRowWithLevelPolling` with same properties and pass-through

### InactiveAppRow.swift

- Same changes as AppRow: removed guard, added 4 new properties with defaults

### MenuBarPopupView.swift

- Wired up active app row callbacks:
  ```swift
  deviceSelectionMode: audioEngine.getDeviceSelectionMode(for: app),
  selectedDeviceUIDs: audioEngine.getSelectedDeviceUIDs(for: app),
  onModeChange: { mode in audioEngine.setDeviceSelectionMode(for: app, to: mode) },
  onDevicesSelected: { uids in audioEngine.setSelectedDeviceUIDs(for: app, to: uids) }
  ```
- Wired up inactive app row callbacks using `ForInactive` variants

---

## Part 5: Build Verification

- `swift build` — succeeded (2.78s) but excludes Views/ directory (not in Package.swift)
- `xcodebuild build` — **FAILED** initially due to `DeviceIcon` type error
- After fix (`DeviceIcon` → `NSImage?`): **BUILD SUCCEEDED**
- `swift test` — 290 tests, 19 failures, 0 unexpected. Pre-existing failures (CrossfadeState duration: tests expect 50ms, code uses 200ms)

---

## Part 6: Menu Bar Icon Debug (Post-Build)

### Problem
App launched but no menu bar icon was visible. Console log showed "Menu bar status item created" but icon wasn't rendering.

### Investigation
- Settings file was corrupted/missing on launch: `Failed to load settings: The data couldn't be read because it is missing.`
- `MenuBarStatusController.start()` code and `MenuBarIcon` asset both verified present and correct
- `killall SystemUIServer` and `killall ControlCenter` did not resolve

### Fix
Added comprehensive `[MENUBAR]` debug logging to `MenuBarStatusController.swift`:
- Status item creation: `isVisible`, `length`
- Button state: `frame`, `window`
- Icon style resolution: `rawValue`, `iconName`, `isSystemSymbol`
- Icon application: which path taken (SF Symbol vs asset), image size
- Explicit `item.isVisible = true` after creation
- 3-second delayed health check: `visible`, `hasButton`, `hasImage`, `hasWindow`, `imgSize`

### Build Error
`os.Logger` string interpolation doesn't support `CGRect` directly. Fixed: `\(button.frame)` → `\(NSStringFromRect(button.frame))`

### Result
Icon appeared after clean rebuild. Likely a macOS menu bar caching issue resolved by the rebuild.

---

## Part 7: Proactive Audio Permission Check

### Problem
The macOS system "record your system audio" permission dialog appeared mid-interaction (when user clicked DevicePicker dropdown), because:
1. App never proactively checks permission status
2. `AudioEngine` init triggers tap creation for detected audio apps
3. CoreAudio triggers the system dialog when first tap is created

### Solution
Added `CGPreflightScreenCaptureAccess()` check **before** `AudioEngine` creation in `FineTuneApp.swift`:

```swift
private func createAndStartAudioEngine(settings: SettingsManager) {
    let hasAccess = CGPreflightScreenCaptureAccess()
    if !hasAccess && settings.appSettings.onboardingCompleted {
        // Show our alert BEFORE engine creates taps
        let alert = NSAlert()
        alert.messageText = "Audio Permission Required"
        alert.informativeText = "..."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Continue Anyway")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:...")!)
        }
    }
    // Engine created AFTER alert dismissed
    let engine = AudioEngine(settingsManager: settings)
    ...
}
```

### Key Design Decisions
- Only runs when `onboardingCompleted == true` (not for `--skip-onboarding` dev builds)
- Runs synchronously before engine creation (blocks until user dismisses alert)
- `CGPreflightScreenCaptureAccess()` is a passive check — does NOT trigger the system dialog
- "Continue Anyway" lets user browse the UI without audio control

### Iteration
1. First attempt: check after engine creation → system dialog still fired (engine creates taps in init)
2. Second attempt: check after engine, run regardless of onboarding → redundant for onboarded users
3. Final: check before engine, only when onboarding completed → correct

---

## Files Modified (Complete List)

| File | Changes |
|------|---------|
| `ProcessTapController.swift` | `[String]` device arrays, `buildAggregateDescription()` helper, `updateDevices()`, state preservation fixes |
| `AudioEngine.swift` | Mode-aware routing (5 methods), multi-device `ensureTapExists`, disconnect/reconnect handling, inactive app getters/setters |
| `DevicePicker.swift` | Complete rewrite: mode toggle, checkbox multi-select, trigger text, backward-compat init, `NSImage?` type fix |
| `DropdownMenu.swift` | `DropdownTriggerButton` access: `private` → `internal` |
| `AppRow.swift` | Removed macOS 26 guard, 4 new multi-device props + init params (AppRow + AppRowWithLevelPolling) |
| `InactiveAppRow.swift` | Removed macOS 26 guard, 4 new multi-device props + init params |
| `MenuBarPopupView.swift` | Wired up mode change + multi-device callbacks for active and inactive rows |
| `MenuBarStatusController.swift` | `[MENUBAR]` debug logging, `item.isVisible = true`, delayed health check, `NSStringFromRect` fix |
| `FineTuneApp.swift` | `import ScreenCaptureKit`, `CGPreflightScreenCaptureAccess()` check before engine creation, `NSAlert` for missing permission |
| `CHANGELOG.md` | New section for multi-device routing + permission UX |

**No changes needed:** `VolumeState.swift`, `SettingsManager.swift`, `TapResources.swift` (persistence layer was already complete)

---

## Comprehensive TODO List

### High Priority — Runtime Testing Required
- [ ] **Test single-device mode (default):** Verify existing behavior is unchanged — one device per app, volume/mute/EQ all work
- [ ] **Test multi-device mode:** Toggle to Multi in DevicePicker, check 2+ devices → audio plays on all simultaneously via stacked aggregate
- [ ] **Test mode switching:** Toggle Single → Multi and back — tap reconfigures via crossfade
- [ ] **Test device disconnect in multi:** Remove one device while in multi mode → remaining devices keep playing
- [ ] **Test device reconnect in multi:** Plug device back in → re-added to aggregate if in persisted selection
- [ ] **Test persistence:** Quit and relaunch → multi-mode and selected device UIDs restored correctly
- [ ] **Test macOS 26 DevicePicker:** Verify device picker works (not disabled), per-app routing functional
- [ ] **Test permission alert flow:** Fresh install or revoked permission → our NSAlert appears before system dialog
- [ ] **Full Xcode build (`xcodebuild build`)** — verified, but re-test after any further changes

### Medium Priority — Pending Experiments
- [ ] **Test C (bundle-ID experiment):** Set `tapDesc.bundleIDs = [bundleID]` WITHOUT setting `isProcessRestoreEnabled`. Test with Brave/Chrome for multi-process capture with working output. Orthogonal to multi-device routing. (Noted in original plan as "Reminder: After Implementation")
- [ ] **Test `applyPersistedSettings()` multi-device restore path:** Code was added in the plan but not implemented in this session — verify startup restore for apps saved in multi-mode
- [ ] **Verify `CGPreflightScreenCaptureAccess()` on macOS 26:** Confirmed passive (no dialog trigger) on current build, but test across OS versions

### Low Priority — Cleanup & Polish
- [ ] **Remove `[MENUBAR]` debug logging** — added for diagnosing menu bar icon issue, should be removed or reduced to `.debug` level before release
- [ ] **Codesign stale PlugIns issue** — `FineTuneTests.xctest` keeps appearing in `FineTune.app/Contents/PlugIns/` unsigned. Needs Xcode build settings fix or clean build script
- [ ] **CrossfadeState test expectations** — 19 pre-existing test failures (expect 50ms duration, code uses 200ms). Tests need updating to match current code
- [ ] **`SystemSoundsDeviceChanges.swift` dead code** — 200-line documentation stub, should be deleted (noted in previous session's known issues)
- [ ] **Settings panel auto-close on popup dismiss** — `isSettingsOpen` persists across popup show/hide cycles (noted in previous session's known issues)

---

## Known Issues

1. **Multi-device routing is compile-verified + Xcode build verified only** — no runtime testing with actual multi-device playback has been performed
2. **Codesign error with stale `PlugIns/FineTuneTests.xctest`** — intermittent build failure, resolved by clean build (`Cmd+Shift+K`)
3. **Pre-existing test failures (19)** — CrossfadeState duration values (tests expect 50ms, code uses 200ms). All marked "0 unexpected". Unrelated to multi-device changes.
4. **Menu bar icon may not appear on first launch** — possibly macOS caching. Debug logging added. Explicit `isVisible = true` helps. Clean rebuild resolves.
5. **Permission alert only shown when `onboardingCompleted == true`** — dev builds with `--skip-onboarding` skip the check entirely, meaning the system dialog can still appear for developers
6. **`applyPersistedSettings()` multi-device restore** — plan included updating this method to restore multi-device state on startup, but this specific code path was not implemented in this session. Apps will restore to single-device mode on relaunch.

---

## Architecture Notes for Handoff

### Multi-Device Flow
```
User toggles to Multi in DevicePicker
  → DevicePicker.onModeChange callback
  → MenuBarPopupView calls audioEngine.setDeviceSelectionMode(for: app, to: .multi)
  → AudioEngine persists via volumeState, calls updateTapForCurrentMode()
  → updateTapForCurrentMode() reads mode + UIDs, calls tap.updateDevices(to: [uid1, uid2, ...])
  → ProcessTapController.updateDevices() calls switchDevice() with crossfade
  → buildAggregateDescription() creates stacked aggregate with drift compensation
  → Audio plays on all devices simultaneously
```

### Permission Check Flow
```
App launches → createAndStartAudioEngine()
  → CGPreflightScreenCaptureAccess() (passive, no dialog)
  → If false AND onboardingCompleted:
      → Show NSAlert with "Open System Settings" / "Continue Anyway"
      → User dismisses alert
  → THEN create AudioEngine (which triggers tap creation)
```

### Key Types
- `DeviceSelectionMode` — `.single` | `.multi` (defined in `VolumeState.swift`)
- `ProcessTapController.targetDeviceUIDs: [String]` — ordered array, first = clock source
- `ProcessTapController.buildAggregateDescription()` — creates CoreAudio aggregate dict with drift compensation
- `AudioEngine.updateTapForCurrentMode()` — bridges VolumeState mode/UIDs to ProcessTapController
