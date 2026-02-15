# Session Summary - 2026-02-15

## Request
Prevent the `No apps playing audio` empty state from taking over when playback pauses/stops. Behavior requested:
- If any app is playing, show active app(s).
- If none are currently playing, keep showing the last played app.

## Findings
- `AudioEngine` already tracked `lastDisplayedApp` and pause state (`isPausedDisplayApp`).
- UI emptiness was driven by `displayableApps`, which were rebuilt only from current active apps + pinned inactive apps.
- Result: `displayableApps` became empty during pause/stop transitions even though paused fallback metadata existed.

## Changes Made
1. Updated `FineTune/Audio/AudioEngine.swift`:
- In `rebuildDisplayableApps()`, introduced `effectiveActiveApps`:
  - uses real active apps when present
  - falls back to `[lastDisplayedApp]` when no active apps exist
- Existing pinned active/inactive ordering logic remains intact.

2. Updated tests (fail-first then pass) in `testing/tests/AudioEngineRoutingTests.swift`:
- `testPausedFallbackWhenPlaybackStops` now asserts `displayableApps` contains the fallback app.
- Added `testPausedFallbackTracksMostRecentlyActiveApp` to verify fallback follows most recent app.
- Strengthened `testActiveAppsPrecedeOverPausedFallback` with `displayableApps` assertions.

3. Updated docs:
- `CHANGELOG.md`
- `docs/architecture/finetune-architecture.md`
- `docs/known_issues/eq-panel-no-audible-change-troubleshooting.md`

## Validation
- `swift test --filter AudioEngineRoutingTests` ✅
- `xcodebuild -project finetune_fork.xcodeproj -scheme FineTune -configuration Debug -sdk macosx build` ✅

## Notes
- Empty state can still appear if no app has been seen yet in the session and nothing is pinned.
