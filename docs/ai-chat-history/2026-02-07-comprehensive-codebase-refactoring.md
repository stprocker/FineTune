# Comprehensive Codebase Refactoring — Full Session Record

**Date:** 2026-02-06 to 2026-02-07
**Sessions:** 2 (continued via context summary)
**Branch:** `main`
**Starting commit:** `9033bf1` (1.29)
**Ending commit:** `3730c84` (4.1 — extract MenuBarPopupViewModel)
**Total commits:** 24

---

## Overview

Executed a multi-phase refactoring plan ("FineTune Codebase Refactoring Plan Revised v2") targeting the FineTune macOS menu bar audio control app (~60 Swift source files). The plan addressed god classes, code duplication, missing architectural layers, and build system debris through safe, incremental phases with characterization tests before every risky extraction.

**Net result:** 1,041 lines added, 951 lines removed across 37 files. 262 tests (up from ~220 at start). SPM + Xcode builds both pass. No regressions.

---

## Execution Rules Followed

1. Fail-first characterization tests before risky extractions
2. Phase 2 ran serially — each extraction built and tested before starting the next
3. God-class breakup used two stages: same-file MARK grouping first, then file extraction
4. One substep = one atomic commit with substep number in commit message
5. Success criteria were behavior-based: build passes, tests pass, no regressions

---

## Phase 0: Testability & Seam Setup (4 commits)

| Commit | Step | Description |
|--------|------|-------------|
| `f67d023` | 0.1 | Audit existing test seams — documented all injection points across ProcessTapController, AudioEngine, DeviceVolumeMonitor, AudioDeviceMonitor |
| `8bb03dc` | 0.2 | Add deterministic timing injection — injectable `Duration` properties on AudioEngine (diagnosticPollInterval, startupTapDelay, staleTapGracePeriod, serviceRestartDelay, fastHealthCheckIntervals) and ProcessTapController timing seams |
| `46aaeb8` | 0.3 | Add deterministic queue injection — injectable queue/executor closures for ProcessTapController audio callbacks and DeviceVolumeMonitor debounce |
| `f0e3729` | 0.4 | Add AppRow interaction tests — `AppRowInteractionTests.swift` with 20 tests covering volume slider, mute toggle, auto-unmute, device selection callbacks |

---

## Phase 1: Cleanup & Dead Code Removal (4 commits)

| Commit | Step | Description |
|--------|------|-------------|
| `5536adf` | 1.1 | Remove orphaned test files — deleted `FineTuneTests/StartupAudioInterruptionTests.swift` (585 lines) and `FineTuneTests/SingleInstanceGuardTests.swift` (135 lines) |
| `34cf0a8` | 1.2 | Remove deprecated view files — deleted `AppVolumeRowView.swift` (82 lines) and `DeviceVolumeRowView.swift` (107 lines) after grep-confirming zero references |
| `865e65c` | 1.3 | Gitignore additions — added `.lancedb/` and `lancedb/` patterns |
| `3f1fc91` | 1.4 | Centralize magic numbers into `DesignTokens.swift` — scroll thresholds, EQ slider tick config, PopoverHost offset, `defaultUnmuteVolume`, animation spring constants, VU meter update interval |

---

## Phase 2: DRY — Extract Shared Patterns (8 commits, serial)

| Commit | Step | Description | Lines Saved |
|--------|------|-------------|-------------|
| `fe56267` | 2.1 | Extract shared slider auto-unmute logic — created `SliderAutoUnmute.swift` ViewModifier, replaced identical patterns in AppRow and DeviceRow | ~30 |
| `684c37e` | 2.2 | Consolidate DropdownMenu variants — extracted shared `DropdownTriggerButton`, merged config, reduced DropdownMenu.swift from 330 to ~220 lines | ~110 |
| `d2b6b7f` | 2.3 | Extract DeviceIconView — shared NSImage/SF Symbol icon component replacing duplicated rendering in DevicePicker, DevicePickerView, DeviceRow | ~40 |
| `c3066ba` | 2.4 | Extract CoreAudio listener factory — `AudioObjectID+Listener.swift` with `addPropertyListener`/`removePropertyListener` helpers, updated AudioDeviceMonitor, AudioProcessMonitor, DeviceVolumeMonitor | ~60 |
| `8d8fe3c` | 2.5 | Consolidate volume/mute listeners — `DevicePropertyKind` enum replaced 6 near-identical methods with 3 parameterized ones in DeviceVolumeMonitor | ~80 |
| `40ed4e2` | 2.6 | Extract device lookup-with-fallback — `resolveDeviceID(for:)` on AudioDeviceMonitor, updated ProcessTapController crossfade code and AudioDeviceID+Resolution | ~30 |
| `3894d00` | 2.7 | Consolidate volume read attempts — replaced 3 near-identical read blocks with strategy tuple loop in AudioDeviceID+Volume.swift | ~25 |
| `eed03f0` | 2.8 | Extract shared test helpers — `AudioBufferTestHelpers.swift` and `IntegrationTestHelpers.swift`, removed private duplicates from 6 test files | ~100 |

