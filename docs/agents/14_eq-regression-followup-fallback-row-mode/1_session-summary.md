# Session Summary - 2026-02-15

## Request
User reported a regression after fallback-row changes: EQ appeared non-functional.

## Findings
- Previous fallback implementation injected `lastDisplayedApp` as an active display row when no app was active.
- Active-row settings flows use active-tap paths (`setEQSettings(for:)`, etc.), which can be misleading/non-functional when no tap exists.
- This could make EQ appear broken in fallback state.

## Changes Made
1. Updated `FineTune/Audio/AudioEngine.swift` fallback display logic:
- Reworked `rebuildDisplayableApps()` to keep fallback as a transient **inactive** row (via `DisplayableApp.pinnedInactive`) when no active apps exist.
- Active apps remain unchanged and continue to take precedence.

2. Updated tests:
- `testing/tests/AudioEngineRoutingTests.swift`
  - adjusted `testPausedFallbackWhenPlaybackStops` to assert inactive fallback row
  - retained fallback persistence + precedence assertions

3. Updated docs:
- `CHANGELOG.md`
- `docs/architecture/finetune-architecture.md`
- `docs/known_issues/eq-panel-no-audible-change-troubleshooting.md`

## Validation
- `swift test --filter AudioEngineRoutingTests` ✅
- `xcodebuild -project finetune_fork.xcodeproj -scheme FineTune -configuration Debug -sdk macosx build` ✅

## Notes
- Fallback requirement is preserved (show last played app when nothing is currently active).
- Fallback row now follows inactive row behavior, which avoids relying on active tap paths when playback is stopped.
