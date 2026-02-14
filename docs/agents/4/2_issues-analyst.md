# Agent 2: Comprehensive Issues Analysis

**Agent:** issues-analyst
**Date:** 2026-02-07
**Task:** Deep dive into all documented issues, agent research sessions, and current source code

---

## 1. COMPLETE ISSUE INVENTORY

### Issue A: Audio Mute on Permission Grant (RESOLVED)
- **Status:** Resolved (2026-02-06)
- **Severity:** Critical
- **Files:** `AudioEngine.swift`, `ProcessTapController.swift`, `AudioDeviceMonitor.swift`
- **Symptom:** Clicking "Allow" on macOS system audio permission dialog caused complete audio loss, app freeze, SIGKILL.
- **Root cause:** Three interacting issues: (1) `.mutedWhenTapped` taps survive app death during SIGKILL, (2) main-thread freeze during coreaudiod restart from synchronous CoreAudio reads on `@MainActor`, (3) no `AudioEngine` handler for `kAudioHardwarePropertyServiceRestarted`.
- **Fix:** Per-session `permissionConfirmed` flag starting taps as `.unmuted`, off-main-thread CoreAudio reads via `Task.detached`, coreaudiod restart handler, enhanced health check detecting both stalled and broken taps.

### Issue B: Xcode Permission Pause / Premature Permission Confirmation (RESOLVED)
- **Status:** Resolved (2026-02-07)
- **Severity:** High
- **Files:** `AudioEngine.swift`, `MenuBarStatusController.swift`, `SingleInstanceGuard.swift`
- **Symptom:** Xcode pause on permission dialog, menu bar unresponsive, audio mutes after permission.
- **Root cause:** (A) Xcode runtime diagnostic pauses, (B) layout recursion in menu bar panel, (C) permission confirmation gate only checked callback/output activity, not real input audio.
- **Fix:** Removed recursive layout trigger, strengthened `shouldConfirmPermission` to require `inputHasData > 0 || lastInputPeak > 0.0001`.

### Issue C: Spurious Default Device Display During Permission/Restart (OPEN -- partially mitigated)
- **Status:** OPEN (core issue persists with mitigations in place)
- **Severity:** HIGH -- causes PERSISTENT DATA CORRUPTION of saved routing
- **Symptom:** After clicking "Allow" or coreaudiod restart, per-app device picker shows "MacBook Pro Speakers" even though audio plays through AirPods.
- **Root causes (cascading failure):**
  1. coreaudiod restart causes `AudioDeviceMonitor` to refresh `outputDevices`
  2. AirPods temporarily disappear from `outputDevices` (Bluetooth reconnection latency)
  3. `appDeviceRouting` still maps `{pid: "AirPods-UID"}` but the `availableDevices.contains` check in `resolvedDeviceUIDForDisplay` FAILS because AirPods are absent
  4. Falls through to `defaultDeviceUID` which `DeviceVolumeMonitor` has set to "MacBook Pro Speakers"
  5. **CRITICAL:** If a debounced notification slips through, `routeAllApps` calls `settingsManager.updateAllDeviceRoutings(to: deviceUID)` which REWRITES ALL saved per-app routings to speakers -- this is persistent data corruption, not just a display bug
- **Current mitigations:** `isRecreatingTaps` flag, `recreationGracePeriod` (2s), `recreationEndedAt` timestamp, routing snapshot/restore, `serviceRestartTask` cancellation on re-entry
- **Remaining gaps:**
  - `isRecreatingTaps` is set INSIDE a Task in `recreateAllTaps()` (line 843), creating a timing window
  - `defaultDeviceUID` is updated independently by `DeviceVolumeMonitor`, not blocked by the flag
  - `availableDevices.contains` check fails when AirPods are transiently absent
  - No replay of legitimately suppressed device changes

