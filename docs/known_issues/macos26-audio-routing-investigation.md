# macOS 26 Audio Routing Investigation — Comprehensive Report

**Date:** 2026-02-07
**Status:** RESOLVED — `isProcessRestoreEnabled` confirmed as sole culprit (2026-02-08)
**Investigated by:** 3-agent team + lead synthesis

---

## Executive Summary

FineTune has a **dual-failure mode** on macOS 26 (Tahoe) where neither process tap mode fully works:

| Mode | Capture (Input) | Playback (Output) |
|------|-----------------|-------------------|
| Bundle-ID tap (`bundleIDs` + `isProcessRestoreEnabled`) | **Works** | **Dead** (outPeak=0.000) |
| PID-only tap (legacy) | **Dead** (input=0) | **Works** |

This report maps the complete audio routing architecture on macOS 26, identifies the root cause, and proposes a ranked set of solutions targeting Tahoe only.

---

## Part 1: Root Cause Analysis

### 1.1 What Changed in macOS 26

macOS 26 introduced two new properties on `CATapDescription`:

- **`bundleIDs: [String]`** — Identifies processes by bundle ID instead of PID. Persists across process restarts.
- **`isProcessRestoreEnabled: Bool`** — "True if this tap should save tapped processes by bundle ID when they exit, and restore them to the tap when they start up again."

These are macOS 26-only APIs (Mac Catalyst 26.0+). Apple's documentation is minimal — just the property descriptions above. No WWDC 2025 session covered CoreAudio tap changes specifically.

### 1.2 Why PID-Only Taps Can't Capture on macOS 26

On macOS 26, Chromium-based browsers (Brave, Chrome) use a multi-process audio architecture. The PID visible to `NSRunningApplication` is the **main browser process**, but audio is output by a **separate renderer/utility process**.

On macOS 15 and earlier, PID-based taps could still intercept audio from the main process's AudioObjectID because CoreAudio's process hierarchy was simpler. On macOS 26, the audio daemon (`coreaudiod`) routes audio through the renderer PID, which is NOT the PID in the tap description. Result: the tap sees zero input.

The `bundleIDs` API solves this by letting CoreAudio match ALL processes sharing a bundle ID (main process + renderers + helpers), capturing audio regardless of which child process outputs it.

### 1.3 Why Bundle-ID Taps Kill Output — Root Cause (Confirmed)

**Confirmed (2026-02-08): `isProcessRestoreEnabled` changes how CoreAudio internally wires the aggregate device's output stream.** Setting `bundleIDs` alone (without `isProcessRestoreEnabled`) produces working capture AND working output.

Evidence:
1. The aggregate device creation dictionary is **identical** for both modes — same sub-device list, same tap list, same main sub-device. The ONLY difference is in the `CATapDescription` properties.
2. The IOProc callback receives valid output buffers (`outBuf=1x4096B`) and writes to them (`outputWritten > 0`), but `outPeak` stays at 0.000. This means **the buffers exist but aren't connected to the physical output device's audio stream**.
3. Rogue Amoeba (SoundSource/Audio Hijack) documented that macOS 26.0 had a bug where "applications playing audio to multiple devices could be silenced when SoundSource is running" due to **sample rate mismatches between devices**. They implemented an "alternate capture method" to work around it. This was fixed in macOS 26.1.
4. The `isProcessRestoreEnabled` flag may cause CoreAudio to treat the tap as a **persistent capture point** that changes the aggregate's internal routing — potentially disconnecting the output sub-device from the physical device to avoid conflicts with process restore logic.

### 1.4 The Four-Flag Matrix (Resolved)

| # | `bundleIDs` set? | `isProcessRestoreEnabled`? | Capture | Output | Status |
|---|------------------|---------------------------|---------|--------|--------|
| A | No (PID-only) | No | Dead | Works | Confirmed |
| B | Yes | Yes | Works | **Dead** | Confirmed |
| **C** | **Yes** | **No** | **Works** | **Works** | **Confirmed 2026-02-08** |
| D | No (PID-only) | Yes | Unknown | Unknown | Not tested (unnecessary) |

**Test C confirmed the hypothesis.** `isProcessRestoreEnabled` is the sole culprit. The fix is to set `bundleIDs` without `isProcessRestoreEnabled`.

### 1.5 Known macOS 26 Audio Bugs (from Rogue Amoeba)

Rogue Amoeba documented these macOS 26 bugs affecting process-tap-based audio apps:

