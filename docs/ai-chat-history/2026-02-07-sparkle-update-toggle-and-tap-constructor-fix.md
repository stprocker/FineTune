# Sparkle Update Toggle + CATapDescription Constructor Fix (Per-App Volume)

**Date:** 2026-02-07
**Session type:** Feature implementation + critical bug fix
**Build status:** BUILD SUCCEEDED (all code paths compile)

---

## Summary

This session had two major work streams:

1. **Added Sparkle auto-update settings toggle** — compared fork against the original dev's updated version, added `UpdateManager.swift`, `SettingsUpdateRow.swift`, and wired them into `SettingsView.swift`. Also guided user through adding Sparkle SPM dependency in Xcode.

2. **Fixed per-app volume not working (critical)** — diagnosed and fixed the root cause of audio taps receiving zero input data ("Reporter disconnected"). The fork was using the wrong `CATapDescription` constructor (`__processes:andDeviceUID:withStream:`) which ties taps to a specific device stream and causes CoreAudio to disconnect the reporter. Changed all three code paths to use `stereoMixdownOfProcesses:` (matching the original dev's working implementation) and updated aggregate device configuration (`isStacked: true`, `ClockDeviceKey`).

---

## Phase 1: Sparkle Auto-Update Settings Toggle

### Context
User compared their fork against the original dev's updated version at `_local/26.2.7 FineTune OG/FineTune-main/` and identified a missing "Check for updates automatically" toggle in the Settings panel.

### Files Created

#### `FineTune/Settings/UpdateManager.swift` (NEW)
- Wraps Sparkle's `SPUStandardUpdaterController` for auto-update management
- Uses `startingUpdater: false` to prevent popup on launch, then manually calls `start()`
- Publishes `canCheckForUpdates` via Combine
- Properties: `automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates`, `lastUpdateCheckDate`
- Method: `checkForUpdates()` triggers manual check

#### `FineTune/Views/Settings/SettingsUpdateRow.swift` (NEW)
- Combined settings row with "Check for updates automatically" toggle + "Check for Updates" button
- Displays version number and relative last-check date
- Uses `DesignTokens` for consistent styling (typography, colors, spacing, dimensions)
- Matches the original dev's UI design

### Files Modified

#### `FineTune/Views/Settings/SettingsView.swift`
- Added `@ObservedObject var updateManager: UpdateManager` property
- Added `SettingsUpdateRow` to `generalSection` after the icon picker row
- Uses custom `Binding` to bridge `UpdateManager`'s non-`@Published` properties

### SPM Dependency
Guided user through adding Sparkle framework via Xcode's "Add Package Dependencies" flow:
- Repository: `https://github.com/sparkle-project/Sparkle`
- Target: `FineTune`

### Known Limitation
`SettingsView` is not yet wired into the main `MenuBarPopupView` in the fork — no settings gear button or panel navigation exists yet. The `UpdateManager` needs to be instantiated at app startup and passed through the view hierarchy.

---

## Phase 2: Per-App Volume Not Working (Critical Fix)

### Symptom
User reported "Individual app volume doesn't work" — sliding the per-app volume slider had no effect on actual audio output. Brave Browser showed at 100% with EQ panel open but adjusting volume did nothing.

### Diagnostic Evidence
User-provided logs showed:
```
Reporter disconnected. { function=sendMessage, reporterID=326765406846977 }
[DIAG] Brave Browser: callbacks=861 input=0 output=861 ... inPeak=0.000 outPeak=0.000
```
Key indicators:
- `input=0` — tap callbacks were firing but receiving NO audio data
- `inPeak=0.000` / `outPeak=0.000` — zero audio passing through the pipeline
- "Reporter disconnected" — CoreAudio dropped the tap's audio source

### Root Cause Analysis

**Two separate issues were found:**

#### Issue 1: Permission Flow Creating `.unmuted` Taps (Minor)
The fork added a `permissionConfirmed` flow in `AudioEngine.ensureTapExists()` that created taps with `.unmuted` initially. This meant audio played through the original path unprocessed, so volume/EQ changes had no effect. The original dev's code always uses `.mutedWhenTapped`.

**Fix:** Removed the permission checking flow from `ensureTapExists` — taps now always use `.mutedWhenTapped` (matching original).

#### Issue 2: Wrong CATapDescription Constructor (Critical — Root Cause)
This was the actual root cause. The fork used a different tap description constructor than the original:

| | Fork (BROKEN) | Original (WORKING) |
|---|---|---|
| **Constructor** | `CATapDescription(__processes: [processNumber], andDeviceUID: outputUID, withStream: streamIndex)` | `CATapDescription(stereoMixdownOfProcesses: [app.objectID])` |
| **Behavior** | Ties tap to specific device stream | Captures ALL audio from process regardless of device |
| **Aggregate isStacked** | `false` | `true` |
| **ClockDeviceKey** | Not set | Set to output device UID |

The device-specific constructor (`__processes:andDeviceUID:withStream:`) caused CoreAudio to disconnect the reporter, resulting in the tap firing callbacks with zero input data.

### Changes Made

#### `FineTune/Audio/AudioEngine.swift`
- Removed `permissionConfirmed` flow in `ensureTapExists()`:
  ```swift
  // BEFORE (fork):
  let shouldMute = permissionConfirmed
  let tap = ProcessTapController(app: app, targetDeviceUID: deviceUID,
      deviceMonitor: deviceMonitor, muteOriginal: shouldMute)

  // AFTER (matching original):
  let tap = ProcessTapController(app: app, targetDeviceUID: deviceUID,
      deviceMonitor: deviceMonitor)
  ```
- `permissionConfirmed`, `upgradeTapsToMutedWhenTapped()`, `shouldConfirmPermission()` are now dead code

#### `FineTune/Audio/ProcessTapController.swift` — THREE code paths fixed:

##### 1. `activate()` (primary activation)
- Changed `makeTapDescription()` from device-specific to stereo mixdown:
  ```swift
  // BEFORE:
  private func makeTapDescription(for outputUID: String, streamIndex: Int) -> CATapDescription {
      let processNumber = NSNumber(value: app.objectID)
      let tapDesc = CATapDescription(__processes: [processNumber],
          andDeviceUID: outputUID, withStream: streamIndex)
      ...
  }

  // AFTER:
  private func makeTapDescription() -> CATapDescription {
      let tapDesc = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
      tapDesc.uuid = UUID()
      tapDesc.muteBehavior = muteOriginal ? .mutedWhenTapped : .unmuted
      return tapDesc
  }
  ```
- Updated aggregate device config:
  - Added `kAudioAggregateDeviceClockDeviceKey: outputUID`
  - Changed `kAudioAggregateDeviceIsStackedKey` from `false` to `true`
  - Removed `streamInfo` dependency; reads sample rate from aggregate device after creation

##### 2. `createSecondaryTap(for:)` (crossfade path)
- Changed from `makeTapDescription(for:streamIndex:)` to `makeTapDescription()` (no args)
- Removed `resolveOutputStreamInfo` guard (no longer needed — stereo mixdown doesn't need stream info)
- Updated aggregate device config: added `ClockDeviceKey`, changed `isStacked` to `true`
- Changed sample rate source: now reads from aggregate device instead of `streamInfo`
- Moved `updateSecondaryFormat(from:tapID:fallbackSampleRate:)` to after aggregate creation (needs the aggregate's sample rate)

##### 3. `performDeviceSwitch(to:)` (destructive fallback path)
- Changed from `makeTapDescription(for:streamIndex:)` to `makeTapDescription()` (no args)
- Removed `resolveOutputStreamInfo` guard
- Updated aggregate device config: added `ClockDeviceKey`, changed `isStacked` to `true`
- Changed sample rate source: now reads from aggregate device instead of `streamInfo`

##### Dead Code Removed
- `resolveOutputStreamInfo(for:)` wrapper method — no longer called from any code path (was only used by the old device-specific tap creation)

### Technical Details

**Why `stereoMixdownOfProcesses` works and `__processes:andDeviceUID:withStream:` doesn't:**

The `stereoMixdownOfProcesses:` constructor creates a tap that captures ALL audio output from the specified process, regardless of which audio device it's playing through. The aggregate device then handles routing the captured audio to the actual output device.

The `__processes:andDeviceUID:withStream:` constructor ties the tap to a specific device stream. When the aggregate device is created, CoreAudio gets confused about stream ownership and disconnects the reporter — the tap fires callbacks but they contain zero audio data.

**Why `isStacked: true` and `ClockDeviceKey` matter:**

- `isStacked: true` tells CoreAudio to stack the tap stream on top of the device stream (required for stereo mixdown taps)
- `ClockDeviceKey` designates which sub-device provides the master clock for the aggregate. Without it, the aggregate may not properly synchronize tap and device streams.

---

## Files Changed (Complete List)

### New Files
| File | Purpose |
|---|---|
| `FineTune/Settings/UpdateManager.swift` | Sparkle auto-update wrapper |
| `FineTune/Views/Settings/SettingsUpdateRow.swift` | Settings row UI for update toggle + check button |

### Modified Files
| File | Changes |
|---|---|
| `FineTune/Views/Settings/SettingsView.swift` | Added `updateManager` property, added `SettingsUpdateRow` to general section |
| `FineTune/Audio/AudioEngine.swift` | Removed permission flow from `ensureTapExists` (always `.mutedWhenTapped` now) |
| `FineTune/Audio/ProcessTapController.swift` | Rewrote `makeTapDescription()` to stereo mixdown; fixed aggregate config in all 3 paths; removed dead `resolveOutputStreamInfo` |

---

## TODO List (Handoff)

### High Priority — Must Fix
1. **Wire `UpdateManager` into app startup and view hierarchy**
   - `UpdateManager` needs to be instantiated (likely in `AppDelegate` or `FineTuneApp`)
   - Needs to be passed through to wherever `SettingsView` is embedded
   - Currently `SettingsView` is NOT wired into `MenuBarPopupView` at all — no settings gear button or panel navigation exists in the fork

2. **Test per-app volume control end-to-end**
   - The `CATapDescription` constructor fix compiled successfully but has NOT been runtime-tested
   - Need to verify: launch app, play audio in an app (e.g., Brave, Spotify), adjust per-app volume slider, confirm audio level changes
   - Check logs for "Reporter disconnected" — should no longer appear
   - Check `[DIAG]` logs — `input` count should be > 0, `inPeak` should be non-zero

3. **Remove dead permission flow code from `AudioEngine.swift`**
   - `permissionConfirmed` property
   - `upgradeTapsToMutedWhenTapped()` method
   - `shouldConfirmPermission()` method
   - These are now unreachable since `ensureTapExists` no longer uses them
   - Left in place to minimize change scope during this session

### Medium Priority
4. **Add settings panel to `MenuBarPopupView`**
   - The original dev's version has a settings gear button that slides in a settings panel
   - Fork's `MenuBarPopupView` doesn't have this — needs a gear button, `isSettingsOpen` state, slide transition
   - Reference: `_local/26.2.7 FineTune OG/FineTune-main/FineTune/Views/MenuBarPopupView.swift`

5. **Verify crossfade works with new tap constructor**
   - Crossfade path (`createSecondaryTap`) was updated but NOT tested
   - Switch between audio devices while audio is playing to trigger crossfade
   - Check for glitches, silence gaps, or "Reporter disconnected" during switch

6. **Verify destructive switch fallback**
   - `performDeviceSwitch` was updated but NOT tested
   - To trigger: crossfade must fail first (e.g., force-fail by temporarily breaking `createSecondaryTap`)
   - Or test with devices that historically fail crossfade (some Bluetooth devices)

### Low Priority
7. **`HALC_ShellObject::SetPropertyData` error 1852797029 ('nope')**
   - Appears at startup in logs, likely unrelated to tap issues
   - Investigate if this is caused by the aggregate device configuration

8. **Consider removing `resolveOutputStreamInfo` extension method**
   - `AudioObjectID.resolveOutputStreamInfo(for:using:)` is defined as an extension elsewhere
   - Now that `ProcessTapController` doesn't call the wrapper, check if anything else uses the extension
   - If unused, remove to reduce dead code

9. **Add Sparkle appcast URL to Info.plist**
   - Sparkle needs `SUFeedURL` in Info.plist pointing to an appcast XML file
   - Without this, "Check for Updates" will fail silently
   - The original dev's version likely has this configured

---

## Known Issues

1. **Per-app volume fix is compile-verified only** — the stereo mixdown constructor fix builds successfully but has not been runtime-tested. There's a possibility the original's working behavior depends on other subtle differences not yet identified.

2. **`SettingsView` not accessible in fork UI** — the settings panel exists in code but there's no navigation path to reach it from the popup menu. The original dev has a gear button in `MenuBarPopupView` that the fork is missing.

3. **Dead code remaining in `AudioEngine.swift`** — `permissionConfirmed`, `upgradeTapsToMutedWhenTapped()`, and `shouldConfirmPermission()` are unreachable after the `ensureTapExists` change. Left for separate cleanup.

4. **Bundle-ID tap issues on macOS 26** — previous session identified that bundle-ID taps (macOS 26 feature) create aggregate devices where output doesn't reach physical device. This session's fix (stereo mixdown) may or may not resolve that issue — needs testing on macOS 26. See `docs/known_issues/bundle-id-tap-silent-output-macos26.md`.

5. **`shouldConfirmPermission` false-positive** — flagged in previous session. Now moot since permission confirmation flow was removed, but the underlying issue (outputWritten > 0 doesn't confirm real audio) still applies if the flow is ever re-enabled.

---

## Session Timeline

1. User showed screenshots comparing fork vs original dev's updated app — identified missing settings toggle
2. Investigated both codebases, found `UpdateManager.swift` and `SettingsUpdateRow.swift` in original
3. Created `UpdateManager.swift` and `SettingsUpdateRow.swift`, updated `SettingsView.swift`
4. Guided user through adding Sparkle SPM dependency in Xcode
5. User reported "Individual app volume doesn't work" with screenshot
6. Deep investigation of audio pipeline: UI slider -> VolumeMapping -> AudioEngine -> ProcessTapController -> GainProcessor
7. Found Issue 1: permission flow creating `.unmuted` taps — fixed
8. User provided diagnostic logs showing `Reporter disconnected` and `input=0`
9. Found Issue 2 (root cause): wrong `CATapDescription` constructor — fixed `activate()` path
10. Fixed remaining broken call sites in crossfade and destructive switch paths
11. Removed dead `resolveOutputStreamInfo` wrapper
12. Build verified: **BUILD SUCCEEDED**
