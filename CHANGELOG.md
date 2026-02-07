# Changelog

## [Unreleased] - 2026-02-07

### Documentation
- **Architecture diagram comprehensive rewrite:** `docs/architecture/finetune-architecture.md` updated from 88-line single Mermaid flowchart to 332-line document with expanded diagram (12 subgraphs, ~50 nodes), data flow summary, 9 architectural pattern descriptions, and complete file layout. Reflects all changes from the 4-phase refactoring, FluidMenuBarExtra removal, ViewModel extraction, DesignTokens, and new component extractions.
  - Full details: `docs/ai-chat-history/2026-02-07-architecture-diagram-comprehensive-update.md`

### Refactoring (4-phase codebase restructuring)

Comprehensive internal refactoring for readability, DRY, complexity reduction, and architecture.
All public APIs preserved. 1,041 lines added, 951 lines removed across 37 files. 42 new tests.
Full details: `docs/ai-chat-history/2026-02-07-comprehensive-codebase-refactoring.md`

#### Phase 0 — Testability & Seam Setup
- Audited and documented all existing test injection points
- Added injectable timing properties on AudioEngine (diagnosticPollInterval, startupTapDelay, staleTapGracePeriod, serviceRestartDelay, fastHealthCheckIntervals)
- Added deterministic queue injection for ProcessTapController and DeviceVolumeMonitor
- Added 20 AppRow interaction tests (volume, mute, auto-unmute, device selection)

#### Phase 1 — Cleanup & Dead Code Removal
- Removed orphaned `FineTuneTests/` test files (720 lines — duplicates of `testing/tests/` with wrong imports)
- Removed deprecated `AppVolumeRowView.swift` and `DeviceVolumeRowView.swift` (189 lines, zero references)
- Added `.lancedb/` to `.gitignore`
- Centralized magic numbers into `DesignTokens.swift` (scroll thresholds, animation constants, VU meter interval, default unmute volume)

#### Phase 2 — DRY Extractions (serial, 8 steps)
- **SliderAutoUnmute.swift** — ViewModifier replacing duplicated auto-unmute patterns in AppRow/DeviceRow
- **DropdownMenu consolidation** — extracted shared trigger button, merged two near-identical variants (-110 lines)
- **DeviceIconView.swift** — shared NSImage/SF Symbol icon component replacing 3 duplicated renderers
- **AudioObjectID+Listener.swift** — CoreAudio listener add/remove factory used by 3 monitors
- **DevicePropertyKind enum** — consolidated 6 volume/mute listener methods to 3 in DeviceVolumeMonitor (-80 lines)
- **resolveDeviceID(for:)** — cache-then-fallback device lookup on AudioDeviceMonitor, replaces inline pattern in ProcessTapController and AudioDeviceID+Resolution
- **Volume read strategy loop** — replaced 3 near-identical read blocks in AudioDeviceID+Volume (-25 lines)
- **Shared test helpers** — AudioBufferTestHelpers.swift and IntegrationTestHelpers.swift, removed duplicates from 6 test files

#### Phase 3 — God-Class Breakup
- **ProcessTapController** (1414→1380 lines): 15 characterization tests, 10 MARK sections, extracted TapDiagnostics to standalone struct
- **AudioEngine** (838→870 lines): 7 characterization tests, 12 MARK sections, consolidated test helpers
- **AppRow** (437→415 lines): MARK grouping, extracted AppRowEQToggle sub-view

#### Phase 4 — ViewModel Extraction
- **MenuBarPopupViewModel.swift** — EQ expansion state, animation debounce, popup visibility, device sorting, app activation logic moved from MenuBarPopupView to dedicated ViewModel

