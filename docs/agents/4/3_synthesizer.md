# Agent 3: Comprehensive Audio Fix Synthesis

**Agent:** synthesizer
**Date:** 2026-02-07
**Task:** Combine findings from upstream-reviewer and issues-analyst; provide prioritized fix recommendations

---

## Section A: Upstream Delta

Compared our fork against the upstream `ronitsingh10/FineTune` repo (latest commit `729de82` from Feb 4, 2026).

### A.1 -- Things Upstream Has That We Don't

1. **"Follow Default" / System Audio concept** -- Upstream has a `followsDefault: Set<pid_t>` that tracks which apps should track the system default device. When the system default changes, only apps in `followsDefault` are switched. Our fork uses `routeAllApps(to:)` which overwrites ALL persisted routings on every default-device-change notification -- the root cause of Issue C.

2. **Multi-device output** -- Upstream supports routing a single app to multiple output devices simultaneously via `kAudioAggregateDeviceIsStackedKey: true`. `ProcessTapController` takes `targetDeviceUIDs: [String]` (array). Our fork is single-device only.

3. **Pinned (inactive) apps** -- Upstream has a pinning system where apps can persist in the UI even when not running, with pre-set volume/mute/EQ/routing.

4. **Input device lock** -- Upstream prevents Bluetooth codec downgrade by locking the input device to built-in mic when BT headphones connect.

5. **Device reconnection handler** -- Upstream has `handleDeviceConnected()` that switches pinned apps BACK to their preferred device when it reappears. Our fork only handles disconnection.

6. **`CrossfadeOrchestrator` utility** -- Upstream extracted tap destruction into a static helper. Cleaner but not functionally different.

7. **`AudioObjectID.waitUntilReady(timeout:)`** -- Upstream waits for aggregate devices to be ready before use. Our fork doesn't, which could cause race conditions on slow devices.

8. **`CATapDescription(stereoMixdownOfProcesses:)`** -- Upstream uses the stereo mixdown convenience initializer (no explicit stream index or device UID). Our fork uses `CATapDescription(__processes:andDeviceUID:withStream:)` with explicit stream/device matching -- this is MORE correct for per-device routing but potentially more fragile.

### A.2 -- Things We Have That Upstream Doesn't

1. **Permission lifecycle** (`.unmuted` -> `.mutedWhenTapped` upgrade) -- Upstream always uses `.mutedWhenTapped` from the start. Our fork has the safer first-launch flow that avoids silencing audio if the app is killed during permission grant.

2. **Live tap reconfiguration** (`updateMuteBehavior`) -- We can change muteBehavior in-place without destroying taps. Upstream doesn't have this.

3. **Health checks** -- We have stalled/broken tap detection with automatic recreation. Upstream has no health monitoring.

4. **Recreation suppression** -- We have `isRecreatingTaps`, `recreationEndedAt`, grace periods, and routing snapshots. Upstream has none of this (but also doesn't need it since it doesn't do recreation).

5. **Service restart handler** -- We handle coreaudiod restarts. Upstream doesn't.

6. **Diagnostics** -- We have extensive TapDiagnostics with 20+ counters. Upstream has none.

7. **Format handling** -- We handle non-float32 audio formats, converters, and non-interleaved layouts. Upstream assumes stereo float32 interleaved.

8. **Switch serialization** -- We cancel in-flight switches (`switchTasks`). Upstream fires concurrent switches without protection.

9. **Pause/play detection** -- We have asymmetric hysteresis, MediaRemote integration, and a dedicated recovery timer. Upstream has none.

10. **Concurrent switch cancellation** -- Our `setDevice` cancels previous in-flight switches and reverts routing on failure. Upstream doesn't.

### A.3 -- Key Takeaway

**Upstream's "follow default" pattern is the critical adoption target.** It directly fixes Issue C. The multi-device output is nice-to-have but not related to our bug reports. The rest of upstream's additions (pinning, input lock) are feature work, not bug fixes.

---

## Section B: Fix Recommendations (Prioritized)

### Issue C: Spurious Default Device Display / Routing Data Corruption (HIGH)

**Problem:** When coreaudiod restarts or aggregate devices are created/destroyed, the real output device in our aggregate fires spurious `kAudioHardwarePropertyDefaultOutputDevice` change notifications. Our `routeAllApps(to:)` then overwrites ALL persisted per-app device routings to the system default, destroying user customization.

**Recommended Fix:**
Adopt upstream's "follow default" pattern. This is a multi-step change:

1. **Add `followsDefault: Set<pid_t>` to `AudioEngine`** -- tracks which apps should follow the system default.

