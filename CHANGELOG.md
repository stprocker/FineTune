# Changelog

## [1.14] - 2026-02-05

### Added
- Diagnostic instrumentation for audio pipeline troubleshooting
  - `TapDiagnostics` struct with RT-safe callback counters in ProcessTapController
  - 5-second diagnostic timer in AudioEngine logs callback counts, format info, peak levels
  - Activation logging with full format and converter details
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

## Unreleased

### Fixed
- Aggregate device sample rate now uses output device rate instead of tap rate. Process taps may report the app's internal rate (e.g., Chromium 24kHz) which the output device may not support (e.g., AirPods 48kHz). CoreAudio drift compensation handles resampling.

### Added (local only, gitignored)
- CrossfadeStateTests (31 tests) — validates warmup detection, equal-power curves, state lifecycle
- AudioEngineRoutingTests (5 tests) — validates routing revert on tap creation failure
