# Audio Wiring Agent Team Review and Implementation

**Date:** 2026-02-07
**Session type:** Multi-agent team review + implementation
**Model:** Claude Opus 4.6
**Branch:** main
**Duration:** ~45 minutes total across 8 agents

---

## Overview

Comprehensive 4-agent review of FineTune's audio switching/crossfade wiring, followed by a 5-phase implementation using parallel agent teams. The review identified 17 issues (1 critical, 4 high, 7 medium, 5 low) and produced a detailed implementation plan. All critical and high-priority fixes were implemented and verified.

## Trigger

User-reported bug: when switching Spotify from MacBook Pro Speakers to AirPods, there is a ~200-400ms silence gap. The crossfade (50ms) completes before Bluetooth actually produces audible sound. A prior diagnosis (screenshot) identified the root cause as crossfade progress counting starting during the 500ms BT warmup sleep, racing ahead and silencing speakers before AirPods are audible.

---

## Phase 1: Agent Team Review (4 agents)

### Agent 1 — Documentation & Best Practices Expert
- **Scope:** Read all local Apple Core Audio docs (`docs/Apple Core Audio Docs/`), SDK headers (`AudioHardwareBase.h`, `AudioHardware.h`), and web research
- **Key findings:**
  - `kAudioDevicePropertyLatency` reports codec latency (~3ms for BT), NOT connection warmup (~200-400ms)
  - `kAudioDevicePropertySafetyOffset` similarly reports small buffer offsets
  - Total output latency formula: `deviceLatency + streamLatency + safetyOffset + bufferFrameSize`
  - BT playback latency measurements: AirPods Pro ~215-220ms initial, ~144ms steady-state; first-gen AirPods 274ms
  - Recommended two-phase approach: warmup (primary at full volume) then crossfade (equal-power transition)
  - Four cardinal rules for audio callbacks: no locks, no ObjC/Swift runtime, no allocation, no IO
  - Equal-power crossfade: `primary = cos(progress * pi/2)`, `secondary = sin(progress * pi/2)`
- **Sources cited:** Apple SDK headers, Stephen Coyle AirPods latency measurements, Ross Bencina RT audio programming, Tasty Pixel audio dev mistakes, Signalsmith cheap energy crossfade, JUCE forum, Rogue Amoeba drift correction

### Agent 2 — Code Reviewer
- **Scope:** Read every audio-related file in the repo, map architecture, identify all issues
- **Key findings (17 issues):**
  - **C1 (CRITICAL):** Crossfade timing vs BT playback latency — the known bug. Full execution trace with timing table showing 50ms crossfade completion vs 200-400ms BT latency
  - **H1 (HIGH):** Sample rate mismatch logged but not compensated (48kHz speakers vs 44.1kHz BT)
  - **H2 (HIGH):** Shared diagnostic counters (`_diagCallbackCount` etc.) incremented by both callbacks — multi-writer data race
  - **H3 (HIGH):** `_peakLevel` read-modify-write from both callbacks — VU meter jitter
  - **H4 (HIGH):** Device volume compensation disabled — volume jump on device switch
  - **M1-M7 (MEDIUM):** CrossfadeState @unchecked Sendable, EQ dropout during crossfade, virtual device filter location, no clock source management, destroyAsync race window, stale device cache, AirPlay not given extended warmup
  - **L1-L5 (LOW):** Duplicate appliedPIDs.insert, hasCustomSettings edge case, BiquadMath sign convention, shared EQ instance, 400ms poll overhead

### Agent 3 — Mediator/Synthesizer
- **Scope:** Cross-reference Agents 1 and 2, read code to verify claims, facilitate discussion, produce synthesis
- **Key corrections:**
  - Downgraded M3 (virtual device filter) to LOW — filter exists, just in different location
  - Downgraded M4 (clock source) to LOW — `kAudioAggregateDeviceMainSubDeviceKey` IS set in code
  - Found that `CrossfadePhase` enum already exists as dead code (L19-28 in CrossfadeState.swift) — scaffolding is there
  - Confirmed `kAudioDevicePropertyLatency`/`SafetyOffset` are never queried anywhere in codebase
  - Confirmed `kAudioAggregateDeviceTapAutoStartKey` already set to `true` — not a new fix
  - Caught critical overlap issue: Agent 1's "keep primary at full volume" proposal would cause doubled audio because `secondaryMultiplier` returns 1.0 when `!isActive`

