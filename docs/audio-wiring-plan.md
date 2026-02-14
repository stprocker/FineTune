# Audio Wiring Implementation Plan

**Author:** Agent 4 (The Skeptical Planner)
**Date:** 2026-02-07
**Status:** Final Review Plan

---

## Preamble: Skeptical Review of Agent 3's Findings

Before writing this plan, I challenged every finding from the prior synthesis. Below are the questions I asked, the code I read to answer them, and the conclusions I reached. These are not theoretical --- each is grounded in specific line numbers and control flow analysis.

### Q1: Is the CrossfadePhase state machine the right approach, or is it over-engineering?

**Code examined:** `CrossfadeState.swift` L19-28 (the dead enum), L57-63 (`beginCrossfade`), L70-77 (`updateProgress`); `ProcessTapController.swift` L504-508 (manual state setup), L520-522 (warmup sleep), L533-536 (poll loop).

**Finding:** The current flow already has an implicit two-phase structure: (1) sleep for warmup, (2) poll for crossfade completion. The problem is that during the "warmup sleep" at L520-522, the crossfade progress is ALREADY ticking because `isActive = true` at L507 and `updateProgress` is called from the secondary callback at L1155. By the time the 500ms BT sleep ends, progress has long since hit 1.0 (only takes ~50ms worth of samples). The primary is already at multiplier 0.0 (silent) while AirPods are still warming up.

**Conclusion:** The fix does NOT require a full state machine. The simpler and more robust approach: **delay the start of crossfade progress counting until warmup is confirmed**. Concretely, set `isActive = false` during warmup, set a separate `isWarmingUp = true` flag so the secondary still counts `secondarySamplesProcessed` (for warmup detection), and only flip `isActive = true` after warmup is confirmed. This means:
- During warmup: primary stays at multiplier 1.0 (full volume), secondary stays at multiplier 0.0 (silent via the sin curve).
- After warmup confirmed: `isActive = true`, crossfade begins normally.

The dead `CrossfadePhase` enum CAN be used if desired for clarity, but is NOT required. A boolean `isWarmingUp` is simpler and carries less risk. **I recommend using the enum but only the `idle`, `warmingUp`, and `crossfading` states. Drop `completing` --- it adds no value over the existing `progress >= 1.0` check.**

### Q2: Is the 250ms BT constant reliable across all BT devices?

**Code examined:** `ProcessTapController.swift` L181 (`crossfadeWarmupBTMs: Int = 500`).

**Finding:** The current code already uses 500ms, not 250ms as Agent 3 suggests. The 500ms value is the sleep before the crossfade poll begins, but because the crossfade starts ticking IMMEDIATELY (see Q1), the actual crossfade window is the first ~50ms of that 500ms --- and audio is already silent on the primary by the 50ms mark.

**Conclusion:** The fixed constant is inherently fragile. However, once the Phase 1 fix (delayed crossfade start) is in place, the warmup constant becomes a MINIMUM WAIT, not the only protection. The flow becomes:
1. Wait minimum warmup period (500ms for BT, 50ms for wired).
2. After sleep, check `secondarySamplesProcessed >= minimumWarmupSamples`.
3. Only THEN start the crossfade.

This makes the constant a floor, not a ceiling. The actual crossfade won't start until samples are confirmed flowing. 500ms is generous enough for all BT devices. Keep it. Do NOT reduce to 250ms --- there is no benefit since the poll loop handles the actual timing.