1. **Sample rate mismatch silence** (26.0, fixed in 26.1): Secondary output devices with different sample rates from the default could be silenced during capture. SoundSource 5.8.7+ works around it by matching sample rates.
2. **Communication app audio loss** (26.0, fixed in 26.1): FaceTime, WhatsApp, Phone app audio lost in certain device configurations. SoundSource used an "alternate capture method."
3. **Safari audio skipping at 44.1 kHz** (26.0, fixed in 26.1)
4. **Low sample rate capture regression** (from macOS 15, fixed in 26.1)

**Critical question: Are you running macOS 26.0 or 26.1+?** If 26.0, upgrading to 26.1 may fix or change the behavior.

---

## Part 2: Aggregate Device Wiring Analysis

### 2.1 Current Architecture

```
CATapDescription (PID + optional bundleIDs)
        ↓
AudioHardwareCreateProcessTap() → tapID
        ↓
Aggregate Device Dictionary:
  ├─ kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID
  ├─ kAudioAggregateDeviceSubDeviceListKey: [{outputDeviceUID}]
  └─ kAudioAggregateDeviceTapListKey: [{tapUUID, driftComp=true}]
        ↓
AudioHardwareCreateAggregateDevice() → aggregateDeviceID
        ↓
AudioDeviceCreateIOProcIDWithBlock() → IOProc callback
        ↓
IOProc receives: inInputData (from tap) → processes → outOutputData (to output device)
```

### 2.2 What the IOProc Sees

In **PID-only mode** (working output, dead input):
- `inInputData`: Empty buffers (0 bytes, no audio from tap)
- `outOutputData`: Valid buffers connected to physical device → audio plays

In **bundle-ID mode** (working input, dead output):
- `inInputData`: Valid buffers with audio samples (inPeak > 0)
- `outOutputData`: Valid buffers (1x4096B) but NOT connected to physical device → silence

### 2.3 Key Observation

The aggregate device's **output stream topology** appears to change when `bundleIDs` + `isProcessRestoreEnabled` are set on the tap. Even though the aggregate creation dictionary is identical, CoreAudio may internally reconfigure how output streams are routed when it detects a bundle-ID-based tap with process restore.

This could be because:
1. Process restore requires the tap to be independent of the output device lifecycle
2. CoreAudio may create a "detached" aggregate where the tap captures independently and the output device is disconnected to avoid routing conflicts
3. It may be an outright bug in macOS 26's aggregate device implementation

---

## Part 3: Alternative Architectures (Ranked)

### Approach 1: Isolate the Flag — Test Without `isProcessRestoreEnabled` [HIGHEST PRIORITY]

**Effort: 5 minutes | Risk: Low | Impact: Could be the complete fix**

Simply set `bundleIDs` but NOT `isProcessRestoreEnabled`:

```swift
if #available(macOS 26.0, *), let bundleID = app.bundleID,
   !UserDefaults.standard.bool(forKey: "FineTuneForcePIDOnlyTaps") {
    tapDesc.bundleIDs = [bundleID]
    // tapDesc.isProcessRestoreEnabled = true  // DON'T SET THIS
    logger.info("Creating bundle-ID tap: \(bundleID) (processRestore=false)")
}
```

**Rationale:** `isProcessRestoreEnabled` is a convenience feature for persistent taps across process restarts. FineTune already handles process lifecycle via `AudioProcessMonitor`. We don't need CoreAudio's restore feature. If removing it fixes the output path, this is the simplest solution.

### Approach 2: Decoupled Capture/Output (Two Aggregates) [PRIMARY ALTERNATIVE]

**Effort: Medium (1-2 days) | Risk: Medium | Impact: Architectural fix**

Split into two separate audio paths:

```
PATH 1 — CAPTURE (bundle-ID tap, tap-only aggregate)
  CATapDescription(bundleIDs: [appBundleID])
  → Tap-only aggregate (NO output sub-device)
  → IOProc reads input, writes to shared ring buffer

PATH 2 — OUTPUT (no tap, standard aggregate or direct device)
  Separate IOProc on output device
  → Reads from shared ring buffer
  → Applies volume/EQ/processing
  → Writes to output buffers
```

**Key insight from reference code:** Apple's own sample code and open-source projects like AudioTee use **tap-only aggregates** (no `kAudioAggregateDeviceSubDeviceListKey`, no `kAudioAggregateDeviceMainSubDeviceKey`). The `TapAPITestRunner.runTestB()` in this codebase already tests tap-only aggregates.

