# Agent 3 -- The Perfectionist: Exhaustive Analysis

## 1. Code Path Traces

### Bug 1: Permission Button Erroneous Device Display

**Scenario:** AirPods are the current output device. User clicks "Allow" on the system audio permission dialog. The per-app device picker under "APPS" shows "MacBook Pro Speakers" instead of "AirPods."

**Exact sequence of events:**

1. **User clicks "Allow"** on the macOS system audio recording permission dialog.

2. **macOS restarts coreaudiod.** Granting (or revoking) TCC permissions for audio recording triggers a coreaudiod service restart. All AudioObjectIDs become invalid.

3. **Two independent listeners fire** for `kAudioHardwarePropertyServiceRestarted`:
   - `AudioDeviceMonitor.handleServiceRestartedAsync()` (line 180)
   - `DeviceVolumeMonitor.handleServiceRestarted()` (line 493)

4. **AudioDeviceMonitor path:**
   - Reads the device list on a background thread (line 190)
   - Updates `outputDevices`, `devicesByUID`, `devicesByID` on MainActor
   - Calls `onServiceRestarted?()` (line 207), which invokes `AudioEngine.handleServiceRestarted()`

5. **AudioEngine.handleServiceRestarted()** (line 197):
   - Sets `isRecreatingTaps = true` (line 200)
   - Cancels all in-flight switches
   - Calls `tap.invalidate()` on all taps (destroying aggregate devices)
   - Clears `taps`, `appliedPIDs`, `lastHealthSnapshots`
   - Spawns a Task that waits 1500ms, then calls `applyPersistedSettings()`, then sets `isRecreatingTaps = false` (line 223)

6. **CRITICAL: Destroying aggregate devices changes the macOS default output device.** When FineTune's private aggregate device (which wraps, say, AirPods) is destroyed, macOS may temporarily change the system default output device. This fires a `kAudioHardwarePropertyDefaultOutputDevice` change notification.

7. **DeviceVolumeMonitor** receives this default device change notification via its listener block (line 123). The listener has a 300ms debounce (`defaultDeviceDebounceMs`).

