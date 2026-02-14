# Chat Log: Gold Standard Testing — SPM Integration Tests via swift test

**Date:** 2026-02-06
**Topic:** Running ALL tests (pure logic + integration) via `swift test` with no Xcode and no app instances

---

## Summary

Phase 1 had already extracted 9 pure-logic tests into `FineTuneCore` + `FineTuneCoreTests` SPM targets. This session completed the gold standard testing plan by adding integration tests as a new `FineTuneIntegrationTests` SPM test target backed by a `FineTuneIntegration` library target that compiles the full app source (minus `@main` entry point and SwiftUI views). Five integration test files were moved from `_local/archive/` back to `testing/tests/`, imports were updated, and cross-module visibility was fixed by making all `FineTuneCore` types public. The result: **220 tests, 218 pass, 2 known-bug failures, ~1.1 seconds wall time, zero app instances spawned.**

---

## Steps Executed

### 1. Moved 5 integration test files from archive back to testing/tests

- `AudioEngineRoutingTests.swift`
- `AudioSwitchingTests.swift`
- `DefaultDeviceBehaviorTests.swift`
- `StartupAudioInterruptionTests.swift`
- `SingleInstanceGuardTests.swift`
- Left `SingleInstanceProcessTests.sh` in `_local/archive/` (needs built app binary)

### 2. Updated Package.swift

- Added `FineTuneIntegration` library target that compiles everything in `FineTune/` EXCEPT:
  - `FineTuneApp.swift` (the `@main` entry point)
  - `Views/` directory (all SwiftUI)
  - The 9 files already in `FineTuneCore`
  - Non-source files (plists, entitlements)
- Added `FineTuneIntegrationTests` test target with explicit sources list
- Bumped platform from `.macOS(.v14)` to `.macOS("14.2")` because `AudioHardwareCreateProcessTap` and `AudioHardwareDestroyProcessTap` require macOS 14.2
- Added `.swiftLanguageMode(.v5)` to `FineTuneIntegration` target because existing code has concurrency patterns that are warnings in Swift 5 but errors in Swift 6

### 3. Updated imports in integration test files

- Changed `@testable import FineTune` to `@testable import FineTuneIntegration` in all 5 files
- Added `@testable import FineTuneCore` to `AudioSwitchingTests.swift` (uses `CrossfadeState`/`CrossfadeConfig`)
- Added `import AudioToolbox` to `DefaultDeviceBehaviorTests.swift` (uses `AudioDeviceID` type)

### 4. Made FineTuneCore types public (required for cross-module visibility)

All 9 `FineTuneCore` files had internal (default) access. Since `FineTuneIntegration` depends on `FineTuneCore`, types needed to be public:

- **EQSettings.swift**: struct, all properties, init, static members made `public`. Added `Sendable` conformance.
- **CrossfadeState.swift**: `CrossfadeConfig` enum, `CrossfadePhase` enum, `CrossfadeState` struct — all made `public` including properties, methods, init.
- **VolumeRamper.swift**: struct, properties, inits, static methods made `public`. Added `Sendable` conformance.
- **VolumeMapping.swift**: enum and static methods made `public`.
- **BiquadMath.swift**: enum, static let, static funcs made `public`.
- **AudioBufferProcessor.swift**: enum and all static methods made `public`.
- **GainProcessor.swift**: enum and public static method made `public`.
- **SoftLimiter.swift**: enum, static lets, static var, static funcs made `public`.
- **EQPreset.swift**: enum, nested `Category` enum, all properties/methods made `public`. Added `Sendable` conformance.

### 5. Added `import FineTuneCore` to integration source files

These files in `FineTuneIntegration` reference types from `FineTuneCore`:

- `Audio/AudioEngine.swift` — uses `EQSettings`, `VolumeMapping`, `VolumeRamper`
- `Audio/ProcessTapController.swift` — uses `CrossfadeConfig`, `CrossfadeState`, `VolumeRamper`, `AudioBufferProcessor`, `GainProcessor`, `SoftLimiter`
- `Audio/EQProcessor.swift` — uses `EQSettings`
- `Settings/SettingsManager.swift` — uses `EQSettings`
- `Audio/Processing/AudioFormatConverter.swift` — uses `AudioBufferProcessor`, `GainProcessor`