**Pros:**
- Completely decouples capture from output — each path works independently
- Bundle-ID tap captures audio without needing to route output through the same aggregate
- Output device is a standard audio device, not affected by tap configuration
- More resilient to future macOS changes

**Cons:**
- Ring buffer adds latency (~1-5ms depending on buffer size)
- Need to handle clock synchronization between capture and output aggregates
- More complex teardown/lifecycle management
- Two IOProcs instead of one

**Implementation sketch:**
1. Create a lock-free ring buffer (TPCircularBuffer or custom)
2. Capture IOProc: Read from tap input → write to ring buffer
3. Output IOProc: Read from ring buffer → apply volume/EQ/soft limit → write to output
4. Handle clock drift via buffer level monitoring

### Approach 3: ScreenCaptureKit Audio [BACKUP]

**Effort: High (2-4 days) | Risk: Medium-High | Impact: Complete API replacement**

macOS 14+ provides `SCStreamConfiguration` with per-app audio capture via `SCContentFilter`. macOS 15+ added `SCRecordingOutputConfiguration`.

```swift
let filter = SCContentFilter(desktopIndependentWindow: window)
let config = SCStreamConfiguration()
config.capturesAudio = true
config.excludesCurrentProcessAudio = true
let stream = SCStream(filter: filter, configuration: config, delegate: self)
```

**Pros:**
- Apple's officially supported per-app audio capture API
- No process tap/aggregate device complexity
- Built-in per-app filtering
- Works with bundle IDs natively

**Cons:**
- Designed for recording, not real-time playback. Has higher latency (~50-100ms)
- `SCStreamOutput` delivers `CMSampleBuffer`, need to convert to raw PCM
- Requires screen recording permission (different from audio capture permission)
- No direct output path — still need a mechanism to play processed audio
- May not support the low-latency requirements for EQ/volume control

### Approach 4: Virtual Audio Device (HAL Plugin) [HEAVY BUT DEFINITIVE]

**Effort: Very High (1-2 weeks) | Risk: High | Impact: Complete control**

Create a lightweight virtual audio device using Apple's Audio Server Plugin API:

1. Create a virtual output device ("FineTune Output")
2. Set it as the default output device (or route specific apps to it)
3. Apps send audio to the virtual device
4. FineTune reads from the virtual device, processes, and routes to the real output

**Pros:**
- Complete control over audio routing
- No dependency on process tap API
- How SoundSource/Loopback/Audio Hijack work under the hood

**Cons:**
- Requires a kernel extension or DriverKit extension
- Complex to implement correctly (sample rate handling, format conversion, clock sync)
- Requires system-level installation (not just an app)
- May need special entitlements

### Approach 5: Dual-Mode Hybrid [PRAGMATIC SAFETY NET]

**Effort: Low (hours) | Risk: Low | Impact: Partial fix**

Use both tap modes simultaneously:
- Bundle-ID tap (capture-only, tap-only aggregate) for VU meter and input monitoring
- PID-only tap (with output device in aggregate) for audio playback

```
Bundle-ID tap → tap-only aggregate → IOProc reads input for VU/analysis
PID-only tap → standard aggregate → IOProc handles output with volume/EQ

Problem: PID-only can't capture on macOS 26, so no input processing
Benefit: At least audio passes through correctly
```

This is a degraded-mode fallback: audio works, but FineTune can't process it (just passthrough with volume control via the output path).

---

## Part 4: Recommended Action Plan

### Phase 1: Quick Isolation Test (Do This First)

1. **Test C from the matrix**: Set `bundleIDs` but NOT `isProcessRestoreEnabled`. If output works, you're done.
2. **Test D**: Set `isProcessRestoreEnabled` but NOT `bundleIDs` (PID-only + restore). To understand which flag causes the issue.
3. **Check macOS version**: If running 26.0, test on 26.1 — the Rogue Amoeba sample-rate bug fix may resolve this.

### Phase 2: If isProcessRestoreEnabled Is the Culprit

Simply remove `tapDesc.isProcessRestoreEnabled = true` from `makeTapDescription()`. FineTune doesn't need process restore — `AudioProcessMonitor` already handles process lifecycle.

Also add the `outPeak > 0` safety check to `shouldConfirmPermission`:
```swift
// Require real output audio before promoting to .mutedWhenTapped
(snapshot?.lastOutputPeak ?? 0) > 0.0001
```