### Added (new files)
- `FineTune/Views/Components/SliderAutoUnmute.swift`
- `FineTune/Views/Components/DeviceIconView.swift`
- `FineTune/Audio/Extensions/AudioObjectID+Listener.swift`
- `FineTune/Audio/Tap/TapDiagnostics.swift`
- `FineTune/Views/Rows/AppRowEQToggle.swift`
- `FineTune/Views/MenuBarPopupViewModel.swift`
- `FineTune/Views/DesignSystem/DesignTokens.swift`
- `testing/tests/AudioBufferTestHelpers.swift`
- `testing/tests/IntegrationTestHelpers.swift`
- `testing/tests/ProcessTapControllerTests.swift` (15 tests)
- `testing/tests/AudioEngineCharacterizationTests.swift` (7 tests)
- `testing/tests/AppRowInteractionTests.swift` (20 tests)

### Removed (deleted files)
- `FineTuneTests/StartupAudioInterruptionTests.swift` (orphaned, 585 lines)
- `FineTuneTests/SingleInstanceGuardTests.swift` (orphaned, 135 lines)
- `FineTune/Views/AppVolumeRowView.swift` (deprecated, 82 lines)
- `FineTune/Views/DeviceVolumeRowView.swift` (deprecated, 107 lines)

### Fixed
- **False-positive permission confirmation causing post-Allow mute risk:** `AudioEngine` permission confirmation now requires real input evidence (`inputHasData > 0` or `lastInputPeak > 0.0001`) in addition to callback/output activity. Prevents premature tap recreation with `.mutedWhenTapped` while input is still silent.
- **Menu bar panel sizing recursion trigger:** Removed forced `layoutSubtreeIfNeeded` path from `MenuBarStatusController` panel sizing logic and switched to `fittingSize` fallback sizing only.
- **SingleInstanceGuard actor-isolation warnings in Xcode debug flow:** Guard helper methods are now explicitly `nonisolated`, eliminating main-actor isolation warning calls from this utility path.
- **Additional Swift 6 actor/concurrency warnings in audio wrappers and monitors:** `AudioScope`/`TransportType` utilities, device volume/mute CoreAudio wrappers, and monitor callsites now use explicit nonisolated-safe access patterns. Also fixed captured mutable vars in async contexts (`DeviceVolumeMonitor`) via immutable snapshots before `MainActor.run`.
- **`AudioDeviceMonitor` cache warning noise with `@Observable`:** marked cache dictionaries as `@ObservationIgnored` while retaining explicit cross-actor lookup strategy.

### Added
- **Permission confirmation test coverage (fail-first then pass):**
  - `AudioEngineRoutingTests.testPermissionConfirmationRequiresRealInputAudio`
  - `AudioEngineRoutingTests.testPermissionConfirmationSucceedsWithInputAudio`
- **Resolved-issue and handoff docs for this incident:**
  - `docs/known_issues/resolved/xcode-permission-pause-menubar-audio-mute-2026-02-07.md`
  - `docs/ai-chat-history/2026-02-07-xcode-permission-pause-menubar-trace-and-audio-mute-fix.md`

### Changed
- **Concurrency annotation cleanup for CoreAudio utility types:** `AudioScope.propertyScope`, `TransportType.init(rawValue:)`, and `TransportType.defaultIconSymbol` now compile cleanly under default MainActor isolation when called from nonisolated codepaths.
- **Replaced FluidMenuBarExtra with native AppKit status item:** FluidMenuBarExtra v1.5.1 relied on `NSEvent.addLocalMonitorForEvents` to detect clicks on the status bar button, which is broken on macOS 26. Replaced with direct `NSStatusItem` + `button.action`/`target` pattern using `NSApplicationDelegateAdaptor` for reliable AppKit lifecycle initialization.
  - New `MenuBarStatusController` class (`FineTune/Views/MenuBar/MenuBarStatusController.swift`) — owns `NSStatusItem`, `KeyablePanel`, and popup lifecycle
  - New `AppDelegate` in `FineTuneApp.swift` — uses `@NSApplicationDelegateAdaptor` to set up AudioEngine and menu bar in `applicationDidFinishLaunching`
  - `KeyablePanel` subclass overrides `canBecomeKey` (required for `.nonactivatingPanel` style to properly receive key/resign events)
  - Left-click shows/hides popup panel; right-click (or Ctrl+click) shows context menu with "Quit FineTune"
  - Panel auto-dismisses on outside click (via global event monitor) and on `windowDidResignKey`
  - Removed FluidMenuBarExtra package dependency from `project.pbxproj` and `Package.resolved`

