# Audio Mute on System Audio Permission Grant

**Status:** Resolved
**Date:** 2026-02-06
**Severity:** Critical (complete audio loss, app freeze/kill)
**Files Modified:** `AudioEngine.swift`, `ProcessTapController.swift`, `AudioDeviceMonitor.swift`

---

## Symptom

When the user clicks "Allow" on the macOS system audio recording permission dialog, all system audio immediately goes silent and the app freezes (menu bar icon unresponsive). The process is then killed by the system (SIGKILL). On relaunch (with permission now granted), audio worked — but only if the user knew to relaunch.

Console output at the moment of failure:

```
Reporter disconnected. { function=sendMessage, reporterID=133105331470337 }
HALC_ProxyIOContext.cpp:1631 HALC_ProxyIOContext::IOWorkLoop: context 3033 received an out of order message (got 10 want: 9)
Message from debugger: killed
```

## Root Cause (Three Interacting Issues)

### 1. Process Tap Mute Behavior Survives App Death

Process taps created with `CATapMuteBehavior.mutedWhenTapped` silence the original audio output while the tap's IO proc is actively reading. When the system kills the app during the permission grant flow, the tap may not be cleaned up immediately — leaving audio muted with no replacement audio pipeline.

The macOS permission grant flow for system audio recording terminates the app process (SIGKILL). No in-process handler can intercept SIGKILL, so cleanup code (`stopSync()`, `invalidate()`) never runs. The tap's mute effect persists until coreaudiod finishes cleaning up orphaned audio objects.

### 2. Main-Thread Freeze During coreaudiod Restart

`AudioDeviceMonitor` is annotated `@MainActor`. When coreaudiod restarts (triggered by the permission grant), `kAudioHardwarePropertyServiceRestarted` fires and calls `handleServiceRestartedAsync()`. This method called `Self.readDeviceDataFromCoreAudio()` — a function that makes synchronous CoreAudio API calls (`AudioObjectID.readDeviceList()`, `readDeviceUID()`, `readDeviceName()`).

