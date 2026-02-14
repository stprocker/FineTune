# macOS 26 Bundle-ID Crossfade Fix, ARK Research, and Dead-Tap Loop Prevention

**Date:** 2026-02-08
**Session type:** Multi-agent investigation + implementation
**Branch:** main (uncommitted)
**Continuation of:** Session 3 (`docs/agents/3/session-summary.md`)

---

## Summary

This session continued from the Session 3 investigation into macOS 26 audio routing failures. The previous session confirmed that `isProcessRestoreEnabled` was the sole cause of dead aggregate output and implemented health check Case 3 for crossfade disconnection detection. This session:

1. Ran a 3-agent deep investigation into why bundle-ID taps disconnect after crossfade
2. Researched how Rogue Amoeba's ARK, original FineTune, and open-source audio apps handle device switching
3. Implemented a destructive switch fix for bundle-ID taps (bypasses crossfade entirely)
4. Fixed an infinite tap recreation loop for apps that never produce audio (CoreSpeech)

---

## Problem Statement

After the `isProcessRestoreEnabled` fix from Session 3, bundle-ID taps (`bundleIDs: [bundleID]`) still failed during device switching. The crossfade architecture creates TWO simultaneous process taps with identical `bundleIDs`, which confuses CoreAudio's tap routing. After the primary tap is destroyed, the surviving secondary stops receiving audio input. User-observed symptoms:

- "Switches and mutes" — switch completes but audio goes silent
- "Refuses to switch and mutes" — switch fails, audio silenced
- "Refuses to switch" — nothing happens

