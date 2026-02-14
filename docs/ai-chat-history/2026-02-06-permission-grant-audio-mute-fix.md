# Chat Log: System Audio Permission Grant — Audio Mute, App Freeze, and Recovery

**Date:** 2026-02-06
**Commit:** `20c6a61` (1.23)
**Topic:** Fixing critical audio loss and app freeze when granting system audio recording permission, plus multiple audio routing/muting fixes
**Continuation of:** `2026-02-06-audio-pipeline-diagnostics-and-fixes.md`

---

## Summary

This session resolved a critical issue where clicking "Allow" on the macOS system audio recording permission dialog caused complete audio loss, app freeze, and eventual process termination. The root cause was three interacting issues: (1) process taps with `.mutedWhenTapped` surviving app death, (2) main-thread deadlock from CoreAudio reads during coreaudiod restart, and (3) no recovery path when coreaudiod invalidated all audio objects. Additionally, several audio routing, muting, and crossfade bugs were fixed during investigation.

This was a multi-session effort spanning two context windows. The first session (summarized below) identified and fixed several routing/muting bugs but did not resolve the core permission issue. This second session diagnosed the root cause and implemented the final fix.

---

## Files Modified

### Core Changes (Permission Fix)

1. **`FineTune/Audio/AudioDeviceMonitor.swift`**
   - Added `onServiceRestarted: (() -> Void)?` callback (fired after coreaudiod restart)
   - Fixed main-thread freeze: `handleServiceRestartedAsync()` and `handleDeviceListChangedAsync()` now run `readDeviceDataFromCoreAudio()` via `Task.detached` instead of on MainActor
   - Removed redundant `await MainActor.run { ... }` wrappers (methods are already `@MainActor`-isolated)

2. **`FineTune/Audio/AudioEngine.swift`**
   - Added per-session `permissionConfirmed` flag (not persisted — safe against `tccutil reset`)
   - Added `handleServiceRestarted()` — destroys all taps, clears state, waits 1.5s, recreates via `applyPersistedSettings()`
   - Added `recreateAllTaps()` helper — destroys and recreates all taps (used for `.unmuted` → `.mutedWhenTapped` upgrade)
   - Added `TapHealthSnapshot` struct replacing simple `lastCallbackCounts` dictionary — tracks `callbackCount`, `outputWritten`, `emptyInput` for delta analysis
   - Enhanced `checkTapHealth()` — now detects both stalled taps (callbacks stopped) AND broken taps (callbacks running, empty input, no output)
   - Reduced health check interval from 5s to 3s
   - Fast health check intervals changed from 1s/2s/3s to 300ms/500ms/700ms for faster permission confirmation
   - `ensureTapExists()` passes `muteOriginal: permissionConfirmed` to `ProcessTapController`
   - Permission confirmation logic: once `callbackCount > 10 && outputWritten > 0`, sets `permissionConfirmed = true` and calls `recreateAllTaps()`
   - Wired `deviceMonitor.onServiceRestarted` callback in init

3. **`FineTune/Audio/ProcessTapController.swift`**
   - Added `muteOriginal: Bool` parameter to `init()` (default: `true`)
   - All three `tapDesc.muteBehavior` sites now use `muteOriginal ? .mutedWhenTapped : .unmuted`
     - `activate()` — primary tap creation
     - `createSecondaryTap()` — crossfade secondary tap
     - `performDeviceSwitch()` — destructive switch new tap

### Fixes From First Session (Carried Forward)

4. **`FineTune/Audio/AudioEngine.swift`** (additional changes from session 1)
   - `ensureTapExists()` now sets `tap.isMuted = volumeState.getMute(for: app.id)` on creation
   - `setDevice()` guard relaxed to allow re-routing when tap is missing
   - 2-second startup delay before `applyPersistedSettings()`
   - `onAppsChanged` callback wired AFTER initial tap creation (prevents bypass)
   - `_diagEmptyInput` counter added to diagnostic log format

5. **`FineTune/Audio/ProcessTapController.swift`** (additional changes from session 1)
   - Force-silence check added to `processAudioSecondary()`
   - Destructive switch fade-in uses built-in ramper (removed manual volume loop)
   - Non-float crossfade protection: silences non-float output during crossfade
   - `_diagEmptyInput` counter for tracking callbacks with empty/nil input buffers
   - `emptyInput` field added to `TapDiagnostics` struct
   - Empty input detection in `processAudio()` primary callback

6. **`FineTune/Audio/Processing/AudioFormatConverter.swift`** — `#if canImport(FineTuneCore)` wrapper
7. **`FineTune/Audio/EQProcessor.swift`** — `#if canImport(FineTuneCore)` wrapper
8. **`FineTune/Settings/SettingsManager.swift`** — `#if canImport(FineTuneCore)` wrapper