8. **After the 300ms debounce**, `handleDefaultDeviceChanged()` runs (line 309). It checks:
   - `isSettingDefaultDevice` -- false (we didn't initiate this change)
   - `lastSelfChangeTimestamp` -- stale (not within 1 second)
   - So it proceeds to read the new default device on a background thread.

9. **The new default device may be "MacBook Pro Speakers"** because when the aggregate device wrapping AirPods was destroyed, macOS fell back to the built-in speakers as the default.

10. **`applyDefaultDeviceChange`** fires (line 344), updates `defaultDeviceID` and `defaultDeviceUID`, then calls `onDefaultDeviceChangedExternally?(uid)`.

11. **This callback reaches AudioEngine** (line 144). **HERE IS THE RACE:** The check `if self.isRecreatingTaps` (line 146) should block this, BUT:

**THE TIMING PROBLEM:**

```
T=0ms:     handleServiceRestarted() fires
           isRecreatingTaps = true
           Aggregate devices destroyed (tap.invalidate())

T=0ms:     Default device change notification fires (async, debounced)

T=300ms:   Debounce fires -> handleDefaultDeviceChanged()
           Reads new default device on background thread

T=300-500ms: Background read completes, but may be delayed for BT devices
             If BT device: adds 500ms delay (line 330-331)

T=800ms+:  applyDefaultDeviceChange() runs on MainActor
           Calls onDefaultDeviceChangedExternally

T=1500ms:  handleServiceRestarted's Task fires
           Calls applyPersistedSettings()
           Sets isRecreatingTaps = false
```

**The race condition:** If the debounced default device change completes its background work AND dispatches to MainActor BEFORE the 1500ms stabilization delay, the `isRecreatingTaps` flag correctly blocks it. But there are two problems:

**Problem A -- Bluetooth timing inversion:** For Bluetooth devices (AirPods), `handleDefaultDeviceChanged` adds an extra 500ms `bluetoothInitDelayMs` (line 330). This means:
- With BT delay: applyDefaultDeviceChange arrives at ~800ms, still within 1500ms window. **Flag blocks it. This works.**
- Without BT delay (speakers): applyDefaultDeviceChange arrives at ~350ms. **Flag blocks it. This works too.**

**Problem B -- The REAL gap: `applyPersistedSettings()` itself can route to the wrong device.** Look at lines 580-596:

```swift
let defaultUID = try defaultOutputDeviceUIDProvider()
if deviceMonitor.device(for: defaultUID) != nil {
    deviceUID = defaultUID
}
```

When `applyPersistedSettings()` runs at T=1500ms, the macOS default output device has ALREADY been changed to "MacBook Pro Speakers" (because the aggregate destruction at T=0ms caused macOS to fall back). The `defaultOutputDeviceUIDProvider` reads the CURRENT default, which is now speakers.

For apps with a saved device routing to AirPods, line 576 catches it:
```swift
if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
   deviceMonitor.device(for: savedDeviceUID) != nil {
    deviceUID = savedDeviceUID
```
**This correctly uses the saved routing.** So the bug is NOT in saved-routing apps.

**BUT** the bug could manifest if:
- The saved routing references a stale UID that no longer matches after coreaudiod restart (AirPods sometimes get new UIDs after reconnection, though rare)
- OR the AirPods device hasn't re-appeared in the device list yet when `applyPersistedSettings()` runs (the 1500ms may not be enough)

**Problem C -- Multiple notifications:** The aggregate device destruction at T=0 may fire MULTIPLE `kAudioHardwarePropertyDefaultOutputDevice` notifications (one per destroyed aggregate). Each gets debounced, but the debounce keeps resetting and only the LAST one fires. If the last notification's default device is speakers, the `defaultDeviceUID` property on `DeviceVolumeMonitor` gets set to the speakers UID. Even though `isRecreatingTaps` blocks the routing call, **the UI still reads this stale value**.

**THE SMOKING GUN for Bug 1:**

Look at `MenuBarPopupView.swift` line 142-146:
```swift
let deviceUID = audioEngine.resolvedDeviceUIDForDisplay(
    app: app,
    availableDevices: audioEngine.outputDevices,
    defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID  // <-- THIS
)
```

And `resolvedDeviceUIDForDisplay` at AudioEngine.swift line 356-368:
```swift
func resolvedDeviceUIDForDisplay(...) -> String {
    if let routedUID = appDeviceRouting[app.id], ... {
        return routedUID  // Priority 1: explicit routing
    }
    if let defaultDeviceUID, ... {
        return defaultDeviceUID  // Priority 2: system default
    }
    return availableDevices.first?.uid ?? ""  // Priority 3: first device
}
```

**During the recreation window (T=0ms to T=1500ms):**
- `appDeviceRouting` has been cleared (taps.removeAll + appliedPIDs.removeAll means applyPersistedSettings hasn't repopulated it yet)
- `deviceVolumeMonitor.defaultDeviceUID` has been updated to "MacBook Pro Speakers" (by the debounced notification)
- So `resolvedDeviceUIDForDisplay` falls through to Priority 2 and shows "MacBook Pro Speakers"

**After T=1500ms:**
- `applyPersistedSettings()` runs and repopulates `appDeviceRouting` with the saved AirPods UID
- The UI should update to show AirPods
- BUT `deviceVolumeMonitor.defaultDeviceUID` is STILL "MacBook Pro Speakers" unless someone explicitly changes it back

**Conclusion for Bug 1:** The `isRecreatingTaps` flag correctly prevents `routeAllApps` from executing. But it does NOT prevent `defaultDeviceUID` from being updated on `DeviceVolumeMonitor`. The UI reads `defaultDeviceUID` as a fallback, and during the recreation window when `appDeviceRouting` is empty, it shows the wrong device. Even after recreation completes and `appDeviceRouting` is repopulated, if the routing IS correctly restored, the picker should update. The question is whether it does.

---

### Bug 2: Permission Button Mutes Audio

**Exact sequence:**

1. **Before permission is granted:** Taps are created with `muteOriginal = false` (`.unmuted`). Audio flows normally -- both the original app audio AND the tapped audio play simultaneously (double audio, but acceptable for permission flow).

2. **User clicks "Allow."** coreaudiod restarts.

3. **All existing taps are destroyed** in `handleServiceRestarted()` (line 207, `tap.invalidate()`).

4. **Audio stops completely** because:
   - The process taps are destroyed (no more tapped audio)
   - The aggregate devices are destroyed (the output path for tapped audio is gone)
   - The app (e.g., Spotify) was using `.unmuted` taps, so its original audio WAS still flowing through the normal system output
   - BUT coreaudiod restarting disrupts ALL audio streams, not just FineTune's

5. **After 1500ms delay**, `applyPersistedSettings()` recreates taps. But now `permissionConfirmed` is still `false` (it only gets set to `true` in the fast health check at line 685, which requires `shouldConfirmPermission` to pass). So new taps are created with `.unmuted` again.

6. **The fast health check** (lines 672-704) fires at 300ms, 500ms, 700ms after tap creation. If at any of these checkpoints `shouldConfirmPermission` returns true (callbackCount > 10, outputWritten > 0, inputHasData > 0), then `permissionConfirmed = true` and `recreateAllTaps()` is called.

7. **`recreateAllTaps()`** (line 719) destroys ALL taps again (async), clears appliedPIDs, then calls `applyPersistedSettings()` which creates new taps with `muteOriginal = true` (`.mutedWhenTapped`).

8. **With `.mutedWhenTapped`**, the original app audio is muted by CoreAudio. The ONLY audio path is through FineTune's aggregate device.

**THE MUTING ROOT CAUSE:**

The problem is step 4. When coreaudiod restarts:
- The audio framework resets. Apps like Spotify need to re-establish their audio sessions.
- FineTune destroys its taps (which were `.unmuted`, so the app was playing audio normally)
- After 1500ms, FineTune recreates taps, but the app may have already "paused" its audio output because the audio session was disrupted
- When taps are recreated with `.unmuted`, audio flows, and then when they're recreated AGAIN with `.mutedWhenTapped` (after permission confirmation), the original audio gets muted
- BUT Spotify's audio session may have been disrupted by the coreaudiod restart, and it doesn't automatically resume

**Evidence for this theory:** The user reports that they must "pause/play in Spotify to restore audio." This is consistent with Spotify's audio session being disrupted by the coreaudiod restart and needing a manual nudge to restart.

**Additional muting vector:** There is a double-recreation happening:
1. First recreation: `handleServiceRestarted()` -> 1500ms delay -> `applyPersistedSettings()` (taps with `.unmuted`)
2. Second recreation: Fast health check fires -> `permissionConfirmed = true` -> `recreateAllTaps()` (taps with `.mutedWhenTapped`)

This double-recreation means taps are destroyed and recreated TWICE in quick succession. Each destruction creates a brief audio gap. The second recreation switches to `.mutedWhenTapped`, which silences the app's original audio. If Spotify's audio session was already disrupted by the coreaudiod restart, the tap's output is the only audio path, and it needs Spotify to actually be producing audio for it to work.

---

### Bug 3: Playing/Paused Status Not Staying Updated

**How play/pause is determined:**

1. `AudioProcessMonitor` (line 141-187) queries `kAudioHardwarePropertyProcessObjectList` and checks `kAudioProcessPropertyIsRunning` for each process.

2. An app appears in `activeApps` when `objectID.readProcessIsRunning()` returns `true` (line 150).

3. The `isPausedDisplayApp` function (AudioEngine.swift line 323-332) determines pause state:
   ```swift
   func isPausedDisplayApp(_ app: AudioApp) -> Bool {
       if apps.isEmpty && lastDisplayedApp?.id == app.id {
           return true  // Last cached app shown as paused
       }
       guard apps.contains(where: { $0.id == app.id }) else { return false }
       let isPauseEligible = taps[app.id] != nil || (pauseEligiblePIDsForTests?.contains(app.id) ?? false)
       guard isPauseEligible else { return false }
       let lastAudibleAt = lastAudibleAtByPID[app.id] ?? .distantPast
       return Date().timeIntervalSince(lastAudibleAt) >= pausedSilenceGraceInterval
   }
   ```

4. `lastAudibleAtByPID` is updated in `getAudioLevel` (line 348-349):
   ```swift
   if level > pausedLevelThreshold {
       lastAudibleAtByPID[app.id] = Date()
   }
   ```

5. `getAudioLevel` is polled by `AppRowWithLevelPolling` (line 329-343) using a Task that calls `getAudioLevel()` every `DesignTokens.Timing.vuMeterUpdateInterval` seconds.

6. But critically, VU meter polling **only runs when the popup is visible AND the app is not paused** (line 302):
   ```swift
   .onAppear {
       if isPopupVisible && !isPaused {
           startLevelPolling()
       } else {
           displayLevel = 0
       }
   }
   ```

**The polling dependency chain:**

```
VU meter polls getAudioLevel()
  -> getAudioLevel reads taps[app.id]?.audioLevel
  -> audioLevel reads _peakLevel from ProcessTapController
  -> _peakLevel is written by processAudio callback on audio thread
  -> If level > 0.002, updates lastAudibleAtByPID[app.id] = Date()

isPausedDisplayApp checks:
  -> Date() - lastAudibleAtByPID[app.id] >= 0.5 seconds
```

**Problems with this approach:**

**Problem A -- Chicken-and-egg with paused state:** When `isPaused` is true, level polling stops (line 319-326). But `isPaused` depends on `lastAudibleAtByPID` which depends on level polling. Once an app enters paused state, there is no mechanism to detect that it started playing again EXCEPT for:
- `AudioProcessMonitor.refreshAsync()` polling every 400ms (line 118-119)
- If the process disappears from `kAudioHardwarePropertyProcessObjectList` and then reappears, `onAppsChanged` fires

**Problem B -- `kAudioProcessPropertyIsRunning` is not a play/pause indicator.** It indicates whether the process has active audio I/O (an audio session running), NOT whether audio is actively being output. Many apps keep their audio session running even when paused.

**Problem C -- During tap recreation, callbacks stop.** When taps are destroyed in `handleServiceRestarted()` or `recreateAllTaps()`, the `processAudio` callback stops running, so `_peakLevel` decays toward 0. `getAudioLevel()` returns 0, so `lastAudibleAtByPID` is not updated. After 0.5 seconds of silence, `isPausedDisplayApp` returns true. This is a FALSE pause detection caused by the tap destruction.

**Problem D -- `AudioProcessMonitor` polls every 400ms.** This is the safety net for catching play/resume transitions. When a process starts playing audio, it may take up to 400ms before `refreshAsync()` detects the new audio object. Then `onAppsChanged` fires, which calls `applyPersistedSettings()` to create a tap. Then audio starts flowing. Then VU meter polling detects audio level. But the UI may show "Paused" during this entire startup sequence.

**Problem E -- The 400ms polling in `AudioProcessMonitor` fires `refreshAsync()` which calls `onAppsChanged`, which calls `cleanupStaleTaps()` AND `applyPersistedSettings()`. The `applyPersistedSettings` has a guard `guard !appliedPIDs.contains(app.id)` (line 567), so once a PID is applied, it won't be re-applied. If the tap was destroyed (e.g., during recreation) but the PID is still in `appliedPIDs`, no new tap will be created through this path.

Wait -- actually, `handleServiceRestarted` clears `appliedPIDs` (line 213), and `recreateAllTaps` also clears `appliedPIDs` (line 730). So this guard is not the issue for the recreation case.

But for normal pause/resume transitions: if the app pauses (stops its audio session), the process disappears from `kAudioHardwarePropertyProcessObjectList`. `cleanupStaleTaps()` fires, and after the 1-second grace period, the tap is destroyed and `appliedPIDs.remove(pid)` is called (well, actually `appliedPIDs` is intersected with `pidsToKeep` on line 841). When the app resumes, it reappears in the process list, `onAppsChanged` fires, `applyPersistedSettings` is called, and since the PID is no longer in `appliedPIDs`, a new tap is created.

The delay here is: 400ms poll + 1000ms grace period cleanup + tap creation time. So there could be up to ~1.5 seconds of stale "Paused" state before the UI updates. But the user complaint is that it "doesn't reliably reflect the actual state," which suggests it's worse than this.

---

## 2. The `isRecreatingTaps` Fix -- Timing Analysis

### Where the flag is set and cleared:

**In `handleServiceRestarted()` (lines 197-225):**
```
T=0:     isRecreatingTaps = true       (synchronous, line 200)
T=0:     tap.invalidate() for all taps (synchronous loop)
T=0:     taps.removeAll()              (synchronous)
T=0:     appliedPIDs.removeAll()       (synchronous)
T=0:     Task spawned with 1500ms delay
T=1500:  applyPersistedSettings()      (in the Task)
T=1500+: isRecreatingTaps = false      (in the Task, line 223)
```

**In `recreateAllTaps()` (lines 719-735):**
```
T=0:     Task spawned (runs on MainActor)
T=0+:    isRecreatingTaps = true       (inside Task, line 721)
T=0+:    await withTaskGroup: destroy all taps async
T=?:     All taps destroyed            (awaited)
T=?:     taps.removeAll()
T=?:     appliedPIDs.removeAll()
T=?:     applyPersistedSettings()
T=?:     isRecreatingTaps = false      (line 733)
```

### Timing concerns:

**Concern 1: The flag is set inside a Task in `recreateAllTaps`.**

```swift
private func recreateAllTaps() {
    Task { @MainActor in
        isRecreatingTaps = true  // <-- Not set until Task starts executing
        ...
    }
}
```

Since `recreateAllTaps()` is called from within a fast health check Task (line 687), the `isRecreatingTaps = true` assignment happens asynchronously. Between the call to `recreateAllTaps()` at line 687 and the Task body starting execution, there is a brief window where `isRecreatingTaps` is still `false`. If a default device change notification fires in this window, `routeAllApps` will execute.

**However**, in `handleServiceRestarted()`, the flag IS set synchronously before any async work. So the service restart path is properly guarded.

**Concern 2: The 1500ms delay in `handleServiceRestarted` may be insufficient.**

After coreaudiod restarts:
- Device list changes fire
- Default device may change
- Bluetooth devices may take 2-3 seconds to re-establish connections

If AirPods take >1500ms to appear in the device list after coreaudiod restart, then `applyPersistedSettings()` at T=1500ms won't find the saved device UID in `deviceMonitor.device(for: savedDeviceUID)` and will fall through to using the system default (speakers).

**Concern 3: The flag does NOT protect `DeviceVolumeMonitor.defaultDeviceUID` from being updated.**

The `isRecreatingTaps` flag only guards the `routeAllApps` call inside the `onDefaultDeviceChangedExternally` callback. But `DeviceVolumeMonitor.applyDefaultDeviceChange()` unconditionally updates `defaultDeviceID` and `defaultDeviceUID` (lines 357-358) BEFORE calling the callback. So even when the callback is suppressed, the stale value is stored. The UI reads this stale value.

**Concern 4: Double notification paths for service restart.**

Both `AudioDeviceMonitor` and `DeviceVolumeMonitor` listen for `kAudioHardwarePropertyServiceRestarted`. Their handlers run independently:
- `AudioDeviceMonitor.handleServiceRestartedAsync()` -> refreshes device list -> calls `onServiceRestarted?()` -> triggers `AudioEngine.handleServiceRestarted()`
- `DeviceVolumeMonitor.handleServiceRestarted()` -> re-reads default device and all volumes

There is no ordering guarantee. `DeviceVolumeMonitor` might read the default device AFTER aggregate destruction (getting speakers) or BEFORE (getting the aggregate device, which is then invalid). The result is unpredictable.

---

## 3. Bug 1 Root Cause Analysis -- Every Contributor

### Primary root cause (HIGH confidence):
**`DeviceVolumeMonitor.defaultDeviceUID` is updated to the wrong device during tap destruction, and the UI reads it as a fallback.**

- When aggregate devices are destroyed in `handleServiceRestarted()`, macOS changes the default output device to speakers.
- `DeviceVolumeMonitor` detects this change (after 300ms debounce) and updates `defaultDeviceUID` to speakers.
- `isRecreatingTaps` suppresses `routeAllApps` but does NOT suppress the `defaultDeviceUID` update.
- During the recreation window (0-1500ms), `appDeviceRouting` is empty (cleared at line 212-213).
- `resolvedDeviceUIDForDisplay` falls through to the `defaultDeviceUID` fallback, showing speakers.

### Contributing factor 1 (MEDIUM confidence):
**After recreation, `appDeviceRouting` IS repopulated from saved settings.** If the saved routing correctly points to AirPods and AirPods are available, the picker should update. The fact that the user reports seeing "MacBook Pro Speakers" suggests either:
- The UI doesn't immediately re-render after `appDeviceRouting` is updated (SwiftUI observation latency)
- OR `defaultDeviceUID` was never corrected back to AirPods

### Contributing factor 2 (MEDIUM confidence):
**`DeviceVolumeMonitor.defaultDeviceUID` may remain stale permanently.** After the bogus default-device-change notification sets `defaultDeviceUID` to speakers, who restores it? Only another default device change notification. If the user had AirPods as the macOS default, and the aggregate destruction temporarily changed it to speakers, macOS might not automatically switch back to AirPods. The user's macOS default would genuinely be speakers now, which means `defaultDeviceUID` is technically correct -- the macOS default IS speakers. But FineTune's per-app routing should override this. The question is whether `appDeviceRouting` was successfully repopulated.

### Contributing factor 3 (LOW confidence):
**Race between `AudioDeviceMonitor.handleServiceRestartedAsync()` and the debounced default device change.** The device list refresh happens on a background thread and may complete before or after the default device change is processed. If the device list refreshes AFTER the aggregate is destroyed, AirPods appear normally. If it refreshes BEFORE, the stale aggregate device might cause confusion.

---

## 4. Bug 2 Root Cause Analysis -- Every Contributor

### Primary root cause (HIGH confidence):
**coreaudiod restart disrupts the app's audio session, and FineTune's tap recreation doesn't restart it.**

When coreaudiod restarts:
1. All active audio streams are torn down by the system
2. Apps like Spotify lose their Core Audio connections
3. Well-behaved apps (Safari, Music) may auto-reconnect
4. Some apps (Spotify) require user interaction to restart their audio session

FineTune has no control over this. The tap recreation is a red herring -- the issue is the coreaudiod restart itself.

### Contributing factor 1 (HIGH confidence):
**Double tap recreation amplifies the disruption.**

After coreaudiod restart:
1. `handleServiceRestarted()`: destroys all taps, waits 1500ms, recreates with `.unmuted`
2. Fast health check (300-700ms later): confirms permission, calls `recreateAllTaps()`, destroys all taps AGAIN, recreates with `.mutedWhenTapped`

The second destruction + recreation creates another audio disruption. If Spotify had managed to auto-reconnect its audio session after the first recreation, the second destruction could disrupt it again.

### Contributing factor 2 (MEDIUM confidence):
**`.mutedWhenTapped` silences the original audio.** After the second recreation, the original app audio is muted by CoreAudio's process tap mechanism. Audio only flows through FineTune's aggregate device. If the app (Spotify) isn't actively producing audio (because its session was disrupted), there is nothing for FineTune to route, and silence results.

### Contributing factor 3 (LOW confidence):
**The 1500ms `serviceRestartDelay` may not be enough for some apps.** If Spotify takes longer than 1500ms to re-establish its audio session after coreaudiod restart, the tap creation at T=1500ms might succeed but find no audio to tap.

### What `.mutedWhenTapped` actually does:
Looking at `CATapDescription.muteBehavior`:
- `.unmuted`: The process's original audio still plays through the system default output. The tap gets a copy.
- `.mutedWhenTapped`: The process's original audio is silenced. Audio ONLY flows through the tap/aggregate.

After permission confirmation, switching to `.mutedWhenTapped` is essential for per-app volume control. But during this transition, if the app isn't producing audio (session disrupted), there is no audio to tap, resulting in silence.

---

## 5. Bug 3 Root Cause Analysis -- Every Contributor

### Primary root cause (HIGH confidence):
**VU meter polling stops when `isPaused` is true, creating a sticky paused state.**

In `AppRowWithLevelPolling` (line 319-326):
```swift
.onChange(of: isPaused) { _, paused in
    if paused {
        stopLevelPolling()
        displayLevel = 0
    } else if isPopupVisible {
        startLevelPolling()
    }
}
```

Once the app shows as "Paused", level polling stops. The only way to leave paused state is:
1. The process disappears from `kAudioHardwarePropertyProcessObjectList` (stops audio session entirely)
2. Then reappears (restarts audio session)
3. This triggers `onAppsChanged` -> `applyPersistedSettings` -> new tap
4. `lastAudibleAtByPID` gets initialized to `Date()` in `updateDisplayedAppsState` (line 864-866)
5. `isPausedDisplayApp` returns false (because less than 0.5s since `lastAudibleAt`)

But if the app resumes audio WITHOUT its process leaving and re-entering the `kAudioHardwarePropertyProcessObjectList` (e.g., it was always in the list but just paused its audio output), then:
- No `onAppsChanged` fires
- `lastAudibleAtByPID` is not refreshed
- Level polling is stopped
- The app stays shown as "Paused" indefinitely

### Contributing factor 1 (MEDIUM confidence):
**`AudioProcessMonitor` polls every 400ms, but `kAudioProcessPropertyIsRunning` is unreliable for play/pause.**

This property indicates whether the process has active I/O, not whether audio is actually being produced. Some apps keep their audio session active even when paused. This means:
- Process stays in `activeApps` even when paused (correct for showing the row)
- But there's no removal/re-addition event to trigger the `lastAudibleAtByPID` reset
- The pause detection relies entirely on VU meter polling, which stops when paused

### Contributing factor 2 (HIGH confidence):
**The `isPausedDisplayApp` function does not have a recovery mechanism.**

Look at the logic:
```swift
let isPauseEligible = taps[app.id] != nil || ...
guard isPauseEligible else { return false }
let lastAudibleAt = lastAudibleAtByPID[app.id] ?? .distantPast
return Date().timeIntervalSince(lastAudibleAt) >= pausedSilenceGraceInterval
```

If the tap exists and `lastAudibleAt` is stale, this returns true (paused). It will NEVER return false unless:
- The tap is removed (cleanup)
- `lastAudibleAtByPID` is refreshed (only by `getAudioLevel()` or `updateDisplayedAppsState`)

Since level polling is stopped when paused, and `updateDisplayedAppsState` only refreshes for "newly active" PIDs (line 864), there is no active polling path to detect audio resumption while in paused state.

### Contributing factor 3 (MEDIUM confidence):
**During tap recreation, audio callbacks stop, causing false pause detection.**

When taps are destroyed (e.g., `recreateAllTaps`), the audio callback stops. `_peakLevel` decays to 0. After 0.5 seconds, `isPausedDisplayApp` returns true. Taps are then recreated, but by then the UI shows "Paused" and level polling has stopped. The next `getAudioLevel()` call won't happen until either:
- The popup is re-opened (triggers onAppear)
- The process re-enters `activeApps` (triggers onChange of isPaused)

---

## 6. Evidence and Proof

### What we KNOW for certain (from code):

1. **`isRecreatingTaps` correctly blocks `routeAllApps`** but does NOT block `DeviceVolumeMonitor.defaultDeviceUID` from being updated.

2. **`appDeviceRouting` is cleared during reconstruction** (lines 212-213 in handleServiceRestarted, line 729 in recreateAllTaps via taps.removeAll + appliedPIDs.removeAll).

3. **`resolvedDeviceUIDForDisplay` falls back to `defaultDeviceUID`** when `appDeviceRouting` is empty.

4. **Aggregate device destruction triggers macOS default device changes.** This is documented CoreAudio behavior.

5. **`DeviceVolumeMonitor` debounces default device changes with 300ms delay.** This is less than the 1500ms service restart delay, so the debounced notification fires during the recreation window.

6. **Permission confirmation triggers `recreateAllTaps`** which is a SECOND destruction/recreation cycle after the service restart.

7. **VU meter polling stops when `isPaused` is true** and only resumes when `isPaused` changes to false.

8. **`isPausedDisplayApp` has no active recovery mechanism** -- it relies on `getAudioLevel()` being called, which requires VU polling to be running.

### What we SUSPECT but cannot prove from code alone:

1. Whether macOS actually changes the default output device to speakers when FineTune's aggregate is destroyed. (Extremely likely based on CoreAudio behavior, but would need runtime verification.)

2. Whether Spotify's audio session auto-reconnects after coreaudiod restart. (Likely no, based on the user report.)

3. Whether AirPods' UID changes after coreaudiod restart. (Unlikely but possible.)

4. The exact timing of asynchronous CoreAudio notifications relative to the recreation window.

---

## 7. Recommended Precise Code Changes

### Fix 1: Suppress `defaultDeviceUID` updates during tap recreation

**File:** `AudioEngine.swift`
**Rationale:** The `isRecreatingTaps` flag prevents `routeAllApps` but `DeviceVolumeMonitor` still updates `defaultDeviceUID`, which the UI reads. Instead of trying to suppress the update in DeviceVolumeMonitor (which would require cross-object coupling), we should also suppress the UI fallback in `resolvedDeviceUIDForDisplay`.

**Change:** In `resolvedDeviceUIDForDisplay`, when `isRecreatingTaps` is true and no explicit routing exists, return the last known device from settings rather than defaultDeviceUID.

```swift
// AudioEngine.swift, resolvedDeviceUIDForDisplay (line 356)
func resolvedDeviceUIDForDisplay(
    app: AudioApp,
    availableDevices: [AudioDevice],
    defaultDeviceUID: String?
) -> String {
    // Priority 1: In-memory explicit routing
    if let routedUID = appDeviceRouting[app.id], availableDevices.contains(where: { $0.uid == routedUID }) {
        return routedUID
    }
    // Priority 2: Persisted routing (survives tap recreation window)
    if let savedUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
       availableDevices.contains(where: { $0.uid == savedUID }) {
        return savedUID
    }
    // Priority 3: System default (only when not recreating)
    if let defaultDeviceUID, availableDevices.contains(where: { $0.uid == defaultDeviceUID }) {
        return defaultDeviceUID
    }
    return availableDevices.first?.uid ?? ""
}
```

This adds a **Priority 2** step that reads from persisted settings, which are NOT cleared during tap recreation. This means even when `appDeviceRouting` is empty (during the recreation window), the UI shows the correct saved device.

### Fix 2: Restore the macOS default output device after tap recreation

**File:** `AudioEngine.swift`
**Rationale:** When aggregate devices are destroyed, macOS falls back to speakers. After recreation, we should restore the default if it was changed by our destruction.

**Change:** In `handleServiceRestarted`, capture the current default device UID BEFORE destroying taps, and restore it after recreation.

```swift
// AudioEngine.swift, handleServiceRestarted (line 197)
private func handleServiceRestarted() {
    logger.warning("[SERVICE-RESTART] coreaudiod restarted - destroying all taps and recreating")

    isRecreatingTaps = true

    // Capture what the user's default device was BEFORE we destroy our aggregates
    let preDestructionDefaultUID = deviceVolumeMonitor.defaultDeviceUID

    // ... existing destruction code ...

    Task { @MainActor [weak self] in
        // ... existing delay and recreation ...
        self?.applyPersistedSettings()
        self?.isRecreatingTaps = false

        // Restore the macOS default output device if our aggregate destruction changed it
        if let savedDefault = preDestructionDefaultUID,
           let currentDefault = self?.deviceVolumeMonitor.defaultDeviceUID,
           savedDefault != currentDefault,
           let device = self?.deviceMonitor.device(for: savedDefault) {
            self?.deviceVolumeMonitor.setDefaultDevice(device.id)
        }
    }
}
```

### Fix 3: Avoid double recreation on first permission confirmation

**File:** `AudioEngine.swift`
**Rationale:** After coreaudiod restart (service restart), `handleServiceRestarted` already recreates all taps. Then the fast health check fires and calls `recreateAllTaps()` again. This double-recreation is unnecessary and amplifies the audio disruption (Bug 2).

**Change:** Skip recreation if `handleServiceRestarted` already cleared and recreated taps. Since `permissionConfirmed` is set to true in the fast health check, the second pass of `applyPersistedSettings` (called by `handleServiceRestarted`) will already create taps with `.mutedWhenTapped` IF we set `permissionConfirmed` earlier.

Alternative approach: In `handleServiceRestarted`, check if audio was flowing before the restart (which means permission was already granted). If so, set `permissionConfirmed = true` BEFORE calling `applyPersistedSettings()`, so the taps are created with `.mutedWhenTapped` on the first try, avoiding the need for a second recreation.

```swift
// AudioEngine.swift, handleServiceRestarted (line 197)
private func handleServiceRestarted() {
    // ...existing code...

    // If we had active taps before the restart, permission was already confirmed
    // (the restart IS the confirmation event -- user just clicked "Allow")
    let hadActiveTaps = !taps.isEmpty

    // ...existing destruction code...

    Task { @MainActor [weak self] in
        // ...existing delay...
        guard let self else { return }

        // If we had taps before, permission is confirmed. Skip the .unmuted phase.
        if hadActiveTaps {
            self.permissionConfirmed = true
        }

        self.applyPersistedSettings()
        self.isRecreatingTaps = false
    }
}
```

This eliminates the double-recreation entirely. Taps go directly to `.mutedWhenTapped` if they were active before the restart.

### Fix 4: Add a recovery polling mechanism for pause state

**File:** `AppRow.swift` (AppRowWithLevelPolling)
**Rationale:** When VU meter polling stops (because `isPaused` is true), there is no mechanism to detect that audio has resumed. We need a low-frequency background check.

**Change:** Instead of completely stopping polling when paused, switch to a slow-poll mode (e.g., every 2 seconds) that checks audio level. If level > threshold, resume fast polling and update lastAudibleAt.

```swift
// AppRow.swift, in AppRowWithLevelPolling
private func startLevelPolling() {
    guard levelPollingTask == nil else { return }
    let pollLevel = getAudioLevel
    let interval = DesignTokens.Timing.vuMeterUpdateInterval

    levelPollingTask = Task { @MainActor in
        while !Task.isCancelled {
            displayLevel = pollLevel()
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}

// ADD: Slow polling for pause recovery
private func startPauseRecoveryPolling() {
    guard pauseRecoveryTask == nil else { return }
    let pollLevel = getAudioLevel

    pauseRecoveryTask = Task { @MainActor in
        while !Task.isCancelled {
            let level = pollLevel()
            if level > 0.002 {  // Audio detected - will cause isPaused to flip via lastAudibleAt
                break
            }
            try? await Task.sleep(for: .seconds(2.0))
        }
    }
}
```

However, this is a view-layer workaround. A better approach would be to keep `getAudioLevel()` polling active regardless of pause state, since it is what updates `lastAudibleAtByPID`. The VU meter display can be zero (by not setting `displayLevel`), but the underlying level check should continue.

### Fix 5 (alternative, cleaner approach for Bug 3): Always poll audio level, decouple from display

**File:** `AudioEngine.swift`
**Rationale:** The `getAudioLevel` function serves two purposes: (1) VU meter display, and (2) pause detection. These should not be coupled. Pause detection should run independently of the UI.

**Change:** Add a periodic check in the diagnostic/health timer (which already runs every 3 seconds) that updates `lastAudibleAtByPID` for all tapped apps.

```swift
// AudioEngine.swift, inside the diagnostic timer Task (line 181)
Task { @MainActor [weak self] in
    while !Task.isCancelled {
        try? await Task.sleep(for: self?.diagnosticPollInterval ?? .seconds(3))
        guard let self else { return }
        self.logDiagnostics()
        self.checkTapHealth()
        self.updatePauseStates()  // NEW
    }
}

private func updatePauseStates() {
    for (pid, tap) in taps {
        let level = tap.audioLevel
        if level > pausedLevelThreshold {
            lastAudibleAtByPID[pid] = Date()
        }
    }
}
```

This ensures pause state is updated every 3 seconds regardless of whether the popup is visible or VU polling is active. The response time for pause->playing transitions would be up to 3 seconds (the diagnostic poll interval), which is acceptable.

### Fix 6: Suppress default device change notifications from DeviceVolumeMonitor during recreation

**File:** `DeviceVolumeMonitor.swift`
**Rationale:** Even though `isRecreatingTaps` blocks `routeAllApps`, the `defaultDeviceUID` property is still updated, causing UI issues. A more thorough fix would suppress the notification at the source.

**Change:** Add a public `suppressDefaultDeviceNotifications` flag that `AudioEngine` can set.

```swift
// DeviceVolumeMonitor.swift
var suppressDefaultDeviceNotifications = false

private func applyDefaultDeviceChange(...) {
    if isVirtual { ... return }

    // Don't update state or notify during tap recreation
    if suppressDefaultDeviceNotifications {
        logger.info("Default device change to \(deviceUID ?? "nil") suppressed")
        return
    }

    defaultDeviceID = deviceID
    defaultDeviceUID = deviceUID
    // ...
}
```

Then in `AudioEngine.handleServiceRestarted()`:
```swift
deviceVolumeMonitor.suppressDefaultDeviceNotifications = true
// ...destruction...
// In the Task after recreation:
deviceVolumeMonitor.suppressDefaultDeviceNotifications = false
deviceVolumeMonitor.refreshDefaultDevice()  // Re-read the real default
```

---

## Summary of Root Causes by Bug

| Bug | Primary Root Cause | Confidence |
|-----|-------------------|------------|
| Bug 1 (wrong device display) | `defaultDeviceUID` updated to speakers during aggregate destruction; UI reads it as fallback when `appDeviceRouting` is empty during recreation window | HIGH |
| Bug 2 (audio muting) | coreaudiod restart disrupts app audio sessions; double tap recreation amplifies disruption; `.mutedWhenTapped` requires app to actively produce audio | HIGH |
| Bug 3 (stale play/pause) | VU meter polling stops when paused; no independent mechanism to detect audio resumption; `lastAudibleAtByPID` not updated without polling | HIGH |

## Priority Ordering of Fixes

1. **Fix 1 + Fix 6** (Bug 1): Add persisted routing fallback in `resolvedDeviceUIDForDisplay` AND suppress `defaultDeviceUID` updates during recreation. These two changes together fully resolve the erroneous device display.

2. **Fix 3** (Bug 2): Avoid double recreation by setting `permissionConfirmed = true` if taps existed before service restart. This eliminates one entire destruction/recreation cycle.

3. **Fix 5** (Bug 3): Add `updatePauseStates()` to the diagnostic timer. This decouples pause detection from VU meter polling with minimal code change.

4. **Fix 2** (Bug 1, Belt-and-suspenders): Restore macOS default device after recreation. This is a nice-to-have on top of Fix 1+6.
