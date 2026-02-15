# Session Summary - 2026-02-15

## Request
User reported that EQ controls were still no-op and requested a gold-standard architecture/performance fix.

## Findings
- `AudioEngine.setEQSettings` persisted settings but returned early when no tap existed.
- Tap creation was primarily startup/persisted-settings-driven, so first live interaction could be non-functional for apps without prior custom settings.
- Rapid repeated EQ writes would be unsafe to naively fix by always attempting tap creation (retry storm risk).

## Changes Made
1. Updated `FineTune/Audio/AudioEngine.swift`:
- Added interaction-driven tap creation for active apps on:
  - `setEQSettings`
  - `setVolume`
  - `setMute`
- Added tap target resolution order for interaction path:
  1. multi-mode selected UIDs
  2. in-memory app routing
  3. persisted app routing
  4. startup default fallback
- Added per-PID exponential tap-creation backoff:
  - base `0.35s`
  - cap `4.0s`
- Added explicit tap-creation reason tagging (`startup`, `routing`, `userInteraction`, `modeChange`, `health`).
- Explicit route/mode-change actions bypass backoff for immediate retries.

2. Tests
- Confirmed fail-first behavior before patch:
  - `testSetEQSettingsAttemptsTapCreationForActiveApp` failed
  - `testSetEQSettingsTapCreationBacksOffAfterFailure` failed
- Verified green after patch via `AudioEngineRoutingTests`.

3. Documentation updated
- `CHANGELOG.md`
- `docs/architecture/finetune-architecture.md`
- `docs/known_issues/eq-panel-no-audible-change-troubleshooting.md`

## Validation
- `swift test --filter AudioEngineRoutingTests` ✅
- `xcodebuild -project finetune_fork.xcodeproj -scheme FineTune -configuration Debug -sdk macosx build` ✅

## Notes
- This addresses the primary EQ no-op path without introducing aggressive tap-creation churn.
- Existing unrelated warnings (e.g., `nonisolated(unsafe)` warnings) remain unchanged.