2. **Change `setDevice(for:deviceUID:)` signature** to accept optional `String?` -- `nil` means "follow system default".

3. **Replace `deviceVolumeMonitor.onDefaultDeviceChangedExternally`** handler: instead of calling `routeAllApps(to:)`, only switch taps for apps in `followsDefault`.

4. **Remove `routeAllApps(to:)` entirely** -- it is the corruption vector. Replace with `handleDefaultDeviceChanged()` that only affects following apps.

5. **In `applyPersistedSettings`**, check `settingsManager.isFollowingDefault(for:)` and populate `followsDefault` accordingly.

6. **Add `handleDeviceConnected`** to switch pinned apps back to their preferred device when it reappears (prevents AirPods from staying on speakers after reconnect).

**Specific files to modify:**
- `AudioEngine.swift`: lines 219-227 (replace `onDefaultDeviceChangedExternally` handler), lines 710-758 (remove `routeAllApps`), lines 640-703 (update `setDevice`), lines 772-847 (update `applyPersistedSettings`)
- `SettingsManager.swift`: add `isFollowingDefault(for:)`, `setFollowDefault(for:)` methods

**Risk:** Medium. Changes routing logic broadly. Test with multiple apps routed to different devices.

**Dependencies:** None -- can be done independently.

---

### Issue D: Audio Muting During .unmuted -> .mutedWhenTapped Transition (HIGH)

**Problem:** On first launch, when system audio permission is granted, coreaudiod restarts. Our `handleServiceRestarted()` tears down all taps and recreates them. If `permissionConfirmed` is false (first launch), taps are created with `.unmuted`, then a fast health check confirms permission and calls `upgradeTapsToMutedWhenTapped()`. If the live `updateMuteBehavior` fails, it falls back to `recreateAllTaps()` -- a second full recreation cycle. During these overlapping recreations, audio goes silent.

**Recommended Fix (Two-Part):**

**Part 1: Consolidate the service-restart + permission-confirm into one cycle**

The fix at line 897 already checks `!self.permissionConfirmed` before triggering, and `handleServiceRestarted` sets `permissionConfirmed = true` inline at line 339. But there's a race: the fast health check task is spawned per-tap in `ensureTapExists` (line 883). If the service-restart inline probe at line 338 confirms permission AFTER the fast health check task has already started but BEFORE it checks `self.permissionConfirmed`, we get a double upgrade.

**Fix:** In the fast health check (line 897), add a guard for `!self.isRecreatingTaps`:
```swift
// Line 897 area:
if needsPermissionConfirmation && !self.permissionConfirmed && !self.isRecreatingTaps && Self.shouldConfirmPermission(from: d) {
```

**Part 2: Make `upgradeTapsToMutedWhenTapped` never fall back to `recreateAllTaps`.**

Currently (line 970), if any single tap fails the live `updateMuteBehavior`, the entire set is recreated. Instead, only recreate the specific failed tap:

```swift
// Replace lines 959-974:
private func upgradeTapsToMutedWhenTapped() {
    for (pid, tap) in taps {
        let appName = apps.first(where: { $0.id == pid })?.name ?? "PID:\(pid)"
        if tap.updateMuteBehavior(to: .mutedWhenTapped) {
            logger.info("[PERMISSION] Upgraded \(appName) to .mutedWhenTapped (live)")
        } else {
            logger.warning("[PERMISSION] Live upgrade failed for \(appName), recreating individually")
            guard let app = apps.first(where: { $0.id == pid }),
                  let deviceUID = appDeviceRouting[pid] else { continue }
            tap.invalidate()
            taps.removeValue(forKey: pid)
            appliedPIDs.remove(pid)
            // Recreate this single tap with muteOriginal=true
            permissionConfirmed = true  // Already set, but ensure
            ensureTapExists(for: app, deviceUID: deviceUID)
        }
    }
}
```

**Risk:** Low. The guard addition is safe. The per-tap fallback is more surgical than the current all-or-nothing approach.

**Dependencies:** None.

---

### Issue E: Bundle-ID Tap Silent Output on macOS 26 (HIGH)

**Problem:** On macOS 26 (Tahoe), taps created with `bundleIDs` + `isProcessRestoreEnabled` have dead aggregate output (outPeak = 0), even though input audio is captured (inPeak > 0). PID-only taps work but can't capture Chromium audio on macOS 26.

**Current state:** `isProcessRestoreEnabled` is already disabled (commented out at line 291 of ProcessTapController.swift). Bundle-ID taps are still attempted but without process restore. The `shouldConfirmPermission` function already guards against promoting taps with dead output.