---

## Phase 3: Break Up God Classes (6 commits)

### 3.1 ProcessTapController (1414 lines)

| Commit | Step | Description |
|--------|------|-------------|
| `44bf880` | 3.1A | Characterization tests — 15 tests covering init, volume/mute state, device volume/mute, diagnostics, timing seams, queue injection in `ProcessTapControllerTests.swift` |
| `71ca48f` | 3.1B | Same-file MARK grouping — Diagnostics, Volume/Mute & EQ State, Injectable Timing, Tap/Device Format Helpers, Converter Setup, Tap Lifecycle, Crossfade, Destructive Switch, Audio Processing, Cleanup & Teardown |
| `8b5dfe5` | 3.1C | Extract TapDiagnostics — moved from nested struct `ProcessTapController.TapDiagnostics` to standalone type in `Audio/Tap/TapDiagnostics.swift`, updated all references in AudioEngine and tests |

**Decision:** Further extraction of audio processing methods was not performed because they access `private nonisolated(unsafe)` fields. Extensions in other files can't access private members, and weakening access control on RT-safe fields was deemed too risky.

### 3.2 AudioEngine (838 lines)

| Commit | Step | Description |
|--------|------|-------------|
| `22be60a` | 3.2A | Characterization tests — 7 tests for permission confirmation logic (5 tests) and injectable timing (2 tests) in `AudioEngineCharacterizationTests.swift`. Fixed `@MainActor` isolation error. |
| `38517a2` | 3.2B | Same-file MARK grouping — 12 sections: Injectable Timing, Permission Confirmation, Initialization, Health & Diagnostics, Display State, Lifecycle, Volume & EQ, Routing, Settings, Tap Management, Device Disconnect, Stale Tap Cleanup, Test Helpers (consolidated) |

**Decision:** 3.2C (file extraction) was skipped. AudioEngine's methods are deeply coupled to ~15 private properties. Extracting into separate files would require either weakening `private` to `internal` for all of them or creating delegate/coordinator objects. MARK grouping provides the organizational clarity.

### 3.3 AppRow (437 lines)

| Commit | Step | Description |
|--------|------|-------------|
| `e51dd5f` | 3.3B | Same-file MARK grouping — AppRow: Properties, Initialization, Body |
| `0eff627` | 3.3C | Extract AppRowEQToggle sub-view — animated EQ toggle button with rotation animation, encapsulates hover state and color logic |

**Note:** 3.3A was already covered by Phase 0.4 AppRow interaction tests. DevicePicker was not extracted further since it's already a standalone component.

---

## Phase 4: Architecture — ViewModel Extraction (1 commit)

| Commit | Step | Description |
|--------|------|-------------|
| `3730c84` | 4.1 | Extract MenuBarPopupViewModel — EQ expansion state, animation debounce, popup visibility, device sorting, app activation logic moved from MenuBarPopupView to new ViewModel. Call site in MenuBarStatusController updated. |

**Decision:** 4.2 (consolidate async/sync refresh) was skipped. `AudioProcessMonitor.refresh()` and `refreshAsync()` serve different roles: `refresh()` provides a synchronous guarantee that `activeApps` is populated before `start()` returns (AudioEngine relies on this). Making it async would change timing semantics and risk race conditions.

---

## Files Created (New)

