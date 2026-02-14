# Research: "Never Recreate" Architecture

## Executive Summary

This document investigates whether FineTune can eliminate or dramatically reduce tap/aggregate destruction and recreation. The current architecture creates one tap + one aggregate per monitored process and tears everything down on permission grant, device switch, coreaudiod restart, and health-check failure. This causes audio gaps, spurious device-change notifications, and race conditions.

**Key discovery:** The Core Audio header (`AudioHardware.h`, line 2015-2017) explicitly states:

> `kAudioTapPropertyDescription` -- "The CATapDescription used to initially create this tap. **This property can be used to modify and set the description of an existing tap.**"

This means live tap reconfiguration is an officially supported API surface. Combined with aggregate device composition updates, a "never recreate" architecture is feasible for most scenarios.

---

## 1. Live Tap Reconfiguration

### 1.1 API Evidence

The macOS SDK header (`CoreAudio/AudioHardware.h`) defines:

```c
kAudioTapPropertyDescription = 'tdsc'
```

Documentation: "The CATapDescription used to initially create this tap. This property can be used to **modify and set the description** of an existing tap."

This is a settable property (can be verified at runtime with `AudioObjectIsPropertySettable`). The workflow would be:

```swift
// 1. Get current description
var desc: CATapDescription = /* AudioObjectGetPropertyData(tapID, &address, ...) */

// 2. Modify the description
desc.muteBehavior = .mutedWhenTapped  // or change processes, deviceUID, etc.

// 3. Set it back
AudioObjectSetPropertyData(tapID, &address, 0, nil, size, &desc)
```

### 1.2 What Can Be Changed on a Live Tap

Based on `CATapDescription.h`, all properties are `readwrite`:

| Property | Type | Live Change? | Impact |
|----------|------|-------------|--------|
| `muteBehavior` | `CATapMuteBehavior` | **YES (via kAudioTapPropertyDescription)** | Eliminates recreation for permission grant |
| `processes` | `[NSNumber]` (AudioObjectIDs) | **YES** | Tap reassignment to different PIDs |
| `deviceUID` | `String?` | **YES** | Eliminates recreation for device switches |
| `stream` | `NSNumber?` | **YES** | Stream index changes |
| `mono` | `Bool` | **YES** | Mixdown mode changes |
| `exclusive` | `Bool` | **YES** | Include/exclude mode toggle |
| `mixdown` | `Bool` | **YES** | Stereo/mono mixdown toggle |
| `privateTap` | `Bool` | **YES** | Visibility changes |
| `bundleIDs` | `[String]` | **YES** (macOS 26+) | Target by bundle ID instead of PID |
| `processRestoreEnabled` | `Bool` | **YES** (macOS 26+) | Auto-restore tapped processes |

### 1.3 Critical Implications

**Permission grant (`unmuted` -> `mutedWhenTapped`):** Instead of destroying and recreating all taps via `recreateAllTaps()`, FineTune could simply update each tap's description:

```swift
// Current: destroy all + recreate (causes audio gap + spurious notifications)
recreateAllTaps()

// Proposed: live reconfigure (no audio gap, no notifications)
for (pid, tap) in taps {
    var desc = tap.tapDescription
    desc.muteBehavior = .mutedWhenTapped
    AudioObjectSetPropertyData(tap.tapID, &address, 0, nil, size, &desc)
}
```

**Device switch:** Instead of creating a secondary tap+aggregate and crossfading, the tap's `deviceUID` could be updated in-place. The aggregate's sub-device list would also need updating (see Section 2).

### 1.4 Unknowns and Risks

- **Glitch behavior:** The header says the property is settable, but does not document whether changing `deviceUID` on a running tap causes a glitch, a brief mute, or is truly seamless. This must be tested empirically.
- **Format change:** If the new device has a different sample rate or channel layout, the tap format (`kAudioTapPropertyFormat`) will change. The IO proc callback must handle format transitions gracefully.
- **Timing:** When does the change take effect? Immediately? At the next buffer boundary? After the current IO cycle completes?
- **Thread safety:** Is `AudioObjectSetPropertyData` safe to call while the IO proc is running? Core Audio generally handles this internally, but it must be verified.

### 1.5 macOS 26 (Tahoe) New APIs

