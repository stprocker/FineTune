# Startup Routing Overwrote Explicit Per-App Device Choice

**Status:** Resolved  
**Date:** 2026-02-14  
**Severity:** High (unexpected routing behavior on launch)  
**Files Modified:** `FineTune/Audio/AudioEngine.swift`, `FineTune/Settings/SettingsManager.swift`, `FineTune/Views/Settings/SettingsView.swift`, `testing/tests/StartupAudioInterruptionTests.swift`, `testing/tests/SettingsManagerRoutingTests.swift`

---

## Symptom

On startup, `AudioEngine.applyPersistedSettings()` always routed customized apps to the current system default output device and persisted that value.  
This overwrote intentional per-app explicit routing from prior sessions.

## Root Cause

Startup routing had a single hardcoded behavior: "follow current default output on launch."  
No policy toggle existed, and explicit persisted per-app routes were not treated as protected user intent.

## Fix

Added configurable startup routing policy in `AppSettings`:
- `preserveExplicitRouting` (default)
- `followSystemDefault`

Implementation behavior:
- `preserveExplicitRouting`: preserve available explicit routing; if unavailable, use startup default as runtime fallback without overwriting saved explicit preference.
- `followSystemDefault`: assign and persist startup default routing (previous behavior).

Added UI control in main settings (`SettingsView`) under Audio:
- `Startup Routing` menu with both policies.

## Backward Compatibility

`AppSettings` now uses a custom decoder with `decodeIfPresent` defaults, so existing settings files without `startupRoutingPolicy` load safely and default to `preserveExplicitRouting`.

## Test Coverage

Fail-first tests were added, then implementation completed:
- `SettingsManagerRoutingTests.testStartupRoutingPolicyDefaultsToPreserveExplicitRouting`
- `SettingsManagerRoutingTests.testStartupRoutingPolicySurvivesSaveAndReload`
- `StartupAudioInterruptionTests.testStartupFollowDefaultPolicyOverridesExplicitRouting`
- Existing preservation behavior test remains passing:
  `StartupAudioInterruptionTests.testStartupPreservesExplicitDeviceRouting`