| File | Purpose |
|------|---------|
| `FineTune/Views/Components/SliderAutoUnmute.swift` | ViewModifier for shared auto-unmute-on-slider-move pattern |
| `FineTune/Views/Components/DeviceIconView.swift` | Shared device icon with NSImage/SF Symbol fallback |
| `FineTune/Audio/Extensions/AudioObjectID+Listener.swift` | CoreAudio listener add/remove factory |
| `FineTune/Audio/Tap/TapDiagnostics.swift` | Standalone TapDiagnostics struct (extracted from ProcessTapController) |
| `FineTune/Views/Rows/AppRowEQToggle.swift` | Animated EQ toggle button sub-view |
| `FineTune/Views/MenuBarPopupViewModel.swift` | ViewModel for MenuBarPopupView presentation logic |
| `FineTune/Views/DesignSystem/DesignTokens.swift` | Centralized magic numbers and design constants |
| `testing/tests/AudioBufferTestHelpers.swift` | Shared buffer test utilities (makeBufferList, readBuffer, freeBufferList) |
| `testing/tests/IntegrationTestHelpers.swift` | Shared makeFakeApp function |
| `testing/tests/ProcessTapControllerTests.swift` | 15 characterization tests for ProcessTapController |
| `testing/tests/AudioEngineCharacterizationTests.swift` | 7 characterization tests for AudioEngine |
| `testing/tests/AppRowInteractionTests.swift` | 20 interaction tests for AppRow |

## Files Deleted

| File | Reason |
|------|--------|
| `FineTuneTests/StartupAudioInterruptionTests.swift` | Orphaned (585 lines, duplicate of testing/tests/ version with wrong import) |
| `FineTuneTests/SingleInstanceGuardTests.swift` | Orphaned (135 lines, same situation) |
| `FineTune/Views/AppVolumeRowView.swift` | Deprecated, zero references (82 lines) |
| `FineTune/Views/DeviceVolumeRowView.swift` | Deprecated, zero references (107 lines) |

## Files Significantly Modified

| File | Changes |
|------|---------|
| `FineTune/Audio/DeviceVolumeMonitor.swift` | -80 lines: consolidated 6 volume/mute methods to 3 via DevicePropertyKind enum, migrated to listener factory |
| `FineTune/Audio/ProcessTapController.swift` | -35 lines: MARK grouping, resolveDeviceID usage, TapDiagnostics extraction |
| `FineTune/Audio/AudioEngine.swift` | +30 lines: 12 MARK sections, consolidated test helpers |
| `FineTune/Views/Components/DropdownMenu.swift` | -110 lines: extracted shared trigger button, merged variants |
| `FineTune/Views/MenuBarPopupView.swift` | -35 lines: state/logic moved to ViewModel |
| `FineTune/Views/Rows/AppRow.swift` | -25 lines: EQ toggle extracted, MARK grouping |
| `FineTune/Audio/AudioDeviceMonitor.swift` | Added `resolveDeviceID(for:)`, migrated to listener factory |
| `FineTune/Audio/Extensions/AudioDeviceID+Volume.swift` | -25 lines: strategy tuple loop |
| 6 test files | Removed private helper duplicates in favor of shared helpers |

---

## Errors Encountered and Resolved

### 1. `@escaping` required on `removePropertyListener` block parameter
- **Where:** `AudioObjectID+Listener.swift` (step 2.4)
- **Cause:** `AudioObjectRemovePropertyListenerBlock` expects `@escaping` closure
- **Fix:** Added `@escaping` to the `block` parameter

### 2. `inout` parameter captured in Logger string interpolation
- **Where:** `AudioObjectID+Listener.swift` (step 2.4)
- **Cause:** `address.mSelector` in Logger string interpolation caused "escaping autoclosure captures 'inout' parameter" error
- **Fix:** Captured `let selector = address.mSelector` before the Logger call

### 3. MainActor isolation errors in AudioEngineCharacterizationTests
- **Where:** `AudioEngineCharacterizationTests.swift` (step 3.2A)
- **Cause:** Test methods accessed `@MainActor`-isolated properties of AudioEngine from nonisolated context
- **Fix:** Added `@MainActor` annotation to the test class

### 4. `replace_all` mangled property declaration
- **Where:** `MenuBarPopupView.swift` (step 4.1)
- **Cause:** Using `replace_all` for `sortedDevices` → `viewModel.sortedDevices` also renamed the local property declaration
- **Fix:** Removed the now-mangled local property (it was being moved to ViewModel anyway)