Despite being declared `nonisolated static`, the function ran on the MainActor because it was called from a `@MainActor`-isolated method. During coreaudiod restart, these CoreAudio reads block for seconds (the daemon is mid-restart and can't service requests), freezing the main thread entirely. This made the app unresponsive before SIGKILL arrived.

The same issue affected `handleDeviceListChangedAsync()`.

### 3. No Recovery Path After coreaudiod Restart

`AudioDeviceMonitor` and `DeviceVolumeMonitor` both listened for `kAudioHardwarePropertyServiceRestarted` and refreshed their own state. However, `AudioEngine` — which owns all the process taps and aggregate devices — had **no handler** for this event. After coreaudiod restarted:

- All `AudioObjectID`s for taps, aggregate devices, and IO procs became invalid
- `AudioEngine` still held references to stale objects
- No taps were recreated
- The 5-second health check only detected **stalled** callbacks (count not changing), not **broken** taps (callbacks running but reporter disconnected — empty input, no output written)

## Fix

### Fix 1: Safe First-Launch Tap Creation (`ProcessTapController.swift`, `AudioEngine.swift`)

Added a `muteOriginal` parameter to `ProcessTapController`:

```swift
init(app: AudioApp, targetDeviceUID: String, deviceMonitor: AudioDeviceMonitor? = nil, muteOriginal: Bool = true)
```

All three locations where `CATapMuteBehavior` is set now use:

```swift
tapDesc.muteBehavior = muteOriginal ? .mutedWhenTapped : .unmuted
```

`AudioEngine` tracks a per-session `permissionConfirmed` flag (not persisted to UserDefaults — permission can be revoked externally via `tccutil reset`). On each launch:

1. Taps start with `.unmuted` — original audio plays alongside tap output
2. Fast health check at 300ms detects audio flowing (`callbackCount > 10 && outputWritten > 0`)
3. Sets `permissionConfirmed = true` and calls `recreateAllTaps()`
4. All taps are destroyed and recreated with `.mutedWhenTapped`

**Result:** If the app is killed during the permission dialog, audio is NOT muted because the taps used `.unmuted`. The brief period of doubled audio (~300ms on normal launches) is imperceptible.

### Fix 2: Off-Main-Thread CoreAudio Reads (`AudioDeviceMonitor.swift`)

Both `handleServiceRestartedAsync()` and `handleDeviceListChangedAsync()` now run blocking CoreAudio reads via `Task.detached`:

```swift
// Before (blocks main thread during coreaudiod restart):
let deviceData = Self.readDeviceDataFromCoreAudio()

// After (runs off MainActor):
let deviceData = await Task.detached { Self.readDeviceDataFromCoreAudio() }.value
```

MainActor state (`knownDeviceUIDs`, `outputDevices`) is captured before the detached task, and UI updates happen after `await` returns — back on MainActor automatically (method is `@MainActor`-isolated).

### Fix 3: coreaudiod Restart Handler (`AudioDeviceMonitor.swift`, `AudioEngine.swift`)

Added `onServiceRestarted` callback to `AudioDeviceMonitor`:

```swift
var onServiceRestarted: (() -> Void)?
```

Called at the end of `handleServiceRestartedAsync()` after device lists are refreshed. `AudioEngine` wires this up to `handleServiceRestarted()` which:

1. Cancels all in-flight device switch tasks
2. Calls `invalidate()` on every tap (async teardown — won't block main thread)
3. Clears `taps`, `appliedPIDs`, `lastHealthSnapshots`
4. Preserves `appDeviceRouting` (user device preferences use string UIDs, not AudioObjectIDs)
5. Waits 1.5s for coreaudiod to stabilize
6. Recreates all taps via `applyPersistedSettings()`

### Fix 4: Enhanced Health Check (`AudioEngine.swift`)

The periodic health check (`checkTapHealth()`, every 3 seconds) now detects two failure modes:

| Mode | Detection | Condition |
|------|-----------|-----------|
| **Stalled** | Callback count unchanged between checks | `callbackDelta == 0` |
| **Broken** | Callbacks running, mostly empty input, no output | `callbackDelta > 50 && outputDelta == 0 && emptyDelta > callbackDelta / 2` |

Previously only stalled taps were detected. Broken taps (reporter disconnected but IO proc still firing with empty buffers) went unnoticed.

Diagnostic tracking was upgraded from a single `lastCallbackCounts: [pid_t: UInt64]` to a `TapHealthSnapshot` struct capturing `callbackCount`, `outputWritten`, and `emptyInput` for delta analysis.

## Additional Changes Made During Investigation

These were implemented in the same session while diagnosing the root cause:

- **Mute state on new tap creation**: `ensureTapExists()` now sets `tap.isMuted = volumeState.getMute(for: app.id)` so persisted mute state is applied immediately.
- **`setDevice()` guard relaxed**: Changed from blocking when device matches to allowing through when no tap exists, so users can retry failed device routing.
- **Startup delay**: 2-second delay before initial `applyPersistedSettings()` to let apps initialize audio sessions. `onAppsChanged` callback wired AFTER initial setup to prevent bypassing the delay.
- **Destructive switch fade-in**: Removed manual volume loop that raced with user changes; uses the built-in exponential ramper instead.
- **Non-float crossfade protection**: Silences non-float output during crossfade to prevent doubled audio from both taps.
- **Force-silence in secondary callback**: Added `_forceSilence` check to `processAudioSecondary()`.
- **Empty input tracking**: Added `_diagEmptyInput` counter and `emptyInput` field to `TapDiagnostics` for detecting reporter disconnection.
- **Conditional imports**: Wrapped all `import FineTuneCore` with `#if canImport(FineTuneCore)` to fix build when FineTuneCore SPM package isn't linked in the Xcode project.

## Key Learnings

1. **macOS kills apps on permission grant.** System audio recording permission (TCC) terminates the requesting process via SIGKILL when the user clicks "Allow". No in-process cleanup runs. Audio objects (taps with `.mutedWhenTapped`) must be safe to orphan.

2. **`@MainActor` class methods run on main thread even when calling `nonisolated` functions.** A `nonisolated static func` called from a `@MainActor`-isolated method executes on the main thread. Use `Task.detached` to explicitly move blocking work off the MainActor.

3. **`kAudioHardwarePropertyServiceRestarted` invalidates ALL AudioObjectIDs.** Every component that holds CoreAudio object references (not just device monitors) must handle this event by tearing down and recreating its resources.

4. **Health checks must distinguish "stalled" from "broken".** A process tap can have its IO proc running (callbacks incrementing) while receiving no actual audio data (reporter disconnected). Monitoring callback count alone misses this failure mode — output and empty-input counters are needed.

5. **Per-session permission flags are safer than persisted ones.** UserDefaults flags can become stale if TCC permissions are revoked externally (`tccutil reset`). A per-session flag that re-confirms permission on each launch (via observing audio flow) is more robust.

## Testing

1. Reset permission: `tccutil reset SystemPolicyAllFiles <bundle-id>`
2. Launch app
3. Observe taps created with `.unmuted` (`[PERMISSION] Creating tap for ... with .unmuted`)
4. Click "Allow" on permission dialog
5. App is killed — audio continues playing (not muted)
6. Relaunch app
7. Observe `[PERMISSION] System audio permission confirmed` within ~300ms
8. Observe `[RECREATE]` logs as taps are rebuilt with `.mutedWhenTapped`
9. Per-app volume control now works normally