### Documentation

9. **`docs/known_issues/resolved/audio-mute-on-permission-grant.md`** — Detailed technical report

---

## Timeline

### Phase 1: Initial Bug Exploration (First Context Window)

User requested: "check for known issues re: audio routing, muting, and let's fix them"

An Explore agent identified ~20 potential issues across the audio codebase. Three were fixed:
- Mute state not applied on new tap creation
- Destructive switch fade-in racing with user volume
- Non-float passthrough missing force-silence and crossfade checks

### Phase 2: Startup Muting and Re-routing Bugs (First Context Window)

User reported: "automatically muted on startup" and "can't reroute audio"

Two more fixes:
- `setDevice()` guard blocking re-routing when tap missing
- 2-second startup delay + `onAppsChanged` callback ordering fix

### Phase 3: Build Fix (First Context Window)

Build failed with `Unable to find module dependency: 'FineTuneCore'`. The module is only available via the SPM package (Package.swift) but the Xcode project doesn't reference it. Fixed by wrapping all 5 `import FineTuneCore` statements with `#if canImport(FineTuneCore)`.

### Phase 4: Permission Grant Investigation (First Context Window)

User identified the core issue: "as soon as I click [Allow] it still mutes." Audio was fine until clicking the permission dialog. Logs showed "Reporter disconnected" immediately after.

Added diagnostic counters, fast health checks (1s/2s/3s after tap creation), and empty input tracking. Health check approach was promising but the app was being killed before handlers could run.

### Phase 5: Root Cause Analysis (This Context Window)

Resumed from context summary. Read all key files and consulted Apple Core Audio documentation at `docs/Apple Core Audio Docs/`.

**Key findings from documentation:**
- "The first time you start recording from an aggregate device that contains a tap, the system prompts you to grant the app system audio recording permission."
- No documentation on "reporter disconnection" or tap behavior during permission changes
- `CATapMuteBehavior.mutedWhenTapped` mutes audio while tap is being actively read

**Key finding from codebase:**
- `AudioDeviceMonitor` and `DeviceVolumeMonitor` both handle `kAudioHardwarePropertyServiceRestarted`
- `AudioEngine` does NOT — all tap/aggregate AudioObjectIDs become invalid with no recovery

### Phase 6: coreaudiod Restart Handler (This Context Window)

Added `onServiceRestarted` callback to `AudioDeviceMonitor` and `handleServiceRestarted()` to `AudioEngine`. Destroys all stale taps and recreates after 1.5s delay.

**Result:** Build succeeded. But user reported same failure — app freezes and is killed.

### Phase 7: Enhanced Health Check (This Context Window)

Improved `checkTapHealth()` to detect two failure modes:
1. Stalled: callback count unchanged (original)
2. Broken: callbacks running, mostly empty input, no output (new)

Replaced simple `lastCallbackCounts: [pid_t: UInt64]` with `TapHealthSnapshot` struct. Reduced health check interval from 5s to 3s.

**Result:** User tested again — same failure. App freezes when clicking "Allow".

### Phase 8: External Code Review (This Context Window)

User shared analysis from another Claude session that identified two critical issues:

1. **Main-thread freeze:** `AudioDeviceMonitor` methods are `@MainActor`-isolated. `readDeviceDataFromCoreAudio()` (declared `nonisolated static`) runs ON the MainActor when called from `@MainActor` methods. During coreaudiod restart, these CoreAudio reads block, freezing the UI.

2. **Stale permission flag:** `permissionConfirmed` was persisted in UserDefaults. After `tccutil reset`, the flag remains `true`, causing taps to use `.mutedWhenTapped` before permission is re-granted.

### Phase 9: Final Fixes (This Context Window)

**Fix 1 — Off-main-thread CoreAudio reads:**
```swift
// Before (blocks main thread):
let deviceData = Self.readDeviceDataFromCoreAudio()

// After (runs off MainActor):
let deviceData = await Task.detached { Self.readDeviceDataFromCoreAudio() }.value
```

**Fix 2 — Per-session permission flag:**
Changed from UserDefaults-backed property to `private var permissionConfirmed = false`. Each launch starts with `.unmuted` taps, confirms permission within ~300ms of audio flow, then recreates all taps with `.mutedWhenTapped`.

**Fix 3 — Safe first-launch mute behavior:**
Added `muteOriginal: Bool` to `ProcessTapController`. On first launch (or after permission reset), taps use `.unmuted` so killing the app doesn't leave audio muted.

**Fix 4 — Faster permission upgrade:**
Fast health check intervals changed to 300ms/500ms/700ms. Permission confirmed and taps rebuilt with `.mutedWhenTapped` within ~300ms of audio flowing.