### Issue D: Audio Muting During `.unmuted` to `.mutedWhenTapped` Transition (OPEN -- partially mitigated)
- **Status:** OPEN
- **Severity:** HIGH
- **Symptom:** Audio goes silent after permission grant; user must pause/play in Spotify to restore.
- **Root causes:**
  1. **Primary:** coreaudiod restart itself disrupts ALL audio sessions system-wide -- outside FineTune's control
  2. **Secondary:** Double (potentially triple) tap recreation: (a) `handleServiceRestarted` destroys+recreates with `.unmuted`, (b) fast health check confirms permission -> `recreateAllTaps()` destroys+recreates with `.mutedWhenTapped`
  3. **Tertiary:** `.mutedWhenTapped` transition silences original audio; if the app isn't producing audio (session disrupted), silence results
- **Current state:** `wasPermissionConfirmed` snapshot in `handleServiceRestarted` helps ONLY for subsequent restarts (not first-launch permission grant where it's `false` by design)

### Issue E: Bundle-ID Tap Silent Output on macOS 26 (OPEN -- investigation complete)
- **Status:** OPEN -- no workaround, root cause under investigation
- **Severity:** HIGH -- complete audio silence for affected apps
- **Files:** `ProcessTapController.swift` (lines 286-290)
- **Symptom:** Bundle-ID taps (`bundleIDs` + `isProcessRestoreEnabled`) capture audio (inPeak > 0) but aggregate output is dead (outPeak = 0.000). PID-only taps can't capture Chromium audio on macOS 26 at all.
- **Root cause hypothesis:** `isProcessRestoreEnabled` changes CoreAudio's internal aggregate wiring, disconnecting output from the physical device
- **Safety net added:** `shouldConfirmPermission` now requires `lastOutputPeak > 0.0001` (with volume awareness) to prevent promotion to `.mutedWhenTapped` with dead output
- **Next steps:** Test 4-flag matrix (bundleIDs on/off x processRestore on/off), test on macOS 26.1+

### Issue F: Stale Play/Pause Status (OPEN -- partially fixed)
- **Status:** PARTIALLY FIXED
- **Severity:** Medium
- **Symptom:** Play/pause indicator doesn't update; gets stuck on "Paused"
- **Root cause:** Circular dependency -- `isPaused=true` stops VU polling -> `lastAudibleAtByPID` never updates -> stays paused forever
- **Fixes applied:**
  - 1s lightweight `updatePauseStates()` timer independent of UI polling
  - Asymmetric hysteresis: 1.5s grace for playing->paused, 0.05s for paused->playing
  - Per-PID `PauseState` enum for proper hysteresis tracking
- **Remaining gaps:** Up to 1s latency for pause->playing recovery; no MediaRemote integration for instant detection on active now-playing app

### Issue G: Volume Jumps on Keyboard Press (OPEN -- not addressed)
- **Status:** OPEN
- **Severity:** Low-Medium
- **Symptom:** Volume jumps far on single keyboard press
- **Root cause hypotheses:** (1) Stale volume state after coreaudiod restart (HAL reports 1.0 for BT devices before init), (2) feedback loop between macOS volume keys and FineTune's volume listener

### Issue H: Permission-Grant Aggregate Device Notification (RESOLVED with ongoing mitigations)
- **Status:** RESOLVED (the routing overwrite path is suppressed)
- **Fix:** `isRecreatingTaps` flag + timestamp grace period + routing snapshot/restore

---

## 2. ROOT CAUSES IDENTIFIED

### Fundamental Root Cause 1: Aggregate Device Destruction Perturbs macOS Audio Graph
Destroying aggregate devices (even private ones) during tap recreation triggers spurious `kAudioHardwarePropertyDefaultOutputDevice` notifications. This causes `DeviceVolumeMonitor` to update `defaultDeviceUID` to the wrong device (speakers instead of AirPods).

### Fundamental Root Cause 2: coreaudiod Restart Invalidates Everything
When the user clicks "Allow," coreaudiod restarts, invalidating ALL AudioObjectIDs. This is unavoidable. The restart disrupts ALL audio sessions system-wide, causing apps like Spotify to pause.

### Fundamental Root Cause 3: `.unmuted` -> `.mutedWhenTapped` Transition Requires Tap Recreation
The current architecture must destroy and recreate all taps to switch mute behavior. This causes audio gaps and spurious notifications.

### Fundamental Root Cause 4: Bluetooth Device Reconnection Latency
AirPods may take >1500ms to reappear in the device list after coreaudiod restart. The current `serviceRestartDelay` of 1500ms may be insufficient, causing `applyPersistedSettings` to fall through to the wrong default device.

### Fundamental Root Cause 5: VU-Based Pause Detection Circular Dependency
`isPaused=true` stops the VU polling that would update `lastAudibleAtByPID`, creating a self-reinforcing stuck state.

### Fundamental Root Cause 6: macOS 26 Bundle-ID Tap + processRestore Aggregate Output Failure
`isProcessRestoreEnabled` appears to change CoreAudio's internal aggregate wiring, killing the output path while capture works fine. PID-only taps simultaneously can't capture Chromium audio on macOS 26 due to multi-process audio architecture.

---

## 3. WHAT'S BEEN TRIED -- Solutions and Outcomes

| Solution | Target | Outcome |
|----------|--------|---------|
| Per-session `permissionConfirmed` flag + `.unmuted` first-launch | Issue A | RESOLVED -- prevents muted audio on app kill during permission |
| Off-main-thread CoreAudio reads (`Task.detached`) | Issue A | RESOLVED -- prevents main-thread freeze |
| `handleServiceRestarted()` in AudioEngine | Issue A | RESOLVED -- recreates taps after coreaudiod restart |
| Enhanced health checks (stalled + broken detection) | Issue A | RESOLVED -- catches reporter-disconnected taps |
| `isRecreatingTaps` flag | Issue C | PARTIALLY EFFECTIVE -- blocks `routeAllApps` but not `defaultDeviceUID` updates; timing gap in `recreateAllTaps()` |
| `recreationGracePeriod` (2s timestamp) | Issue C | HELPS -- catches late-arriving debounced notifications |
| Routing snapshot/restore | Issue C | HELPS -- prevents persisted routing corruption if restoration runs |
| `serviceRestartTask` cancellation | Issue C | HELPS -- prevents overlapping restart tasks from clearing flag prematurely |
| `shouldConfirmPermission` requiring input evidence | Issue B | RESOLVED -- prevents false-positive permission confirmation |
| `shouldConfirmPermission` requiring output peak | Issue E | SAFETY NET -- prevents promotion to `.mutedWhenTapped` with dead output |
| 1s `updatePauseStates()` timer | Issue F | PARTIALLY FIXED -- breaks circular dependency but 1s latency remains |
| Asymmetric hysteresis (1.5s/0.05s) | Issue F | HELPS -- reduces false pauses from song gaps |
| `FineTuneForcePIDOnlyTaps` defaults key | Issue E | NOT A WORKAROUND -- PID-only can't capture Chromium |

---

## 4. WHAT'S STILL BROKEN -- Current Open Issues

1. **Spurious device display (Issue C):** The availability check in `resolvedDeviceUIDForDisplay` fails when AirPods are transiently absent. Need a persisted routing fallback that skips the availability check during the recreation window.

2. **`routeAllApps` data corruption (Issue C):** If ANY notification slips through suppression, `settingsManager.updateAllDeviceRoutings()` rewrites ALL saved per-app routings. This is persistent data loss.

3. **Double/triple recreation on first-launch permission grant (Issue D):** `wasPermissionConfirmed` is `false` on first launch, so the double-recreate path still fires. Need a different guard for first-launch.

4. **macOS 26 bundle-ID tap output failure (Issue E):** Neither tap mode fully works on Tahoe. Need to test the 4-flag matrix and potentially remove `isProcessRestoreEnabled`.

5. **1s pause recovery latency (Issue F):** Acceptable but not instant. MediaRemote integration would provide 0ms latency for the active now-playing app.

6. **Volume jump on keyboard (Issue G):** Not investigated or addressed.

---

## 5. PATTERNS AND THEMES

### Pattern 1: Permission-Related Cascading Failures
The permission grant flow (coreaudiod restart -> all IDs invalidated -> tap destruction -> aggregate destruction -> spurious notifications -> wrong routing) is a single event that triggers a cascade of failures across multiple subsystems. Every fix is a dam at a different point in the cascade.

### Pattern 2: macOS Version-Specific Breakage
- macOS 26 broke PID-based tapping for Chromium browsers (multi-process audio)
- macOS 26 `isProcessRestoreEnabled` may break aggregate output
- macOS 26.0 had multiple audio bugs (sample rate mismatch, communication app silence) fixed in 26.1
- macOS 15.4+ restricted MediaRemote access

### Pattern 3: Timing-Dependent Race Conditions
Nearly every issue involves async notification delivery, debounce timers, Bluetooth reconnection latency, and MainActor scheduling. The `isRecreatingTaps` flag is fundamentally a timing-based defense that can be defeated by specific timing sequences.

### Pattern 4: Aggregate Device Architecture as Root Cause
Including the real output device as a sub-device in aggregates is the root cause of spurious device-change notifications. Multiple open-source projects (SoundPusher, AudioTee) deliberately use tap-only aggregates without the real device, and explicitly document that including it "only confused matters."

### Pattern 5: Circular Dependencies in State Management
VU polling depends on pause state which depends on VU polling. `applyPersistedSettings` reads `defaultOutputDeviceUID` which is corrupted by the same notification sequence it's trying to recover from.

---

## 6. ARCHITECTURE ASSESSMENT

### Current Audio Pipeline
```
App -> ProcessTap (CATapDescription) -> Aggregate Device (tap + real output device) -> IOProc callback -> processed audio -> output device
```

### Known Weak Points

1. **Real device in aggregate:** The `kAudioAggregateDeviceMainSubDeviceKey` and `kAudioAggregateDeviceSubDeviceListKey` referencing the real output device is the primary source of spurious notifications. Three independent sources (SoundPusher, AudioTee, CoreAudio Taps for Dummies) confirm tap-only aggregates work correctly.

2. **Tap recreation for mute behavior change:** The `kAudioTapPropertyDescription` property is documented as settable, meaning `muteBehavior` could potentially be changed live without destroying/recreating taps. This is the single highest-impact architectural improvement.

3. **Boolean flag suppression:** The `isRecreatingTaps` + timestamp approach is fundamentally fragile. A state machine with saved routing would be more robust, but the current targeted fixes (snapshot/restore, cancellation, grace period) address the practical gaps.

4. **No separation of capture and playback:** The aggregate device conflates capture (tap input) and playback (sub-device output). A decoupled architecture (tap-only aggregate for capture + separate output IOProc via ring buffer) would isolate these concerns.

5. **Per-app aggregate proliferation:** N apps = N aggregate devices. Each destruction/creation perturbs the audio graph. A proxy aggregate or tap-only aggregate approach would reduce the blast radius.

### Highest-Impact Architectural Changes (from research)

1. **Switch to tap-only aggregates** -- Remove real device from aggregate configuration. Proven by SoundPusher + AudioTee. Eliminates spurious device notifications at the source.

2. **Live tap reconfiguration via `kAudioTapPropertyDescription`** -- Change `muteBehavior` in-place without destroying taps. Eliminates `recreateAllTaps()` entirely for permission grant.

3. **Always use `.mutedWhenTapped`** -- Remove the `.unmuted` phase and `permissionConfirmed` flag. CoreAudio cleans up process-owned resources on exit, making the `.unmuted` safety net unnecessary.

4. **Decouple capture from playback** -- Use tap-only aggregate for capture + separate output IOProc. Isolates the macOS 26 bundle-ID output failure.

### Current Code State (from git diff)
The codebase has already applied several fixes from the research sessions:
- Routing snapshot/restore mechanism
- `serviceRestartTask` cancellation on re-entry
- Asymmetric hysteresis for pause detection
- `shouldConfirmPermission` with output peak check
- 1s `updatePauseStates()` timer
- `recreationGracePeriod` timestamp-based suppression
- `shouldSuppressDeviceNotifications` computed property combining flag + grace period
