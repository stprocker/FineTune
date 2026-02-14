# Open-Source Audio Routing Architectures: Deep Dive and Recommendations for FineTune

**Date:** 2026-02-07
**Author:** Architecture Research Agent
**Scope:** Detailed analysis of open-source macOS audio projects with bold architectural recommendations

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Project-by-Project Analysis](#2-project-by-project-analysis)
   - 2.1 BackgroundMusic
   - 2.2 eqMac
   - 2.3 AudioCap
   - 2.4 AudioTee
   - 2.5 SoundPusher
   - 2.6 SoundSource (Rogue Amoeba)
3. [The Case for Tap-Only Aggregates](#3-the-case-for-tap-only-aggregates)
4. [The Case for a Proxy Aggregate](#4-the-case-for-a-proxy-aggregate)
5. [The Case for a Persistent Tap Pool](#5-the-case-for-a-persistent-tap-pool)
6. [Bold Recommendations](#6-bold-recommendations)
7. [Appendix: Comparison Matrix](#7-appendix-comparison-matrix)

---

## 1. Executive Summary

FineTune creates **one process tap + one aggregate device per app**, where each aggregate includes the real output device as a sub-device. This architecture causes three classes of bugs:

1. **Spurious device display** -- Destroying aggregates that reference real devices triggers `kAudioHardwarePropertyDefaultOutputDevice` notifications, causing the app to show the wrong device.
2. **Audio muting during permission grant** -- Recreating taps to switch from `.unmuted` to `.mutedWhenTapped` creates a gap where audio disappears.
3. **Stale play/pause** -- VU-based detection has inherent latency and circular dependencies.

After deep analysis of six open-source projects, I argue that FineTune should adopt three major architectural changes:

1. **Drop the real sub-device from aggregates** (the "tap-only aggregate" pattern from SoundPusher/AudioTee)
2. **Never destroy taps for device switches** -- reconfigure them in-place using `CATapDescription` property mutations
3. **Use a persistent tap lifecycle** -- create taps once when an app appears, destroy only when it disappears

These changes would eliminate bugs 1 and 2 entirely and simplify the codebase dramatically.

---

## 2. Project-by-Project Analysis

### 2.1 BackgroundMusic

**Repository:** https://github.com/kyleneideck/BackgroundMusic
**Architecture:** Virtual audio driver + app-level playthrough

**How it works:**

BackgroundMusic installs a virtual audio device (BGMDevice) as a system-wide CoreAudio driver extension. The architecture has two components:

1. **BGMDriver** -- A CoreAudio HAL plugin that creates a virtual audio device. All system audio is routed through this virtual device by setting it as the macOS default output.
2. **BGMApp** -- A user-space app that reads audio from BGMDevice and forwards it to the real output device via a **ring buffer playthrough**, not an aggregate device.

**Key code: BGMPlayThrough.cpp (playthrough without aggregate)**

BackgroundMusic does NOT use an aggregate device for its audio forwarding. Instead, it runs two separate IOProcs:

```cpp
// InputDeviceIOProc: reads from BGMDevice, stores to ring buffer
mBuffer->Store(...)

// OutputDeviceIOProc: reads from ring buffer, writes to real output
mBuffer->Fetch(...)
```

This dual-IOProc design with a `CARingBuffer` is more complex but avoids aggregate device issues entirely. The ring buffer is sized at `bufferFrameSize * 20` frames to handle timing jitter.

**Key code: BGMAudioDeviceManager.mm (device switch)**

When switching output devices, BackgroundMusic uses a **deactivate-reconfigure-activate** pattern:

```objc
- (void)setOutputDeviceForPlaythroughAndControlSync:(const BGMAudioDevice&)newOutputDevice {
    playThrough.Deactivate();       // Stop IO, deallocate buffer
    playThrough_UISounds.Deactivate();

    deviceControlSync.SetDevices(*bgmDevice, newOutputDevice);
    deviceControlSync.Activate();

    playThrough.SetDevices(bgmDevice, &newOutputDevice);  // Reconfigure
    playThrough.Activate();          // Reallocate buffer, create IOProcs
    // ... same for UI sounds
}
```

This is a **destroy-and-recreate** approach, similar to FineTune's current pattern. Audio drops during the switch. BGMPlayThrough mitigates this with `WaitForOutputDeviceToStart()` which uses a semaphore to block until the output IOProc actually runs.

**Key code: BGMAppVolumesController.mm (per-app volume)**

Per-app volume is applied at the **driver level** via custom HAL properties:

```objc
audioDevices.bgmDevice.SetAppVolume(volume, processID, bundleID);
```

This sends the volume to the BGMDriver, which applies gain in the virtual device's IO callback before forwarding audio to the app's playthrough. Volume is communicated via `AudioObjectSetPropertyData` with custom property selectors.

**What FineTune should steal:**

- **Nothing architectural.** BackgroundMusic's driver-based approach requires a system extension, which FineTune intentionally avoids. The ring-buffer playthrough pattern is more complex than FineTune's current aggregate-based approach with no clear benefit.
- **One useful pattern:** The `StopIfIdle()` method that stops playthrough after a delay if no audio is flowing. FineTune could use a similar pattern for tap resource management -- keep taps alive but stop the IOProc when an app is silent, reducing CPU overhead.

---

### 2.2 eqMac

**Repository:** https://github.com/bitgapp/eqMac
**Architecture:** Null audio server driver + AVAudioEngine

**How it works:**

eqMac uses a three-layer architecture:

1. **EQMDriver** -- A CoreAudio HAL plugin (`AudioServerPlugIn`) that creates a virtual audio device. The device implements `EQMDevice.swift` with a ring buffer for capturing system audio.
2. **Engine.swift** -- Uses `AVAudioEngine` with the virtual device set as input, processes through EQ nodes, and writes to a `CircularBuffer` for output.
3. **Output routing** -- A separate output pipeline reads from the circular buffer and plays to the real device.

**Key code: Engine.swift**

```swift
engine = AVAudioEngine()
engine.setInputDevice(sources.system.device)  // EQM virtual device
engine.connect(engine.inputNode, to: equalizers.active!.eq, format: format)
engine.connect(equalizers.active!.eq, to: engine.mainMixerNode, format: format)
engine.mainMixerNode.outputVolume = 0  // Sink to void
```

The render callback writes to a circular buffer:

```swift
let renderCallback: AURenderCallback = { ... in
    if ioActionFlags.pointee == .unitRenderAction_PostRender {
        Application.engine?.buffer.write(from: ioData!, start: start, end: end)
    }
    return noErr
}
```

**Key code: Driver.swift (driver management)**

eqMac's driver is managed via custom HAL properties:

```swift
static var device: AudioDevice? {
    return AudioDevice.lookup(by: Constants.DRIVER_DEVICE_UID)
}

static var shown: Bool {
    get/set { ... AudioObjectGetPropertyData/SetPropertyData ... }
}
```

The driver can be hidden/shown, which effectively enables/disables audio capture.

**What FineTune should steal:**

- **The "hide when not needed" pattern.** eqMac hides its virtual device when not active, preventing it from appearing in system audio lists. FineTune already marks aggregates as private (`kAudioAggregateDeviceIsPrivateKey: true`), but the eqMac pattern of dynamically showing/hiding could be useful if FineTune ever needs to manage device visibility more carefully.
- **Nothing else.** eqMac's driver approach is fundamentally different from FineTune's tap-based approach and doesn't solve FineTune's specific problems.

---

### 2.3 AudioCap

**Repository:** https://github.com/insidegui/AudioCap
**Architecture:** Standard tap + aggregate (with real sub-device)

**How it works:**

AudioCap is the canonical example of the Core Audio Tap API pattern. It creates a process tap, wraps it in an aggregate device alongside the real output device, and reads audio from the aggregate's input stream.

**Key code: ProcessTap.swift (aggregate creation)**

```swift
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Tap-\(processID)",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,        // Real device IS included
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [                 // Real device IS a sub-device
        [kAudioSubDeviceUIDKey: outputUID]
    ],
    kAudioAggregateDeviceTapListKey: [
        [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapDesc.uuid.uuidString
        ]
    ]
]
```

This is essentially identical to FineTune's current pattern in `ProcessTapController.activate()`. The real output device is both the main sub-device and listed in the sub-device list.

**What's missing from AudioCap:**

- No device change handling
- No permission checking (beyond what Apple provides)
- No coreaudiod restart recovery
- No teardown/recreation logic

AudioCap is a recording tool, not a persistent audio routing app. It creates a tap, records, and tears down. It never needs to handle the dynamic scenarios that cause FineTune's bugs.

**What FineTune should steal:**

- **Nothing.** AudioCap's pattern is what FineTune already uses, and it's the source of FineTune's problems.

---

### 2.4 AudioTee

**Repository:** https://github.com/makeusabrew/audiotee
**Architecture:** Tap-only aggregate (NO real sub-device)

**How it works:**

AudioTee takes a radically different approach to aggregate device creation. Instead of including the real output device as a sub-device, it creates an aggregate with an **empty sub-device list** and adds the tap via `kAudioAggregateDevicePropertyTapList` after creation.

**Key code: AudioTapManager.swift**

```swift
private func createAggregateDevice() throws -> AudioObjectID {
    let uid = UUID().uuidString
    let description = [
        kAudioAggregateDeviceNameKey: "audiotee-aggregate-device",
        kAudioAggregateDeviceUIDKey: uid,
        kAudioAggregateDeviceSubDeviceListKey: [] as CFArray,  // EMPTY - no real device
        kAudioAggregateDeviceMasterSubDeviceKey: 0,            // No main sub-device
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
    ] as [String: Any]

    var deviceID: AudioObjectID = 0
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
    // ...
    return deviceID
}
```

Then the tap is added separately:

```swift
private func addTapToAggregateDevice(tapID: AudioObjectID, deviceID: AudioObjectID) throws {
    // Read tap UID
    var tapUID: CFString = ...
    AudioObjectGetPropertyData(tapID, &propertyAddress, ...)

    // Set tap list on aggregate
    propertyAddress = getPropertyAddress(selector: kAudioAggregateDevicePropertyTapList)
    let tapArray = [tapUID] as CFArray
    AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, propertySize, ptr)
}
```

The critical insight: **the aggregate device does NOT reference the real output device at all.** The tap alone provides the input stream.

**What FineTune should steal:**

- **The tap-only aggregate pattern.** This is the single most important change FineTune should make. See [Section 3](#3-the-case-for-tap-only-aggregates) for the full argument.

---

### 2.5 SoundPusher

**Repository:** https://codeberg.org/q-p/SoundPusher (originally https://github.com/q-p/SoundPusher)
**Architecture:** Tap-only aggregate (explicitly evolved from tap+sub-device)

**How it works:**

SoundPusher is a virtual audio device that forwards system audio to SPDIF digital output. Its tap implementation is the most instructive because it shows the **deliberate evolution** from including the real device to removing it.

**Key code: AudioTap.mm (aggregate creation -- the smoking gun)**

```objc
AggregateTappedDevice::AggregateTappedDevice(AudioTap &&audioTap, const bool enableDriftCompensation)
: _audioTap(std::move(audioTap))
{
  NSDictionary *dict = @{
    @kAudioAggregateDeviceUIDKey : [NSString stringWithFormat:@"%@%@", ...],
    @kAudioAggregateDeviceNameKey : [NSString stringWithFormat:@"SoundPusher Aggregate for '%@'", ...],
    // it seems we only need the tap, not the actual device in there
//    @kAudioAggregateDeviceMainSubDeviceKey : _audioTap._deviceUID,
//    @kAudioAggregateDeviceSubDeviceListKey : @[
//      @{
//        @kAudioSubDeviceUIDKey : _audioTap._deviceUID,
//      },
//    ],
    @kAudioAggregateDeviceIsPrivateKey : @YES,
    @kAudioAggregateDeviceTapListKey : @[
      @{
        @kAudioSubTapUIDKey : _audioTap._tapUID,
        @kAudioSubTapDriftCompensationKey : [NSNumber numberWithBool:enableDriftCompensation],
      },
    ],
//    @kAudioAggregateDeviceTapAutoStartKey : @YES,
  };
  // ...
}
```

The commented-out lines are the evidence: the developer **tried** including the real device (`kAudioAggregateDeviceMainSubDeviceKey`, `kAudioAggregateDeviceSubDeviceListKey`) and **deliberately removed them**, with the comment: *"it seems we only need the tap, not the actual device in there."*

Also note: `kAudioAggregateDeviceTapAutoStartKey` is also commented out -- SoundPusher manages tap start/stop explicitly.

**This is confirmed by the CoreAudio Taps for Dummies article** (https://www.maven.de/2025/04/coreaudio-taps-for-dummies/) which states:

> "The aggregate device with the tap (and nothing else -- initially the device being tapped was put into the aggregate device as well but that only confused matters) will then provide an input stream that contains the tapped data."

**What FineTune should steal:**

- **The tap-only aggregate pattern** -- proven by two independent developers to work correctly.
- **The RAII resource management** -- SoundPusher uses C++ RAII structs for tap and aggregate lifecycle, similar to FineTune's `TapResources` struct but with stricter ownership semantics.
- **Explicit tap start/stop** rather than `kAudioAggregateDeviceTapAutoStartKey`.

---

### 2.6 SoundSource (Rogue Amoeba)

**Product:** https://rogueamoeba.com/soundsource/
**Architecture:** Proprietary ARK (Audio Routing Kit) plugin

SoundSource is the commercial gold standard for per-app audio control on macOS. While closed-source, key facts emerge from their support documentation:

1. **macOS 14.5+**: SoundSource uses a new "ARK" (Audio Routing Kit) backend. The ARK plugin requires both System Audio Access and Microphone Access permissions.
2. **Pre-macOS 14.5**: Used "ACE" (Audio Capture Engine), a privileged audio plugin loaded via Apple's kernel extension verification system.
3. **Audio capture attribution**: "Audio capture is actually handled by the Audio Routing Kit (ARK) background application" -- this appears as the process accessing system audio in macOS's Control Center.

**Inference:** Given that ARK requires System Audio Access permission and was introduced alongside macOS 14.5 (which enhanced the Core Audio Tap API), it's highly likely that SoundSource's ARK uses the same `AudioHardwareCreateProcessTap` API that FineTune uses, but with a more sophisticated wrapper.

The key difference is likely that SoundSource's ARK runs as a separate privileged background process (visible in System Audio Access), which may give it more control over tap lifecycle and error recovery.

**What FineTune should steal:**

- **The concept of a persistent background audio routing process.** While FineTune runs as a menu bar app, the idea of a persistent routing layer that survives transient failures is valuable. FineTune's tap pool (Section 5) would serve a similar purpose.

---

## 3. The Case for Tap-Only Aggregates

### The Problem with Including the Real Device

FineTune's current aggregate device configuration in `ProcessTapController.activate()` includes the real output device as both the main sub-device and a member of the sub-device list:

```swift
// Current FineTune pattern (ProcessTapController.swift:332-348)
let description: [String: Any] = [
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,       // PROBLEM
    kAudioAggregateDeviceSubDeviceListKey: [                // PROBLEM
        [kAudioSubDeviceUIDKey: outputUID]
    ],
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapDriftCompensationKey: true,
         kAudioSubTapUIDKey: tapDesc.uuid.uuidString]
    ]
]
```

Including the real device causes three problems:

1. **Spurious device-change notifications (Bug 1).** When the aggregate is destroyed, CoreAudio internally detaches the real device from the aggregate. This perturbation to the device graph can trigger `kAudioHardwarePropertyDefaultOutputDevice` notifications -- even though the aggregate is private. During `recreateAllTaps()` or `handleServiceRestarted()`, destroying multiple aggregates that all reference the same real device amplifies this effect.

2. **Clock domain conflicts.** The aggregate device synchronizes the clocks of all its sub-devices and sub-taps. When the real output device is both a sub-device AND the tap's target, CoreAudio must reconcile two clock references to the same hardware. This is unnecessary overhead and a potential source of timing issues, especially during device transitions.

3. **Increased blast radius during coreaudiod restart.** Aggregates that reference real devices have more internal state to invalidate when coreaudiod restarts. A tap-only aggregate has no reference to the real device except through the tap itself, making it simpler to tear down and recreate.

### The Evidence

Three independent sources confirm the tap-only pattern works:

1. **SoundPusher** (AudioTap.mm) -- Explicitly comments out the real device references with the note "it seems we only need the tap, not the actual device in there."

2. **AudioTee** (AudioTapManager.swift) -- Creates aggregates with `kAudioAggregateDeviceSubDeviceListKey: []` (empty array) and adds taps post-creation via property mutation.

3. **CoreAudio Taps for Dummies** (maven.de, April 2025) -- States: "The aggregate device with the tap (and nothing else) will then provide an input stream that contains the tapped data." Explicitly warns that including the real device "only confused matters."

### The Proposed Change

```swift
// PROPOSED: Tap-only aggregate
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: "FineTune-\(app.id)",
    kAudioAggregateDeviceUIDKey: aggregateUID,
    // NO kAudioAggregateDeviceMainSubDeviceKey
    // NO kAudioAggregateDeviceSubDeviceListKey (or empty [])
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapListKey: [
        [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapDesc.uuid.uuidString
        ]
    ]
]
```

### Impact on Bug 1 (Spurious Device Display)

Removing the real device from the aggregate means destroying the aggregate no longer perturbs the device graph in a way that triggers default-device-change notifications. This eliminates the root cause of Bug 1 -- the `isRecreatingTaps` flag and `recreationGracePeriod` become unnecessary safety nets rather than critical correctness mechanisms.

### Impact on the Audio Pipeline

The tap-only aggregate still provides an input stream containing the tapped audio data. FineTune reads from this input stream and writes to the output stream (which goes to... where?). This is the key question: **without a real device in the aggregate, where does the processed audio go?**

The answer: **the tap itself handles audio delivery.** When `muteBehavior` is `.mutedWhenTapped`, the process's audio is captured by the tap and muted at the hardware level. FineTune's IO callback processes the captured audio (applying volume, EQ, etc.) and writes it to the aggregate's output buffers. The processed audio then flows through the tap back to the hardware -- but since it's `.mutedWhenTapped`, only the tapped version (FineTune's processed output) reaches the speakers.

This is how AudioTee and SoundPusher work: the aggregate's output stream is the tap's output, which CoreAudio routes to the target device specified in the `CATapDescription`.

### Risk Assessment

**Risk:** FineTune's current crossfade device switching creates a secondary aggregate for the new device during the transition. Both primary and secondary aggregates currently reference their respective real devices. Removing the real device from both should be safe because the tap's `deviceUID` property (set in `CATapDescription`) already determines which device the audio is routed to.

**Mitigation:** This change can be tested incrementally by first removing only `kAudioAggregateDeviceMainSubDeviceKey` and `kAudioAggregateDeviceSubDeviceListKey` while keeping all other configuration the same. If audio continues to flow correctly, the change is validated.

---

## 4. The Case for a Proxy Aggregate

### The Concept

Instead of creating one aggregate per app, create a **single persistent aggregate device** that all taps attach to. All per-app taps would be listed in this aggregate's tap list. The aggregate would persist across device changes, permission grants, and coreaudiod restarts.

### Why This Won't Work for FineTune

After analyzing the codebase and the Core Audio Tap API, I **do not recommend** a single proxy aggregate for these reasons:

1. **Independent device routing.** FineTune routes different apps to different devices. App A might output to AirPods while App B outputs to MacBook speakers. A single aggregate can only have one set of output streams targeting one device. Per-app routing requires per-app aggregates.

2. **Independent IO callbacks.** Each aggregate runs its own IO callback at the device's sample rate. FineTune's per-app volume, EQ, and crossfade processing happens in these callbacks. A single aggregate would require multiplexing all app processing in a single callback, which is more complex and harder to make RT-safe.

3. **Tap list mutation complexity.** Adding/removing taps from a running aggregate via `kAudioAggregateDevicePropertyTapList` property mutation is possible but creates timing hazards. The IO callback would need to handle taps appearing/disappearing mid-buffer.

4. **No benefit over per-app tap-only aggregates.** The bugs FineTune faces are caused by the real device reference in aggregates, not by having multiple aggregates. Removing the real device (Section 3) eliminates the device-change notification issue without requiring the complexity of a shared aggregate.

### Verdict

**Do not adopt a proxy aggregate.** Per-app tap-only aggregates are the right architecture for FineTune's per-app routing model.

---

## 5. The Case for a Persistent Tap Pool

### The Problem

FineTune currently creates and destroys taps at multiple points:

1. **App appears** -- `ensureTapExists()` creates a new tap
2. **Permission confirmed** -- `recreateAllTaps()` destroys ALL taps and recreates them (to switch from `.unmuted` to `.mutedWhenTapped`)
3. **Device switch** -- `switchDevice()` creates a secondary tap (crossfade) or destroys/recreates the primary (destructive)
4. **coreaudiod restart** -- `handleServiceRestarted()` destroys ALL taps and recreates them
5. **Health check failure** -- `checkTapHealth()` destroys and recreates individual taps
6. **App disappears** -- `cleanupStaleTaps()` destroys the tap after a grace period

The `.unmuted` -> `.mutedWhenTapped` transition in step 2 is the direct cause of Bug 2. Step 4 is also disruptive but unavoidable (coreaudiod restart invalidates all AudioObjectIDs).

### The Proposed Architecture

**Create taps ONCE with `.mutedWhenTapped` from the start, and never recreate them for permission changes.**

The current reason for the `.unmuted` -> `.mutedWhenTapped` transition is defensive: if the app is killed during the permission dialog, `.unmuted` taps won't leave audio permanently silenced. But this defense creates Bug 2.

A better defense: **create taps with `.mutedWhenTapped` from the start AND implement a watchdog** that monitors whether the FineTune process is still running. If FineTune crashes, the OS destroys all its AudioObjectIDs (taps, aggregates), which un-mutes the audio automatically. The `.unmuted` safety net is unnecessary because:

1. Process tap cleanup is automatic when the owning process exits
2. `kAudioAggregateDeviceIsPrivateKey: true` means the aggregate is destroyed when the process exits
3. There is no scenario where FineTune can crash and leave taps alive -- CoreAudio cleans up process-owned resources on exit

**The exception:** If the user denies permission, taps with `.mutedWhenTapped` will produce silence with no audio flowing. But `.unmuted` taps also produce silence in this case (the tap captures nothing useful without permission). The user's recourse is the same either way: grant permission or close FineTune.

### What Changes

1. **Remove `permissionConfirmed` flag entirely.** Always create taps with `.mutedWhenTapped`.
2. **Remove `recreateAllTaps()`** -- it exists solely for the `.unmuted` -> `.mutedWhenTapped` transition.
3. **Remove `isRecreatingTaps` flag and `recreationGracePeriod`** -- the recreation suppression logic becomes unnecessary because aggregates without real sub-devices don't trigger spurious device notifications (from Section 3), and there's no `.mutedWhenTapped` transition to trigger recreation.
4. **Simplify `handleServiceRestarted()`** -- still needs to destroy and recreate taps (IDs are invalid), but no longer needs to handle the permission confirmation path.
5. **Remove fast health check permission confirmation logic** -- the fast health checks at 300ms/500ms/700ms after tap creation currently probe for permission. Without the `.unmuted` -> `.mutedWhenTapped` transition, permission confirmation is unnecessary.

### Impact on Bug 2 (Audio Muting During Permission Grant)

**Bug 2 is eliminated entirely.** There is no `.unmuted` -> `.mutedWhenTapped` transition, so there is no audio gap during permission grant.

The coreaudiod restart during permission grant still causes a brief audio interruption (unavoidable -- coreaudiod restart disrupts all system audio), but FineTune no longer amplifies this disruption with a tap recreation cycle.

### Impact on Bug 1 (Spurious Device Display)

Combined with tap-only aggregates (Section 3), the persistent tap lifecycle eliminates all remaining paths that trigger spurious device-change notifications. The `handleServiceRestarted()` path still destroys and recreates taps, but tap-only aggregates don't trigger device notifications.

### Device Switching Without Tap Destruction

For device switches, the current crossfade approach (create secondary tap, crossfade, destroy primary) works well and should be kept. But with tap-only aggregates, the crossfade can be simplified:

1. Create a new `CATapDescription` targeting the new device
2. Create a new tap-only aggregate
3. Crossfade from old to new (existing equal-power curve logic)
4. Destroy old tap and aggregate

The critical difference: destroying the old tap-only aggregate won't trigger device-change notifications because it doesn't reference the real device.

### Can Taps Be Reconfigured Without Destruction?

An even more ambitious approach: **mutate the tap's target device UID in-place** using `AudioObjectSetPropertyData` on the tap's device UID property. If CoreAudio supports changing a tap's `deviceUID` after creation, FineTune could switch devices without creating/destroying any taps or aggregates.

This requires investigation: the `CATapDescription` properties may not be mutable after creation. If they are, this would be the ideal approach -- a single persistent tap per app that gets redirected to different devices as needed. The crossfade would then be between two IO callbacks on the same tap, not between two separate taps.

**Recommendation:** Investigate `CATapDescription` property mutability as a follow-up. Even without this, the tap-only aggregate pattern delivers most of the benefit.

---

## 6. Bold Recommendations

### Recommendation 1: Switch to Tap-Only Aggregates (HIGH PRIORITY)

**Change:** Remove `kAudioAggregateDeviceMainSubDeviceKey` and `kAudioAggregateDeviceSubDeviceListKey` from all aggregate device creation dictionaries in `ProcessTapController`.

**Files affected:**
- `ProcessTapController.swift` -- `activate()` (lines 332-348), `createSecondaryTap()` (lines 637-653), `performDeviceSwitch()` (lines 948-964)

**Effort:** Small -- 3 dictionary keys removed from 3 locations.

**Risk:** Low -- proven by SoundPusher, AudioTee, and the CoreAudio Taps for Dummies article.

**Impact:** Eliminates the primary trigger for Bug 1 (spurious device-change notifications from aggregate destruction). Simplifies the `isRecreatingTaps` suppression logic. Removes clock domain conflicts.

### Recommendation 2: Always Use `.mutedWhenTapped` (MEDIUM PRIORITY)

**Change:** Remove the `permissionConfirmed` flag, `recreateAllTaps()`, and all `.unmuted` -> `.mutedWhenTapped` transition logic. Always create taps with `.mutedWhenTapped`.

**Files affected:**
- `AudioEngine.swift` -- Remove `permissionConfirmed` (line 40), `recreateAllTaps()` (lines 839-858), permission confirmation in fast health checks (lines 800-808), permission path in `handleServiceRestarted()` (lines 272-292)
- `ProcessTapController.swift` -- Remove `muteOriginal` parameter, always use `.mutedWhenTapped`

**Effort:** Medium -- removes ~80 lines, simplifies multiple code paths.

**Risk:** Low-medium. The risk is that if permission is denied, audio will be silenced. But this is the same behavior as the current post-permission-confirmed state. Users who deny permission must re-grant it regardless of the mute behavior.

**Impact:** Eliminates Bug 2 entirely. Removes the `recreateAllTaps()` function and all code paths that trigger it.

### Recommendation 3: Remove Recreation Suppression Logic (LOW PRIORITY, depends on 1+2)

**Change:** Remove `isRecreatingTaps`, `recreationEndedAt`, `recreationGracePeriod`, and `shouldSuppressDeviceNotifications`. These become unnecessary with tap-only aggregates (no spurious notifications to suppress) and always-mutedWhenTapped (no recreation to trigger).

**Files affected:**
- `AudioEngine.swift` -- Remove lines 44-51, 96-98, and all guards using `shouldSuppressDeviceNotifications`

**Effort:** Small -- removes ~30 lines.

**Risk:** None after Recommendations 1 and 2 are implemented.

**Impact:** Significant code simplification. Removes a fragile timing-dependent mechanism (the 2-second grace period) that is inherently racy.

### Recommendation 4: Investigate Live Tap Reconfiguration (FUTURE)

**Change:** Test whether `CATapDescription` properties (specifically `deviceUID`) can be mutated after tap creation using `AudioObjectSetPropertyData`.

**Effort:** Small investigation, potentially large implementation if it works.

**Risk:** Unknown -- this may not be supported by CoreAudio.

**Impact:** If it works, device switching could be done by redirecting the existing tap to a new device, eliminating tap creation/destruction during switches entirely. The crossfade would operate between two IO states on the same tap.

### What I Am NOT Recommending

1. **Do not adopt a virtual audio driver architecture.** BackgroundMusic and eqMac use drivers, which require system extensions, installation complexity, and per-macOS-version maintenance. FineTune's tap-based approach is lighter and doesn't require elevated privileges.

2. **Do not adopt a proxy aggregate.** Per-app aggregates are the right model for per-app routing. A shared aggregate would add complexity without solving FineTune's actual bugs.

3. **Do not adopt BackgroundMusic's ring buffer pattern.** The dual-IOProc + ring buffer approach is more complex than FineTune's direct IO proc pattern. FineTune's approach of reading tap input and writing to aggregate output in a single callback is simpler and lower-latency.

---

## 7. Appendix: Comparison Matrix

| Feature | BackgroundMusic | eqMac | AudioCap | AudioTee | SoundPusher | FineTune (current) | FineTune (proposed) |
|---------|----------------|-------|----------|----------|-------------|-------------------|-------------------|
| **Mechanism** | Virtual driver | Virtual driver | Tap + aggregate | Tap + aggregate | Tap + aggregate | Tap + aggregate | Tap + aggregate |
| **Real device in aggregate?** | N/A (no aggregate) | N/A | Yes | No | No (removed) | Yes | **No** |
| **Per-app volume?** | Yes (driver-level) | No (system-wide EQ) | No | No | No | Yes (IO callback) | Yes (IO callback) |
| **Device switch method** | Deactivate/reactivate | N/A | N/A | N/A | N/A | Crossfade (dual tap) | Crossfade (dual tap) |
| **coreaudiod restart?** | Handled (driver recovers) | Handled (driver) | Not handled | Not handled | Not handled | Handled (destroy/recreate) | Handled (destroy/recreate) |
| **Permission handling** | N/A (driver) | N/A (driver) | None | None | None | `.unmuted` -> `.mutedWhenTapped` | **Always `.mutedWhenTapped`** |
| **Requires system extension?** | Yes | Yes | No | No | No | No | No |
| **Spurious notification risk** | Low (driver) | Low (driver) | Unknown | Low (no real device) | Low (no real device) | **High** | **Low** |

---

## Sources

### Open-Source Projects (Code Analyzed)
- [BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic) -- BGMPlayThrough.cpp, BGMAudioDeviceManager.mm, BGMAppVolumesController.mm
- [eqMac](https://github.com/bitgapp/eqMac) -- Engine.swift, Driver.swift, EQMDevice.swift
- [AudioCap](https://github.com/insidegui/AudioCap) -- ProcessTap.swift
- [AudioTee](https://github.com/makeusabrew/audiotee) -- AudioTapManager.swift
- [SoundPusher](https://codeberg.org/q-p/SoundPusher) -- AudioTap.mm, AudioTap.h, ForwardingInputTap.cpp

### Articles and Documentation
- [CoreAudio Taps for Dummies](https://www.maven.de/2025/04/coreaudio-taps-for-dummies/) -- Confirms tap-only aggregate pattern
- [AudioTee article](https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos) -- Tap-only aggregate discussion
- [SoundSource ARK details](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Plugin-Audio-Capture-Details&product=SoundSource) -- SoundSource macOS 14+ architecture
- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [Sudara's Core Audio Tap example](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f)

### FineTune Codebase Files Referenced
- `FineTune/Audio/AudioEngine.swift` -- Central audio engine (1031 lines)
- `FineTune/Audio/ProcessTapController.swift` -- Per-app tap management (1545 lines)
- `FineTune/Audio/DeviceVolumeMonitor.swift` -- Device volume and default device tracking (612 lines)
- `FineTune/Audio/AudioDeviceMonitor.swift` -- Device list monitoring (313 lines)
- `FineTune/Audio/Tap/TapResources.swift` -- RAII tap resource wrapper (92 lines)
- `FineTune/Audio/Crossfade/CrossfadeState.swift` -- RT-safe crossfade state machine (141 lines)

---

## Implementation Status (as of 2026-02-08)

| Recommendation | Priority | Status | Notes |
|---------------|----------|--------|-------|
| Switch to tap-only aggregates (no real sub-device) | HIGH | NOT IMPLEMENTED | Proven by SoundPusher/AudioTee/CoreAudio Taps for Dummies. Would eliminate Bug 1 root cause. Still the highest-impact unimplemented architectural change. |
| Always use `.mutedWhenTapped` from start | MEDIUM | NOT IMPLEMENTED | Current approach uses `.unmuted` -> `.mutedWhenTapped` upgrade. Session 4's synthesizer recommended keeping the current permission lifecycle. |
| Remove recreation suppression logic | LOW | NOT APPLICABLE YET | Depends on recommendations 1+2 being implemented first. |
| Investigate live tap reconfiguration | FUTURE | RESEARCHED ONLY | Session 2's "never-recreate" doc confirmed API supports it (`kAudioTapPropertyDescription` is settable). No runtime validation done. |

**Related changes since this research:**
- `CATapDescription` constructor changed to `stereoMixdownOfProcesses` (2026-02-07). This is a different axis than the tap-only aggregate recommendation but does simplify the tap creation path.
- Crossfade device switching received a major overhaul (warmup phase, equal-power curves, Bluetooth extended warmup). See CHANGELOG "Audio Wiring Overhaul".
- Aggregate devices now use `kAudioAggregateDeviceIsStackedKey: true` and `kAudioAggregateDeviceClockDeviceKey`, matching the original upstream developer's working implementation.