### Added
- **SPM integration test infrastructure:** All 59 integration tests now run via `swift test` alongside 161 pure-logic tests (220 total, ~1.1s wall time, zero app instances)
  - `FineTuneIntegration` library target — compiles all non-UI, non-@main source files with FineTuneCore dependency
  - `FineTuneIntegrationTests` test target — AudioEngineRouting, AudioSwitching, DefaultDeviceBehavior, StartupAudioInterruption, SingleInstanceGuard tests
  - Integration tests restored from `_local/archive/` to `testing/tests/` with updated module imports
- **Public API for FineTuneCore types:** EQSettings, CrossfadeState, CrossfadeConfig, CrossfadePhase, VolumeRamper, VolumeMapping, BiquadMath, AudioBufferProcessor, GainProcessor, SoftLimiter, EQPreset — all made `public` for cross-module use
- **coreaudiod restart handler:** `AudioEngine` now handles `kAudioHardwarePropertyServiceRestarted` — destroys all stale taps, waits 1.5s for daemon to stabilize, recreates all taps via `applyPersistedSettings()`
- **`onServiceRestarted` callback on `AudioDeviceMonitor`** — fires after coreaudiod restart and device list refresh, allows consumers to react to daemon restarts
- **Per-session permission confirmation:** Taps start with `.unmuted` on each launch, auto-upgrade to `.mutedWhenTapped` within ~300ms once audio flow is confirmed. Prevents audio loss if app is killed during first-time permission grant
- **`muteOriginal` parameter on `ProcessTapController`** — controls whether taps use `.mutedWhenTapped` (normal operation) or `.unmuted` (safe for pre-permission launches)
- **Enhanced tap health check:** Now detects both stalled taps (callbacks stopped) and broken taps (callbacks running but reporter disconnected — empty input, no output). Uses `TapHealthSnapshot` struct for delta analysis across check cycles
- **`recreateAllTaps()` in `AudioEngine`** — destroys and recreates all taps (used for `.unmuted` → `.mutedWhenTapped` upgrade after permission confirmation)
- **Empty input diagnostic counter:** `_diagEmptyInput` tracks callbacks with zero-length or nil input buffers, exposed in `TapDiagnostics.emptyInput`

### Changed
- Platform minimum bumped from macOS 14.0 to macOS 14.2 (required for AudioHardwareCreateProcessTap/DestroyProcessTap APIs)
- `AudioDeviceMonitor.devicesByUID`/`devicesByID` marked `nonisolated(unsafe)` with `nonisolated` lookup methods for safe cross-actor reads from ProcessTapController
- `AudioEngine.appDeviceRouting` access changed from `private(set)` to internal setter for `@testable import` compatibility
- FineTuneIntegration target uses `.swiftLanguageMode(.v5)` to accommodate existing concurrency patterns
- **CoreAudio reads moved off main thread:** `AudioDeviceMonitor.handleServiceRestartedAsync()` and `handleDeviceListChangedAsync()` now run `readDeviceDataFromCoreAudio()` via `Task.detached`. Previously ran on MainActor due to class annotation, causing UI freeze during coreaudiod restart
- Health check interval reduced from 5s to 3s for faster broken-tap detection
- Fast health check intervals changed from 1s/2s/3s to 300ms/500ms/700ms for faster permission confirmation
- `setDevice()` guard relaxed to allow re-routing when tap is missing (enables retry after failed activation)
- `onAppsChanged` callback wired AFTER initial `applyPersistedSettings()` to prevent startup delay bypass
- 2-second startup delay before initial tap creation to let apps initialize audio sessions