**Recommended Fix:**

This is a macOS platform bug. Our options are limited:

1. **Keep current approach:** Bundle-ID taps are created but `isProcessRestoreEnabled` stays disabled. The `shouldConfirmPermission` guard prevents upgrade to `.mutedWhenTapped` when output is dead, so we stay on `.unmuted` (audio still plays through system, just without per-app volume control). This is the safest.

2. **Add automatic fallback to PID-only:** In `makeTapDescription`, after creating a bundle-ID tap, schedule a health check. If output is dead after N seconds, recreate as PID-only:

```swift
// In ensureTapExists, after tap creation succeeds:
if #available(macOS 26.0, *), app.bundleID != nil {
    // Schedule bundle-ID tap validation
    Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(2))
        guard let self, let tap = self.taps[pid] else { return }
        let d = tap.diagnostics
        if d.hasDeadOutput && !d.hasDeadInput {
            self.logger.warning("[BUNDLE-ID] Dead output detected for \(app.name), falling back to PID-only")
            UserDefaults.standard.set(true, forKey: "FineTuneForcePIDOnlyTaps")
            tap.invalidate()
            self.taps.removeValue(forKey: pid)
            self.appliedPIDs.remove(pid)
            self.ensureTapExists(for: app, deviceUID: deviceUID)
        }
    }
}
```

3. **Monitor Apple's fix:** Track macOS 26 beta releases. The stereo mixdown initializer (upstream's approach) might work better -- test `CATapDescription(stereoMixdownOfProcesses:)` as an alternative to the explicit device+stream constructor.

**Risk:** Option 1 = no risk. Option 2 = medium risk (UserDefaults side-effect). Option 3 = requires testing.

**Dependencies:** None.

---

### Issue F: Stale Play/Pause Status (MEDIUM)

**Problem:** 1s latency for pause-to-playing recovery. The `pauseRecoveryPollInterval` is 1 second, and the VU polling stops when `isPaused` is true (circular dependency).

**Current mitigations already in place:**
- `updatePauseStates()` runs every 1s independently of UI polling
- `getAudioLevel()` immediately marks as playing when audio detected
- `mediaNotificationMonitor` provides instant Spotify play/pause

**Recommended Fix:**

1. **Reduce `pauseRecoveryPollInterval` from 1s to 0.3s** -- the timer is lightweight (just reads tap.audioLevel), so the CPU cost increase is negligible:
```swift
var pauseRecoveryPollInterval: Duration = .milliseconds(300)
```

2. **Add MediaRemote integration for more apps** -- the `mediaNotificationMonitor.onPlaybackStateChanged` currently only fires for apps that post `kMRMediaRemoteNowPlayingApplicationPlaybackStateDidChange`. Check if Chrome, Firefox, and other browsers support this. If not, the 0.3s poll is the best we can do.

**Risk:** Very low.

**Dependencies:** None.

---

### Issue G: Volume Jumps on Keyboard Press (LOW-MEDIUM)

**Problem:** Not investigated.

**Likely cause (based on code analysis):** When the user presses volume keys, macOS changes the system output device volume. Our `deviceVolumeMonitor.onVolumeChanged` callback updates `tap.currentDeviceVolume`. However, `_deviceVolumeCompensation` (computed during crossfade as `sourceVolume / destVolume`) may interact poorly with real-time device volume changes, causing momentary gain jumps.

**Recommended investigation:**
1. Add logging in `onVolumeChanged` to capture the exact volume delta
2. Check if `_deviceVolumeCompensation` is non-1.0 when volume jumps occur
3. If compensation is the culprit, reset it to 1.0 after crossfade completes + a settling period

**Dependencies:** Needs investigation before fix can be specified.

---

## Section C: Architectural Recommendations

### C.1 -- Switch to tap-only aggregates (Remove real device from aggregate)

**Feasibility:** Uncertain. Our aggregate currently includes the real output device as a sub-device AND as `kAudioAggregateDeviceMainSubDeviceKey`. The tap is layered on top. Upstream uses the same pattern (real device in aggregate). SoundPusher/AudioTee use a different approach where they have a virtual device that receives the tap output and a separate output path.

**Implementation complexity:** HIGH. Would require:
- Creating a tap-only aggregate (no real sub-device)
- Adding a separate output IOProc to write to the real device
- Managing clock synchronization between the tap aggregate and the real device

**Upstream status:** Upstream does NOT do this. They still include the real device in the aggregate.

