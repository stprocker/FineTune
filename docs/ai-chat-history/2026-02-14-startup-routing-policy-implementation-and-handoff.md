# Startup Routing Policy Implementation + Session Handoff

**Date:** 2026-02-14  
**Session type:** Comprehensive review follow-up -> implementation + docs + repo hygiene  
**Project:** FineTune (macOS 26/Tahoe only)

---

## Executive Summary

This session started from a codebase review request and moved into implementation after product-direction decisions were made. The key result is a configurable startup routing policy that fixes a high-impact startup behavior bug: explicit per-app device routing was being overwritten on launch.

The selected behavior is now configurable in main settings, with a default of preserving explicit routing.

In the same session, documentation and changelog updates were completed, and repository ignore behavior was corrected so `docs/` is tracked (with only `docs/.DS_Store` ignored).

---

## User Decisions Captured

1. Make startup routing behavior configurable.
2. Put the control in main settings.
3. Use the recommended default behavior.

Selected default:
- `preserveExplicitRouting`

---

## Initial Review Findings (Pre-Implementation)

Primary bug identified:
- `AudioEngine.applyPersistedSettings()` forced all customized apps to startup system-default output and persisted that value.
- This overwrote explicit per-app device choices made by users in previous sessions.

Additional review context:
- Existing known failing test cluster remained in crossfade duration expectations.
- No dependency removals or framework replacements were performed.

---

## Implementation Work Performed

### 1. Fail-first tests (then implementation)

Added tests before code completion:
- `testing/tests/StartupAudioInterruptionTests.swift`
  - `testStartupFollowDefaultPolicyOverridesExplicitRouting`
- `testing/tests/SettingsManagerRoutingTests.swift`
  - `testStartupRoutingPolicyDefaultsToPreserveExplicitRouting`
  - `testStartupRoutingPolicySurvivesSaveAndReload`

### 2. Settings model + persistence

Updated `FineTune/Settings/SettingsManager.swift`:
- Added `StartupRoutingPolicy` enum:
  - `preserveExplicitRouting`
  - `followSystemDefault`
- Added `AppSettings.startupRoutingPolicy` with default `.preserveExplicitRouting`.
- Added custom `AppSettings.init(from:)` with `decodeIfPresent` defaults to preserve compatibility with older `settings.json` files that do not yet include the new key.

### 3. Engine behavior change

Updated `FineTune/Audio/AudioEngine.swift`:
- Added helper `resolveStartupDefaultDeviceUID(for:)`.
- Added helper `resolveStartupRouting(for:)` returning `(deviceUID, shouldPersist)`.
- Updated `applyPersistedSettings(for:)` to route by policy:

`preserveExplicitRouting`:
- If explicit route exists and device is available: use it, do not overwrite persisted value.
- If explicit route exists but unavailable: runtime fallback to startup default, do not overwrite explicit persisted preference.
- If no explicit route exists: use startup default and persist.

`followSystemDefault`:
- Use startup default and persist (legacy behavior).

### 4. Main settings UI

Updated `FineTune/Views/Settings/SettingsView.swift`:
- Added `Startup Routing` row under Audio settings.
- Implemented policy chooser (`Menu`) with checkmark state and titles.

---

## Validation Performed

### Targeted tests run in this session

Passed:
- `swift test --filter SettingsManagerRoutingTests/testStartupRoutingPolicyDefaultsToPreserveExplicitRouting`
- `swift test --filter SettingsManagerRoutingTests/testStartupRoutingPolicySurvivesSaveAndReload`
- `swift test --filter StartupAudioInterruptionTests/testStartupPreservesExplicitDeviceRouting`
- `swift test --filter StartupAudioInterruptionTests/testStartupFollowDefaultPolicyOverridesExplicitRouting`

### Session-level prior validation (same chat, earlier step)

- Full suite was previously run in this chat context and reported as:
  - `335 tests, 18 failures`
  - Remaining failures are pre-existing crossfade duration expectation mismatch tests.
- Xcode build was previously run in this chat context and reported as:
  - `xcodebuild ... build` -> `BUILD SUCCEEDED`

---

## Documentation and Project Records Updated

### Architecture/known issues/changelog updates

- Updated architecture document:
  - `docs/architecture/finetune-architecture.md`
  - Added startup routing policy behavior + schema snippet update.

- Added resolved known issue:
  - `docs/known_issues/resolved/startup-routing-policy-overwrote-explicit-routing.md`

- Added agent run docs:
  - `docs/agents/6_startup-routing-policy-config/1_review_and_plan.md`
  - `docs/agents/6_startup-routing-policy-config/2_implementation_and_validation.md`

- Updated root changelog with startup routing policy release note:
  - `CHANGELOG.md`

### Repo ignore behavior correction

User requested docs not be git ignored.