### Agent 4 — Skeptical Planner
- **Scope:** Challenge all findings, read code to ground skepticism, write comprehensive implementation plan
- **Key corrections and rejections:**
  - **REJECTED A4 (sample rate normalization):** Both numerator (`secondarySampleCount`) and denominator (`totalSamples`) use the secondary device's sample rate — the ratio is inherently correct. Agent 3's claim of 8.8% timing error was wrong.
  - **Kept BT warmup at 500ms** (not 250ms) — with the Phase 1 fix, this becomes a floor, not the sole protection
  - **Device latency querying demoted to logging only** — BT devices report ~3ms codec latency, not 200-400ms connection warmup
  - **Found the compelling reason to use CrossfadePhase enum**: during `.warmingUp`, secondary must return 0.0 (not the default 1.0), requiring a third state
- **Output:** Comprehensive plan written to `docs/audio-wiring-plan.md` with 5 phases, pseudocode, risk analysis, dependency graph

### External Review (Codex)
- **5 criticisms applied to plan:**
  1. **[High]** Phase 4.2 `asyncAfter(0.1)` is timing heuristic, not real completion — fixed with `destroyAsync(completion:)` + `invalidateAsync()` + `withCheckedContinuation`
  2. **[Medium]** `isActive` blast radius underestimated — added full callsite audit table (EQ bypass, volume compensation, ramp coefficient, multiplier, diagnostics)
  3. **[Medium]** Duplicate `appliedPIDs.insert` already confirmed — changed from "needs verification" to confirmed with fix instruction
  4. **[Medium]** Concurrency stance inconsistent — clarified: single-writer aligned loads/stores safe on ARM64 vs multi-writer RMW not safe
  5. **[Low]** TDD fail-first not stated — added methodology section to testing strategy

---

## Phase 2: Implementation (5 parallel agent waves)

### Wave 1 (parallel)

#### Phase 1 Implementation Agent — Fix BT Silence Bug (CRITICAL)
- **Files modified:**
  - `FineTune/Audio/Crossfade/CrossfadeState.swift`
  - `FineTune/Audio/ProcessTapController.swift`
  - `testing/tests/CrossfadeStateTests.swift` (7 new tests)
  - `testing/tests/AudioSwitchingTests.swift` (8 tests updated)
- **Changes:**
  - `CrossfadePhase` enum: reduced from 4 to 3 cases (`idle`, `warmingUp`, `crossfading`), Int raw values for RT-safe storage
  - Replaced `isActive: Bool` with `_phaseRawValue: Int` + `phase` computed property + backward-compatible `isActive` computed property
  - `beginCrossfade(at:)` now sets `.warmingUp` (primary=1.0, secondary=0.0)
  - New `beginCrossfading()` transitions to `.crossfading` (engages cos/sin curves)
  - `updateProgress(samples:)` only advances `secondarySampleCount`/`progress` during `.crossfading`; always increments `secondarySamplesProcessed` for warmup detection
  - `performCrossfadeSwitch` restructured: Phase A (warmup with 3s timeout for BT) then Phase B (crossfade after warmup confirmed)
- **Result:** 269 tests, 0 failures

#### Phase 5.4 Implementation Agent — Remove Duplicate Insert
- **File modified:** `FineTune/Audio/AudioEngine.swift`
- **Change:** Removed redundant `appliedPIDs.insert(app.id)` at L613 (L605 already covers both paths)
- **Result:** 269 tests, 0 failures

### Wave 2 (parallel, after Phase 1)