The macOS 26 SDK adds two significant new properties to `CATapDescription`:

1. **`bundleIDs`** (`[String]`): Target processes by bundle ID instead of AudioObjectID. This survives process restarts -- no need to re-resolve PIDs.
2. **`processRestoreEnabled`** (`Bool`): When true, the system automatically re-adds processes to the tap when they restart. This eliminates the need for FineTune to monitor process lifecycle for tap management.

These are game-changers for the "never recreate" architecture: a tap created with `bundleIDs` + `processRestoreEnabled = true` would survive app restarts without any intervention.

---

## 2. Aggregate Device Hot-Reconfiguration

### 2.1 API Surface

The aggregate device has several settable properties:

| Property | Selector | Settable? | Notes |
|----------|----------|-----------|-------|
| `kAudioAggregateDevicePropertyComposition` | `'acom'` | **Likely YES** | Full device composition as CFDictionary |
| `kAudioAggregateDevicePropertyFullSubDeviceList` | `'grup'` | **Uncertain** | CFArray of sub-device UIDs |
| `kAudioAggregateDevicePropertyMainSubDevice` | `'amst'` | **Uncertain** | Main sub-device UID |
| `kAudioAggregateDevicePropertyClockDevice` | `'apcd'` | **YES** (confirmed by CAAudioHardware library) | Clock source UID |
| `kAudioAggregateDevicePropertyTapList` | `'tap#'` | **Likely YES** | CFArray of tap UUIDs |

### 2.2 Composition Update Strategy

The most promising approach is using `kAudioAggregateDevicePropertyComposition` to update the entire aggregate device configuration in one atomic operation:

```swift
let newComposition: [String: Any] = [
    kAudioAggregateDeviceUIDKey: existingUID,
    kAudioAggregateDeviceNameKey: existingName,
    kAudioAggregateDeviceMainSubDeviceKey: newOutputDeviceUID,  // changed
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: newOutputDeviceUID]  // changed
    ],
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: existingTapUUID, kAudioSubTapDriftCompensationKey: true]
    ]
]
AudioObjectSetPropertyData(aggregateDeviceID, &compositionAddress, 0, nil, size, &newComposition)
```

### 2.3 Sub-Device Hot-Swap for Device Switching

If composition updates work while IO is running, device switching becomes:

1. Update tap's `deviceUID` via `kAudioTapPropertyDescription`
2. Update aggregate's sub-device list and main sub-device via `kAudioAggregateDevicePropertyComposition`
3. No destruction, no recreation, no crossfade needed

### 2.4 Risks

- **IO interruption:** Changing the main sub-device may cause the aggregate to briefly stop its IO proc while reconfiguring. This could cause a click/pop.
- **Sample rate mismatch:** If old device was 44.1kHz and new is 48kHz, the aggregate's nominal sample rate must also be updated.
- **Empirical testing required:** Apple's documentation does not specify the behavior of live composition updates. The `AudioObjectIsPropertySettable` API can be used at runtime to verify.

---

## 3. Proxy Aggregate Architecture

### 3.1 Concept

Instead of one aggregate per app, use a shared "proxy" aggregate per output device:

```
App A  ─── Tap A ──┐
                    ├──> Proxy Aggregate (Headphones) ──> Headphones
App B  ─── Tap B ──┘

App C  ─── Tap C ──── Proxy Aggregate (Speakers) ──> Speakers
```

When the user switches output devices, only the proxy aggregate is reconfigured (its sub-device is swapped). Individual taps never need to know about the output device.

### 3.2 Feasibility Analysis

**Can multiple taps feed into one aggregate?**

The `kAudioAggregateDeviceTapListKey` accepts a CFArray of tap dictionaries, suggesting multiple taps can be included. However:

- Each tap is its own stream in the aggregate. The aggregate would have N input streams (one per tap).
- Per-app volume would still work: each tap's IO callback processes its own audio independently.
- The aggregate's output streams would need to mix the tap inputs. This may happen automatically if the taps are targeting the same output device.

**Constraints:**

