# FineTune Audio Path

How audio flows from an application to your ears, and what happens when things change.

---

## Big Picture

FineTune sits between every app's audio output and your speakers/headphones. It does this using two macOS CoreAudio primitives:

1. **Process Tap** -- captures the stereo mixdown of a single app's audio stream and silences the app's original output so you don't hear it twice.
2. **Aggregate Device** -- a private virtual device that routes FineTune's processed audio to whatever physical output device (speakers, AirPods, USB DAC) you've chosen.

Every app that FineTune manages gets its own tap + aggregate pair. This is what makes per-app volume, EQ, and device routing possible.

> **macOS 26 Note:** On macOS 26, taps use `bundleIDs` for bundle-ID targeting (required for Chromium-based browsers). `isProcessRestoreEnabled` must NOT be set — it causes dead aggregate output. See [bundle-id-tap-silent-output-macos26.md](../known_issues/bundle-id-tap-silent-output-macos26.md) for the resolved investigation. Per-app device routing to 3+ simultaneous devices has shown issues — see [macos26-audio-routing-investigation.md](../known_issues/macos26-audio-routing-investigation.md).

---

## Startup: What Happens When FineTune Launches

```
1. Single-instance guard  (FineTuneApp.swift:25)
   Only one copy of FineTune can run. If another is already running, quit
   immediately. MUST happen before orphan cleanup — otherwise we'd destroy
   the running instance's live aggregate devices.

2. Orphan cleanup  (OrphanedTapCleanup.swift)
   If a previous session crashed, leftover aggregate devices may still exist
   in CoreAudio. Scans for devices named "FineTune-*" and destroys them so
   they don't ghost your device list or silently mute apps.

3. Crash guard install  (CrashGuard.swift)
   Allocates a fixed-size C buffer (64 slots) for tracking live aggregate
   device IDs. Installs signal handlers for SIGABRT, SIGSEGV, SIGBUS, and
   SIGTRAP. On crash, destroys all tracked aggregates via IPC to coreaudiod
   before re-raising the signal for normal crash behavior.

4. Signal handlers  (FineTuneApp.swift:116-134)
   Installs SIGTERM/SIGINT handlers via DispatchSource so that `kill <pid>`
   and Ctrl+C trigger a clean shutdown (destroys taps and aggregates before
   exiting). `kill -9` is uncatchable — startup cleanup handles that case.

5. Permission pre-check  (FineTuneApp.swift:72-91)
   Calls CGPreflightScreenCaptureAccess() to check if the "Screen & System
   Audio Recording" permission is granted. If missing after onboarding, shows
   a dialog directing the user to System Settings before proceeding.

6. Load saved settings
   Reads persisted per-app volumes, mute states, EQ presets, and device
   routings from settings.json. (Device routings have known limitations on
   macOS 26 — see known_issues docs for details.)

7. Create AudioEngine  (AudioEngine.swift:194-343)
   The central coordinator. It starts monitoring for:
     - Active audio processes (AudioProcessMonitor)
     - Available output/input devices (AudioDeviceMonitor)
     - System default device changes (DeviceVolumeMonitor)
     - Device volume/mute changes (DeviceVolumeMonitor)
     - Media play/pause notifications (MediaNotificationMonitor)

8. Startup delay  (AudioEngine.swift:289-296)
   Waits 2 seconds (startupTapDelay) before creating any taps. This lets
   apps initialize their audio sessions and avoids creating taps before
   system audio permission is active.

9. Create taps for running apps
   For each app that already has audio streams AND has saved settings,
   FineTune creates a tap + aggregate device and applies the saved
   volume/mute/EQ/routing. The onAppsChanged callback is wired AFTER
   initial taps are created to prevent it from bypassing the startup delay.
```

### First-Launch Onboarding

macOS requires "Screen & System Audio Recording" permission for process taps. The catch: **there is no API to ask "do I have permission?"** The `AudioHardwareCreateProcessTap` call succeeds either way -- it doesn't return an error when permission is missing. The tap just silently receives empty buffers.

On first launch (before the `onboardingCompleted` flag is set in settings), FineTune shows an onboarding window that:
1. Explains the permission requirement
2. Provides a button to open System Settings to the correct privacy pane
3. Lets the user click "Continue" once they've granted permission