#### Phase 2 Implementation Agent — Fix Data Races
- **File modified:** `FineTune/Audio/ProcessTapController.swift`
- **Changes:**
  - Added 16 `_diagSecondary*` counter fields mirroring all primary diagnostic counters
  - All counter increments in `processAudioSecondary` redirected to secondary variants
  - Added `_secondaryPeakLevel: Float` — secondary callback writes here instead of shared `_peakLevel`
  - `promoteSecondaryToPrimary`: merges secondary counters (additive for counts, overwrite for format info) then resets
  - `cleanupSecondaryTap`: resets secondary counters (discards rather than merges on failure)
  - `audioLevel` getter returns `max(_peakLevel, _secondaryPeakLevel)` for smooth VU during crossfade
  - New `resetSecondaryDiagnostics()` helper
- **Result:** 269 tests, 0 failures

#### Phase 3 Implementation Agent — Volume Compensation
- **File modified:** `FineTune/Audio/ProcessTapController.swift`
- **Changes:**
  - `performCrossfadeSwitch`: replaced disabled compensation with fresh ratio computation `sourceVolume / destVolume`, clamped [0.1, 4.0]
  - `performDestructiveDeviceSwitch`: same fresh computation applied
  - Both paths guard against near-zero volumes (> 0.01 threshold)
  - Audio callback integration verified correct — compensation applied when `!crossfadeState.isActive` on primary, always on secondary
- **Result:** 269 tests, 0 failures

#### Phase 4 Implementation Agent — AirPlay + Async Destruction
- **Files modified:**
  - `FineTune/Audio/ProcessTapController.swift`
  - `FineTune/Audio/Tap/TapResources.swift`
  - `FineTune/Audio/AudioEngine.swift`
- **Changes:**
  - Renamed `isBluetoothDestination` to `needsExtendedWarmup` throughout `performCrossfadeSwitch` (7 occurrences)
  - Added `.airPlay` to transport type check: `transport == .bluetooth || transport == .bluetoothLE || transport == .airPlay`
  - `TapResources.destroyAsync(completion:)`: added optional completion handler, fires after CoreAudio teardown completes
  - New `ProcessTapController.invalidateAsync()`: async method using `withCheckedContinuation` + `DispatchGroup` to await both resource destructions
  - `AudioEngine.recreateAllTaps()`: uses `Task { @MainActor in ... }` with `withTaskGroup` to await all `invalidateAsync()` calls before recreating
- **Result:** 269 tests (+ 87 integration tests), 0 failures

### Final Verification
- `xcodebuild build`: **BUILD SUCCEEDED**
- `swift test`: **269 tests, 0 failures** (0.876 seconds)

---

## Files Modified (complete list)

| File | Phases | Summary |
|------|--------|---------|
| `FineTune/Audio/Crossfade/CrossfadeState.swift` | 1 | CrossfadePhase state machine, phase-based multipliers, two-phase transitions |
| `FineTune/Audio/ProcessTapController.swift` | 1, 2, 3, 4 | Warmup/crossfade flow, split counters, volume compensation, AirPlay warmup, invalidateAsync |
| `FineTune/Audio/AudioEngine.swift` | 4, 5.4 | Async recreateAllTaps, duplicate insert removal |
| `FineTune/Audio/Tap/TapResources.swift` | 4 | Completion handler on destroyAsync |
| `testing/tests/CrossfadeStateTests.swift` | 1 | 7 new phase-based tests + existing tests updated |
| `testing/tests/AudioSwitchingTests.swift` | 1 | 8 tests updated for two-phase model |
| `docs/audio-wiring-plan.md` | (new) | Comprehensive implementation plan with Codex corrections |

---

## Comprehensive TODO List (Remaining Work)

### Not Yet Implemented (from the plan)

#### Phase 5.1: Device Latency Property Logging (LOW)
- **What:** Add `readDeviceLatency()` and `readSafetyOffset()` helpers to `AudioDeviceID+Info.swift`
- **Where:** `FineTune/Audio/Extensions/AudioDeviceID+Info.swift`, `ProcessTapController.swift` (logging in performCrossfadeSwitch)
- **Why:** Diagnostic logging only — values not useful for warmup timing but helpful for debugging device-specific issues
- **Effort:** 30 minutes