---

## Known Issues (Pre-existing, Not Regressions)

### 1. Two expected test failures (0 unexpected)
These failures existed before the refactoring and are documented bugs:

**`DefaultDeviceBehaviorTests.testApplyPersistedSettingsSkipsVirtualDefault`**
- File: `testing/tests/DefaultDeviceBehaviorTests.swift:125`
- Error: `XCTAssertEqual failed: ("nil") is not equal to ("Optional("real-uid")")`
- Issue: `applyPersistedSettings` doesn't properly skip virtual default devices in the test environment. The test expectation is correct but the production code path doesn't handle this edge case in the no-hardware test scenario.

**`StartupAudioInterruptionTests.testRetryStormWritesSettingsRepeatedly`**
- File: `testing/tests/StartupAudioInterruptionTests.swift:191`
- Error: `XCTAssertEqual failed: ("Optional("built-in-speakers")") is not equal to ("Optional("CLEARED")")`
- Issue: After initial tap creation failure, subsequent `applyPersistedSettings` calls still retry tap creation for the same app. The test documents the desired behavior (no retry storm) but the fix has not been implemented.

### 2. SourceKit false positives in multi-target SPM
When editing files that belong to the `FineTuneIntegration` target, SourceKit frequently reports errors like "Cannot find type 'AudioApp' in scope" or "Cannot find 'DesignTokens' in scope". These are SourceKit indexing issues with multi-target SPM setups — the actual build always succeeds. These can be safely ignored.

### 3. SPM warning about unhandled `.xcassets`
```
warning: 'finetune_fork': found 1 file(s) which are unhandled; explicitly declare them as resources or exclude from the target
    FineTune/Assets.xcassets
```
Harmless — the xcassets are handled by Xcode but not by SPM. Could be added to the exclude list in Package.swift if desired.

---

## Comprehensive TODO / Handoff List

### High Priority — Production Bugs to Fix

1. **Fix `testApplyPersistedSettingsSkipsVirtualDefault` failure**
   - File: `FineTune/Audio/AudioEngine.swift`, `applyPersistedSettings(for:)` method (~line 540)
   - The virtual device check needs to handle the case where `deviceMonitor.device(for:)` returns nil for the default but no real devices exist either
   - Related test: `testing/tests/DefaultDeviceBehaviorTests.swift:125`

2. **Fix `testRetryStormWritesSettingsRepeatedly` failure**
   - File: `FineTune/Audio/AudioEngine.swift`, `applyPersistedSettings(for:)` method
   - After tap creation fails and routing is reverted, `appliedPIDs` is not marked, so the next `applyPersistedSettings()` call retries. Need a "failed" set to suppress retries within a session.
   - Related test: `testing/tests/StartupAudioInterruptionTests.swift:191`

### Medium Priority — Deferred Refactoring

3. **3.2C — AudioEngine file extraction (deferred)**
   - The MARK grouping in 3.2B provides good organization, but if further decomposition is desired:
   - Option A: Change ~15 `private` properties to `internal` and extract Routing/Health/Settings into extensions in separate files
   - Option B: Create a `TapHealthMonitor` coordinator class that AudioEngine delegates health checking to (requires passing ~8 dependencies)
   - Recommendation: Leave as-is unless AudioEngine grows significantly

4. **4.2 — Consolidate async/sync refresh (deferred)**
   - `AudioProcessMonitor` has `refresh()` (sync) and `refreshAsync()` (async) sharing ~70% logic
   - The sync version is needed for `start()` to guarantee `activeApps` is populated before the next line
   - Safe consolidation: extract the shared app-resolution logic into a `resolveApps(from processInfos:, runningApps:)` helper, called by both methods
   - Risk: Low, but the current duplication is only ~50 lines and both methods are well-tested via characterization tests

5. **Extract `AudioProcessMonitor` app resolution logic**
   - Lines 149-176 and 220-241 share identical `findResponsibleApp` + AudioApp construction
   - A `resolveApp(objectID:pid:bundleID:runningApps:)` helper would DRY this

### Low Priority — Polish

6. **Add `.xcassets` to SPM exclude list**
   - In Package.swift, add `"Assets.xcassets"` to the FineTuneIntegration target's exclude list to suppress the warning