**AudioEngine is not created until onboarding completes.** This ensures no taps are created (and no macOS permission dialogs appear) before the user has context about why the permission is needed.

The `onboardingCompleted` flag persists in `settings.json`. On subsequent launches the onboarding is skipped and AudioEngine starts immediately. For development, pass `--skip-onboarding` as a launch argument to bypass the dialog regardless of the flag.

### Runtime Permission Verification

Permission can be revoked between launches (via System Settings or `tccutil reset`), so even if FineTune confirmed permission last time, that tells you nothing about this time. The `permissionConfirmed` flag is per-session and never saved to disk.

Taps are created with `muteBehavior = .mutedWhenTapped` by default. If permission was revoked, taps receive empty buffers. The existing health monitoring (`checkTapHealth()`) detects dead taps and attempts recreation automatically.

Permission confirmation uses a multi-gate check (`AudioEngine.shouldConfirmPermission()`, line 156):
1. Callbacks are running (tap is active)
2. Output has been written (pipeline is working)
3. Input audio is present (permission is granted — user audio captured)
4. When volume > 0.01, requires non-zero output peak (prevents false confirmation when the aggregate output path is dead, e.g. bundle-ID tap failure mode)

---

## The Audio Processing Chain

Once a tap is active, every audio callback (firing hundreds of times per second on a real-time thread) runs this pipeline. The implementation lives in `ProcessTapController.processAudio()` (line 1185).

```
App's raw audio samples
  |
  v
[Force Silence Check]   -- If _forceSilence is set (during device switch),
  |                         output zeros immediately and return
  v
[Format Detection]       -- Read tap format (Float32? Interleaved? Channel count?)
  |
  v
[Input Peak Tracking]    -- Always measure INPUT signal for VU meter
  |                         (shows source activity even when muted)
  v
[User Mute Check]        -- If _isMuted, output zeros and return
  |                         (VU meter still shows source activity above)
  v
[Volume Ramp]            -- Smoothly transitions toward the target volume
  |                         (~30ms exponential curve, prevents clicks)
  v
[Crossfade Mix]          -- Only active during a device switch
  |                         Primary: cos(progress * π/2) fade-out
  |                         Secondary: sin(progress * π/2) fade-in
  v
[Device Volume           -- Compensates for different hardware volume levels
 Compensation]              when switching devices. Ramped to unity after
  |                         crossfade promotion (~30ms via ramp coefficient).
  v
[10-Band EQ]             -- Biquad filter cascade via vDSP (Accelerate framework)
  |                         DISABLED during active crossfade to prevent artifacts
  v
[Soft Limiter]           -- Prevents clipping from volume boost + EQ peaks
  |                         Threshold: 0.8, ceiling: 1.0 (asymptotic compression)
  |                         Only engaged when volume > 1.0 (boost territory)
  v
Aggregate device -> Physical output -> Your ears
```

### Format Conversion Path

When the tap format is not stereo interleaved Float32 (rare but happens with some USB interfaces and mono apps), the `AudioFormatConverter` handles it:

```
Non-standard input (e.g., Int16, non-interleaved, mono)
  |
  v
[Input Converter]        -- AudioConverterFillComplexBuffer to canonical
  |                         format (stereo interleaved Float32)
  v
[Volume + Crossfade]     -- GainProcessor on normalized buffer
  v
[EQ + Limiter]           -- Applied on canonical format
  v
[Output Converter]       -- Convert back to device's native format
  |
  v
Output buffers
```

Mono sources are upmixed (duplicated to both channels) for processing and downmixed back. Formats with >2 channels return nil from the converter (unsupported, audio passes through unprocessed).

### RT Safety Constraints