#### Phase 5.2: Secondary EQProcessor During Crossfade (LOW, deferred)
- **What:** Create a cloned EQProcessor for the secondary callback so EQ stays active during crossfade
- **Where:** `EQProcessor.swift` (add `clone()` method), `ProcessTapController.swift` (secondary callback EQ application)
- **Why:** Currently EQ drops out during crossfade because the single shared EQProcessor has mutable biquad delay buffers that can't be safely called from two IO threads
- **Impact:** Only noticeable if user has significant EQ boost AND the crossfade is long. With current 50ms crossfade, barely perceptible
- **Effort:** Medium (2-3 hours)

#### Phase 5.3: Migrate CrossfadeState to Swift Atomics (LOW, deferred)
- **What:** Replace `nonisolated(unsafe)` with proper `Atomic` types from Swift's Synchronization framework
- **Why:** Current implementation is safe on ARM64 for single-writer fields, but not formally correct under the Swift/C++ memory model
- **Effort:** Medium (requires evaluating Synchronization framework vs swift-atomics package)

### Manual Testing Required

These tests should be performed before considering this work complete:

1. **BT Silence Bug (Phase 1) — CRITICAL:**
   - Play music in any app
   - Switch from Built-in Speakers to AirPods Pro
   - VERIFY: Speakers stay audible until AirPods take over. No silence gap.
   - Switch back. VERIFY: Same smooth transition.

2. **Fast Wired Switch (Phase 1 regression check):**
   - Switch between two wired/USB devices rapidly
   - VERIFY: Crossfade is fast (~60ms), no regression from warmup changes

3. **VU Meter (Phase 2):**
   - Watch VU meter while switching devices
   - VERIFY: No erratic jumping during crossfade

4. **Volume Compensation (Phase 3):**
   - Set speakers to 100%, AirPods to 30%
   - Switch. VERIFY: Perceived loudness stays roughly constant
   - Switch back. VERIFY: No cumulative drift

5. **AirPlay (Phase 4):**
   - Switch to HomePod/Apple TV
   - VERIFY: No silence gap, similar to BT fix

---

## Known Issues

### Active Issues (not addressed in this session)

1. **EQ dropout during crossfade (M2, MEDIUM):** EQ processing is disabled on both primary and secondary taps during crossfade because the single shared `EQProcessor` instance has mutable biquad delay buffers. If user has significant EQ boost (+6dB+), there's a brief tonal change during the 50ms crossfade. Mitigated by Phase 1 keeping EQ active on primary during the warmup phase (only drops during the 50ms actual crossfade). See Phase 5.2 above for fix plan.

2. **Device cache stale reads (M6, MEDIUM):** `devicesByUID`/`devicesByID` in `AudioDeviceMonitor` are `nonisolated(unsafe)` dictionaries written on MainActor but read from `ProcessTapController` background tasks. Probability of read-during-structural-mutation (rehash) is very low but nonzero and could theoretically crash. Fallback path in `resolveDeviceID` reads directly from CoreAudio, masking most stale data issues.

3. **Volume compensation UX question (Phase 3):** Volume compensation is now active, computing fresh `sourceVolume / destVolume` ratio at each switch. If a user intentionally sets different volumes on different devices, the compensation may feel wrong. Consider adding a user preference toggle.

4. **400ms AudioProcessMonitor poll overhead (L5, LOW):** The `refreshAsync()` poll runs every 400ms reading the full process list from CoreAudio. The process list listener should handle most changes; the poll is a safety net. Low priority but adds continuous background overhead for a menu-bar app.

### Resolved Issues (this session)