### Fixed
- **Audio mute on permission grant (critical):** Clicking "Allow" on the system audio recording permission dialog no longer causes permanent audio loss. Three interacting root causes fixed: (1) taps now use `.unmuted` before permission confirmation so app death doesn't mute audio, (2) `readDeviceDataFromCoreAudio()` runs off MainActor so coreaudiod restart doesn't freeze the UI, (3) `AudioEngine` handles coreaudiod restart by destroying and recreating all taps. See `docs/known_issues/resolved/audio-mute-on-permission-grant.md`.
- **AirPods/Bluetooth silence:** Aggregate device sample rate now uses output device rate instead of tap rate. Process taps may report the app's internal rate (e.g., Chromium 24kHz) which Bluetooth devices don't support (e.g., AirPods require 48kHz). CoreAudio's drift compensation handles resampling. Fixed in `activate()` and `createSecondaryTap()`.
- **Virtual device silent routing:** FineTune no longer follows macOS default device changes to virtual audio drivers (e.g., SRAudioDriver, BlackHole). Three entry points patched:
  - `DeviceVolumeMonitor.handleDefaultDeviceChanged()` — ignores virtual device as new default
  - `AudioEngine.applyPersistedSettings()` — validates default UID against non-virtual device list, falls back to first real device
  - `MenuBarPopupView` UI fallback — uses first real device instead of potentially-virtual default
- **Mute state not applied on new tap creation:** `ensureTapExists()` now sets `tap.isMuted` from persisted state
- **Destructive switch fade-in race:** Removed manual volume loop that raced with user changes; uses built-in exponential ramper
- **Non-float doubled audio during crossfade:** Non-float output now silenced when `crossfadeMultiplier < 1.0`
- **Secondary callback missing force-silence check:** `processAudioSecondary()` now checks `_forceSilence` at entry
- **Build failure from `import FineTuneCore`:** All 5 occurrences wrapped with `#if canImport(FineTuneCore)` for Xcode builds without SPM dependency

### Added
- Comprehensive audio pipeline diagnostics (RT-safe atomic counters)
  - `TapDiagnostics` struct with 19 fields: callback counts, silence flags, converter stats, peak levels, format info, volume/crossfade state, empty input count
  - Both `processAudio()` and `processAudioSecondary()` instrumented at every decision point
  - `computeOutputPeak()` RT-safe helper for output buffer peak measurement
  - 3-second diagnostic + health check timer in AudioEngine logs per-app state including device UID
  - Activation logging with format, converter, aggregate device ID, ramp coefficient
  - Enhanced log format: `vol=`, `curVol=`, `xfade=`, `dev=`, `empty=` fields for gain/state debugging

## [1.14] - 2026-02-05

### Added
- Device disconnect handling in AudioDeviceMonitor
- Enhanced volume/mute logging in DeviceVolumeMonitor

### Changed
- Simplified device display in MenuBarPopupView

## [1.13] - 2026-02-05

### Fixed
- **Bug 1:** `setDevice()` now reverts `appDeviceRouting` when async `switchDevice()` fails, preventing UI/audio desync
- **Bug 2:** Crossfade no longer promotes secondary tap that hasn't produced audio — checks `isWarmupComplete` before destroying primary, falls back to destructive switch if warmup incomplete
- **Bug 3:** `setDevice()` else-branch (no existing tap) now reverts routing when `ensureTapExists` fails
- **Bug 4:** `applyPersistedSettings()` removes stale `appDeviceRouting` entries when tap creation fails, so UI falls back to showing default device

## [1.12] - 2026-02-05

## [1.11] - 2026-02-05

## [1.10] - 2026-02-05

### Fixed
- Fix 'angry robot noise' and System Settings freeze
- Fix System Settings contention and feedback loop in device sync

## [1.09] - 2026-02-05

## [1.08] - 2026-02-05

## [1.07] - 2026-02-05

---

### Added (local only, gitignored)
- CrossfadeStateTests (31 tests) — validates warmup detection, equal-power curves, state lifecycle
- AudioEngineRoutingTests (5 tests) — validates routing revert on tap creation failure