All state that the audio callback reads (volume, mute, EQ coefficients, crossfade state) is updated atomically from the main thread. The callback never takes locks. Aligned Float/Bool reads are atomic on Apple Silicon, so slight staleness (one callback's worth, ~5ms) is acceptable and avoids any risk of audio glitches from lock contention.

The `GainProcessor` (extracted to `FineTune/Audio/Processing/GainProcessor.swift`) and `SoftLimiter` are `@inline(__always)` static functions marked with RT safety documentation.

---

## Safety Checks & Guards

### Crash Guard (`CrashGuard.swift`)

Handles unclean process termination (SIGABRT, SIGSEGV, SIGBUS, SIGTRAP):

| Aspect | Detail |
|--------|--------|
| **Buffer** | Fixed-size C buffer, 64 slots, allocated once at startup, never freed |
| **Tracking** | `os_unfair_lock`-protected add/remove; swap-with-last removal algorithm |
| **Signal handler** | Resets to `SIG_DFL` FIRST (prevents infinite recursion if cleanup crashes), then destroys all tracked aggregates via `AudioHardwareDestroyAggregateDevice` (IPC to coreaudiod, doesn't depend on in-process heap), then re-raises for normal crash behavior |

### Orphaned Device Cleanup (`OrphanedTapCleanup.swift`)

Called on startup before CrashGuard. Scans CoreAudio device list for aggregate devices with transport type `.aggregate` and name prefix `"FineTune-"`. Destroys them and logs the count. This catches devices left by `kill -9` or system crashes that the crash guard couldn't handle.

### TapResources -- Safe Ordered Teardown (`Tap/TapResources.swift`)

Encapsulates CoreAudio resource lifecycle with a **critical teardown order**:

```
1. AudioDeviceStop()                    -- Stop IO proc
2. AudioDeviceDestroyIOProcID()         -- Destroy IO proc (blocks until callback finishes)
3. CrashGuard.untrackDevice()           -- Remove from crash tracking
4. AudioHardwareDestroyAggregateDevice()-- Destroy aggregate device
5. AudioHardwareDestroyProcessTap()     -- Destroy process tap
```

Violating this order can leak resources or crash on shutdown. Two variants:
- `destroy()` -- synchronous, correct order
- `destroyAsync()` -- captures values, clears state immediately, dispatches blocking teardown to a background queue (prevents main thread blocking from `AudioDeviceDestroyIOProcID`)

### TapDiagnostics -- RT-Safe Health Counters (`Tap/TapDiagnostics.swift`)

Snapshot of atomically-read counters from the audio callback:

| Counter | Purpose |
|---------|---------|
| `callbackCount` | Total callbacks fired |
| `inputHasData` | Callbacks with valid input audio |
| `outputWritten` | Callbacks that wrote output |
| `silencedForce` | Callbacks silenced for device switch |
| `silencedMute` | Callbacks silenced by user mute |
| `converterUsed` / `converterFailed` | Format conversion attempts |
| `directFloat` | Direct Float32 processing (no conversion) |
| `nonFloatPassthrough` | Non-float passed through unchanged |
| `emptyInput` | Callbacks with zero-length/nil input |
| `lastInputPeak` / `lastOutputPeak` | Peak levels for VU meter |
| `outputBufCount` / `outputBuf0ByteSize` | Output buffer metadata |

**Derived health checks:**
- `hasDeadOutput`: callbacks > 10, output written, but output peak ≈ 0 with volume > 0.01
- `hasDeadInput`: callbacks > 10, but zero input data and input peak ≈ 0

Primary and secondary taps maintain **separate** diagnostic counters to avoid read-modify-write races when both callbacks run simultaneously during crossfade. Counters are merged in `promoteSecondaryToPrimary()` after crossfade completes.

### Activation Guards (`ProcessTapController.activate()`, line 421)

Each step has error handling with rollback:

```
guard !activated                    -- Prevent double-activation
  |
  v
Create process tap                  -- On failure: throw
  |
  v
Create aggregate device             -- On failure: cleanupPartialActivation()
  |                                    (destroys tap, clears format/converter)
  v
CrashGuard.trackDevice()            -- Register for crash-safe cleanup
  |
  v
Read sample rate                    -- Fallback: 48kHz if read fails
  |
  v
Configure format converter          -- May return nil (no conversion needed)
  |
  v
Create IO proc                      -- On failure: cleanupPartialActivation()
  |
  v
Start device                        -- On failure: cleanupPartialActivation()
  |
  v
activated = true                    -- ONLY set after complete success
```

### Health Monitoring (`AudioEngine.checkTapHealth()`, line 414)

Runs every 3 seconds. Detects four failure modes:

| # | Condition | Meaning | Detection |
|---|-----------|---------|-----------|
| 0 | `callbackCount == 0` across two cycles | Tap never started / wrong device | Two consecutive zero-callback snapshots |
| 1 | `callbackDelta == 0` | IO proc stopped running (stalled) | Callback count not changing between cycles |
| 2 | `callbackDelta > 50, outputDelta == 0, emptyDelta > callbackDelta/2` | Reporter disconnected (broken) | Callbacks fire with zero-length buffers |
| 3 | `callbackDelta > 50, inputDelta == 0, prev.inputHasData > 0` | Bundle-ID tap disconnected after crossfade | Input frozen within 10s of crossfade completion |

**Infinite recreation guard:** `maxDeadTapRecreations = 3` per PID. After 3 failed recreations, the tap is removed and the app is given up on (apps like CoreSpeech never produce audio). Counter resets once a tap produces any callbacks.

**Dead tap fallback:** If a tap is dead (zero callbacks), health monitoring tries rerouting to the system default device before recreating on the same device.

### Concurrent Switch Prevention (`AudioEngine`, line 31)

```swift
private var switchTasks: [pid_t: Task<Void, Never>] = [:]
```

Each in-flight device switch is tracked per PID. Starting a new switch cancels the old one first, preventing crossfade state corruption from concurrent `switchDevice` calls on the same `ProcessTapController`.

### Routing Restoration on Failure (`AudioEngine`, line 973)

If a device switch fails, the routing state is reverted so the UI reflects where audio is actually playing. Cancelled switches don't revert (the newer switch is handling the transition).

### Recreation Suppression (`AudioEngine`, line 119)

Two-layer defense prevents device-change notifications from corrupting routing during tap recreation:

1. `isRecreatingTaps` flag -- synchronous suppression during active recreation
2. Grace period (2 seconds after `recreationEndedAt`) -- catches late-arriving debounced notifications that slip past the flag

### Stale Tap Cleanup Grace Period (`AudioEngine`, line 106)

When an app disappears from the process list, cleanup is scheduled with a 1-second grace period. If the app reappears during that window, cleanup is cancelled. This prevents tap destruction during normal audio interruptions (e.g., aggregate device creation during crossfade causes processes to momentarily disappear).

### Menu Bar Button Health (`MenuBarStatusController.swift`, line 50)

macOS 26 can reset the status bar button's action/target during Control Center scene reconnections. A 2-second timer verifies the button is still wired and re-wires it if reset. A delayed health check at 3 seconds after creation logs icon visibility diagnostics.

---

## Scenario: User Drags the Per-App Volume Slider

```
UI slider moves
  |
  v
audioEngine.setVolume(for: app, to: 0.75)
  |
  +--> In-memory state updated (VolumeState)
  +--> Settings persisted to disk (debounced async via SettingsManager)
  +--> tap._volume = 0.75  (atomic write)
  |
  v
Next audio callback (microseconds later):
  reads _volume = 0.75
  ramps _primaryCurrentVolume from old value toward 0.75
  applies ramped volume to each sample

  Over ~30ms, volume smoothly reaches 0.75.
  No click. No gap.
```

The ramp coefficient is calculated from the device's sample rate so the transition time is consistent regardless of whether you're on 44.1kHz or 96kHz.

---

## Scenario: User Adjusts the macOS System Volume Slider

FineTune does **not** intercept or modify the system volume slider. The system volume controls the physical output device's hardware gain, which is downstream of FineTune's processing chain.

```
FineTune's processed audio at digital level
  |
  v
Aggregate device passes audio to physical device
  |
  v
Physical device applies its own hardware volume  <-- This is what the system slider controls
  |
  v
Sound comes out of speakers/headphones
```

So when you drag the system volume slider, it changes the output device's gain. FineTune's per-app volumes are multiplicative on top of that. If your system volume is at 50% and FineTune has an app at 50%, the effective output is 25% of the app's original level.

FineTune **does** monitor device volume changes (via CoreAudio property listeners) for one purpose: **device volume compensation** during device switches (explained below).

---

## Scenario: User Selects a Different Output Device for an App

> **macOS 26 Note:** Per-app device routing has known limitations on macOS 26. Single non-default routing and dual simultaneous output work, but 3+ simultaneous devices have shown issues. See [macos26-audio-routing-investigation.md](../known_issues/macos26-audio-routing-investigation.md).

This is the most complex operation. FineTune uses a **crossfade** to make the switch seamless. The crossfade state machine lives in `CrossfadeState.swift`.

```
1. CANCEL CONCURRENT SWITCHES
   - Cancel any in-flight switch for this app (prevents state corruption)

2. READ PROPERTIES
   - Source device: volume = 0.75, sample rate = 48kHz
   - Destination device: volume = 0.06 (AirPods are quiet), sample rate = 48kHz
   - Compute volume compensation: 0.75 / 0.06 = 12.5x, clamped to 2.0x
     (prevents the audio from being deafeningly loud on the new device)

3. BEGIN WARMUP (CrossfadePhase.warmingUp)
   - beginCrossfade() sets phase, resets counters, OSMemoryBarrier()
   - New process tap + aggregate device targeting the destination
   - Secondary tap starts with _forceSilence = true (no audio output yet)
   - Its audio callback begins firing in parallel with the primary
   - Primary continues at full volume (primaryMultiplier = 1.0)
   - Secondary is silent (secondaryMultiplier = 0.0)

4. WARMUP COMPLETE (minimumWarmupSamples = 2048, ~43ms at 48kHz)
   - Polls every 5ms until secondary has processed enough samples
   - Timeout: 500ms normal, 3000ms for Bluetooth
   - Falls back to destructive switch if warmup fails

5. CROSSFADE (CrossfadePhase.crossfading, 200ms duration)
   - beginCrossfading() transitions phase, OSMemoryBarrier()
   - Primary (old device):   volume *= cos(progress * π/2)  -->  fades 1.0 to 0.0
   - Secondary (new device): volume *= sin(progress * π/2)  -->  fades 0.0 to 1.0
   - Sample-accurate timing: secondary callback drives progress via sample counting
   - This is an equal-power crossfade (perceived loudness stays constant)
   - EQ processing is DISABLED during crossfade to prevent artifacts

6. PROMOTE SECONDARY
   - complete() resets crossfade state, OSMemoryBarrier()
   - Destroy the primary tap (old device) via destroyAsync()
   - Secondary becomes the new primary
   - Volume state, diagnostics, and converter state transferred
   - _targetCompensation set to 1.0, ramped back to unity over ~30ms
   - Done. Audio is now flowing through the new device.
```

**Bundle-ID tap exception:** On macOS 26, bundle-ID taps skip crossfade entirely and use destructive switch instead. Two taps with identical `bundleIDs` cause CoreAudio to stop delivering audio to the surviving tap after the other is destroyed.

If the crossfade fails (e.g., device disconnects mid-switch), FineTune falls back to a **destructive switch**: sets `_forceSilence = true` with `OSMemoryBarrier()`, waits 100ms for silence to propagate, creates the new tap+aggregate BEFORE destroying the old one, then fades in by setting `_primaryCurrentVolume = 0` and clearing `_forceSilence`. This causes a brief audio gap (~350ms) but is reliable.

---

## Scenario: User Changes the System Default Output Device

When you switch the system default (e.g., click the volume icon in the menu bar and pick AirPods), macOS fires a `kAudioHardwarePropertyDefaultOutputDevice` notification.

```
System default changes to AirPods
  |
  v
DeviceVolumeMonitor detects the change (debounced 300ms)
  |
  v
shouldSuppressDeviceNotifications check
  (skip if recreating taps or within 2s grace period)
  |
  v
AudioEngine.routeAllApps(to: "AirPods UID")
  |
  v
For each managed app not already on AirPods:
  crossfade switch to AirPods (same process as above)
```

All apps switch simultaneously. Their per-app volume/EQ settings are preserved -- only the output device changes.

**Debounce note:** The 300ms debounce exists because macOS sometimes fires multiple rapid default-device-change notifications (e.g., when connecting Bluetooth). Debouncing coalesces them into a single switch.

---

## Scenario: Output Device Disconnects (AirPods Removed)

```
AirPods disconnect
  |
  v
AudioDeviceMonitor detects device removal
  |
  v
AudioEngine.handleDeviceDisconnected("AirPods UID")
  |
  v
For each app routed to AirPods:
  1. Switch to system default device (MacBook speakers) via crossfade
  2. Mark this app as "followsDefault" (displaced from its preferred device)
  3. DO NOT update the persisted setting (still saved as AirPods)
```

The key insight: FineTune **does not** overwrite your saved preference. It switches to the fallback in memory only and remembers that the app was displaced.

---

## Scenario: Output Device Reconnects (AirPods Back)

```
AirPods reconnect
  |
  v
AudioDeviceMonitor detects new device
  |
  v
AudioEngine.handleDeviceConnected("AirPods UID")
  |
  v
For each app marked as "followsDefault":
  Check if its persisted routing matches the reconnected device UID
  If yes:
    1. Crossfade back to AirPods
    2. Remove from "followsDefault" set
    3. Notification: "AirPods reconnected. Audio restored."
```

Result: seamless round-trip. Unplug AirPods, audio goes to speakers. Plug them back in, audio returns to AirPods automatically. Your saved preference was never lost.

---

## Scenario: coreaudiod Restarts

This happens when:
- The user grants (or revokes) the Screen & System Audio Recording permission
- macOS decides to restart the audio daemon for internal reasons

When coreaudiod restarts, **every AudioObjectID in the system becomes invalid**. All taps, aggregate devices, and listeners are gone.

```
kAudioHardwarePropertyServiceRestarted fires
  |
  v
1. Cancel any previous restart task (reentrancy guard)
2. Set isRecreatingTaps = true (suppress device notifications)
3. Snapshot current routing state (in-memory + persisted)
4. Cancel all in-flight device switches
5. Destroy all taps (their IDs are garbage now anyway)
6. Wait 1.5 seconds (serviceRestartDelay) for coreaudiod to stabilize
7. Recreate all taps from persisted settings
8. If permission not yet confirmed this session, probe for audio inline
9. Restore routing snapshot (prevents spurious notifications
   during recreation from corrupting the routing table)
10. Clear isRecreatingTaps flag
11. Set recreationEndedAt for 2-second grace period
    (catches late-arriving debounced notifications)
```

From the user's perspective: audio cuts out for ~2 seconds, then everything comes back exactly as it was.

---

## Scenario: App Quits or Audio Stream Ends

```
App terminates (or stops producing audio)
  |
  v
AudioProcessMonitor detects PID removal from CoreAudio's process list
  |
  v
cleanupStaleTaps() schedules cleanup with 1-second grace period
  |
  v
If app reappears within grace period: cancel cleanup
If grace period expires:
  |
  v
Cancel any in-flight switch tasks for this app
  |
  v
AudioEngine removes the app from its active list
  |
  v
Tap + aggregate device destroyed (async to avoid blocking main thread)
  |
  v
Persisted settings (volume, EQ, device routing) remain on disk
  for when the app launches again
```

The grace period prevents tap destruction during normal audio interruptions — processes momentarily disappear during aggregate device creation (crossfade).

---

## Scenario: FineTune Quits

```
applicationWillTerminate fires
  |
  v
1. menuBarController.stop()
     - Invalidate button health timer
     - Dismiss panel
     - Remove status item
2. audioEngine.stopSync() -- synchronous on main thread:
     - Stop all monitors (process, device, volume, media)
     - Cancel all async tasks (diagnostics, health, cleanup, switches)
     - Destroy all taps (which un-silences apps' original audio)
     - Destroy all aggregate devices (via TapResources teardown order)
     - Remove all CoreAudio property listeners
       (CRITICAL: prevents orphaned listeners from corrupting coreaudiod/System Settings)
3. settings.flushSync() -- ensure all pending writes complete
4. Exit
```

After FineTune quits, all apps' audio goes back to normal -- they output directly to whatever the system default device is, with no FineTune processing.

---

## Health Monitoring

Every 3 seconds (`diagnosticPollInterval`), FineTune runs `checkTapHealth()` which checks each tap's diagnostic counters:

| Condition | Meaning | Action |
|-----------|---------|--------|
| Callback count = 0 for two checks | Tap never started firing | Recreate tap (try system default as fallback) |
| Callback count stopped incrementing | Tap stalled | Recreate tap |
| Callbacks firing but mostly empty input, no output | Reporter disconnected | Recreate tap |
| Callbacks running, output written, but input frozen within 10s of crossfade | Bundle-ID tap disconnection (macOS 26) | Recreate tap |

**Infinite recreation guard:** After 3 consecutive dead-tap recreations for the same PID, FineTune gives up. Counter resets when the tap produces any callbacks.

Recreation is automatic and transparent. The user might hear a brief (~100ms) audio glitch during recreation but otherwise won't notice.

Additionally, `logDiagnostics()` logs detailed per-tap information every cycle: callback counts, format info, peak levels, converter usage, and device routing — all from the RT-safe diagnostic counters.

---

## Pause/Play Detection

FineTune uses **asymmetric hysteresis** to determine if an app is playing or paused:

- **Playing -> Paused:** Requires 1.5 seconds of continuous silence. This avoids false pauses during natural gaps in audio (silence between songs, loading screens).
- **Paused -> Playing:** Requires only 0.05 seconds of audio. Recovery feels instant.

Two detection paths feed into this:
1. **Audio level monitoring** -- a lightweight 1-second timer (`pauseRecoveryPollInterval`) reads `tap.audioLevel` directly. This breaks the circular dependency where `isPaused→true` stops VU polling, which prevents `lastAudibleAtByPID` updates, which keeps `isPaused→true` forever.
2. **Media notifications** (`MediaNotificationMonitor`) -- listens for system play/pause events (Spotify, Apple Music) for instant response. Bypasses VU-level detection lag entirely.

---

## Summary Diagram

```
                    FineTune
                    ========

  [Spotify]  [Zoom]  [Safari]  [Music]     <-- Apps producing audio
      |         |        |         |
      v         v        v         v
  [Tap A]   [Tap B]  [Tap C]  [Tap D]      <-- Process taps (capture + silence original)
      |         |        |         |
      v         v        v         v
  [Force Silence Guard]                     <-- Zero output if device switch in progress
  [Format Converter]                        <-- Non-Float32/mono → canonical stereo Float32
  [Volume Ramp]                             <-- Per-app volume + smooth ~30ms ramp
  [Crossfade Mix]                           <-- Equal-power sin/cos during device switch
  [Device Volume Compensation]              <-- Hardware volume normalization
  [10-Band EQ]                              <-- Per-app biquad cascade (disabled during xfade)
  [Soft Limiter]                            <-- Asymptotic compression above 0.8
      |         |        |         |
      v         v        v         v
  [Agg A]   [Agg B]  [Agg C]  [Agg D]      <-- Aggregate devices
      \         \       /         /             (CrashGuard tracked)
       `---------+-----+---------'
                 v
         [System Default Device]               <-- Most common: all apps to same output
         (e.g., AirPods, Speakers)

  NOTE: On macOS 26, per-app routing to different devices partially works
  (single non-default + dual output OK, 3+ devices has issues).
  The diagram above shows the typical case; per-app routing to different
  devices is possible when it works (see earlier diagram description).

  SAFETY LAYERS:
  ├─ CrashGuard .............. Signal handler destroys aggregates on crash
  ├─ OrphanedTapCleanup ...... Startup scan for leftover "FineTune-*" devices
  ├─ TapResources ............ Correct teardown order (stop → destroy IO → destroy agg → destroy tap)
  ├─ TapDiagnostics .......... RT-safe counters for health detection
  ├─ Health Monitor .......... 3s poll: dead/stalled/broken/frozen tap detection + recreation
  ├─ Concurrent Switch Guard . Cancel-before-start per-PID switch tracking
  ├─ Recreation Suppression .. Flag + 2s grace period prevents notification corruption
  ├─ Stale Tap Grace Period .. 1s delay before cleanup (prevents crossfade interference)
  ├─ Routing Restoration ..... Snapshot/restore prevents recreation from corrupting routes
  ├─ Activation Rollback ..... cleanupPartialActivation() on any step failure
  └─ Signal Handlers ......... SIGTERM/SIGINT clean shutdown via DispatchSource
```