1. **BT silence gap on device switch (CRITICAL)** — Fixed by Phase 1: two-phase warmup/crossfade with `CrossfadePhase` state machine
2. **Diagnostic counter data race during crossfade (HIGH)** — Fixed by Phase 2: split into per-tap counters
3. **`_peakLevel` data race during crossfade (HIGH)** — Fixed by Phase 2: separate `_secondaryPeakLevel`
4. **Volume jump on device switch (HIGH)** — Fixed by Phase 3: fresh volume compensation ratio
5. **AirPlay not given extended warmup (MEDIUM)** — Fixed by Phase 4: added `.airPlay` to `needsExtendedWarmup`
6. **`destroyAsync` race window (MEDIUM)** — Fixed by Phase 4: completion-aware destruction with `invalidateAsync()`
7. **Duplicate `appliedPIDs.insert` (LOW)** — Fixed by Phase 5.4: removed redundant insert at AudioEngine L613

### Rejected Findings (with reasoning)

| Finding | Why Rejected |
|---------|-------------|
| A4: Sample rate normalization | Both numerator and denominator use secondary device's sample rate — ratio is inherently correct |
| C6: Reduce BT warmup to 250ms | 500ms is already in code; with Phase 1 fix it's a floor, not the sole protection |
| C7: Use device latency properties for warmup timing | BT devices report ~3ms codec latency, not 200-400ms connection warmup |
| M3: Virtual device filter omitted | Filter exists, just deferred to `createAudioDevices(from:)` — behavior is correct |
| M4: No clock source management | `kAudioAggregateDeviceMainSubDeviceKey` IS set; two aggregates during crossfade is architecturally correct |

---

## Architecture Reference

### The Fixed Crossfade Flow (Post-Phase 1)

```
User selects new device
  -> AudioEngine.setDevice()
  -> ProcessTapController.switchDevice()
  -> performCrossfadeSwitch()

    Phase A — Warmup:
      1. Set crossfadeState.phase = .warmingUp
         (primary=1.0, secondary=0.0 — speakers at full volume)
      2. Create secondary tap + aggregate for new device
      3. Sleep warmup period (500ms BT/AirPlay, 50ms wired)
      4. Poll isWarmupComplete (3s timeout BT, 500ms wired)
         — secondary callback counts samples via secondarySamplesProcessed
         — primary continues playing at full volume throughout

    Phase B — Crossfade:
      5. crossfadeState.beginCrossfading()
         (resets progress, engages cos/sin curves)
      6. Poll isCrossfadeComplete (50ms + padding)
         — primary fades: cos(progress * pi/2) -> 0.0
         — secondary fades in: sin(progress * pi/2) -> 1.0
      7. Destroy primary, promote secondary

    Fallback:
      If warmup times out -> throw -> performDestructiveDeviceSwitch()
```

### CrossfadePhase State Machine

```
.idle (primary=1.0, secondary=1.0)
  |-- beginCrossfade(at:) -->
.warmingUp (primary=1.0, secondary=0.0)
  |-- beginCrossfading() -->
.crossfading (primary=cos curve, secondary=sin curve)
  |-- complete() -->
.idle
```

---

## Agent Performance Summary

| Agent | Role | Tool Calls | Tokens | Duration |
|-------|------|-----------|--------|----------|
| Agent 1 | Best Practices Research | 64 | 115,899 | 7.3 min |
| Agent 2 | Code Review | 36 | 126,919 | 4.0 min |
| Agent 3 | Mediator/Synthesis | 21 | 85,589 | 4.3 min |
| Agent 4 | Skeptical Planner | 35 | 64,314 | 5.1 min |
| Phase 1 Impl | BT Silence Fix | 62 | 128,438 | 6.9 min |
| Phase 2 Impl | Data Race Fixes | 39 | 108,622 | 5.2 min |
| Phase 3 Impl | Volume Compensation | 27 | 66,310 | 2.3 min |
| Phase 4 Impl | AirPlay + Async Destroy | 67 | 119,873 | 5.2 min |
| Phase 5.4 Impl | Duplicate Insert | 3 | 13,900 | 0.3 min |
| **Total** | | **354** | **829,864** | **~41 min** |