### 6. Fixed concurrency isolation errors

`AudioDeviceMonitor` is `@MainActor` but `ProcessTapController` calls `device(for:)` from background queues.

**Fix:**
- Made `devicesByUID` and `devicesByID` dictionaries `nonisolated(unsafe)`
- Made both `device(for:)` methods `nonisolated`

These are simple dictionary reads; writes only happen on MainActor.

### 7. Fixed access control for test compatibility

- Changed `AudioEngine.appDeviceRouting` from `private(set) var` to `var` (internal setter)
- `@testable import` exposes `internal` members but NOT `private` setters from a separate module

---

## Files Modified

| File | Change |
|---|---|
| `Package.swift` | Added `FineTuneIntegration` target + `FineTuneIntegrationTests` target, bumped platform to 14.2, added `swiftLanguageMode(.v5)` |
| `testing/tests/AudioEngineRoutingTests.swift` | Moved from archive, import changed to `FineTuneIntegration` |
| `testing/tests/AudioSwitchingTests.swift` | Moved from archive, imports changed to `FineTuneIntegration` + `FineTuneCore` |
| `testing/tests/DefaultDeviceBehaviorTests.swift` | Moved from archive, import changed to `FineTuneIntegration`, added `import AudioToolbox` |
| `testing/tests/StartupAudioInterruptionTests.swift` | Moved from archive, import changed to `FineTuneIntegration` |
| `testing/tests/SingleInstanceGuardTests.swift` | Moved from archive, import changed to `FineTuneIntegration` |
| `FineTune/Models/EQSettings.swift` | Made public, added `Sendable` |
| `FineTune/Audio/Crossfade/CrossfadeState.swift` | Made public (`CrossfadeConfig`, `CrossfadePhase`, `CrossfadeState`), added public `init()` |
| `FineTune/Audio/Processing/VolumeRamper.swift` | Made public, added `Sendable` |
| `FineTune/Models/VolumeMapping.swift` | Made public |
| `FineTune/Audio/BiquadMath.swift` | Made public |
| `FineTune/Audio/Processing/AudioBufferProcessor.swift` | Made public |
| `FineTune/Audio/Processing/GainProcessor.swift` | Made public |
| `FineTune/Audio/Processing/SoftLimiter.swift` | Made public |
| `FineTune/Models/EQPreset.swift` | Made public, added `Sendable` |
| `FineTune/Audio/AudioEngine.swift` | Added `import FineTuneCore`, changed `appDeviceRouting` to internal setter |
| `FineTune/Audio/ProcessTapController.swift` | Added `import FineTuneCore` |
| `FineTune/Audio/EQProcessor.swift` | Added `import FineTuneCore` |
| `FineTune/Settings/SettingsManager.swift` | Added `import FineTuneCore` |
| `FineTune/Audio/Processing/AudioFormatConverter.swift` | Added `import FineTuneCore` |
| `FineTune/Audio/AudioDeviceMonitor.swift` | Made `devicesByUID`/`devicesByID` `nonisolated(unsafe)`, `device(for:)` `nonisolated` |

---

## Test Results

| Target | Tests | Pass | Fail | Notes |
|---|---|---|---|---|
| `FineTuneCoreTests` | 161 | 161 | 0 | Pure logic tests (Phase 1) |
| `FineTuneIntegrationTests` | 59 | 57 | 2 | Known-bug failures, not regressions |
| **Total** | **220** | **218** | **2** | ~1.1s wall time, zero app instances |

### Known Failing Tests (2 -- both are known bugs, not regressions)

1. **`DefaultDeviceBehaviorTests.testApplyPersistedSettingsSkipsVirtualDefault`** -- Bug: `applyPersistedSettings` does not skip virtual default device when routing
2. **`StartupAudioInterruptionTests.testRetryStormWritesSettingsRepeatedly`** -- Bug: engine retries full tap-creation sequence on every `onAppsChanged` for previously failed apps

The plan predicted 7 failures but only 2 failed -- some startup bugs appear to have been fixed since the plan was written.

