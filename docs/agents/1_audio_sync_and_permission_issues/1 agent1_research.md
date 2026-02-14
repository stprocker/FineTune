# Agent 1 Research Report: Audio Sync, Permission, and Play/Pause Issues

**Date:** 2026-02-07
**Scope:** Bugs 1-3 in FineTune (permission button erroneous device display, permission button mutes audio, play/pause status not staying updated)

---

## Table of Contents

1. [Core Audio Fundamentals](#1-core-audio-fundamentals)
2. [Permission Grant Flow](#2-permission-grant-flow)
3. [Race Conditions & Pitfalls](#3-race-conditions--pitfalls)
4. [Best Practices from Other Projects](#4-best-practices-from-other-projects)
5. [Audio Continuity](#5-audio-continuity)
6. [Now Playing / Play-Pause Tracking](#6-now-playing--play-pause-tracking)
7. [Recommendations](#7-recommendations)

---

## 1. Core Audio Fundamentals

### 1.1 Aggregate Devices

An `AudioHardwareAggregateDevice` is a virtual device that combines the input and output streams of multiple real devices or taps. It synchronizes the clocks of its subdevices and subtaps when running IO to ensure streams are aligned ([Apple docs](https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice)).

Key aggregate device constants used by FineTune:
- `kAudioAggregateDeviceNameKey` -- human-readable name
- `kAudioAggregateDeviceUIDKey` -- unique identifier
- `kAudioAggregateDeviceMainSubDeviceKey` -- the primary sub-device (the real output device)
- `kAudioAggregateDeviceIsPrivateKey` -- when `true`, the device is not visible to other processes
- `kAudioAggregateDeviceTapAutoStartKey` -- auto-starts the tap when the aggregate starts
- `kAudioAggregateDeviceTapListKey` -- list of taps attached to the aggregate
- `kAudioSubTapDriftCompensationKey` -- enables drift compensation for the tap

Creation: `AudioHardwareCreateAggregateDevice(description, &deviceID)`
Destruction: `AudioHardwareDestroyAggregateDevice(deviceID)`

**Critical teardown order** (from `TapResources.swift` lines 19-49):
1. `AudioDeviceStop(aggregateDeviceID, procID)` -- stop the IO proc
2. `AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)` -- destroy IO proc
3. `AudioHardwareDestroyAggregateDevice(aggregateDeviceID)` -- destroy aggregate
4. `AudioHardwareDestroyProcessTap(tapID)` -- destroy process tap

Violating this order can leak resources or crash on shutdown.

### 1.2 Process Taps

An `AudioHardwareTap` captures outgoing audio from a process or group of processes and can be used as an input stream source in an aggregate device ([Apple docs](https://developer.apple.com/documentation/coreaudio/audiohardwaretap)).

Key `CATapDescription` properties:
- `processes` -- array of `AudioObjectID`s for the processes to tap
- `deviceUID` -- the target output device UID
- `stream` -- which stream index to tap
- `uuid` -- unique identifier for the tap
- `isPrivate` -- visibility flag
- `muteBehavior` -- controls whether tapped process audio is muted (see below)
- `isProcessRestoreEnabled` -- whether process state should be restored

### 1.3 CATapMuteBehavior

The `CATapMuteBehavior` enum has three cases ([Apple docs](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)):
- `.unmuted` -- audio is captured by the tap AND also sent to the audio hardware (default)
- `.muted` -- audio is always captured and muted at the hardware
- `.mutedWhenTapped` -- audio is muted at the hardware only when being read through a tap

FineTune's strategy:
- **Before permission is confirmed**: uses `.unmuted` so that if the app is killed during the permission dialog, audio continues normally
- **After permission is confirmed**: switches to `.mutedWhenTapped` for proper per-app volume control

This is implemented in `AudioEngine.swift` line 647: `let shouldMute = permissionConfirmed`

### 1.4 Device Change Notifications

Two critical property selectors:
- `kAudioHardwarePropertyDefaultOutputDevice` -- fires when the system default output device changes
- `kAudioHardwarePropertyServiceRestarted` -- fires when coreaudiod restarts

Both are listened to by `DeviceVolumeMonitor` and `AudioDeviceMonitor`. The default device notification fires on the `coreAudioListenerQueue` (a shared CoreAudio listener dispatch queue) and is debounced by 300ms before processing.

### 1.5 The AudioObjectID Lifecycle

All `AudioObjectID`s (taps, aggregates, devices) are assigned by coreaudiod and become **invalid when coreaudiod restarts**. This is the fundamental reason that FineTune must handle service restarts: every tap and aggregate device ID becomes a dangling reference.

---

## 2. Permission Grant Flow

### 2.1 What Happens When the User Clicks "Allow"

Based on code analysis and Apple documentation, the following sequence occurs when the user grants system audio recording permission:

1. **TCC database is updated** -- macOS records the permission grant in the TCC database
2. **coreaudiod restarts** -- the audio daemon restarts to pick up the new permission state. This is observed in FineTune's logs and is why both `AudioDeviceMonitor` and `DeviceVolumeMonitor` listen for `kAudioHardwarePropertyServiceRestarted`
3. **All AudioObjectIDs become invalid** -- taps, aggregate devices, and even device IDs may change
4. **Device list notifications fire** -- `kAudioHardwarePropertyDevices` notifications fire because the device list has been refreshed
5. **Default device notification fires** -- `kAudioHardwarePropertyDefaultOutputDevice` notification fires as coreaudiod re-establishes device state. This is the **spurious notification** that causes Bug 1
6. **Process list refreshes** -- `kAudioHardwarePropertyProcessObjectList` notifications fire

### 2.2 The Timing Problem

The notification sequence is approximately:

```
T+0ms:    User clicks "Allow"
T+~50ms:  TCC database updated
T+~100ms: coreaudiod begins restart
T+~200ms: kAudioHardwarePropertyServiceRestarted fires
T+~250ms: kAudioHardwarePropertyDevices fires (device list refreshed)
T+~300ms: kAudioHardwarePropertyDefaultOutputDevice fires (spurious)
T+~500ms: coreaudiod fully stabilized
```

The timing varies, and notifications can arrive in different orders on different hardware configurations and macOS versions.

### 2.3 Permission in FineTune

FineTune uses a per-session `permissionConfirmed` flag (not persisted). The flow:

1. On launch, `permissionConfirmed = false`
2. Taps are created with `.unmuted` behavior
3. Fast health checks fire at 300ms, 500ms, 700ms after tap creation
4. `shouldConfirmPermission()` checks: `callbackCount > 10 && outputWritten > 0 && (inputHasData > 0 || lastInputPeak > 0.0001)`
5. When confirmed, `recreateAllTaps()` is called to switch all taps to `.mutedWhenTapped`

**The gap**: Between the permission grant (coreaudiod restart) and the tap recreation completing, the `isRecreatingTaps` flag is supposed to suppress spurious default device change notifications. However, the current implementation has timing issues (see Section 3).

---

## 3. Race Conditions & Pitfalls

### 3.1 Bug 1: Spurious Default Device Change Notification

**Root Cause Analysis:**

When coreaudiod restarts after permission grant, the following race occurs:

1. `handleServiceRestarted()` in `AudioEngine.swift` sets `isRecreatingTaps = true` (line 200)
2. All taps are destroyed synchronously (lines 207-214)
3. A Task is created that waits 1500ms then calls `applyPersistedSettings()` and sets `isRecreatingTaps = false` (lines 217-224)
4. **Meanwhile**, `DeviceVolumeMonitor.handleDefaultDeviceChanged()` fires due to the coreaudiod restart
5. The debounce delay is 300ms (line 47), so this notification is processed at roughly T+500ms
6. When `onDefaultDeviceChangedExternally` fires, `AudioEngine` checks `isRecreatingTaps` (lines 146-149)

**The problem**: There are TWO paths that can trigger the spurious routing:

**Path A -- Service Restart handler**: `handleServiceRestarted()` correctly sets `isRecreatingTaps = true`. The `onDefaultDeviceChangedExternally` callback checks it and suppresses the call. This works.

**Path B -- Permission Confirmation handler**: `recreateAllTaps()` sets `isRecreatingTaps = true` at line 721, but this happens **inside a Task** (line 720). Before the Task runs, the debounced default device change notification at `DeviceVolumeMonitor` may have already fired and be processing. The `isRecreatingTaps` flag won't be set yet because:

- The debounced notification fires on MainActor after 300ms
- `recreateAllTaps()` is called from a health check Task that itself fires at 300ms-700ms after tap creation
- If the health check fires at 300ms and permission is confirmed, `recreateAllTaps()` creates a nested Task on MainActor
- The debounced default device notification may already be in the MainActor queue

**Path C -- Direct `handleDefaultDeviceChanged()` not through service restart**: The `DeviceVolumeMonitor` also listens for `kAudioHardwarePropertyDefaultOutputDevice` independently. During aggregate device teardown in `recreateAllTaps()`, destroying aggregate devices that reference real output devices can cause macOS to fire a default device change notification. Even though the aggregates are private, the act of destroying them can perturb the device graph enough to trigger a notification. The `isRecreatingTaps` flag in `onDefaultDeviceChangedExternally` catches this case IF it is set before the notification processes, but timing is critical.

**Why it shows "MacBook Pro Speakers"**: When the default device notification fires after coreaudiod restart, `readDefaultOutputDevice()` returns the system default (built-in speakers), not the AirPods. This is because coreaudiod may not have fully re-established the Bluetooth device connection yet. The notification handler reads the default device, gets the built-in speakers UID, and calls `routeAllApps(to: speakersUID)`, which overwrites the per-app routing.

### 3.2 Bug 2: Audio Muting During Permission Grant

**Root Cause Analysis:**

There are two distinct muting mechanisms at play:

**Mechanism 1 -- `.unmuted` to `.mutedWhenTapped` transition**: When `recreateAllTaps()` runs:
1. All existing taps (with `.unmuted` behavior) are destroyed via `invalidateAsync()`
2. New taps are created with `.mutedWhenTapped` behavior
3. Between destruction and creation, there is a gap where no tap exists for the process
4. The process's audio was previously going to both the tap AND the hardware (`.unmuted`)
5. When the old tap is destroyed, audio continues to flow to the hardware normally
6. When the new tap is created with `.mutedWhenTapped`, the process's audio is now muted at the hardware
7. But the new tap's aggregate device may not be fully running yet, so the audio that was muted isn't being played back through the tap either

**Mechanism 2 -- coreaudiod restart disruption**: When coreaudiod restarts:
1. All existing audio streams are interrupted
2. Apps like Spotify may detect the stream interruption and pause playback
3. Even after taps are recreated, Spotify remains paused
4. The user must manually pause and play again in Spotify to resume

**Mechanism 3 -- Aggregate device re-creation lag**: The new aggregate device takes time to start its IO proc and begin processing audio. During this lag (potentially 50-500ms depending on device type), audio from the tapped process is muted but not being passed through.

### 3.3 Bug 3: Play/Pause Status Staleness

**Root Cause Analysis:**

The play/pause detection in FineTune relies on:

1. **Audio level thresholds**: `isPausedDisplayApp()` in `AudioEngine.swift` checks if the app's audio level has been below `pausedLevelThreshold` (0.002) for longer than `pausedSilenceGraceInterval` (0.5s)
2. **`lastAudibleAtByPID` tracking**: Updated in `getAudioLevel()` when `level > pausedLevelThreshold`
3. **`kAudioProcessPropertyIsRunning` notifications**: `AudioProcessMonitor` listens for process running state changes
4. **Safety poll**: `AudioProcessMonitor` polls every 400ms for pause/resume transitions that don't reliably trigger listeners (line 118)

**Problems with this approach:**

- **VU-based detection lag**: There is an inherent delay between when the user hits pause in Spotify and when the audio level drops below threshold. The `pausedSilenceGraceInterval` of 0.5s adds to this delay.
- **False "playing" during silence**: Some apps (e.g., Spotify between songs) have brief silence that can trigger false "paused" state
- **Process running state unreliability**: `kAudioProcessPropertyIsRunning` doesn't always fire reliably for media state transitions. The comment on line 115-116 of `AudioProcessMonitor.swift` explicitly acknowledges this: "Safety poll for pause/resume transitions that don't reliably trigger listeners."
- **No media state API**: FineTune does not use the MediaRemote framework to query actual play/pause state. It relies solely on audio level detection, which is inherently unreliable for state transitions.
- **Observation frequency**: `getAudioLevel()` is called from the UI layer when rendering VU meters. If the UI is not actively polling (e.g., popup is closed), the `lastAudibleAtByPID` dictionary is not updated, causing stale state.

---

## 4. Best Practices from Other Projects

### 4.1 BackgroundMusic

[BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic) is an open-source macOS audio utility that provides per-app volume control and system audio recording.

**Architecture**: BackgroundMusic uses a completely different approach from FineTune:
- It installs a **virtual audio driver** (BGMDevice) as a system-wide audio device
- BGMApp sets BGMDevice as the system default output
- All system audio is routed through BGMDevice
- BGMApp reads audio from BGMDevice and forwards it to the real output device
- Per-app volume is applied during the forwarding step

**Device change handling**: BGMApp and BGMDriver communicate via property change notifications and XPC. Their TODO list mentions "Listen for notifications when the output device is removed/disabled and revert to the previous output device" as a planned feature ([Issue #94](https://github.com/kyleneideck/BackgroundMusic/issues/94)).

**Relevance to FineTune**: BackgroundMusic's approach avoids the tap recreation problem entirely because it uses a persistent virtual device. However, it requires a kernel/driver extension, which FineTune intentionally avoids. The key lesson is that any system that modifies the audio routing graph must carefully handle device change notifications to avoid feedback loops.

### 4.2 eqMac

[eqMac](https://github.com/bitgapp/eqMac) provides system-wide audio EQ and per-app volume mixing on macOS.

**Architecture**: eqMac uses a "System Audio loopback/passthrough device driver based on Apple's Null Audio Server Driver Plug-in example" ([eqMac GitHub](https://github.com/bitgapp/eqMac)). The driver captures the system audio stream and sends it to the app through a "secure memory tunnel," allowing processing and routing to the appropriate audio device.

**Key design choice**: Like BackgroundMusic, eqMac runs in User space rather than Kernel space. The driver-based approach provides more control over the audio pipeline but requires a driver extension.

**Relevance to FineTune**: eqMac's per-app volume mixing is similar to FineTune's goal, but achieved via a different mechanism. The driver approach provides continuous audio routing without the need for tap recreation.

### 4.3 AudioCap (insidegui)

[AudioCap](https://github.com/insidegui/AudioCap) is sample code for recording system audio on macOS 14.4+.

**Permission handling**: AudioCap implements permission checking via private TCC framework APIs with a build-time flag to disable this. Without it, permission is requested the first time recording starts. There is no public API to check audio recording permission status ([AudioCap README](https://github.com/insidegui/AudioCap/blob/main/README.md)).

**Aggregate device lifecycle**: AudioCap creates CATapDescription, calls `AudioHardwareCreateProcessTap`, creates aggregate device dictionary with tap UUID in `kAudioAggregateDeviceTapListKey`, and calls `AudioHardwareCreateAggregateDevice`. **No handling for coreaudiod restart or device change notifications is implemented** -- it is a simple recording sample, not a persistent audio routing app.

### 4.4 AudioTee (makeusabrew)

[AudioTee](https://github.com/makeusabrew/audiotee) captures system audio output using Core Audio taps API.

**Key insight**: The tap is the ONLY input into the aggregate device. No real device is added as a sub-device for input -- only the tap. This is different from FineTune, which includes the real output device as a sub-device and the tap as a sub-tap. AudioTee references AudioCap's "clever TCC probing approach" for permission checking ([AudioTee article](https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos)).

**Important note**: AudioTee explicitly states that there is no way to query the `NSAudioCaptureUsageDescription` permission status, and if the user denies the request, "all you will get is silence."

### 4.5 Sudara's Core Audio Tap Example

[Sudara's Gist](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f) provides a minimal example of the Core Audio Tap API.

**Key comment about device changes**: "In a real use of this API I would imagine you wouldn't call this every time... You would probably set up a listener to see when the default device changes." The example does not implement device change listeners.

**Known bug**: "If the default output device has 2 output channels this works as expected. But if you have a device with 4 output channels then the volume of the resulting buffer will be halved." This is relevant to FineTune's multi-channel handling.

### 4.6 SoundSource (Rogue Amoeba)

[SoundSource](https://rogueamoeba.com/soundsource/) is the commercial gold standard for per-app audio control on macOS. It provides per-app volume control, audio routing, and effects processing.

**Key capabilities relevant to FineTune**:
- Per-app volume control with audio unit support
- Individual app routing to different output devices
- Support for all device types including Bluetooth, AirPlay, USB, HDMI

SoundSource is closed-source, so implementation details are not available. However, it historically used a kernel extension (now likely a system extension or driver extension). Its seamless handling of device changes and permission flows suggests a driver-level approach that avoids the tap recreation issues FineTune faces.

---

## 5. Audio Continuity

### 5.1 Why Audio Interruption Happens

During tap recreation (whether from permission grant, coreaudiod restart, or device switch), there are multiple points where audio can be interrupted:

1. **Tap destruction gap**: Between destroying the old tap (which unmutes the process's direct-to-hardware audio) and creating the new tap (which re-mutes it), there is a brief moment where:
   - If old tap was `.unmuted`: audio continues normally during the gap
   - If old tap was `.mutedWhenTapped`: audio unmutes briefly, then re-mutes when new tap takes effect

2. **Aggregate device startup lag**: After `AudioDeviceStart()`, the IO proc doesn't immediately start receiving callbacks. There is hardware/driver initialization time, especially for Bluetooth devices (500ms+).

3. **coreaudiod restart disruption**: When coreaudiod restarts, ALL audio streams are interrupted. Apps like Spotify may detect this as a playback error and pause.

### 5.2 FineTune's Current Mitigation Strategies

**Crossfade switching** (`ProcessTapController.performCrossfadeSwitch()`):
- Creates secondary tap+aggregate BEFORE destroying primary
- Crossfades between them using equal-power curves (cos/sin)
- Handles warmup phase, crossfade phase, and promotion
- Extended warmup for Bluetooth/AirPlay devices (500ms vs 50ms)
- Falls back to destructive switch if crossfade fails

**Destructive switching** (`ProcessTapController.performDestructiveDeviceSwitch()`):
- Forces silence before switch (`_forceSilence = true`)
- Creates new tap+aggregate BEFORE destroying old (create-before-destroy pattern)
- Waits for fade-in via volume ramper after re-enabling

**Service restart handling** (`AudioEngine.handleServiceRestarted()`):
- Sets `isRecreatingTaps = true` to suppress spurious notifications
- Destroys all stale taps
- Waits 1500ms for coreaudiod to stabilize
- Recreates all taps via `applyPersistedSettings()`
- Sets `isRecreatingTaps = false`

### 5.3 Gaps in Current Strategy

1. **No way to prevent Spotify from detecting the interruption**: When coreaudiod restarts, the audio session interruption is visible to all running apps. There is no Core Audio API to suppress this.

2. **`recreateAllTaps()` uses `invalidateAsync()` but not a coordinated transition**: The recreation destroys all taps asynchronously, waits for completion, then creates new ones. There is no create-before-destroy pattern here -- it is destroy-then-create, which creates an audio gap.

3. **The `isRecreatingTaps` flag timing issue**: As analyzed in Section 3.1, the flag may not be set before the debounced default device notification processes.

---

## 6. Now Playing / Play-Pause Tracking

### 6.1 Current Approach in FineTune

FineTune determines play/pause state purely from audio levels:

- `isPausedDisplayApp()` checks if `lastAudibleAtByPID[pid]` is older than `pausedSilenceGraceInterval` (0.5s)
- `getAudioLevel()` updates `lastAudibleAtByPID` when level exceeds `pausedLevelThreshold` (0.002)
- Audio levels come from the `_peakLevel` field written by the IO proc callback

This approach has inherent limitations:
- **Lag**: 0.5s delay before "paused" is shown
- **Silent content**: A silent passage in music is detected as "paused"
- **UI polling dependency**: Level is only read when `getAudioLevel()` is called from the UI

### 6.2 MediaRemote Framework (Private API)

Apple's private `MediaRemote.framework` provides access to the system's "Now Playing" information ([The Apple Wiki](https://theapplewiki.com/wiki/Dev:MediaRemote.framework)).

**Key functions**:
- `MRMediaRemoteGetNowPlayingInfo()` -- returns now playing metadata (title, artist, album, elapsed time, duration)
- `MRMediaRemoteGetNowPlayingApplicationIsPlaying()` -- returns whether the current now-playing app is playing
- `MRMediaRemoteGetNowPlayingApplicationBundleIdentifier()` -- identifies the current now-playing app
- `MRMediaRemoteRegisterForNowPlayingNotifications()` -- registers for notifications

**Available notifications** (from [media-remote library](https://github.com/nohackjustnoobb/media-remote)):
- Now playing info changed
- Playback state changed
- Application became now playing client

**Limitations**:
- **Single-app focus**: MediaRemote tracks the "currently active" media application, not all playing apps simultaneously. If Spotify and YouTube are both playing, only one is the "now playing" client.
- **Private API risk**: Not officially supported; can change between macOS versions
- **macOS 15.4+ entitlement requirement**: Recent macOS versions require `com.apple.mediaremote.set-playback-state` entitlement ([ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter))
- **Playback state is binary**: `is_playing` is `Option<bool>` -- no "buffering" or "seeking" states

### 6.3 kAudioProcessPropertyIsRunning

Core Audio's `kAudioProcessPropertyIsRunning` property indicates whether a process is currently running audio IO. FineTune listens for changes to this property in `AudioProcessMonitor.swift`.

**Limitations** (acknowledged in code comments):
- Does not reliably fire for all pause/resume transitions
- Some apps keep their audio session running even when paused
- Requires a safety poll (400ms interval) as fallback

### 6.4 Hybrid Approaches

A more robust play/pause detection could combine multiple signals:

1. **Audio level monitoring** (current approach) -- detects actual audio output
2. **MediaRemote framework** -- provides authoritative play/pause state for the foreground media app
3. **`kAudioProcessPropertyIsRunning`** -- provides audio session state
4. **Process list monitoring** -- detects app launch/quit

The trade-off is complexity vs. accuracy. MediaRemote provides the most accurate state but only for one app at a time. Audio level monitoring works for all tapped apps but with lag and false positives.

---

## 7. Recommendations

### 7.1 Bug 1 Fix: Permission Button Erroneous Device Display

**Problem**: When the user clicks "Allow," the per-app output device display changes to "MacBook Pro Speakers" even though audio plays through AirPods.

**Root cause**: Spurious `kAudioHardwarePropertyDefaultOutputDevice` notification during coreaudiod restart/tap recreation reads the wrong device (built-in speakers instead of AirPods) and overwrites per-app routing.

**Recommended fix -- Snapshot and Restore approach**:

1. **Snapshot routing state before recreation**: Before `recreateAllTaps()` or `handleServiceRestarted()` runs, capture the current `appDeviceRouting` dictionary.

2. **Set `isRecreatingTaps` SYNCHRONOUSLY before any async work**: The flag must be set on the MainActor BEFORE any Task is created that might yield. In `recreateAllTaps()`:

```swift
// Set BEFORE creating the Task, not inside it
isRecreatingTaps = true
Task { @MainActor in
    // ... teardown and recreate ...
    isRecreatingTaps = false
}
```

However, this alone is not sufficient because `recreateAllTaps()` is called from within a fast health check Task that is already on MainActor. The fix needs to be:

```swift
private func recreateAllTaps() {
    isRecreatingTaps = true  // Set IMMEDIATELY, not inside nested Task
    Task { @MainActor in
        await withTaskGroup(of: Void.self) { group in
            // ... existing destruction code ...
        }
        taps.removeAll()
        appliedPIDs.removeAll()
        lastHealthSnapshots.removeAll()
        applyPersistedSettings()
        isRecreatingTaps = false
    }
}
```

Wait -- looking at the current code, `isRecreatingTaps = true` IS already set inside the Task at line 721. The issue is that `recreateAllTaps()` is called from another Task (the health check). When the health check confirms permission at line 687 and calls `recreateAllTaps()`, the nested Task inside `recreateAllTaps()` doesn't run immediately -- it is scheduled for the next MainActor turn. Meanwhile, the debounced default device notification (also on MainActor) may already be queued.

**Fix**: Move `isRecreatingTaps = true` out of the Task:

```swift
private func recreateAllTaps() {
    isRecreatingTaps = true  // <-- Move this OUTSIDE the Task
    Task { @MainActor in
        await withTaskGroup(of: Void.self) { ... }
        // ... rest of recreation ...
        isRecreatingTaps = false
    }
}
```

This ensures the flag is set synchronously in the same MainActor turn as the permission confirmation, before any queued debounce tasks can run.

3. **Validate device UID before routing**: In `onDefaultDeviceChangedExternally`, add validation that the device UID actually represents a device change (not just a coreaudiod restart artifact):

```swift
deviceVolumeMonitor.onDefaultDeviceChangedExternally = { [weak self] deviceUID in
    guard let self else { return }
    if self.isRecreatingTaps {
        self.logger.info("Ignoring default device change during tap recreation")
        return
    }
    // Additional guard: if all apps are already routed to this device, skip
    let anyAppOnDifferentDevice = self.appDeviceRouting.values.contains { $0 != deviceUID }
    guard anyAppOnDifferentDevice else { return }
    self.routeAllApps(to: deviceUID)
}
```

4. **Extend the suppression window**: Add a timestamp-based suppression in addition to the boolean flag:

```swift
private var lastRecreationTimestamp: TimeInterval = 0
private let recreationSuppressionWindow: TimeInterval = 2.0  // seconds

// In onDefaultDeviceChangedExternally callback:
let timeSinceRecreation = Date().timeIntervalSince1970 - lastRecreationTimestamp
if isRecreatingTaps || timeSinceRecreation < recreationSuppressionWindow {
    logger.info("Suppressing default device change (recreation window)")
    return
}
```

### 7.2 Bug 2 Fix: Permission Button Mutes Audio

**Problem**: When clicking "Allow," audio gets muted and the user must pause/play in Spotify.

**Root cause**: coreaudiod restart interrupts all audio streams. The `.unmuted` -> `.mutedWhenTapped` transition creates a gap where audio is muted but not yet being passed through the new tap.

**Recommended fixes**:

1. **Delay the `.mutedWhenTapped` transition**: Instead of recreating all taps immediately upon permission confirmation, delay the transition until the next natural event (e.g., next device switch, next app launch):

```swift
if needsPermissionConfirmation && Self.shouldConfirmPermission(from: d) {
    self.permissionConfirmed = true
    self.logger.info("[PERMISSION] Permission confirmed -- taps will use .mutedWhenTapped for future taps")
    // DON'T recreate existing taps -- they work fine with .unmuted
    // New taps created from here on will use .mutedWhenTapped
    return
}
```

**Trade-off**: With `.unmuted`, the user hears audio through both the tap (processed) and directly (unprocessed). This means per-app volume control is "additive" rather than "replacement" -- lowering the volume in FineTune doesn't fully mute the app because the direct audio path remains. However, this avoids the muting bug entirely.

2. **Create-before-destroy recreation**: If taps must be recreated immediately, use a create-before-destroy pattern (similar to the crossfade device switch approach):

```swift
private func recreateAllTaps() {
    isRecreatingTaps = true

    // Step 1: Create all NEW taps (with .mutedWhenTapped)
    // At this point, both old (.unmuted) and new (.mutedWhenTapped) taps exist
    // The process audio is being captured by both taps
    var newTaps: [pid_t: ProcessTapController] = [:]
    for (pid, _) in taps {
        if let app = apps.first(where: { $0.id == pid }),
           let deviceUID = appDeviceRouting[pid] {
            let newTap = ProcessTapController(app: app, targetDeviceUID: deviceUID, ...)
            newTap.volume = volumeState.getVolume(for: pid)
            try? newTap.activate()
            newTaps[pid] = newTap
        }
    }

    // Step 2: Destroy old taps
    for (_, oldTap) in taps {
        oldTap.invalidate()
    }

    // Step 3: Promote new taps
    taps = newTaps
    isRecreatingTaps = false
}
```

3. **Handle the coreaudiod restart case separately**: When the service restart handler fires, the audio is already interrupted by coreaudiod. The user will likely need to pause/play anyway. Focus the fix on the permission confirmation path, which is more controllable.

### 7.3 Bug 3 Fix: Play/Pause Status Not Staying Updated

**Problem**: The play/pause indicator doesn't reliably stay updated.

**Recommended fixes**:

1. **Add MediaRemote integration for the active now-playing app**: Use the private MediaRemote framework to get authoritative play/pause state for the current media app:

```swift
import Foundation

// Dynamic loading of MediaRemote framework
class MediaRemoteMonitor {
    typealias MRNowPlayingInfoCallback = @convention(c) (CFDictionary?) -> Void
    typealias MRRegisterFunc = @convention(c) (DispatchQueue) -> Void
    typealias MRGetInfoFunc = @convention(c) (DispatchQueue, @escaping MRNowPlayingInfoCallback) -> Void

    private var registerFunc: MRRegisterFunc?
    private var getInfoFunc: MRGetInfoFunc?

    func start() {
        guard let bundle = CFBundleCreate(nil,
            "/System/Library/PrivateFrameworks/MediaRemote.framework" as CFString) else { return }
        // Load functions...
        registerFunc?(DispatchQueue.main)
    }
}
```

This provides instant play/pause state changes for the foreground media app, supplementing the audio-level-based detection for background apps.

2. **Reduce silence grace interval for better responsiveness**: Consider reducing `pausedSilenceGraceInterval` from 0.5s to 0.25s. This trades off more "flickering" for faster state updates.

3. **Decouple VU polling from UI visibility**: Ensure that `getAudioLevel()` is called periodically even when the popup is not visible, so that `lastAudibleAtByPID` stays current. Add a lightweight polling timer:

```swift
// In AudioEngine init, after taps are created:
Task { @MainActor [weak self] in
    while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard let self else { return }
        // Touch audio levels for all tapped apps to keep lastAudibleAtByPID current
        for (pid, tap) in self.taps {
            let level = tap.audioLevel
            if level > self.pausedLevelThreshold {
                self.lastAudibleAtByPID[pid] = Date()
            }
        }
    }
}
```

4. **Use hysteresis for state transitions**: Instead of a simple threshold, use separate thresholds for transitioning to "playing" and "paused":

```swift
// Playing -> Paused: level < 0.001 for 0.4s (strict, avoids false paused)
// Paused -> Playing: level > 0.005 for 0.05s (loose, fast response)
```

This avoids the "flickering" problem where brief silence during playback causes a momentary "paused" state.

### 7.4 Architecture Recommendations

1. **Event-driven rather than flag-based suppression**: Instead of using `isRecreatingTaps` as a boolean flag, use a state machine with clear transitions:

```swift
enum AudioEngineState {
    case running
    case recreatingTaps(savedRouting: [pid_t: String])
    case handlingServiceRestart(savedRouting: [pid_t: String])
}
```

This makes the suppression logic explicit and allows restoring the exact routing state after recreation.

2. **Centralized notification debouncing**: Consider using a single debounce timer for all coreaudiod-related notifications (device list change, default device change, service restart) to avoid processing intermediate states during the coreaudiod restart sequence.

3. **Saved routing as source of truth**: During any recreation event, save the `appDeviceRouting` dictionary BEFORE destruction and restore it AFTER recreation, rather than relying on persisted settings (which may have been overwritten by the spurious notification).

---

## Sources

### Apple Documentation
- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))
- [AudioHardwareAggregateDevice](https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice)
- [CATapMuteBehavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)
- [kAudioHardwarePropertyDefaultOutputDevice](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydefaultoutputdevice)

### Open Source Projects
- [BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic) -- macOS per-app volume control using virtual audio driver
- [eqMac](https://github.com/bitgapp/eqMac) -- macOS system-wide audio EQ using null audio server driver
- [AudioCap](https://github.com/insidegui/AudioCap) -- Sample code for recording system audio on macOS 14.4+
- [AudioTee](https://github.com/makeusabrew/audiotee) -- System audio capture using Core Audio taps
- [Sudara's Core Audio Tap example](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f) -- Minimal tap API example
- [SoundSource](https://rogueamoeba.com/soundsource/) -- Commercial per-app audio control (Rogue Amoeba)

### MediaRemote Framework
- [media-remote library](https://github.com/nohackjustnoobb/media-remote) -- Rust bindings for MediaRemote.framework
- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) -- Functional MediaRemote access for macOS 15.4+
- [Dev:MediaRemote.framework - The Apple Wiki](https://theapplewiki.com/wiki/Dev:MediaRemote.framework) -- API documentation

### Developer Resources
- [CoreAudio Taps for Dummies](https://www.maven.de/2025/04/coreaudio-taps-for-dummies/) -- Practical guide to tap API
- [AudioTee article](https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos) -- System audio capture walkthrough
- [Apple Developer Forums - Core Audio](https://developer.apple.com/forums/tags/core-audio)

---

## FineTune Codebase Files Referenced

- `/FineTune/Audio/AudioEngine.swift` -- Central audio engine managing taps, routing, and permissions
- `/FineTune/Audio/DeviceVolumeMonitor.swift` -- Monitors device volumes and default device changes
- `/FineTune/Audio/ProcessTapController.swift` -- Manages individual process taps with crossfade
- `/FineTune/Audio/AudioDeviceMonitor.swift` -- Monitors audio device list and service restarts
- `/FineTune/Audio/AudioProcessMonitor.swift` -- Monitors audio processes and their running state
- `/FineTune/Audio/Tap/TapResources.swift` -- Encapsulates Core Audio tap and aggregate resources
- `/FineTune/Audio/Crossfade/CrossfadeState.swift` -- RT-safe crossfade state machine
- `/FineTune/Audio/Tap/TapDiagnostics.swift` -- Diagnostic counters from audio callbacks
- `/FineTune/Audio/Extensions/AudioObjectID+Listener.swift` -- Property listener helpers
- `/FineTune/Audio/Extensions/AudioObjectID+System.swift` -- System-level device queries