Additionally, CoreSpeech (Apple's speech recognition daemon, which never produces audio) triggered an infinite health check recreation loop, burning through 20+ tap/aggregate device IDs in seconds and potentially destabilizing `coreaudiod`.

---

## What Was Done

### Phase 1: 3-Agent Deep Investigation

Three parallel research agents were launched:

#### Agent 1: Code Analyst (Explore agent)
- Confirmed root cause: two process taps with identical `bundleIDs` during crossfade
- Detailed the dual-tap timeline: `createSecondaryTap()` at line 717 calls `makeTapDescription()` which sets `bundleIDs = [bundleID]` — identical to the still-running primary
- Identified 4 solution approaches ranked by feasibility

#### Agent 2: Git Historian (general-purpose agent)
- Found original FineTune by Ronit Singh at `_local/26.2.7 FineTune OG/FineTune-main/`
- Original also uses dual-tap crossfade but was designed before macOS 26 bundle-ID taps existed — never hits this bug
- Original uses simple `_isCrossfading` boolean, 50ms crossfade, no warmup
- Fork has 30,541 lines added across 158 files
- Found existing research docs:
  - `docs/agents/2_continued/research-never-recreate-architecture.md` — `kAudioTapPropertyDescription` is settable for live reconfiguration
  - `docs/agents/2_continued/research-open-source-architectures.md` — tap-only aggregates proven by SoundPusher/AudioTee

#### Agent 3: External Researcher (general-purpose agent)
- Researched Rogue Amoeba SoundSource/ARK, CoreAudio API docs, open-source references
- **Key finding:** No documentation or code demonstrates sharing one tap between two aggregate devices — single-tap crossfade (Option 2) is uncharted territory
- **Key finding:** SoundSource does NOT use crossfade — likely fast destroy/recreate through proprietary ARK layer
- **Key finding:** `kAudioAggregateDevicePropertyTapList` is settable but has known Apple documentation bug (FB17411663)
- **"Reporter disconnected"** explained: internal CoreAudio telemetry (RTAID), not a tap failure indicator

### Phase 2: ARK Architecture Research

Deep investigation into Rogue Amoeba's ARK (Audio Routing Kit):

- **ARK is a hybrid system:**
  - Layer 1: CoreAudio process taps (same API as FineTune) for capture-only apps (Audio Hijack, Piezo, Airfoil) — zero installation
  - Layer 2: AudioServerPlugin (`.driver` in `/Library/Audio/Plug-Ins/HAL/`) for routing apps (SoundSource, Loopback) — requires admin install
- **SoundSource's "instant" switching:** Virtual proxy device becomes system default. Apps output to proxy. Switch = internal pointer redirect, no CoreAudio resource churn
- **Open-source references cataloged:**
  - BlackHole — cleanest minimal AudioServerPlugin
  - Background Music — most complete open-source SoundSource alternative (proxy device pattern)
  - eqMac — AudioServerPlugin in Swift
  - libASPL — C++17 library for building AudioServerPlugins
  - proxy-audio-device — exact proxy pattern SoundSource likely uses
- **Conclusion:** ARK-like architecture is a "FineTune 2.0" decision, not needed for the immediate bug fix

### Phase 3: Ranked Solution Approaches

| # | Approach | Effort | Audio Gap | Confidence |
|---|----------|--------|-----------|------------|
| **1** | **Destructive switch for bundle-ID taps** | 10 min | ~200ms | Very High |
| **2** | **Live tap `deviceUID` change** via `kAudioTapPropertyDescription` | 4-8 hrs | ~50ms glitch | Medium |
| **3** | **Sub-device swap** on existing aggregate | 4-8 hrs | Brief glitch | Low (untested by anyone) |
| **4** | **PID-only secondary** during crossfade | 1-2 hrs | None | Medium (Chromium audio lost during crossfade) |
| ~~5~~ | ~~Single-tap multi-aggregate~~ | — | — | ~~Low — no evidence this works~~ |

### Phase 4: Implementation

#### Fix 1: Destructive Switch for Bundle-ID Taps

**File:** `FineTune/Audio/ProcessTapController.swift`

Added `usesBundleIDTaps` computed property (line ~318):
```swift
private var usesBundleIDTaps: Bool {
    if #available(macOS 26.0, *), app.bundleID != nil,
       !UserDefaults.standard.bool(forKey: "FineTuneForcePIDOnlyTaps"),
       !UserDefaults.standard.bool(forKey: "FineTuneDisableBundleIDTaps") {
        return true
    }
    return false
}
```

Modified `switchDevice()` (line ~565) to route bundle-ID taps directly to destructive switch:
```swift
if usesBundleIDTaps {
    logger.info("[SWITCH] Using destructive switch (bundle-ID taps active)")
    try await performDestructiveDeviceSwitch(to: newDeviceUID)
} else {
    // PID-only taps: crossfade with destructive fallback
    do {
        try await performCrossfadeSwitch(to: newOutputUID)
    } catch { ... }
}
```

**Log output confirming fix works:**
```
[SWITCH] Using destructive switch (bundle-ID taps active)
[SWITCH-DESTROY] Volume compensation: source=0.750000, dest=1.000000, ratio=0.750000
[SWITCH-DESTROY] Complete
[SWITCH] === END === Total time: 462.191939ms
```

Post-switch diagnostics showed healthy audio: `callbacks=1984 input=1971 output=1971 inPeak=0.001 outPeak=0.001 curVol=1.00`

#### Fix 2: Dead-Tap Recreation Limit

**File:** `FineTune/Audio/AudioEngine.swift`

Added recreation counter (line ~87):
```swift
private var deadTapRecreationCount: [pid_t: Int] = [:]
private let maxDeadTapRecreations = 3
```

Applied to both health checks:
- **Slow health check** (`checkTapHealth()`): Guard at the start of the recreation loop. If `deadTapRecreationCount[pid] > 3`, invalidate tap and stop trying.
- **Fast health check** (post-creation timer): Same guard before dead-tap rerouting logic.
- **Counter reset:** When `checkTapHealth()` sees `d.callbackCount > 0` for a PID, removes it from `deadTapRecreationCount`.
- **Counter cleanup:** Filtered along with `lastHealthSnapshots` when PIDs are removed.

**Before:** CoreSpeech created 20+ taps in the logs (device IDs 243 → 364).
**After:** Will stop after 3 attempts with: `[HEALTH] CoreSpeech tap dead after 3 recreation attempts — giving up (app may not produce audio)`

---

## Files Modified

| File | Changes |
|------|---------|
| `FineTune/Audio/ProcessTapController.swift` | Added `usesBundleIDTaps` property; modified `switchDevice()` to skip crossfade for bundle-ID taps |
| `FineTune/Audio/AudioEngine.swift` | Added `deadTapRecreationCount` and `maxDeadTapRecreations`; added recreation limit to both slow and fast health checks; added counter reset on healthy audio |

**Note:** Changes from the previous session (Session 3 continuation) are also uncommitted in these files:
- `ProcessTapController.swift`: `lastCrossfadeCompletedAt` property, set in `promoteSecondaryToPrimary()`
- `AudioEngine.swift`: `inputHasData` in `TapHealthSnapshot`, Case 3 health check for input frozen after crossfade

---

## Build Status

**BUILD SUCCEEDED** — verified via `xcodebuild -scheme FineTune -configuration Debug build`

SourceKit diagnostics (Cannot find type 'AudioApp', etc.) are single-file indexing noise, not real build errors.

---

## Key Code Locations

| File | Line | What |
|------|------|------|
| `ProcessTapController.swift` | ~318 | `usesBundleIDTaps` computed property |
| `ProcessTapController.swift` | ~330 | `makeTapDescription()` — bundle-ID targeting |
| `ProcessTapController.swift` | ~565 | `switchDevice()` — bundle-ID routing to destructive switch |
| `ProcessTapController.swift` | ~600 | `performCrossfadeSwitch()` — PID-only crossfade path |
| `ProcessTapController.swift` | ~955 | `performDestructiveDeviceSwitch()` — destroy/recreate |
| `ProcessTapController.swift` | ~1080 | `performDeviceSwitch()` — internal create-before-destroy |
| `ProcessTapController.swift` | ~278 | `updateMuteBehavior()` — existing live tap reconfiguration via `kAudioTapPropertyDescription` |
| `AudioEngine.swift` | ~87 | `deadTapRecreationCount` and `maxDeadTapRecreations` |
| `AudioEngine.swift` | ~432 | Counter reset in `checkTapHealth()` |
| `AudioEngine.swift` | ~488 | Recreation limit in slow health check |
| `AudioEngine.swift` | ~1248 | Recreation limit in fast health check |

---

## Research Artifacts

### Investigation Reports (from 3-agent team)

| Agent | Output Location | Key Findings |
|-------|----------------|--------------|
| Code Analyst | (in-memory) | Dual-tap timeline, 4 solution approaches, IOProc dynamic routing analysis |
| Git Historian | (in-memory) | Original FineTune comparison, fork delta (30,541 lines), existing research docs, Test D for live deviceUID change |
| External Researcher | (in-memory) | ARK hybrid architecture, no evidence for tap sharing between aggregates, sub-device swapping as alternative, "Reporter disconnected" = RTAID telemetry |

### Existing Research Docs (read during investigation)
- `docs/agents/2_continued/research-never-recreate-architecture.md` — `kAudioTapPropertyDescription` settable, live tap reconfiguration supported
- `docs/agents/2_continued/research-open-source-architectures.md` — tap-only aggregates proven, 6 open-source projects analyzed
- `docs/known_issues/macos26-audio-routing-investigation.md` — comprehensive investigation report from Session 3
- `docs/agents/3/session-summary.md` — Session 3 summary with implementation status

### ARK Research Summary
- ARK = CoreAudio process taps (capture) + AudioServerPlugin (routing/virtual devices)
- SoundSource uses virtual proxy device as system default for instant switching
- Building ARK-like system is feasible but 4-6 weeks effort, requires admin install, loses App Store compatibility
- Open-source references: BlackHole, Background Music, eqMac, libASPL, proxy-audio-device

---

## TODO List (Handoff)

### Immediate (Before Next Release)

- [ ] **Test destructive switch across multiple devices** — Switch Brave between MacBook speakers, Scarlett 2i2, CalDigit, M32UC. Verify audio resumes on each device. Check for ~200ms silence gap (expected and acceptable).
- [ ] **Test rapid consecutive switches** — Switch Brave back and forth 5+ times rapidly. Verify no resource leaks or stuck state.
- [ ] **Verify CoreSpeech loop is fixed** — Launch FineTune, wait 30+ seconds, check logs. Should see max 3 recreations then `giving up` message. No more tap ID escalation.
- [ ] **Test with multiple tapped apps** — Have Brave + Spotify + Music all tapped. Switch devices for each independently. Verify no interference.
- [ ] **Commit all changes** — Both Session 3 and this session's changes are uncommitted:
  - `ProcessTapController.swift`: `usesBundleIDTaps`, destructive switch routing, `lastCrossfadeCompletedAt`, Case 3 health check support
  - `AudioEngine.swift`: `deadTapRecreationCount`, recreation limit, `inputHasData` in health snapshots, Case 3 health check
  - `CrossfadeState.swift`: minor changes from Session 3
  - `VolumeState.swift`, `SettingsManager.swift`, `SettingsView.swift`: changes from earlier sessions

### Short-Term Improvements

- [ ] **Live tap `deviceUID` change (Option 2)** — The ideal long-term fix. Uses `kAudioTapPropertyDescription` (already proven by `updateMuteBehavior()`). Would eliminate dual taps entirely. TapExperiment Test D exists but hasn't been run at runtime. Effort: 4-8 hours.
- [ ] **Reduce destructive switch silence** — Current `performDestructiveDeviceSwitch()` has configurable timing (`destructiveSwitchPreSilenceMs`, `destructiveSwitchPostSilenceMs`, `destructiveSwitchFadeInMs`). Tune these values to minimize the ~200-462ms gap.
- [ ] **Dual-tap overlap in destructive switch** — `performDeviceSwitch()` creates new tap BEFORE destroying old (to prevent audio leak). With bundle-ID taps, there's a brief dual-tap overlap (~10-20ms). Currently works because overlap is very brief, but could be eliminated by destroying old first (accepts ~10ms audio leak) or creating PID-only then upgrading.
- [ ] **Add `FineTuneForceDestructiveSwitch` defaults key** — Allow users to force destructive switch even for PID-only taps, as an escape hatch for crossfade issues.

### Longer-Term Architecture

- [ ] **Tap-only aggregates** — Remove real output device from aggregate (only include tap). Proven by SoundPusher/AudioTee. Would eliminate spurious device-change notifications. HIGH PRIORITY recommendation from open-source research but NOT IMPLEMENTED.
- [ ] **Live aggregate sub-device swapping** — Change output device by modifying `kAudioAggregateDevicePropertySubDeviceList` on existing aggregate. Would keep single tap alive through device switches. Untested by anyone.
- [ ] **ARK-like AudioServerPlugin** — Virtual proxy device for instant switching. 4-6 week effort. Requires admin install, loses App Store compatibility. "FineTune 2.0" decision.
- [ ] **Run TapExperiment Tests A-D on macOS 26** — Validate live tap reconfiguration, tap-only aggregates, bundle-ID targeting, and live deviceUID change at runtime.

---

## Known Issues

### Active

| Issue | Status | Details |
|-------|--------|---------|
| **~200ms silence during bundle-ID device switch** | Expected behavior | Destructive switch trades seamless crossfade for reliability. Gap is ~200-462ms. |
| **Dual-tap overlap in destructive switch** | Low risk | `performDeviceSwitch()` creates new tap before destroying old. Brief (~10-20ms) overlap with same `bundleIDs`. Works in testing but theoretically risky. |
| **Crossfade still broken for bundle-ID taps** | Bypassed, not fixed | Crossfade code still has the dual-tap bundle-ID conflict. Now unreachable for bundle-ID taps (routed to destructive switch). PID-only taps unaffected. |
| **Apps that never produce audio** | Mitigated | Health check stops after 3 recreation attempts. App disappears from tap list but may still show in UI. |
| **`lastCrossfadeCompletedAt` unused for bundle-ID taps** | Cosmetic | Case 3 health check targets post-crossfade input freeze. Now unreachable for bundle-ID taps since crossfade is skipped. Still useful for PID-only taps. |

### Pre-Existing (From Previous Sessions)

| Issue | Details |
|-------|---------|
| **19 test failures** | CrossfadeState duration tests expect 50ms, code uses 200ms. Unrelated to these changes. |
| **PostEQLimiterTests not runnable via `swift test`** | Sparkle dependency issue. Verified via standalone compilation. |
| **`CGPreflightScreenCaptureAccess()` behavior on macOS 26** | Passive check confirmed not to trigger system dialog, needs broader testing. |

---

## External References

- [Rogue Amoeba: ARK Details](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Plugin-Audio-Capture-Details&product=SoundSource)
- [Rogue Amoeba: macOS 26 Audio Bug Fixes](https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/)
- [Apple: CATapDescription.isProcessRestoreEnabled](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled)
- [Apple: Capturing System Audio with Core Audio Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple: Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- [CoreAudio Taps for Dummies](https://www.maven.de/2025/04/coreaudio-taps-for-dummies/)
- [BlackHole (GitHub)](https://github.com/ExistentialAudio/BlackHole)
- [Background Music (GitHub)](https://github.com/kyleneideck/BackgroundMusic)
- [libASPL (GitHub)](https://github.com/gavv/libASPL)
- [AudioTee (GitHub)](https://github.com/makeusabrew/audiotee)
- [SoundPusher (Codeberg)](https://codeberg.org/q-p/SoundPusher)
- [Apple Documentation Bug FB17411663](https://developer.apple.com/forums/thread/798941) — `kAudioAggregateDevicePropertyTapList` sample code uses wrong target object ID