### Phase 3: If bundleIDs Itself Is the Culprit

Implement Approach 2 (Decoupled Capture/Output):
1. Bundle-ID tap in tap-only aggregate for capture
2. Separate output IOProc on the real device for playback
3. Lock-free ring buffer connecting them
4. Crossfade logic adapts to the two-aggregate model

### Phase 4: Safety Net (Regardless of Root Cause)

1. Fix `shouldConfirmPermission` to require `outPeak > 0` (not just `outputWritten > 0`)
2. Add aggregate device stream topology logging on activation (dump output stream count, format, active state)
3. Add a `FineTuneDisableBundleIDTaps` defaults key as an escape hatch

---

## Part 5: macOS 26 Audio Routing Map

### How Audio Flows in macOS 26

```
Application (e.g., Brave Browser)
  │
  ├── Main Process (PID 1234, bundleID: com.brave.Browser)
  │     └── No audio output on macOS 26 (UI only)
  │
  └── Renderer Process (PID 5678, bundleID: com.brave.Browser)
        └── Audio output via CoreAudio
              │
              ▼
        coreaudiod (system daemon)
              │
              ├─── Default Output Device (speakers/headphones)
              │       └── Physical audio stream
              │
              └─── Process Tap (if registered)
                      │
                      ├── PID-based: Matches PID 1234 → MISS (audio is from PID 5678)
                      │
                      └── Bundle-ID-based: Matches "com.brave.Browser" → HIT (all PIDs)
                              │
                              ▼
                        Aggregate Device
                              ├── Input stream: Tap sub-device (captured audio)
                              └── Output stream: Physical device sub-device
                                    └── ??? (broken for bundle-ID taps)
```

### The `.mutedWhenTapped` Contract

When `.mutedWhenTapped` is active:
1. CoreAudio silences the app's audio on the **original output path** (physical device)
2. The ONLY way audio reaches speakers is through the **aggregate device's output stream**
3. The IOProc callback reads captured audio from input, processes it, writes to output
4. If the output stream isn't connected to the physical device → silence

This contract works perfectly for PID-only taps. For bundle-ID taps, step 4 breaks — the output buffers exist but aren't routed to hardware.

---

## Appendix A: Key Code Locations

| File | Line | What |
|------|------|------|
| `ProcessTapController.swift` | 287 | Bundle-ID toggle in `makeTapDescription()` |
| `ProcessTapController.swift` | 356 | `activate()` — tap + aggregate creation |
| `ProcessTapController.swift` | 390-410 | Aggregate device dictionary construction |
| `ProcessTapController.swift` | 1107 | Primary IOProc callback `processAudio()` |
| `AudioEngine.swift` | ~280 | `shouldConfirmPermission()` — needs outPeak fix |
| `TapAPITestRunner.swift` | 361 | Test C — bundle-ID tap testing |
| `TapResources.swift` | 26 | Teardown order |

## Appendix B: External References