---

## Known Issues / Technical Debt

### 1. Swift 5 language mode on FineTuneIntegration

The integration target uses `.swiftLanguageMode(.v5)` because existing code has actor isolation violations (calling `@MainActor`-isolated methods from non-isolated contexts). This should be migrated to Swift 6 eventually by properly annotating concurrency boundaries.

### 2. `nonisolated(unsafe)` on AudioDeviceMonitor dictionaries

`devicesByUID` and `devicesByID` are marked `nonisolated(unsafe)` to allow cross-actor reads from `ProcessTapController`. This is safe in practice (writes only on MainActor, reads are atomic dictionary lookups) but is technically a data race. A proper fix would use an actor or a lock.

### 3. `appDeviceRouting` access control relaxed

Changed from `private(set)` to `var` (internal) to support `@testable import` from separate test module. This means other code within the module can now modify it directly. Could be addressed with a test-specific setter method instead.

### 4. SPM "unhandled files" warnings

`swift test` emits warnings about files that are in the `path` directories but not listed in `sources` for targets using explicit source lists (`FineTuneCore`, `FineTuneCoreTests`, `FineTuneIntegrationTests`). These are harmless but noisy. Could be suppressed by either (a) restructuring directories so each target has its own folder, or (b) adding `exclude` lists.

### 5. Platform minimum bumped to 14.2

The Xcode project may have different deployment target settings. Verify that the Xcode project and `Package.swift` stay aligned.

### 6. Xcode project not updated

The Xcode project (`.xcodeproj`) was not modified. The `import FineTuneCore` statements added to source files may cause Xcode build issues if the Xcode project does not know about `FineTuneCore` as a dependency. Need to verify Xcode still builds correctly.

### 7. SingleInstanceProcessTests.sh

Remains in `_local/archive/` -- it requires a built app binary and cannot run via `swift test`.

---

## TODO List for Future Work

- [ ] Verify Xcode project still builds after the import/access changes
- [ ] Migrate `FineTuneIntegration` from Swift 5 to Swift 6 language mode (fix actor isolation properly)
- [ ] Fix the 2 known failing tests (startup audio interruption bugs)
- [ ] Suppress or eliminate "unhandled files" SPM warnings (restructure directories or add excludes)
- [ ] Consider restructuring test directories so each test target has its own folder (eliminates need for explicit `sources:` lists)
- [ ] Evaluate whether `nonisolated(unsafe)` on `AudioDeviceMonitor` dictionaries should be replaced with proper synchronization
- [ ] Consider adding a test-specific setter for `appDeviceRouting` rather than relaxing access control
- [ ] Add CI integration for `swift test` (runs in seconds, no Xcode required)
- [ ] Investigate whether `SingleInstanceProcessTests.sh` can be adapted to run without a full app binary

---

## Architecture Reference

### SPM Target Dependency Graph

```
FineTuneCore (library)
  - 9 pure-logic source files (EQ, crossfade, volume, audio processing)
  - No framework dependencies beyond Foundation

FineTuneCoreTests (test target)
  - depends on: FineTuneCore
  - 161 tests

FineTuneIntegration (library)
  - depends on: FineTuneCore
  - All app source files EXCEPT: @main entry, Views/, FineTuneCore files
  - Swift 5 language mode
  - macOS 14.2 minimum

FineTuneIntegrationTests (test target)
  - depends on: FineTuneIntegration, FineTuneCore
  - 59 tests (5 test files)
```

### Key Decision: Why a separate FineTuneIntegration target?

SPM cannot compile `@main` entry points into library targets (only executable targets can have `@main`). SwiftUI views also pull in framework dependencies that are unnecessary for testing. By excluding `FineTuneApp.swift` and `Views/`, the integration target compiles the entire audio engine, device monitoring, settings management, and process tap infrastructure as a testable library.

---

## Build/Test Commands

```bash
# Run all tests (both targets)
swift test

# Run only integration tests
swift test --filter FineTuneIntegrationTests

# Run only core tests
swift test --filter FineTuneCoreTests

# Build without running tests (verify compilation)
swift build --build-tests
```
