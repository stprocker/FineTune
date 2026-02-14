# Team Lead: Executive Analysis & Recommendations

**Agent:** team-lead
**Date:** 2026-02-07
**Task:** Coordinate three research agents, synthesize findings for actionable next steps

---

## Team Composition

| Agent | Role | Deliverable |
|-------|------|-------------|
| **upstream-reviewer** | Reviewed original FineTune repo (40+ commits, issues, PRs, code) | Upstream delta report |
| **issues-analyst** | Deep dive into all docs/, known_issues/, agents/, investigation/ | 8-issue inventory with root causes |
| **synthesizer** | Cross-referenced both reports against source code | 5-phase fix plan with code-level guidance |

---

## Key Conclusions

### 1. The #1 Finding: Adopt Upstream's "Follow Default" Pattern

The single most impactful change is replacing our `routeAllApps(to:)` with upstream's `followsDefault: Set<pid_t>` approach. Our current code overwrites **ALL persisted per-app device routings** every time a default-device-change notification fires -- including spurious ones from aggregate device creation/destruction. This is persistent data corruption, not just a display bug.

### 2. Upstream Has the Same Core Audio Problems

Despite a simpler architecture (`stereoMixdownOfProcesses`, no health checks, no diagnostics), upstream has the same fundamental issues: distortion with USB interfaces (#84, #62), buzzing on device switch (#2, #30), Bluetooth codec problems (#52), and app-specific silence (#12, #57). Their simplicity doesn't solve these -- it just means they have no recovery mechanisms.

### 3. Our Robustness Features Are Worth Keeping

Our fork's health checks, diagnostics, permission lifecycle, service restart handling, and format conversion are genuinely valuable. The synthesizer recommends keeping all of these while selectively adopting upstream patterns.

### 4. Architecture Changes Should Be Incremental

The synthesizer evaluated 4 proposed architectural changes and recommends:
- **Tap-only aggregates:** Not now (too complex, "follow default" fixes the notification problem)
- **Live tap reconfiguration:** Already implemented (use more aggressively)
- **Always `.mutedWhenTapped`:** Don't adopt (our permission lifecycle is safer)
- **Decouple capture/playback:** Not now (too complex for uncertain benefit)

---

## Prioritized Fix Plan

### Phase 1: Quick Wins (Low Risk, Immediate)
| # | Fix | Issue | Risk |
|---|-----|-------|------|
| 1 | Reduce `pauseRecoveryPollInterval` to 300ms | F | Very low |
| 2 | Add `!isRecreatingTaps` guard in fast health check | D | Low |
| 3 | Reset `_deviceVolumeCompensation` to 1.0 after crossfade | G | Low |

### Phase 2: Issue D Full Fix (Medium Risk)
| # | Fix | Issue | Risk |
|---|-----|-------|------|
| 4 | Refactor `upgradeTapsToMutedWhenTapped` to per-tap fallback | D | Low |

### Phase 3: Issue C Full Fix (Higher Risk, Highest Impact)
| # | Fix | Issue | Risk |
|---|-----|-------|------|
| 5 | Add `followsDefault` tracking to AudioEngine | C | Medium |
| 6 | Add `isFollowingDefault`/`setFollowDefault` to SettingsManager | C | Medium |
| 7 | Replace `routeAllApps` with `handleDefaultDeviceChanged` | C | Medium |
| 8 | Update `setDevice` to accept optional deviceUID | C | Medium |
| 9 | Add `handleDeviceConnected` for device reconnection | C | Low |
| 10 | Remove `routeAllApps` entirely | C | Low (after above) |

### Phase 4: Issue E (Platform Bug, Monitor)
| # | Fix | Issue | Risk |
|---|-----|-------|------|
| 11 | Test `stereoMixdownOfProcesses` on macOS 26 | E | Medium |
| 12 | Optional automatic PID-only fallback for dead bundle-ID taps | E | Medium |

### Phase 5: Investigation
| # | Fix | Issue | Risk |
|---|-----|-------|------|
| 13 | Investigate Issue G (volume jumps) with logging | G | None |

---

## Open Issues Summary

| Issue | Severity | Status | Root Cause |
|-------|----------|--------|------------|
| **C** — Spurious device display / routing corruption | HIGH | OPEN | `routeAllApps` + spurious notifications from aggregate devices |
| **D** — Audio muting during permission transition | HIGH | OPEN | Double/triple tap recreation on first-launch |
| **E** — macOS 26 bundle-ID tap silence | HIGH | OPEN | Platform bug: `isProcessRestoreEnabled` kills aggregate output |
| **F** — Stale play/pause status | MEDIUM | PARTIAL | 1s poll latency, circular VU dependency |
| **G** — Volume jumps on keyboard | LOW-MED | OPEN | Not investigated (likely stale `_deviceVolumeCompensation`) |

---

## Upstream Features Worth Adopting (Future)

| Feature | Priority | Complexity |
|---------|----------|------------|
| "Follow Default" routing | **Critical** (fixes Issue C) | Medium |
| `waitUntilReady()` for aggregates | High | Low |
| Device reconnection handler | Medium | Low |
| Pinned apps | Low | Medium |
| Multi-device output | Low | High |
| Input device lock (BT codec protection) | Low | Medium |
| URL scheme automation | Low | Low |

---

## Implementation Status (as of 2026-02-08)

### Fix Plan Progress

| Phase | Item | Status | Notes |
|-------|------|--------|-------|
| **1** | #1 Reduce `pauseRecoveryPollInterval` to 300ms | NOT DONE | Still `.seconds(1)` at `AudioEngine.swift:108` |
| **1** | #2 Add `!isRecreatingTaps` guard in fast health check | DONE | `isRecreatingTaps` flag + `recreationGracePeriod` + `recreationEndedAt` implemented (`AudioEngine.swift:61-70, 117`). `routeAllApps` is gated by this at `AudioEngine.swift:888`. |
| **1** | #3 Reset `_deviceVolumeCompensation` to 1.0 after crossfade | DONE | Reset at `ProcessTapController.swift:430` on first activation; during crossfade, compensation is bypassed (`1.0`) at lines 1149, 1179. |
| **2** | #4 Refactor `upgradeTapsToMutedWhenTapped` to per-tap fallback | NOT DONE | `upgradeTapsToMutedWhenTapped()` exists at `AudioEngine.swift:1159` but still operates as batch recreation via `recreateAllTaps()` (line 388), not per-tap fallback. |
| **3** | #5-10 "Follow Default" pattern | PARTIALLY DONE | `followsDefault: Set<pid_t>` added at `AudioEngine.swift:29`. `isFollowingDefault()` in `SettingsManager.swift:119`. `routeAllApps` now skips follow-default apps (line 1255). However, `routeAllApps` is **not removed** — it still exists (line 882) and is still called on default-device-change (line 245). Full replacement with `handleDefaultDeviceChanged` not done. |
| **4** | #11-12 macOS 26 bundle-ID tap investigation | NOT DONE | `isProcessRestoreEnabled` still set. No PID-only fallback for dead bundle-ID taps. `stereoMixdownOfProcesses` not tested on macOS 26. |
| **5** | #13 Investigate volume jumps (Issue G) | NOT DONE | No dedicated logging added. `_deviceVolumeCompensation` logic exists but no investigation of volume jumps. |

### Open Issues Update

| Issue | Session 4 Status | Current Status |
|-------|-----------------|----------------|
| **C** — Routing corruption | OPEN | PARTIALLY MITIGATED — `followsDefault` tracking added, `routeAllApps` skips those apps; but `routeAllApps` still exists and fires on device change |
| **D** — Permission muting | OPEN | PARTIALLY MITIGATED — `isRecreatingTaps` guard prevents spurious `routeAllApps` during recreation; batch per-tap fallback not done |
| **E** — Bundle-ID silence | OPEN | OPEN — no changes to the underlying issue |
| **F** — Stale play/pause | PARTIAL | IMPROVED — `MediaNotificationMonitor` added for Spotify/Apple Music instant detection (Session 2 work); poll interval still 1s |
| **G** — Volume jumps | OPEN | OPEN — no investigation |

### Upstream Features Adopted (via Session 5)

| Feature | Status |
|---------|--------|
| "Follow Default" routing | Partially adopted (tracking in place, `routeAllApps` not removed) |
| `waitUntilReady()` for aggregates | NOT adopted |
| Device reconnection handler | DONE — `AudioEngine.swift:1248-1311` handles device reconnection, restores persisted routing |
| Pinned apps | DONE — `PinnedAppInfo` in `SettingsManager`, `InactiveAppRow` view, `DisplayableApp.pinnedInactive` |
| Multi-device output | NOT adopted |
| Input device lock (BT codec protection) | DONE — `lockInputDevice` setting, auto-revert logic in `AudioEngine.swift:290, 1473, 1538` |
| URL scheme automation | DONE — `URLHandler.swift` with `finetune://` scheme (set-volumes, step-volume, set-mute, toggle-mute, set-device, reset) |
| Menu bar icon customization | DONE — `MenuBarIconStyle` enum, `SettingsIconPickerRow`, `MenuBarStatusController` |