7. **Consider DevicePropertyKind consolidation for handleDevicePropertyChanged**
   - The `handleDevicePropertyChanged` method in DeviceVolumeMonitor currently handles volume vs mute via a switch. The two branches share debounce + read + notify logic — could be further consolidated with a closure-based approach.

8. **MenuBarPopupViewModel testing**
   - The new ViewModel has no dedicated tests. Consider adding tests for:
     - `toggleEQ` debounce behavior (rapid clicks during animation)
     - `sortedDevices` ordering (default first, then alphabetical)
     - `activateApp` (mock NSWorkspace for testing)

9. **AppRowEQToggle accessibility**
   - The extracted component inherits `help` text but could benefit from explicit accessibility labels

10. **DesignTokens namespace expansion**
    - Many inline constants remain in views (font sizes, padding values). A follow-up pass could move these to DesignTokens for consistency.

### Build & Test Verification Checklist

After any future changes, verify:
```bash
# SPM build
swift build

# SPM tests (expect 262 tests, 2 pre-existing failures, 0 unexpected)
swift test

# Xcode build
xcodebuild build -project FineTune.xcodeproj -scheme FineTune -quiet
```

### Manual Smoke Matrix

| Scenario | What to verify |
|----------|---------------|
| Per-app volume | Drag slider for individual app, audio level changes correctly |
| Mute / unmute | Toggle mute, audio silences and restores |
| Device switch | Route app to different output device, audio moves |
| EQ | Enable EQ, adjust bands, hear difference |
| App start / quit | Launch and quit an audio app, FineTune updates list |
| Sleep / wake | Sleep Mac and wake, audio state restores |

---

## Architecture After Refactoring

```
FineTune/
├── Audio/
│   ├── AudioEngine.swift          (870 lines, 12 MARK sections)
│   ├── ProcessTapController.swift (1380 lines, 10 MARK sections)
│   ├── AudioDeviceMonitor.swift   (has resolveDeviceID helper)
│   ├── AudioProcessMonitor.swift  (unchanged)
│   ├── DeviceVolumeMonitor.swift  (DevicePropertyKind enum, -80 lines)
│   ├── Tap/
│   │   └── TapDiagnostics.swift   (extracted from ProcessTapController)
│   └── Extensions/
│       ├── AudioObjectID+Listener.swift  (new: listener factory)
│       ├── AudioDeviceID+Volume.swift    (strategy loop)
│       └── AudioDeviceID+Resolution.swift (uses resolveDeviceID)
├── Views/
│   ├── MenuBarPopupView.swift     (presentational, uses ViewModel)
│   ├── MenuBarPopupViewModel.swift (new: EQ state, sorting, app activation)
│   ├── Components/
│   │   ├── SliderAutoUnmute.swift  (new: shared ViewModifier)
│   │   ├── DeviceIconView.swift    (new: shared icon component)
│   │   └── DropdownMenu.swift      (consolidated, -110 lines)
│   ├── DesignSystem/
│   │   └── DesignTokens.swift      (new: centralized constants)
│   └── Rows/
│       ├── AppRow.swift            (MARK grouped, -25 lines)
│       └── AppRowEQToggle.swift    (new: extracted sub-view)
├── Models/
│   └── (unchanged)
└── testing/tests/
    ├── AudioBufferTestHelpers.swift         (new: shared buffer helpers)
    ├── IntegrationTestHelpers.swift          (new: shared makeFakeApp)
    ├── ProcessTapControllerTests.swift       (new: 15 characterization tests)
    ├── AudioEngineCharacterizationTests.swift (new: 7 characterization tests)
    ├── AppRowInteractionTests.swift          (new: 20 interaction tests)
    └── (6 existing test files updated to use shared helpers)
```

---

## Test Suite Summary (Final State)

| Target | Tests | Failures | Status |
|--------|-------|----------|--------|
| FineTuneCoreTests | 130 | 0 | Pass |
| FineTuneIntegrationTests | 132 | 2 (expected) | Pass (0 unexpected) |
| **Total** | **262** | **2** | **All expected** |

New tests added in this refactoring: 42 tests
- AppRowInteractionTests: 20
- ProcessTapControllerTests: 15
- AudioEngineCharacterizationTests: 7

---

## Plan File Location

The full refactoring plan is at: `~/.claude/plans/glowing-rolling-riddle.md`