- [Rogue Amoeba: macOS 26 Audio Bug Fixes](https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/)
- [Rogue Amoeba: SoundSource macOS 26 Troubleshooting](https://rogueamoeba.com/support/knowledgebase/?showArticle=Troubleshooting-MacOS-26-Tahoe&product=SoundSource)
- [Apple: Capturing System Audio with Core Audio Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple: CATapDescription.bundleIDs](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids)
- [Apple: CATapDescription.isProcessRestoreEnabled](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled)
- [AudioCap: Sample code for recording system audio](https://github.com/insidegui/AudioCap)
- [AudioTee: System audio capture tool](https://github.com/makeusabrew/audiotee)
- [Core Audio Tap API Example (Gist)](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f)

## Appendix C: Agent Research Summaries

### Agent 1 (api-researcher): macOS 26 API Changes
- `bundleIDs` and `isProcessRestoreEnabled` are macOS 26-only additions to CATapDescription
- No WWDC 2025 sessions covered these changes specifically
- Apple's sample code updated to require macOS 26.0+ but no bundle-ID examples in public code
- Rogue Amoeba confirmed significant audio subsystem changes in 26.0, many fixed in 26.1
- No public developer forum posts specifically about bundle-ID tap output failure
- Other apps using process taps (AudioTee, AudioCap) don't use bundle-ID taps

### Agent 2 (code-analyst): Aggregate Device Analysis
- Aggregate device dictionary is IDENTICAL for both modes — only CATapDescription differs
- IOProc callback structure is identical — same buffer layout, same processing pipeline
- Output buffers are allocated and sized correctly (1x4096B) in both modes
- The `processAudio` callback writes valid samples to output but they don't reach hardware
- `isProcessRestoreEnabled` is the most likely culprit — it may change CoreAudio's internal routing
- TapAPITestRunner.runTestC() uses `.mutedWhenTapped` with bundle-IDs but doesn't check output peak
- Key gap: No diagnostic logging of aggregate device stream properties after creation

### Agent 3 (arch-researcher): Alternative Architectures
- Decoupled capture/output (two aggregates + ring buffer) is the most viable alternative
- ScreenCaptureKit has too much latency for real-time audio control
- Virtual audio device works but requires DriverKit/kernel extension
- Apple's own screen recording uses ScreenCaptureKit, not process taps for capture
- SoundSource/Audio Hijack use virtual audio devices (ACE driver) — process taps are a supplement
- Tap-only aggregates (no output sub-device) are well-supported and used by multiple apps

---

## Resolution (2026-02-08)

### Action Plan — Final Status

| Phase | Item | Status | Notes |
|-------|------|--------|-------|
| **Phase 1** | Test C (bundleIDs=yes, isProcessRestoreEnabled=no) | **DONE** | Both capture and output work. `inPeak=0.048, outPeak=0.043`. |
| **Phase 1** | Test D (PID-only + isProcessRestoreEnabled) | SKIPPED | Not needed — root cause identified. |
| **Phase 1** | Check macOS version (26.0 vs 26.1) | NOT CONFIRMED | Fix works regardless. |
| **Phase 2** | Remove `isProcessRestoreEnabled` | **DONE** | `makeTapDescription()` sets `bundleIDs` without `isProcessRestoreEnabled`. |
| **Phase 2** | `shouldConfirmPermission` outPeak safety check | DONE | `AudioEngine.swift:147-162`. |
| **Phase 3** | Decoupled capture/output | NOT NEEDED | Fix in Phase 2 resolves the issue. |
| **Phase 4** | `FineTuneDisableBundleIDTaps` defaults key | DONE | Escape hatch in place. |

### Fix Applied

```swift
// ProcessTapController.swift — makeTapDescription()
if #available(macOS 26.0, *), let bundleID = app.bundleID,
   !UserDefaults.standard.bool(forKey: "FineTuneForcePIDOnlyTaps"),
   !UserDefaults.standard.bool(forKey: "FineTuneDisableBundleIDTaps") {
    tapDesc.bundleIDs = [bundleID]
    // Do NOT set isProcessRestoreEnabled — it causes dead aggregate output
}
```

### New Issue: Bundle-ID Tap Disconnection After Crossfade (MITIGATED)

After device switching (crossfade) with bundle-ID taps, the tap can lose its connection to the app — `inputHasData` freezes while `callbackCount` continues. Observed after 3 consecutive crossfade switches (AirPods→MacBook→AirPods→MacBook).

**Root cause hypothesis:** During crossfade, `createSecondaryTap()` creates a second process tap with the same `bundleIDs`. CoreAudio may have issues routing audio when two taps claim the same bundle ID. After the primary tap is destroyed, the surviving secondary may stop receiving audio.

**Why existing health checks missed it:** The IOProc continues running (not Case 1: stalled), output buffers are written with zeros (not Case 2: broken with `outputDelta == 0`), and input buffers exist with data pointers but zero-value samples (not `emptyInput`).

**Mitigation:** Added Case 3 to `checkTapHealth()` — detects "input frozen after crossfade" by tracking `inputHasData` delta and scoping to a 10-second window after `lastCrossfadeCompletedAt`. When triggered, the tap is recreated (same as other health check cases), restoring audio within one health check cycle (~3-6 seconds).

**Code locations:**
- `ProcessTapController.swift`: `lastCrossfadeCompletedAt` timestamp set in `promoteSecondaryToPrimary()`
- `AudioEngine.swift`: `TapHealthSnapshot.inputHasData` field + Case 3 in `checkTapHealth()`

**Future improvement:** A more robust fix would avoid dual bundle-ID taps during crossfade entirely — e.g., reusing the same process tap across aggregates, or sharing a single tap between old and new aggregate devices. This would prevent the disconnection rather than detecting and recovering from it.