**Recommendation:** **Do NOT adopt now.** The "follow default" fix (Issue C fix) addresses the spurious notification problem more surgically. If notifications remain problematic after that fix, revisit.

### C.2 -- Live tap reconfiguration via `kAudioTapPropertyDescription`

**Feasibility:** ALREADY IMPLEMENTED in our fork. `updateMuteBehavior(to:)` at ProcessTapController.swift:245 does exactly this.

**Recommendation:** Already done. Use it more aggressively -- e.g., in `upgradeTapsToMutedWhenTapped`, trust the live path and only recreate on failure (already recommended in Issue D fix).

### C.3 -- Always use `.mutedWhenTapped` (Remove `.unmuted` phase)

**Feasibility:** HIGH. Upstream does this -- always `.mutedWhenTapped` from the start. The risk is that on first launch, if the user dismisses or ignores the permission dialog, audio is silenced with no recovery path until they grant permission.

**Upstream approach:** Upstream doesn't handle the permission lifecycle at all. It just creates taps with `.mutedWhenTapped` and presumably the user deals with it.

**Recommendation:** **Do NOT adopt.** Our permission lifecycle is safer. The Issue D fix addresses the double-recreation problem without losing the safety net. The `.unmuted` first-launch approach prevents a class of "app silenced my audio" user complaints.

### C.4 -- Decouple capture from playback (tap-only aggregate + separate output IOProc)

**Same as C.1.** Not recommended now.

### Recommended Adoption Order:
1. C.2 (already done)
2. C.1/C.4 only if "follow default" pattern doesn't fully solve Issue C
3. C.3 not recommended

---

## Section D: Quick Wins

1. **Reduce `pauseRecoveryPollInterval` to 300ms** -- One line change, immediate improvement for Issue F. File: `AudioEngine.swift`.

2. **Add `!self.isRecreatingTaps` guard to fast health check** -- One line change, prevents double-recreation race in Issue D. File: `AudioEngine.swift`.

3. **Reset `_deviceVolumeCompensation` to 1.0 after crossfade settles** -- In `promoteSecondaryToPrimary()` at ProcessTapController.swift, add a scheduled reset:
```swift
// After crossfade completes, gradually decay compensation back to 1.0
// This prevents stale compensation from affecting subsequent volume changes
_deviceVolumeCompensation = 1.0
```
This may address Issue G (volume jumps) -- the compensation ratio could go stale.

4. **Add `aggregateDeviceID.waitUntilReady(timeout:)` check** -- Upstream does this. We should too, in `activate()` after `AudioHardwareCreateAggregateDevice`. Prevents race conditions on slow Bluetooth devices.

---

## Section E: Recommended Implementation Order

### Phase 1: Quick Wins (Low Risk, Immediate)
1. Reduce `pauseRecoveryPollInterval` to 300ms (Issue F)
2. Add `isRecreatingTaps` guard in fast health check (Issue D partial)
3. Reset `_deviceVolumeCompensation` to 1.0 in `promoteSecondaryToPrimary` (Issue G investigation)

### Phase 2: Issue D Full Fix (Medium Risk)
4. Refactor `upgradeTapsToMutedWhenTapped` to per-tap fallback (Issue D)

### Phase 3: Issue C Full Fix (Higher Risk, Highest Impact)
5. Add `followsDefault` tracking to AudioEngine
6. Add `isFollowingDefault` / `setFollowDefault` to SettingsManager
7. Replace `routeAllApps(to:)` with `handleDefaultDeviceChanged()` that only affects following apps
8. Update `setDevice` to accept optional deviceUID
9. Add `handleDeviceConnected` for device reconnection
10. Remove `routeAllApps` entirely

### Phase 4: Issue E (Platform Bug, Monitor)
11. Test `CATapDescription(stereoMixdownOfProcesses:)` on macOS 26
12. Optionally add automatic PID-only fallback for dead bundle-ID taps

### Phase 5: Investigation
13. Investigate Issue G (volume jumps) with logging -- may already be fixed by Phase 1 item 3

---

## Summary

The single highest-impact change is **adopting the "follow default" pattern from upstream** (Issue C fix, Phase 3). This eliminates the routing corruption that causes the most user-visible damage. The Issue D fix is surgical and low-risk. Issue E is a platform bug with limited mitigation options. Issues F and G have quick wins available.

Key files to modify:
- `FineTune/Audio/AudioEngine.swift`
- `FineTune/Audio/ProcessTapController.swift`
- `SettingsManager.swift` (needs `isFollowingDefault`, `setFollowDefault` methods)