**Regarding adaptive warmup:** Not worth the complexity. The `secondarySamplesProcessed` check already adapts --- if BT connects in 200ms, the 500ms sleep still completes, but the crossfade starts immediately after. The sleep is cheap (it's an async Task.sleep, not blocking anything).

### Q3: Won't the user hear audio from BOTH devices during warmup?

**Code examined:** `CrossfadeState.swift` L102-110 (`primaryMultiplier`), L115-120 (`secondaryMultiplier`).

**Finding:** During warmup (with the fix from Q1), `isActive` will be `false`, so:
- `primaryMultiplier` returns 1.0 (full volume on speakers).
- `secondaryMultiplier` returns 1.0 (full volume on AirPods --- because when `!isActive`, it returns 1.0 at L119).

This IS a problem. During warmup, both devices would be at full volume. As soon as AirPods become audible, the user hears doubled audio for the entire crossfade duration.

**Conclusion:** This is why we need a third state. During warmup:
- Primary: full volume (1.0) --- correct, keeps speakers playing.
- Secondary: SILENT (0.0) --- NOT the default 1.0.

The current `secondaryMultiplier` returns 1.0 when `!isActive` because after promotion, the now-primary tap needs full volume. We need to distinguish "warmup" from "promoted". **This is the compelling reason to use the `CrossfadePhase` enum.** The three states:
- `.idle`: primary=1.0, secondary=1.0 (after promotion to primary)
- `.warmingUp`: primary=1.0, secondary=0.0 (warmup, both taps exist but only primary audible)
- `.crossfading`: primary=cos curve, secondary=sin curve (normal crossfade)

### Q4: Is the sample rate normalization actually audible?

**Code examined:** `CrossfadeState.swift` L74 (`progress = ... Float(secondarySampleCount) / Float(max(1, totalSamples))`), `ProcessTapController.swift` L635 (`crossfadeState.totalSamples = CrossfadeConfig.totalSamples(at: deviceSampleRate)`).

**Finding:** `totalSamples` is computed from `deviceSampleRate` (the destination device's rate) and `secondarySampleCount` accumulates samples from the secondary callback (which runs at the destination device's rate). Both use the SAME rate. Agent 3's claim about 48/44.1 mismatch causing timing error is WRONG for the crossfade itself --- the crossfade duration is correctly computed relative to the secondary device's clock.

The only scenario where this matters is if you wanted the crossfade duration to be exactly 50ms wall-clock time and the secondary device runs at a different rate than expected. But since both numerator and denominator are in secondary-device samples, the ratio is correct. The crossfade will be exactly `CrossfadeConfig.duration` seconds as measured by the secondary device's clock. Any drift between device clocks over 50-100ms is negligible (< 0.1 samples at worst).

**Conclusion: REJECT this finding.** The sample rate normalization fix is unnecessary. The current code is correct. Do not implement A4.

### Q5: Do BT devices report meaningful latency values?

**Finding:** `kAudioDevicePropertyLatency` reports the device's internal processing latency in frames. For BT devices, this typically reports the codec latency (SBC ~150 frames, AAC ~120 frames at 44.1kHz, i.e., ~3ms). It does NOT report the A2DP connection establishment latency (~200-400ms). `kAudioDevicePropertySafetyOffset` is similar --- small buffer size, not connection warmup.

**Conclusion:** Querying these properties is informative but does NOT solve the BT warmup problem. The `secondarySamplesProcessed` check combined with the minimum sleep is the correct approach. Query the properties for logging/diagnostics only. Do not use them to compute warmup timing.

### Q6: Is volume compensation the right UX?

**Code examined:** `ProcessTapController.swift` L493-495 (currently disabled with comment "causes cumulative attenuation on round-trip switches").

**Finding:** The comment explains why it was disabled. If device A is at 80% and device B is at 50%, compensation would scale by 80/50 = 1.6x. Switching back would scale by 50/80 = 0.625x. Round-trip: 1.6 * 0.625 = 1.0, so cumulative attenuation is NOT a mathematical problem. The bug was likely that the compensation was being applied cumulatively without resetting on each switch.

**Conclusion:** Volume compensation IS good UX (prevents volume jump when switching between devices with different system volumes). But the implementation needs to compute a fresh ratio at each switch (not accumulate). Re-enable with fresh computation. However, this is orthogonal to the crossfade fix and should be a separate phase.

### Q7: Is the destroyAsync 100ms delay reliable?

**Code examined:** `TapResources.swift` L56-86 (`destroyAsync`). The `recreateAllTaps` function at `AudioEngine.swift` L707-717 calls `tap.invalidate()` then immediately `taps.removeAll()` and `applyPersistedSettings()` which creates new taps.

**Finding:** `destroyAsync` dispatches destruction to a utility queue. `applyPersistedSettings` creates new taps on the main actor. There is no explicit synchronization between the background destruction and the new tap creation. In practice, the background destruction calls `AudioHardwareDestroyProcessTap` which might race with `AudioHardwareCreateProcessTap` for the same process.

**Conclusion:** Adding a fixed delay is fragile. The correct fix: `recreateAllTaps` should await the destruction before creating new taps. Since the function is on `@MainActor`, it can dispatch the destroys to a background queue, wait for completion via a DispatchGroup or async/await bridge, then proceed with recreation. However, this is a LOW priority issue --- it only manifests during the rare permission-confirmation recreate or health-check recreate paths.

### Q8: Should EQ during crossfade be reconsidered given longer crossfade?

**Code examined:** `EQProcessor.swift` L29-30 (shared `delayBufferL`/`delayBufferR`), L156-159 (`vDSP_biquad` writes to delay buffers).

**Finding:** The delay buffers are shared mutable state. If two IO threads both call `process()` simultaneously, the delay buffers will be corrupted, causing filter state corruption and audible glitching far worse than a brief EQ dropout. Agent 3 is right to defer this.

With the Phase 1 fix, the crossfade duration stays at 50ms (configurable via UserDefaults). The warmup phase keeps primary at full volume WITH EQ. The crossfade itself is still 50ms --- brief enough that EQ dropout is not noticeable.

**Conclusion:** Defer EQ during crossfade. Agent 3 is correct. The 50ms dropout is acceptable.

---

## Implementation Plan

### Phase 1: Fix the Bluetooth Silence Bug (CRITICAL)

This is the only MUST-FIX. The user hears silence when switching to BT because the crossfade completes (primary goes silent) before BT starts producing audible output.

#### Change 1.1: Introduce CrossfadePhase to CrossfadeState

**What:** Replace the boolean `isActive` with a three-state `phase` field that distinguishes warmup from crossfading.

**Where:** `FineTune/Audio/Crossfade/CrossfadeState.swift`

**How:**

1. Keep the existing `CrossfadePhase` enum but remove the `completing` case (unnecessary):
```swift
public enum CrossfadePhase: Int, Equatable {
    case idle = 0
    case warmingUp = 1
    case crossfading = 2
}
```
Using `Int` raw value for RT-safe storage.

2. Replace `isActive: Bool` with `phase: CrossfadePhase`:
```swift
// Replace:
nonisolated(unsafe) public var isActive: Bool = false

// With:
nonisolated(unsafe) private var _phaseRawValue: Int = 0
public var phase: CrossfadePhase {
    get { CrossfadePhase(rawValue: _phaseRawValue) ?? .idle }
    set { _phaseRawValue = newValue.rawValue }
}

/// Backward-compatible convenience: true when warmingUp OR crossfading
public var isActive: Bool {
    _phaseRawValue != CrossfadePhase.idle.rawValue
}
```

3. Update `beginCrossfade`:
```swift
public mutating func beginCrossfade(at sampleRate: Double) {
    progress = 0
    secondarySampleCount = 0
    secondarySamplesProcessed = 0
    totalSamples = CrossfadeConfig.totalSamples(at: sampleRate)
    phase = .warmingUp  // <-- NOT crossfading yet
    OSMemoryBarrier()
}
```

4. Add a new method to transition from warmup to crossfade:
```swift
public mutating func beginCrossfading() {
    secondarySampleCount = 0  // Reset so crossfade progress starts from 0
    progress = 0
    phase = .crossfading
    OSMemoryBarrier()
}
```

5. Update `complete`:
```swift
public mutating func complete() {
    phase = .idle
    progress = 0
    secondarySampleCount = 0
    secondarySamplesProcessed = 0
    totalSamples = 0
    OSMemoryBarrier()
}
```

6. Update multiplier computations:
```swift
@inline(__always)
public var primaryMultiplier: Float {
    switch phase {
    case .idle:
        // After complete() or before crossfade: full volume
        // But check progress for dead-zone safety
        return progress >= 1.0 ? 0.0 : 1.0
    case .warmingUp:
        // Keep primary at full volume during warmup
        return 1.0
    case .crossfading:
        // Equal-power fade-out
        return cos(progress * .pi / 2.0)
    }
}

@inline(__always)
public var secondaryMultiplier: Float {
    switch phase {
    case .idle:
        // After promotion: full volume
        return 1.0
    case .warmingUp:
        // Silent during warmup (secondary not yet audible)
        return 0.0
    case .crossfading:
        // Equal-power fade-in
        return sin(progress * .pi / 2.0)
    }
}
```

7. Update `updateProgress` to only drive crossfade in `.crossfading` phase:
```swift
@inline(__always)
public mutating func updateProgress(samples: Int) -> Float {
    secondarySamplesProcessed += samples
    if phase == .crossfading {
        secondarySampleCount += Int64(samples)
        progress = min(1.0, Float(secondarySampleCount) / Float(max(1, totalSamples)))
    }
    return progress
}
```

**Why:** This cleanly separates warmup (both taps exist, only primary audible) from crossfading (equal-power transition). The `isActive` computed property maintains backward compatibility for EQ checks and existing code.

**Risk:** The `isActive` computed property changes semantics from "crossfade is happening" to "any crossfade-related activity is happening (warmup or crossfade)". This has blast radius beyond EQ -- `isActive` currently controls:

| Callsite | File:Line | Current behavior when `isActive` | Correct behavior during `.warmingUp` | Correct behavior during `.crossfading` | Action needed |
|---|---|---|---|---|---|
| EQ bypass | ProcessTapController L1030, L1072 | Skip EQ | Skip EQ (two callbacks active) | Skip EQ (two callbacks active) | No change -- `isActive` works |
| Volume compensation | ProcessTapController L1057 | Use 1.0 (no compensation) | Use 1.0 (compensation should apply after crossfade) | Use 1.0 (mid-transition) | No change -- `isActive` works |
| Ramp coefficient selection | ProcessTapController L1176 | Use `secondaryRampCoefficient` | Use `secondaryRampCoefficient` (secondary tap active) | Use `secondaryRampCoefficient` | No change -- `isActive` works |
| Crossfade multiplier application | ProcessTapController L1015, L1139 | Apply cos/sin curves | Primary=1.0, Secondary=0.0 (handled by new multiplier logic) | Apply cos/sin curves | Handled by Change 1.1 multiplier update |
| Diagnostic counter selection | ProcessTapController L953, L1101 | Both increment shared counters | Should use split counters | Should use split counters | Handled by Change 2.1 |

**Mandatory audit**: Before merging Phase 1, grep for all references to `crossfadeState.isActive` and `crossfadeState.phase` and verify each callsite against this table. Any callsite that needs to distinguish `.warmingUp` from `.crossfading` must check `phase` directly instead of `isActive`.

**Testing:**
- Unit tests: `CrossfadeStateTests` --- add tests for phase transitions, multiplier values in each phase.
- Test that `primaryMultiplier` is 1.0 during `.warmingUp`.
- Test that `secondaryMultiplier` is 0.0 during `.warmingUp`.
- Test that `updateProgress` does NOT advance `secondarySampleCount` during `.warmingUp`.
- Test that `updateProgress` DOES advance `secondarySamplesProcessed` during `.warmingUp` (for warmup detection).

#### Change 1.2: Update performCrossfadeSwitch to use two-phase flow

**What:** Restructure the crossfade switch to: (1) warmup with primary at full volume, (2) begin actual crossfade only after secondary is confirmed producing audio.

**Where:** `ProcessTapController.swift` L458-558

**How:**

1. Replace the manual state setup at L504-508 with:
```swift
// Begin warmup phase: primary stays at full volume, secondary starts silent
crossfadeState.progress = 0
crossfadeState.secondarySampleCount = 0
crossfadeState.secondarySamplesProcessed = 0
crossfadeState.phase = .warmingUp
OSMemoryBarrier()
```
Note: We cannot use `beginCrossfade(at:)` here because sample rate is unknown until after tap creation (see existing comment at L500-503). This is fine --- we set `totalSamples` later at L635.

2. After `createSecondaryTap` and the warmup sleep (L522), replace the poll loop at L533-536 with:
```swift
// Phase A: Wait for secondary tap warmup
let warmupMs = isBluetoothDestination ? crossfadeWarmupBTMs : crossfadeWarmupMs
logger.info("[CROSSFADE] Step 4: Waiting for secondary tap warmup (\(warmupMs)ms)...")
try await Task.sleep(for: .milliseconds(UInt64(warmupMs)))

// Poll for warmup confirmation (secondary producing samples)
let warmupTimeoutMs = isBluetoothDestination ? 3000 : 500
var warmupElapsedMs = 0
while !crossfadeState.isWarmupComplete && warmupElapsedMs < warmupTimeoutMs {
    try await Task.sleep(for: .milliseconds(crossfadePollIntervalMs))
    warmupElapsedMs += Int(crossfadePollIntervalMs)
}

if !crossfadeState.isWarmupComplete {
    let samplesProcessed = crossfadeState.secondarySamplesProcessed
    logger.error("[CROSSFADE] Secondary tap warmup incomplete after \(warmupMs + warmupElapsedMs)ms (processed: \(samplesProcessed)/\(CrossfadeState.minimumWarmupSamples) samples)")
    throw NSError(domain: "ProcessTapController", code: -2,
                  userInfo: [NSLocalizedDescriptionKey: "Secondary tap warmup incomplete"])
}

logger.info("[CROSSFADE] Warmup confirmed. Starting crossfade.")

// Phase B: Begin actual crossfade (secondary becomes audible, primary fades)
crossfadeState.beginCrossfading()

// Poll for crossfade completion
let crossfadeTimeoutMs = Int(CrossfadeConfig.duration * 1000) + (isBluetoothDestination ? crossfadeTimeoutPaddingBTMs : crossfadeTimeoutPaddingMs)
var crossfadeElapsedMs = 0
while !crossfadeState.isCrossfadeComplete && crossfadeElapsedMs < crossfadeTimeoutMs {
    try await Task.sleep(for: .milliseconds(crossfadePollIntervalMs))
    crossfadeElapsedMs += Int(crossfadePollIntervalMs)
}

// Small buffer for final samples
try await Task.sleep(for: .milliseconds(Int64(crossfadePostBufferMs)))
```

3. At L635 (inside `createSecondaryTap`), keep the `totalSamples` assignment as-is. It sets the crossfade duration but progress won't start ticking until `beginCrossfading()` is called.

**Why:** This is the core bug fix. By keeping primary at full volume during warmup and delaying the crossfade start, the user never experiences silence. The crossfade only begins once the secondary device is confirmed to be producing audio.

**Risk:** The total switch time for BT increases: 500ms warmup + possible poll + 50ms crossfade + 10ms buffer. Worst case ~560ms. This is acceptable --- users expect some latency when switching to BT.

**Dependencies:** Change 1.1 must be completed first.

**Testing:**
- Integration test with mock sleep hook: verify primary stays at full volume during warmup.
- Integration test: verify crossfade only starts after warmup confirmation.
- Manual test: switch from built-in speakers to AirPods. Speakers should remain audible until AirPods take over. No silence gap.
- Manual test: switch between two wired devices. Crossfade should be fast (~60ms total).

#### Change 1.3: Set totalSamples before warmup starts (minor ordering fix)

**What:** Move the `totalSamples` assignment to happen before the secondary IOProc starts, to prevent a brief window where `totalSamples` is 0.

**Where:** `ProcessTapController.swift` --- inside `createSecondaryTap`, move L635 earlier.

**How:** Currently at L635, `totalSamples` is set AFTER the converter is configured but BEFORE the IOProc is created at L644. This is actually fine --- the IOProc creation is where the callback becomes callable. So this is a non-issue. **No change needed.** (Agent 3 flagged this but the ordering is already correct.)

---

### Phase 2: Data Race Fixes (HIGH)

These fixes eliminate data races that cause diagnostic inaccuracy and potential TSan violations. They should be done together as they are all in the same files.

#### Change 2.1: Split diagnostic counters into primary/secondary

**What:** Give the secondary callback its own set of diagnostic counters. Merge on promotion.

**Where:** `ProcessTapController.swift` L61-76 (declarations), L953 (primary callback), L1101 (secondary callback), L695-718 (`promoteSecondaryToPrimary`)

**How:**

1. Add secondary diagnostic counters:
```swift
// Secondary tap diagnostic counters (only active during crossfade)
private nonisolated(unsafe) var _diagSecondaryCallbackCount: UInt64 = 0
private nonisolated(unsafe) var _diagSecondaryInputHasData: UInt64 = 0
private nonisolated(unsafe) var _diagSecondaryOutputWritten: UInt64 = 0
// ... (mirror the full set of primary counters)
```

2. In `processAudioSecondary`, replace `_diagCallbackCount += 1` (L1101) with `_diagSecondaryCallbackCount += 1`, and similarly for all other shared counter increments in that function.

3. In `promoteSecondaryToPrimary`, merge counters:
```swift
_diagCallbackCount += _diagSecondaryCallbackCount
_diagInputHasData += _diagSecondaryInputHasData
_diagOutputWritten += _diagSecondaryOutputWritten
// ... merge all
// Reset secondary counters
_diagSecondaryCallbackCount = 0
// ... reset all
```

**Why:** During crossfade, both callbacks run simultaneously. `+= 1` on shared `UInt64` is a read-modify-write cycle that is NOT atomic on ARM64 (the load and store are individually atomic, but the read-modify-write sequence is not). Lost increments could mislead the health-check system into thinking a tap is broken.

**Concurrency clarification:** The specific safety claim is: *single-writer aligned loads/stores* are safe on ARM64 (e.g., `crossfadeState.progress` written only by the secondary callback). *Multi-writer read-modify-write* sequences (e.g., `_diagCallbackCount += 1` from both callbacks) are NOT safe on any architecture. These are distinct patterns requiring distinct solutions -- splitting counters solves the multi-writer problem without requiring atomics.

**Risk:** Low. This is purely additive --- new fields, no behavior change.

**Testing:** Existing `ProcessTapControllerTests` should continue to pass. Add a test that verifies counter merge after promotion.

#### Change 2.2: Separate _peakLevel for secondary

**What:** Give the secondary callback its own peak level variable.

**Where:** `ProcessTapController.swift` L53 (`_peakLevel`), L993 (primary write), L1130 (secondary write), L87 (`audioLevel` getter), L695-718 (`promoteSecondaryToPrimary`)

**How:**

1. Add:
```swift
private nonisolated(unsafe) var _secondaryPeakLevel: Float = 0.0
```

2. In `processAudioSecondary`, replace `_peakLevel` writes at L1130 with `_secondaryPeakLevel`.

3. In `promoteSecondaryToPrimary`:
```swift
_peakLevel = _secondaryPeakLevel
_secondaryPeakLevel = 0.0
```

4. Optionally, the `audioLevel` getter could return `max(_peakLevel, _secondaryPeakLevel)` during crossfade for a smoother VU transition. But this is a nice-to-have.

**Why:** Both callbacks do exponential smoothing (`_peakLevel = _peakLevel + factor * (rawPeak - _peakLevel)`) which is a read-modify-write on a shared Float. This causes VU meter jitter during crossfade. The smoothing math produces wrong results when two threads interleave reads and writes.

**Risk:** Low. VU meter shows the primary's level during crossfade, then switches to secondary's level on promotion. Might see a small VU jump at promotion, but this is better than jitter during crossfade.

**Testing:** Visual verification that VU meter doesn't jitter during device switch.

---

### Phase 3: Volume Compensation (MEDIUM)

This is a UX improvement, not a bug fix. Switching from a device at 80% volume to one at 30% volume causes a noticeable loudness change.

#### Change 3.1: Re-enable volume compensation with fresh computation

**What:** Compute a fresh volume ratio at each switch and apply it as a multiplier that ramps to target over ~30ms.

**Where:** `ProcessTapController.swift` L459-495 (volume reading), L48 (`_deviceVolumeCompensation`), L1028/L1057/L1189/L1225 (compensation usage)

**How:**

1. In `performCrossfadeSwitch`, after reading source/dest volumes (L467-483), compute fresh ratio:
```swift
// Compute volume compensation: adjust so perceived loudness stays constant
// Only apply if both devices have volume controls
if sourceVolume > 0.01 && destVolume > 0.01 {
    _deviceVolumeCompensation = sourceVolume / destVolume
    // Clamp to reasonable range to avoid extreme amplification
    _deviceVolumeCompensation = min(max(_deviceVolumeCompensation, 0.1), 4.0)
} else {
    _deviceVolumeCompensation = 1.0
}
```

2. Remove the "disabled" comment at L493-495 and replace with active compensation.

3. In `promoteSecondaryToPrimary`, keep compensation active. It will naturally be overwritten on the next switch.

4. Add a compensation ramp: instead of applying the ratio instantly, ramp from 1.0 to the target ratio over ~30ms using the existing volume ramper infrastructure. This prevents a step change at the instant the crossfade begins.

**Why:** The previous implementation was disabled due to "cumulative attenuation" but that bug was in the persistence, not the math. Computing fresh at each switch eliminates accumulation.

**Risk:** Medium. If the user intentionally set different volumes on different devices, compensation might feel wrong. Consider adding a user preference to disable this. Also, devices without volume controls (returning 1.0) would get no compensation, which is correct.

**Testing:** Switch between speakers at 100% and AirPods at 50%. Volume should stay roughly constant. Switch back. Volume should still stay roughly constant (no cumulative drift).

---

### Phase 4: Robustness Improvements (MEDIUM)

#### Change 4.1: Add AirPlay to extended warmup transport types

**What:** AirPlay devices (HomePod, Apple TV) have similar latency to Bluetooth. Apply extended warmup.

**Where:** `ProcessTapController.swift` L475-482 (transport type check)

**How:**

Replace:
```swift
isBluetoothDestination = (transport == .bluetooth || transport == .bluetoothLE)
```

With:
```swift
let needsExtendedWarmup = (transport == .bluetooth || transport == .bluetoothLE || transport == .airPlay)
```

And rename `isBluetoothDestination` to `needsExtendedWarmup` throughout `performCrossfadeSwitch`.

**Why:** AirPlay uses network buffering with similar latency characteristics to Bluetooth A2DP. Without extended warmup, AirPlay switches would have the same silence bug.

**Risk:** Low. AirPlay warmup might be faster than BT in practice, but the warmup confirmation check means the crossfade starts as soon as samples flow, regardless of the sleep duration.

**Testing:** Manual test switching to an AirPlay device (HomePod, Apple TV).

#### Change 4.2: Safer recreateAllTaps with true completion-aware destruction

**What:** Ensure old tap resources are fully destroyed before creating new taps, using real completion signaling rather than timing heuristics.

**Where:** `TapResources.swift` L56-86 (`destroyAsync`), `ProcessTapController.swift` (`invalidate`), `AudioEngine.swift` L707-717 (`recreateAllTaps`)

**How:**

1. Modify `TapResources.destroyAsync()` to accept an optional completion handler:
```swift
func destroyAsync(completion: (() -> Void)? = nil) {
    let tapID = self.tapID
    let aggregateID = self.aggregateID
    let ioProcID = self.ioProcID
    // Clear instance state immediately
    self.tapID = kAudioObjectUnknown
    self.aggregateID = kAudioObjectUnknown
    self.ioProcID = nil

    DispatchQueue.global(qos: .utility).async {
        // Teardown order: Stop -> DestroyIOProc -> DestroyTap -> DestroyAggregate
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID = ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        completion?()
    }
}
```

2. Add an async wrapper to `ProcessTapController.invalidate()`:
```swift
func invalidateAsync() async {
    await withCheckedContinuation { continuation in
        let group = DispatchGroup()
        if primaryResources.tapID != kAudioObjectUnknown {
            group.enter()
            primaryResources.destroyAsync { group.leave() }
        }
        if secondaryResources.tapID != kAudioObjectUnknown {
            group.enter()
            secondaryResources.destroyAsync { group.leave() }
        }
        group.notify(queue: .global(qos: .utility)) {
            continuation.resume()
        }
    }
}
```

3. Update `recreateAllTaps` to await real destruction:
```swift
private func recreateAllTaps() {
    Task { @MainActor in
        // Destroy all taps and await their actual completion
        await withTaskGroup(of: Void.self) { group in
            for (_, tap) in taps {
                group.addTask { await tap.invalidateAsync() }
            }
        }
        taps.removeAll()
        appliedPIDs.removeAll()
        lastHealthSnapshots.removeAll()

        // Now safe to recreate -- all CoreAudio resources are confirmed destroyed
        applyPersistedSettings()
    }
}
```

**Why:** Without this, `applyPersistedSettings` can race with `destroyAsync` background teardown, potentially creating duplicate taps for the same process. The previous approach of `asyncAfter(0.1)` was still a timing heuristic that did not prove destruction had finished -- it just hid the same race behind a delay. Real completion callbacks eliminate the race entirely.

**Risk:** Low. The `destroyAsync` completion fires after `AudioHardwareDestroyAggregateDevice` returns (which itself may be async per Apple docs, but the API call completing is the best signal we have). The `withCheckedContinuation` bridge is standard Swift concurrency.

**Testing:** Trigger permission confirmation path repeatedly. Verify no duplicate taps created. Add a unit test that confirms `invalidateAsync` does not return until destruction dispatches have completed.

---

### Phase 5: Polish (LOW)

#### Change 5.1: Add device latency property logging

**What:** Query `kAudioDevicePropertyLatency` and `kAudioDevicePropertySafetyOffset` for diagnostic logging during crossfade.

**Where:** `AudioDeviceID+Info.swift` (new methods), `ProcessTapController.swift` (logging in `performCrossfadeSwitch`)

**How:**

Add to `AudioDeviceID+Info.swift`:
```swift
nonisolated func readDeviceLatency() -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyLatency,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var latency: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(self, &address, 0, nil, &size, &latency)
    return latency
}

nonisolated func readSafetyOffset() -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertySafetyOffset,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var offset: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(self, &address, 0, nil, &size, &offset)
    return offset
}
```

Use in crossfade logging only. Do NOT use these values for warmup timing (see Q5 above).

**Why:** Diagnostic logging helps debug device-specific issues. The latency values themselves are not useful for computing warmup time but are useful for understanding why a particular device might behave differently.

**Risk:** None. Logging only.

#### Change 5.2: Secondary EQProcessor (deferred)

**What:** Create a cloned EQProcessor for the secondary callback during crossfade.

**Where:** `EQProcessor.swift`, `ProcessTapController.swift` (secondary callback EQ application)

**Why deferred:** Requires duplicating EQ state (delay buffers, settings, setup). The 50ms EQ dropout during crossfade is not perceptible to most users. The warmup phase (Phase 1 fix) has EQ on primary at full volume, so EQ is only missing during the 50ms actual crossfade.

**Estimated effort:** Medium. Would need to add `clone()` to EQProcessor, manage lifecycle of the secondary instance, transfer state on promotion.

#### Change 5.3: Migrate CrossfadeState to Swift Atomics

**What:** Replace `nonisolated(unsafe)` with proper `Atomic` types from Swift's Synchronization framework (or `swift-atomics` package).

**Why deferred:** The current implementation is safe on ARM64 *for single-writer fields* (e.g., `progress` written only by the secondary callback, read by the primary). Multi-writer fields like diagnostic counters are addressed by Change 2.1 (splitting). The remaining `nonisolated(unsafe)` fields follow the single-writer pattern and are safe on ARM64, but are not formally correct under the Swift/C++ memory model. This is a code hygiene issue, not a correctness issue on current hardware. Revisit if the codebase adds multi-writer patterns or needs to run on non-ARM64.

#### Change 5.4: Remove duplicate appliedPIDs.insert

**What:** Remove the redundant `appliedPIDs.insert(app.id)` at `AudioEngine.swift` L613. This is confirmed -- L605 inserts `app.id` unconditionally (to prevent retry storms regardless of tap outcome), and L613 inserts it again after the tap creation guard succeeds. The second insert is harmless but redundant.

**Where:** `AudioEngine.swift` L613

**How:** Delete the line `appliedPIDs.insert(app.id)` at L613. The insert at L605 already covers this case.

**Risk:** None.

---

## Dependency Graph

```
Phase 1.1 (CrossfadePhase enum)
    |
    v
Phase 1.2 (two-phase crossfade flow)
    |
    v
Phase 2.1 + 2.2 (data race fixes, independent of each other)
    |
    v
Phase 3.1 (volume compensation, needs crossfade working correctly first)
    |
    v
Phase 4.1 + 4.2 (independent of each other, can be done in any order)
    |
    v
Phase 5 (all items independent, do in any order)
```

Phases 2, 3, and 4 could be done in parallel once Phase 1 is complete. Phase 5 items are all independent.

---

## Rejected Recommendations

| Recommendation | Reason for Rejection |
|---|---|
| A4: Sample rate normalization for crossfade progress | **Incorrect analysis.** Both numerator (secondarySampleCount) and denominator (totalSamples) are in secondary device samples. The ratio is inherently correct regardless of source device sample rate. |
| C6: Reduce BT warmup to 250ms | **Premature optimization.** 500ms is already the value in code. With Phase 1 fix, the sleep is a minimum floor, not the sole protection. No reason to reduce. |
| C7: Use device latency properties for warmup timing | **Misleading values.** BT devices report codec latency (~3ms), not connection warmup (~200-400ms). Use for logging only. |
| M6: Lock for device cache dictionaries | **Not examined in detail**, but device cache is accessed from MainActor in AudioDeviceMonitor. No lock needed unless off-main-actor access is added. |
| M1: Migrate to Swift Atomics | **High cost, low benefit.** Current patterns are safe on ARM64. Revisit later. |

---

## Testing Strategy

**Methodology: Test-Driven Development (fail-first).** Per repo policy, each change MUST follow this sequence:
1. Write a failing test that captures the expected behavior
2. Verify the test fails for the right reason
3. Implement the fix
4. Verify the test passes
5. Verify no existing tests regressed

This applies to all unit and integration tests below. Manual tests follow after automated tests pass.

### Unit Tests (Changes 1.1, 2.1, 2.2)

All in `testing/tests/CrossfadeStateTests.swift`:

```
testPhaseTransitionsIdleToWarmingUp()
testPhaseTransitionsWarmingUpToCrossfading()
testPrimaryMultiplierDuringWarmup() -- must be 1.0
testSecondaryMultiplierDuringWarmup() -- must be 0.0
testProgressDoesNotAdvanceDuringWarmup()
testWarmupSamplesStillCountDuringWarmup()
testBeginCrossfadingResetsProgress()
testEqualPowerConservationDuringCrossfading() -- existing test, verify still passes
```

### Integration Tests (Change 1.2)

In `testing/tests/ProcessTapControllerTests.swift`, using existing test hooks:

```
testCrossfadeSwitchKeepsPrimaryAudibleDuringWarmup()
testCrossfadeSwitchOnlyStartsCrossfadeAfterWarmupConfirmed()
testCrossfadeSwitchFallsBackOnWarmupTimeout()
```

### Manual Test Protocol

1. **BT Silence Bug (Phase 1):**
   - Play music in any app.
   - Switch from Built-in Speakers to AirPods Pro.
   - VERIFY: Speakers stay audible until AirPods take over. No silence gap.
   - Switch back. VERIFY: Same smooth transition.

2. **Fast Wired Switch (Phase 1 regression):**
   - Switch between two wired/USB devices rapidly.
   - VERIFY: Crossfade is fast (~60ms), no regression from warmup changes.

3. **VU Meter (Phase 2):**
   - Watch VU meter while switching devices.
   - VERIFY: No erratic jumping during crossfade.

4. **Volume Compensation (Phase 3):**
   - Set speakers to 100%, AirPods to 30%.
   - Switch. VERIFY: Perceived loudness stays similar.
   - Switch back. VERIFY: No cumulative drift.

5. **AirPlay (Phase 4):**
   - Switch to HomePod/Apple TV.
   - VERIFY: No silence gap, similar to BT fix.

---

## Estimated Effort

| Phase | Effort | Risk |
|---|---|---|
| Phase 1 (BT silence fix) | 3-4 hours | Medium (touches RT-critical path) |
| Phase 2 (data races) | 1-2 hours | Low (additive changes) |
| Phase 3 (volume compensation) | 2-3 hours | Medium (UX impact) |
| Phase 4 (robustness) | 1-2 hours | Low |
| Phase 5 (polish) | Variable | Low |

**Total for Phases 1-2 (critical path): 4-6 hours.**

---

## Summary

The core problem is straightforward: the crossfade starts counting before the BT device is ready. The fix is equally straightforward: don't start the crossfade until the device is confirmed ready. Everything else is cleanup and hardening.

The most important insight from this review is that Agent 3's A4 finding (sample rate normalization) is incorrect and should NOT be implemented. The crossfade timing math is already correct because both numerator and denominator use the same clock. Implementing an unnecessary "fix" would add complexity without benefit.

Phase 1 is the only change that fixes user-visible behavior. Phases 2-5 improve code quality and robustness but are not user-facing. Prioritize accordingly.
