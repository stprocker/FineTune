# Agent 3: arch-researcher -- Alternative Architecture Ranking

**Task:** Research and rank alternative approaches to per-app audio capture + output on macOS 26, given that the current process tap + aggregate device approach has a dual-failure mode.

**Constraint:** macOS 26 (Tahoe) only. No backward compatibility required.

---

## Approach 1: Remove `isProcessRestoreEnabled` (Simplest Fix)

**Effort:** 5 minutes | **Risk:** Low | **Impact:** Could be the complete fix

Set `bundleIDs` but do not set `isProcessRestoreEnabled`:

```swift
if #available(macOS 26.0, *), let bundleID = app.bundleID,
   !UserDefaults.standard.bool(forKey: "FineTuneForcePIDOnlyTaps"),
   !UserDefaults.standard.bool(forKey: "FineTuneDisableBundleIDTaps") {
    tapDesc.bundleIDs = [bundleID]
    // Do NOT set: tapDesc.isProcessRestoreEnabled = true
}
```

**Rationale:** `isProcessRestoreEnabled` is a convenience for persistent taps across process restarts. FineTune already handles process lifecycle via `AudioProcessMonitor`, which detects process launch/termination and creates/destroys taps accordingly. The CoreAudio-level restore is redundant and may be causing the aggregate output wiring change.

**Prerequisite:** Test the four-flag matrix (bundleIDs yes/no x isProcessRestoreEnabled yes/no) to confirm this flag is the culprit. Test C (bundleIDs=yes, processRestore=no) is the critical test.

## Approach 2: Decoupled Capture/Output (Two Separate Paths)

**Effort:** 1-2 days | **Risk:** Medium | **Impact:** Architectural fix that decouples capture from output

Split into two independent audio paths:

```
PATH 1 -- CAPTURE
  CATapDescription(bundleIDs: [appBundleID])
  -> Tap-only aggregate (NO output sub-device, NO main sub-device)
  -> IOProc reads input -> writes to lock-free ring buffer

PATH 2 -- OUTPUT
  Separate IOProc on physical output device (or lightweight aggregate)
  -> Reads from ring buffer
  -> Applies volume/EQ/soft limit
  -> Writes to output buffers -> hardware
```

**Key insight:** Apple's own sample code and open-source projects (AudioTee, sudara's gist) use tap-only aggregates -- aggregates with no `kAudioAggregateDeviceSubDeviceListKey` and no `kAudioAggregateDeviceMainSubDeviceKey`. `TapAPITestRunner.runTestB()` in the FineTune codebase already validates that tap-only aggregates work.

**Pros:**
- Completely decouples capture from output. Each path works independently.
- Bundle-ID tap captures audio without needing output through the same aggregate.
- Output device is a standard audio device, unaffected by tap configuration.
- More resilient to future macOS changes.

**Cons:**
- Ring buffer adds latency (~1-5ms depending on buffer size).
- Clock synchronization needed between capture and output aggregates (different clock domains).
- Two IOProcs instead of one. More complex teardown and lifecycle management.
- Crossfade logic in `ProcessTapController` must adapt to the two-aggregate model.

**Implementation sketch:**
1. Create a lock-free ring buffer (TPCircularBuffer or custom).
2. Capture IOProc: Read from tap input, write to ring buffer.
3. Output IOProc: Read from ring buffer, apply volume/EQ/soft limit, write to output.
4. Monitor buffer fill level for clock drift compensation.

## Approach 3: ScreenCaptureKit Audio

**Effort:** 2-4 days | **Risk:** Medium-High | **Impact:** Complete API replacement

macOS 14+ provides `SCStreamConfiguration` with per-app audio capture via `SCContentFilter`. macOS 15+ added `SCRecordingOutputConfiguration`.

```swift
let filter = SCContentFilter(desktopIndependentWindow: window)
let config = SCStreamConfiguration()
config.capturesAudio = true
config.excludesCurrentProcessAudio = true
let stream = SCStream(filter: filter, configuration: config, delegate: self)
```

**Pros:**
- Apple's officially supported per-app audio capture API.
- No process tap or aggregate device complexity.
- Built-in per-app filtering. Works with bundle IDs natively.

**Cons:**
- Designed for recording, not real-time playback. Higher latency (~50-100ms).
- Delivers `CMSampleBuffer`, requires conversion to raw PCM.
- Requires screen recording permission (different from audio capture permission, more intrusive).
- No direct output path -- still need a mechanism to play processed audio back to the user.
- Apple's built-in screen recording uses ScreenCaptureKit, but for recording, not real-time routing.

**Verdict:** Latency makes this unsuitable for real-time volume/EQ control where users expect immediate response.

## Approach 4: Virtual Audio Device (HAL Plugin)

**Effort:** 1-2 weeks | **Risk:** High | **Impact:** Complete control over audio routing

Create a lightweight virtual audio device using Apple's Audio Server Plugin API:

1. Create a virtual output device ("FineTune Output").
2. Set it as default output or route specific apps to it via per-app audio routing (macOS 14+).
3. Apps send audio to the virtual device.
4. FineTune reads from the virtual device, processes, routes to real output.

This is how SoundSource, Loopback, and Audio Hijack work. They install the ACE (Audio Control Engine) driver as a system component.

**Pros:**
- Complete control over audio routing. No dependency on process tap API.
- Proven architecture used by production apps handling millions of users.

**Cons:**
- Requires a DriverKit extension or legacy kext (not App Store compatible without special entitlement).
- Complex implementation: sample rate handling, format conversion, clock synchronization.
- Requires system-level installation beyond the app bundle.
- Significant development effort and ongoing maintenance.
- May need notarization and special Apple entitlements.

**Verdict:** Correct long-term architecture for a professional audio tool, but disproportionate effort for the current issue.

## Approach 5: Dual-Mode Hybrid (Fallback Strategy)

**Effort:** Hours | **Risk:** Low | **Impact:** Partial -- degraded mode

Use both tap modes simultaneously:

```
Bundle-ID tap -> tap-only aggregate -> IOProc reads input (VU meter, analysis)
PID-only tap  -> standard aggregate -> IOProc handles output (volume/EQ)
```

**Behavior:** Audio passes through correctly via the PID-only aggregate's output path. The bundle-ID tap provides input monitoring (VU meters, level analysis) but cannot process audio inline. Volume and EQ adjustments work on the output path but do not affect the captured signal.

**Limitation:** PID-only taps cannot capture audio from Chromium renderers on macOS 26. The bundle-ID tap captures for monitoring but the PID-only tap's input is dead. This means FineTune can adjust volume/EQ on the output path but cannot mute the original audio or apply processing to the captured stream. It is a degraded-mode fallback, not a full solution.

---

## Ranking Summary

| Rank | Approach | Effort | Confidence | Notes |
|------|----------|--------|------------|-------|
| 1 | Remove `isProcessRestoreEnabled` | 5 min | High (if confirmed) | Must test four-flag matrix first |
| 2 | Decoupled capture/output | 1-2 days | High | Robust fix if bundleIDs itself is the problem |
| 3 | ScreenCaptureKit | 2-4 days | Low | Latency disqualifies for real-time use |
| 4 | Virtual audio device | 1-2 weeks | Very High | Production-grade but disproportionate effort |
| 5 | Dual-mode hybrid | Hours | Medium | Degraded mode only, not a full solution |

**Recommended sequence:** Try Approach 1 first. If it fails, implement Approach 2. Approach 4 is the correct long-term architecture if FineTune evolves into a professional audio tool.