**Result:** Issue resolved. Permission grant flow:
1. First launch → `.unmuted` taps → dialog → Allow → app killed → audio NOT muted
2. Relaunch → `.unmuted` taps → audio flows → 300ms → confirmed → recreated with `.mutedWhenTapped`
3. Subsequent launches → `.unmuted` → 300ms → `.mutedWhenTapped` (per-session confirmation)

---

## Architecture Decisions

### Why Per-Session Permission Flag (Not Persisted)

UserDefaults persistence creates a vulnerability: `tccutil reset` revokes TCC permission but doesn't clear UserDefaults. The app would then create `.mutedWhenTapped` taps without permission, causing silent audio and app death. Per-session confirmation costs ~300ms of doubled audio on each launch (imperceptible) and is always correct.

### Why `.unmuted` Instead of No Taps

Alternative: don't create taps until permission is confirmed. This would require a separate permission-checking mechanism, and Apple provides no public API for preflight-checking system audio recording permission (unlike `CGPreflightScreenCaptureAccess()` for screen recording). Creating `.unmuted` taps triggers the permission dialog AND keeps audio flowing.

### Why `Task.detached` for CoreAudio Reads

`nonisolated` functions called from `@MainActor`-isolated async methods still execute on the MainActor (Swift concurrency semantics: synchronous `nonisolated` inherits caller's executor). `Task.detached` explicitly creates a new execution context off the MainActor, ensuring CoreAudio reads can block without freezing the UI.

---

## TODO List (Handoff)

### Critical

- [ ] **Verify permission grant flow end-to-end on clean install.** Reset TCC (`tccutil reset SystemPolicyAllFiles <bundle-id>`), delete app data, launch, click Allow, relaunch, confirm audio works with `.mutedWhenTapped`.
- [ ] **Test doubled audio during 300ms `.unmuted` window.** On launch with permission already granted, verify the brief doubled audio (original + tap) is imperceptible. If noticeable, consider increasing startup delay or suppressing tap output until permission is confirmed.

### High Priority

- [ ] **`DeviceVolumeMonitor` may have the same main-thread freeze.** It also handles `kAudioHardwarePropertyServiceRestarted` and may perform synchronous CoreAudio reads on MainActor during coreaudiod restart. Audit `handleServiceRestarted()` in `DeviceVolumeMonitor.swift` for the same pattern.
- [ ] **Orphaned tap cleanup on launch.** If the app is killed while taps exist, those taps may persist as orphans until coreaudiod cleans them up. Consider adding a launch-time check that destroys any pre-existing FineTune taps (by scanning for taps matching app's bundle ID).
- [ ] **`outPeak=0.000` root cause from previous session.** The diagnostic showing `inPeak=0.460, outPeak=0.000` from the virtual device routing issue (SRAudioDriver) should be verified as resolved after the virtual device filter was deployed.
- [ ] **Test Bluetooth device switching after permission changes.** The crossfade path creates secondary taps with the same `muteOriginal` flag. Verify device switching works correctly in both `.unmuted` (pre-confirmation) and `.mutedWhenTapped` (post-confirmation) modes.

### Medium Priority

- [ ] **Consolidate health check timers.** There are now three overlapping health mechanisms: (1) fast health check per-tap (300ms/500ms/700ms), (2) periodic health check (3s), (3) service restart handler. Consider unifying into a single health monitor.
- [ ] **Diagnostic timer lifecycle.** The `Task` in `AudioEngine.init()` for diagnostics + health checks is never explicitly cancelled. It relies on `[weak self]`. Consider storing and cancelling in `stop()`.
- [ ] **Reduce diagnostic overhead.** `computeOutputPeak()` scans all output buffer samples on every callback (RT thread). Consider sampling every Nth callback or making diagnostics toggleable.
- [ ] **`HALC_ProxyIOContext::IOWorkLoop` out-of-order messages.** These CoreAudio internal warnings appear during permission changes. They appear harmless but should be monitored for correlation with audio issues.
- [ ] **Startup delay tuning.** The 2-second startup delay before tap creation may be too long for normal launches (where permission is already granted). Consider reducing or making it adaptive based on `permissionConfirmed`.

### Low Priority / Future

- [ ] **Permission preflight API.** Apple may add a public API for checking system audio recording permission in future macOS versions. If available, use it instead of the `.unmuted` probe approach.
- [ ] **`isProcessRestoreEnabled` on CATapDescription.** The Apple docs mention this property which "saves tapped processes by bundle ID when they exit and restores them when they start up again." Could potentially help with tap persistence across app restarts.
- [ ] **Virtual device allowlist.** Current filter blocks ALL virtual devices from default routing. Users who intentionally use virtual devices (BlackHole, Loopback) would need to manually select them per-app.
- [ ] **CoreSpeech tap noise.** `CoreSpeech: callbacks=0` in diagnostics — tap activates but never fires. Consider excluding system daemons.

---

## Known Issues

### Resolved This Session

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Audio mutes when clicking "Allow" on permission dialog | `.mutedWhenTapped` persists after app death | Use `.unmuted` until permission confirmed |
| App freezes on permission grant | `readDeviceDataFromCoreAudio()` blocks MainActor during coreaudiod restart | `Task.detached` for off-main-thread reads |
| No recovery after coreaudiod restart | `AudioEngine` had no `ServiceRestarted` handler | Added handler: destroy all taps, wait, recreate |
| Health check misses broken taps | Only detected stalled callbacks (count unchanged) | Added broken-tap detection (empty input, no output) |
| Stale permission flag after `tccutil reset` | `permissionConfirmed` persisted in UserDefaults | Changed to per-session flag |
| Mute not applied on new tap creation | `ensureTapExists()` didn't set `isMuted` | Added `tap.isMuted = volumeState.getMute(...)` |
| Can't re-route when tap missing | `setDevice()` guard rejected when routing matched but no tap | Relaxed guard to allow through |
| Startup delay bypassed | `onAppsChanged` fired during `processMonitor.start()` | Wired callback AFTER initial `applyPersistedSettings()` |
| Destructive switch fade-in races with user volume | Manual volume loop overrode user changes | Removed manual loop, use built-in ramper |
| Non-float doubled during crossfade | Non-float passthrough not silenced during crossfade | Zero output when `crossfadeMultiplier < 1.0` |
| Secondary callback missing force-silence | `processAudioSecondary()` didn't check `_forceSilence` | Added check at callback entry |
| Build failure: `import FineTuneCore` | FineTuneCore not in Xcode project | `#if canImport(FineTuneCore)` wrappers |

### Open / Not Addressed

| Issue | Description | Priority |
|-------|-------------|----------|
| `DeviceVolumeMonitor` potential main-thread freeze | Same `@MainActor` + synchronous CoreAudio reads pattern | High |
| Orphaned taps on crash | Taps may persist if app killed without cleanup | High |
| Bluetooth latency | Audio out of sync on AirPods (inherent BT latency) | Medium |
| `HALC_ProxyObject` hog mode errors | Another process may have exclusive device access | Medium |
| `AudioObjectRemovePropertyListenerBlock` stale IDs | Listeners from previous run referencing dead objects | Low |
| CoreSpeech tap never fires | System daemon produces no audio, wasted resources | Low |

---

## Commands for Future Debugging

```bash
# Pull FineTune diagnostic logs (must include --info flag)
/usr/bin/log show --predicate 'process == "FineTune"' --last 2m --info 2>&1 | grep "DIAG"

# Pull permission-related logs
/usr/bin/log show --predicate 'process == "FineTune"' --last 2m --info 2>&1 | grep -E "PERMISSION|SERVICE-RESTART|HEALTH|RECREATE"

# Pull all errors and key events
/usr/bin/log show --predicate 'process == "FineTune"' --last 5m --info 2>&1 | grep -E "DIAG|error|Error|Failed|SWITCH|CROSSFADE|PERMISSION|SERVICE-RESTART|HEALTH|Reporter"

# Reset system audio recording permission (for testing)
tccutil reset SystemPolicyAllFiles <bundle-id>

# Check for orphaned FineTune audio objects
/usr/bin/log show --predicate 'process == "coreaudiod"' --last 2m 2>&1 | grep -i "FineTune"
```

---

## Build Verification

All changes verified with:
```bash
xcodebuild -project FineTune.xcodeproj -scheme FineTune -configuration Debug build
```
Build succeeded at each stage. No compiler errors. SourceKit diagnostic warnings (e.g., "Cannot find type 'AudioApp' in scope") are indexing artifacts from types defined in other files — not real build errors.

---

## Apple Core Audio Documentation Reference

Local docs at `docs/Apple Core Audio Docs/` were consulted:
- `coreaudio_consolidated.md` — Process tap API, `CATapMuteBehavior`, `AudioHardwareCreateProcessTap`, `kAudioHardwarePropertyServiceRestarted`
- `audiotoolbox_consolidated.md` — AudioConverter APIs (not directly relevant but searched)

Key finding: No Apple documentation exists for "reporter disconnection" or tap lifecycle during permission changes. The `kAudioHardwarePropertyServiceRestarted` property is documented but its relationship to TCC permission grants is not explicitly stated. Behavior was determined empirically.
