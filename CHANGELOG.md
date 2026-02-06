# Changelog

## [Unreleased] - 2026-02-06

### Fixed
- **AirPods/Bluetooth silence:** Aggregate device sample rate now uses output device rate instead of tap rate. Process taps may report the app's internal rate (e.g., Chromium 24kHz) which Bluetooth devices don't support (e.g., AirPods require 48kHz). CoreAudio's drift compensation handles resampling. Fixed in `activate()` and `createSecondaryTap()`.
- **Virtual device silent routing:** FineTune no longer follows macOS default device changes to virtual audio drivers (e.g., SRAudioDriver, BlackHole). Three entry points patched:
  - `DeviceVolumeMonitor.handleDefaultDeviceChanged()` — ignores virtual device as new default
  - `AudioEngine.applyPersistedSettings()` — validates default UID against non-virtual device list, falls back to first real device
  - `MenuBarPopupView` UI fallback — uses first real device instead of potentially-virtual default

### Added
- Comprehensive audio pipeline diagnostics (RT-safe atomic counters)
  - `TapDiagnostics` struct with 18 fields: callback counts, silence flags, converter stats, peak levels, format info, volume/crossfade state
  - Both `processAudio()` and `processAudioSecondary()` instrumented at every decision point
  - `computeOutputPeak()` RT-safe helper for output buffer peak measurement
  - 5-second diagnostic timer in AudioEngine logs per-app state including device UID
  - Activation logging with format, converter, aggregate device ID, ramp coefficient
  - Enhanced log format: `vol=`, `curVol=`, `xfade=`, `dev=` fields for gain/state debugging

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
