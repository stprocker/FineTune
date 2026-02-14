# Startup Routing Policy: Implementation and Validation

**Date:** 2026-02-14
**Agent:** Codex

## Code Changes

- `FineTune/Settings/SettingsManager.swift`
  - Added `StartupRoutingPolicy` enum.
  - Added `AppSettings.startupRoutingPolicy` defaulting to `preserveExplicitRouting`.
  - Added custom `AppSettings` decoder using `decodeIfPresent` defaults for schema compatibility.

- `FineTune/Audio/AudioEngine.swift`
  - Added `resolveStartupDefaultDeviceUID(for:)`.
  - Added `resolveStartupRouting(for:)` with policy-aware behavior.
  - Updated `applyPersistedSettings(for:)` to conditionally persist routing based on policy.

- `FineTune/Views/Settings/SettingsView.swift`
  - Added `Startup Routing` menu row in the Audio section with policy selection.

## Tests Added

- `testing/tests/SettingsManagerRoutingTests.swift`
  - `testStartupRoutingPolicyDefaultsToPreserveExplicitRouting`
  - `testStartupRoutingPolicySurvivesSaveAndReload`

- `testing/tests/StartupAudioInterruptionTests.swift`
  - `testStartupFollowDefaultPolicyOverridesExplicitRouting`

## Validation

- Targeted tests for startup routing policy and persistence pass.
- Full suite baseline improved from 19 to 18 failures; remaining failures are pre-existing crossfade duration expectation mismatches.
- Xcode Debug build succeeds.