Changes made:
- Removed `docs/` ignore rule from `.gitignore`.
- Added targeted `docs/.DS_Store` ignore rule.

Result:
- `docs/` files are now trackable by git.
- Only `docs/.DS_Store` remains ignored in docs scope.

---

## Files Modified (Code + Tests)

- `FineTune/Settings/SettingsManager.swift`
- `FineTune/Audio/AudioEngine.swift`
- `FineTune/Views/Settings/SettingsView.swift`
- `testing/tests/SettingsManagerRoutingTests.swift`
- `testing/tests/StartupAudioInterruptionTests.swift`

## Files Modified (Docs + Repo Metadata)

- `.gitignore`
- `CHANGELOG.md`
- `docs/architecture/finetune-architecture.md`
- `docs/known_issues/resolved/startup-routing-policy-overwrote-explicit-routing.md`
- `docs/agents/6_startup-routing-policy-config/1_review_and_plan.md`
- `docs/agents/6_startup-routing-policy-config/2_implementation_and_validation.md`
- `docs/ai-chat-history/2026-02-14-startup-routing-policy-implementation-and-handoff.md` (this file)

---

## Current Known Issues (Handoff)

1. Pre-existing crossfade test mismatch cluster remains.
- Baseline changed from 19 to 18 failures after startup policy fix.
- Failure class remains duration expectation mismatch (tests vs implementation timing constants).

2. `docs/` now appears widely untracked because it was previously ignored.
- This is expected after removing `docs/` from `.gitignore`.
- Commit strategy is needed (track all docs vs staged subset).

3. Repository has unrelated untracked file:
- `untitled.txt`

---

## Comprehensive TODO List (Handoff Ready)

### Priority 0: Release hygiene

1. Decide docs commit scope now that `docs/` is tracked.
- Option A: commit all existing docs currently untracked.
- Option B: commit only touched docs for this feature.
- Option C: create additional narrow ignore patterns for bulky generated content if needed.

2. Stage and commit startup routing feature + tests + docs + `.gitignore` update.
- Ensure commit message clearly notes behavior change defaulting to preserve explicit routing.

### Priority 1: Verify runtime behavior

3. Manual runtime validation in app UI (macOS 26):
- Set explicit per-app route to non-default device.
- Relaunch app with `preserveExplicitRouting` and confirm route is retained.
- Switch policy to `followSystemDefault`, relaunch, confirm override to default occurs.
- Confirm fallback behavior when explicit device is unavailable does not overwrite saved explicit preference.

4. Regression check startup path for apps with only saved volume/mute and no explicit route.
- Confirm startup default assignment still persists as designed.

### Priority 2: Test debt cleanup

5. Address pre-existing crossfade-duration failing tests.
- Reconcile expectation constants with current `CrossfadeState` implementation.
- Decide whether implementation or tests should change.

6. Re-run full test suite after crossfade alignment and record updated baseline.

### Priority 3: Repo hygiene

7. Remove or intentionally track `untitled.txt`.

8. Consider adding explicit ignores for `docs/**/.DS_Store` (currently only `docs/.DS_Store`) if nested Finder metadata churn appears.

### Priority 4: Documentation consistency

9. If docs commit scope is narrow, ensure at least these are included:
- `docs/architecture/finetune-architecture.md`
- `docs/known_issues/resolved/startup-routing-policy-overwrote-explicit-routing.md`
- `docs/agents/6_startup-routing-policy-config/*`
- this ai-chat-history handoff file

10. Keep changelog and docs in sync after any follow-on crossfade test reconciliation.

---

## Suggested Next Command Sequence (Optional)

```bash
# inspect staged scope choices
git status --short

# stage feature + tests + changelog + ignore + targeted docs
git add .gitignore CHANGELOG.md \
  FineTune/Settings/SettingsManager.swift \
  FineTune/Audio/AudioEngine.swift \
  FineTune/Views/Settings/SettingsView.swift \
  testing/tests/SettingsManagerRoutingTests.swift \
  testing/tests/StartupAudioInterruptionTests.swift \
  docs/architecture/finetune-architecture.md \
  docs/known_issues/resolved/startup-routing-policy-overwrote-explicit-routing.md \
  docs/agents/6_startup-routing-policy-config/1_review_and_plan.md \
  docs/agents/6_startup-routing-policy-config/2_implementation_and_validation.md \
  docs/ai-chat-history/2026-02-14-startup-routing-policy-implementation-and-handoff.md

# commit when ready
git commit -m "Add configurable startup routing policy and preserve explicit routes by default"
```

---

## Final Handoff Status

- Startup routing configurability: implemented.
- Main settings control: implemented.
- Backward-compatible settings decode: implemented.
- Targeted tests for new behavior: passing.
- Project docs/changelog updates: completed.
- `docs/` tracking policy: corrected per user request.
