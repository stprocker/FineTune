# Changelog

## [Unreleased] - 2026-02-06

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