- Per-app device routing (App A -> headphones, App B -> speakers) requires separate proxy aggregates per output device. This is compatible with the model.
- If all apps are on the same device, only one proxy aggregate exists. Device switch reconfigures that one aggregate instead of N separate ones.
- The proxy aggregate approach reduces the number of aggregate devices from N (one per app) to M (one per output device, typically 1-2).

### 3.3 Evaluation

**Pros:**
- Dramatically reduces the number of aggregate devices
- Device switch is O(1) instead of O(N) -- reconfigure one proxy instead of N aggregates
- Fewer aggregate devices means fewer spurious device-change notifications

**Cons:**
- Multiple taps in one aggregate is not well-documented
- Per-app volume still requires separate IO callbacks or multi-stream processing
- The current crossfade logic assumes one tap per aggregate; significant refactoring needed
- If one tap in the aggregate breaks, it could affect all apps sharing that proxy

**Verdict:** Promising for reducing aggregate count but requires significant validation. The single-tap-per-aggregate model is simpler and better understood. The proxy approach is a v2 optimization, not a v1 priority.

---

## 4. Tap Pool Architecture

### 4.1 Concept

Pre-create N taps at startup (or after permission grant). When a new app starts playing, assign an idle tap to its PID. When the app stops, return the tap to the pool (don't destroy it).

### 4.2 Feasibility

**Can a tap's target process be changed after creation?**

YES. Per Section 1, the `processes` property on `CATapDescription` is `readwrite`, and `kAudioTapPropertyDescription` is settable. A pool tap could be re-targeted:

```swift
var desc = poolTap.description
desc.processes = [NSNumber(value: newApp.objectID)]
AudioObjectSetPropertyData(poolTap.tapID, &address, 0, nil, size, &desc)
```

**Can you create a tap with no target?**

Unclear. A tap with an empty `processes` array may fail to create, or it may create but produce silence. The `initStereoMixdownOfProcesses:` initializer requires a non-empty array. However, you could create a tap targeting a known idle process (e.g., the FineTune app itself) as a placeholder.

### 4.3 Evaluation

**Pros:**
- Tap creation is expensive and can fail. Pre-creating eliminates creation latency.
- Tap destruction triggers coreaudiod notifications. Pooling avoids this.
- Pool taps can be pre-warmed (IO proc already running).

**Cons:**
- Each tap requires an aggregate device. Pooling taps also means pooling aggregates.
- The aggregate's sub-device (output device) may need updating when the tap is assigned.
- Pool size management: how many taps to pre-create? Too many wastes resources, too few and you still need to create on-demand.
- macOS 26's `processRestoreEnabled` and `bundleIDs` make pools less necessary -- the system handles process lifecycle automatically.

**Verdict:** Useful optimization for pre-macOS 26, but the live reconfiguration approach (Section 1) achieves the same benefits more elegantly. Consider pooling only if tap creation latency is measured to be a problem.

---

## 5. coreaudiod Restart Survival

### 5.1 What Happens During a Restart

When coreaudiod restarts (e.g., after granting system audio permission, or a crash):

1. **All AudioObjectIDs become invalid.** Every tap, aggregate, device, and stream ID is invalidated.
2. **`kAudioHardwarePropertyServiceRestarted` fires** as a notification.
3. **There is NO pre-restart notification.** The notification fires AFTER the restart, when the new coreaudiod instance is ready.
4. **No objects survive.** All taps, aggregates, and IO procs must be fully recreated.

### 5.2 Timing Guarantees

The `kAudioHardwarePropertyServiceRestarted` notification fires when the new coreaudiod is ready to accept connections. However:

- There may be a delay before all devices are enumerated
- Bluetooth devices may take additional time to reconnect
- Creating taps immediately after the notification can fail if coreaudiod is still initializing

FineTune currently uses a 1500ms stabilization delay (`serviceRestartDelay`) after the notification, which is reasonable.

### 5.3 Can Recreation Be Avoided?

**No.** coreaudiod restarts are the one scenario where full recreation is unavoidable. All AudioObjectIDs are invalidated by the kernel, and there is no mechanism to "re-register" existing objects.

However, the recreation can be **faster and smoother** with the live reconfiguration approach:

1. Create taps with correct `muteBehavior` from the start (if `permissionConfirmed` is persisted)
2. Use `bundleIDs` + `processRestoreEnabled` (macOS 26+) so taps auto-restore
3. Skip the two-phase `.unmuted` -> probe -> `.mutedWhenTapped` dance

### 5.4 macOS 26 Improvement

With `processRestoreEnabled`, coreaudiod may be able to restore taps automatically after restart, since the tap configuration (via bundle IDs) is declarative rather than imperative. This needs testing but could eliminate manual recreation entirely on macOS 26+.

---

## 6. Tap-Only Aggregates

### 6.1 Current Architecture (FineTune)

FineTune includes the real output device as a sub-device in its aggregates:

```swift
kAudioAggregateDeviceSubDeviceListKey: [
    [kAudioSubDeviceUIDKey: outputUID]  // Real device included
],
kAudioAggregateDeviceTapListKey: [
    [kAudioSubTapUIDKey: tapUUID, kAudioSubTapDriftCompensationKey: true]
]
```

### 6.2 AudioTee Architecture (Tap-Only)

AudioTee uses aggregates with ONLY the tap -- no real output device:

```swift
kAudioAggregateDeviceTapListKey: [
    [kAudioSubTapUIDKey: tapUUID, kAudioSubTapDriftCompensationKey: true]
]
// No kAudioAggregateDeviceSubDeviceListKey
```

### 6.3 Functional Differences

| Aspect | FineTune (device + tap) | AudioTee (tap only) |
|--------|------------------------|---------------------|
| **Audio reaches output** | Via aggregate's sub-device routing | Via original unmuted tap (audio plays through system) |
| **Volume control** | Gain applied in IO callback, output via aggregate | Capture only, no volume control |
| **Mute behavior** | `.mutedWhenTapped` -- audio only goes through aggregate | `.unmuted` -- audio plays through system AND is captured |
| **Device change notifications** | Destroying aggregate fires notifications (has real sub-device) | Destroying aggregate may fire fewer notifications (tap only) |
| **Aggregate device appears in device list** | May appear as output device briefly during teardown | Less likely to appear (no real output device) |

### 6.4 Does Including the Real Device Cause Spurious Notifications?

**Likely yes.** When FineTune destroys an aggregate that includes a real output device as a sub-device, coreaudiod processes the removal of that sub-device from the aggregate's internal routing. This can trigger `kAudioHardwarePropertyDefaultOutputDevice` change notifications because:

1. The aggregate was briefly the "real" path for audio to that device
2. Removing the sub-device causes coreaudiod to re-evaluate the default output routing
3. This fires false "device changed" events that FineTune must suppress with `isRecreatingTaps` and `recreationGracePeriod`

### 6.5 Could FineTune Use Tap-Only Aggregates?

**Yes, but with tradeoffs:**

- FineTune uses `.mutedWhenTapped`, which means the original audio path is silenced. The aggregate's output (via its sub-device) is the ONLY path for audio to reach the speakers.
- With a tap-only aggregate, there would be no sub-device to route audio to the speakers. FineTune would need to:
  1. Create a separate output path (e.g., a second aggregate or direct device IO) to write processed audio to the output device
  2. OR change to a model where the tap captures audio, processes it, and writes it to the output device independently

This is a more complex architecture but could eliminate the spurious notification problem entirely.

### 6.6 Recommendation

Switching to tap-only aggregates is a significant architectural change. The simpler path is to use live reconfiguration (Section 1) to avoid destruction entirely, which also eliminates the spurious notifications without changing the aggregate model.

---

## 7. State Machine Redesign

### 7.1 Current Recreation Triggers

| Event | Current Action | Frequency | Can Be Eliminated? |
|-------|---------------|-----------|-------------------|
| **Permission grant** (`.unmuted` -> `.mutedWhenTapped`) | `recreateAllTaps()` | Once per session | **YES** -- live update `muteBehavior` via `kAudioTapPropertyDescription` |
| **Device switch** (user picks new output) | Create secondary tap + crossfade + destroy primary | Per user action | **MAYBE** -- live update `deviceUID` + aggregate composition (needs testing) |
| **coreaudiod restart** | `handleServiceRestarted()` -- destroy all + recreate | Rare (permission grant, crash) | **NO** -- all IDs invalidated by kernel |
| **Health check: stalled tap** | Destroy + recreate single tap | Occasional | **MAYBE** -- try live reconfigure first, recreate only if that fails |
| **Health check: broken tap** | Destroy + recreate single tap | Occasional | **MAYBE** -- try live reconfigure first |
| **Fast health check: broken** | Destroy + recreate single tap | After creation | **MAYBE** -- try live reconfigure first |
| **App exit** (stale tap cleanup) | Destroy tap after grace period | Per app exit | **MAYBE** -- with macOS 26 `processRestoreEnabled`, keep tap alive |
| **Device disconnected** | Route to fallback via `setDevice` (crossfade/destroy) | Per device disconnect | **MAYBE** -- live update deviceUID + aggregate |

### 7.2 Proposed State Machine

```
                        ┌─────────────────────────────┐
                        │           IDLE              │
                        │  (tap created, IO running)  │
                        └──────────┬──────────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                    │
    ┌─────────▼──────┐  ┌─────────▼──────┐  ┌─────────▼──────┐
    │  RECONFIGURE   │  │  CROSSFADE     │  │  RECREATE      │
    │  (live update) │  │  (device sw.)  │  │  (full reset)  │
    │                │  │                │  │                │
    │ muteBehavior   │  │ dual-tap xfade │  │ destroy + new  │
    │ deviceUID      │  │ (if live fails)│  │                │
    │ processes      │  │                │  │ Triggers:      │
    │                │  │                │  │ - coreaudiod   │
    └───────┬────────┘  └───────┬────────┘  │   restart      │
            │                   │           │ - live reconf  │
            │                   │           │   fails AND    │
            └───────────┬───────┘           │   crossfade    │
                        │                   │   fails        │
                        ▼                   └───────┬────────┘
                ┌───────────────┐                   │
                │    IDLE       │◄──────────────────┘
                └───────────────┘
```

### 7.3 Decision Flow for Device Switch

```
Device switch requested
    │
    ├── Try: Live reconfigure tap (deviceUID) + aggregate (composition)
    │   ├── Success? → IDLE (no audio gap, no notifications)
    │   └── Fail?
    │       ├── Try: Crossfade switch (current dual-tap approach)
    │       │   ├── Success? → IDLE (50ms crossfade, minimal gap)
    │       │   └── Fail?
    │       │       └── Destructive switch (silence + destroy + recreate)
    │       │           └── IDLE (100ms+ gap)
```

### 7.4 Decision Flow for Permission Grant

```
Permission confirmed (audio flowing)
    │
    ├── Try: Live reconfigure all taps (muteBehavior → .mutedWhenTapped)
    │   ├── Success? → IDLE (zero audio gap!)
    │   └── Fail? → recreateAllTaps() (current behavior, ~200ms gap)
```

### 7.5 Minimal Recreation Set

After implementing live reconfiguration, the only events that **truly require** full tap+aggregate destruction and recreation are:

1. **coreaudiod restart** -- unavoidable, all IDs are invalidated
2. **Live reconfiguration failure** -- fallback when the API returns an error
3. **Sample rate incompatibility** -- if the new device cannot process the tap's format and reconfiguration doesn't handle it

Everything else can be handled by live reconfiguration or crossfade.

---

## 8. Implementation Roadmap

### Phase 1: Validate Live Reconfiguration (Low Risk, High Impact)

1. **Write a test harness** that:
   - Creates a tap with `.unmuted`
   - Plays audio through it
   - Changes `muteBehavior` to `.mutedWhenTapped` via `kAudioTapPropertyDescription`
   - Verifies audio still flows and muting takes effect
2. **Test `deviceUID` change** on a live tap
3. **Test `processes` change** on a live tap
4. **Call `AudioObjectIsPropertySettable` at runtime** to confirm each property is settable

### Phase 2: Eliminate Permission Grant Recreation (High Impact)

Replace `recreateAllTaps()` with:
```swift
for (pid, tap) in taps {
    // Live-reconfigure muteBehavior
    var desc = tap.tapDescription
    desc.muteBehavior = .mutedWhenTapped
    let err = AudioObjectSetPropertyData(tap.tapID, &descAddress, ...)
    if err != noErr {
        // Fallback: recreate this single tap
        recreateSingleTap(pid)
    }
}
```

This eliminates the biggest source of spurious device-change notifications (the `isRecreatingTaps` flag and `recreationGracePeriod` exist solely because of this).

### Phase 3: Live Device Switching (Medium Impact, Medium Risk)

If Phase 1 validates `deviceUID` changes:
1. Update tap's `deviceUID` via `kAudioTapPropertyDescription`
2. Update aggregate's composition via `kAudioAggregateDevicePropertyComposition`
3. Update aggregate's nominal sample rate if needed
4. Fall back to crossfade if any step fails

### Phase 4: macOS 26 Adoption (Future)

1. Use `bundleIDs` instead of `processes` (PIDs) for tap targeting
2. Enable `processRestoreEnabled` for automatic tap restoration
3. Evaluate whether coreaudiod restart handling can be simplified

---

## 9. Risk Assessment

| Change | Risk | Mitigation |
|--------|------|------------|
| Live muteBehavior change | Low -- property is documented as settable | Test empirically; fallback to recreateAllTaps() |
| Live deviceUID change | Medium -- may cause glitch | Test empirically; fallback to crossfade |
| Aggregate composition update | Medium -- underdocumented | Test empirically; verify with AudioObjectIsPropertySettable |
| Tap pool | Low -- overhead of implementation | Defer unless tap creation latency is measured |
| Proxy aggregates | High -- significant arch change | Defer to v2; single-tap-per-aggregate is simpler |
| macOS 26 bundle ID taps | Low -- additive feature | Feature-detect at runtime; maintain PID path for older macOS |

---

## 10. Sources

- Core Audio SDK headers (macOS 26.0 SDK):
  - `CoreAudio/AudioHardware.h` -- `kAudioTapPropertyDescription` documentation (line 2015-2017)
  - `CoreAudio/CATapDescription.h` -- All readwrite properties
  - `CoreAudio/AudioHardwareTapping.h` -- Create/Destroy API
- [Apple Developer Documentation: CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
- [Apple Developer Documentation: AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))
- [Apple Developer Documentation: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [AudioCap (insidegui)](https://github.com/insidegui/AudioCap) -- Reference implementation
- [AudioTee (makeusabrew)](https://github.com/makeusabrew/audiotee) -- Tap-only aggregate example
- [CAAudioHardware (sbooth)](https://github.com/sbooth/CAAudioHardware) -- Aggregate device property wrappers
- [BackgroundMusic coreaudiod restart issue](https://github.com/kyleneideck/BackgroundMusic/issues/126) -- AudioObjectID invalidation on restart
- [Core Audio Tap API example (sudara)](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f) -- Tap-only aggregate pattern
- [Apple Developer Forums: kAudioAggregateDevicePropertyTapList bug](https://developer.apple.com/forums/thread/798941) -- Correct AudioObjectID for property setting

---

## Implementation Status (as of 2026-02-08)

| Phase | Recommendation | Status | Notes |
|-------|---------------|--------|-------|
| 1 | Validate live reconfiguration (test harness) | NOT DONE | `kAudioTapPropertyDescription` settability confirmed in headers but no runtime test written. `TapAPITestRunner` exists but doesn't test live property mutation. |
| 2 | Eliminate permission grant recreation | NOT DONE | `recreateAllTaps()` still exists and is still called for `.unmuted` -> `.mutedWhenTapped` upgrade. Session 4 recommended keeping this approach as safer. |
| 3 | Live device switching (mutate tap + aggregate in-place) | NOT DONE | Crossfade dual-tap approach was overhauled instead (warmup phase, equal-power curves). The create-secondary/crossfade/destroy-primary pattern works well enough. |
| 4 | macOS 26 adoption (bundleIDs + processRestoreEnabled) | PARTIALLY DONE | `bundleIDs` is used on macOS 26. `isProcessRestoreEnabled` is set but causes dead output (Session 3 investigation). Removing `isProcessRestoreEnabled` is the #1 recommended quick fix from Session 3 but hasn't been done yet. |

**Key insight still valid:** The `kAudioTapPropertyDescription` API for live tap modification is the most promising path to eliminating recreation-related bugs. This research remains highly relevant for future work — particularly if the "lazy permission transition" or "never recreate" approaches are revisited.
