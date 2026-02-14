Remaining Issue 1: Audio still mutes on permission grant                                             
                                                                                                         
  Why our fixes didn't help: The muting is NOT caused by routeAllApps or the double recreation. It's     
  caused by the fundamental act of destroying aggregate devices. Here's the exact timeline:              

  1. Spotify audio flows through the system default output (AirPods)
  2. User clicks "Allow" → coreaudiod restarts → ALL AudioObjectIDs become invalid
  3. handleServiceRestarted() calls tap.invalidate() on every tap — this destroys the aggregate devices
  that were routing audio
  4. coreaudiod itself restarting disrupts active audio sessions
  5. After 1500ms, new taps are created with .unmuted
  6. After 500ms, permission is confirmed inline → taps destroyed AGAIN and recreated with
  .mutedWhenTapped

  The muting happens at step 3-4. When the aggregate device is torn down, Core Audio interrupts the audio
   stream to Spotify. Spotify detects the route change and internally pauses playback. Our fixes
  (suppression flags, elimination of redundant recreation cycles) are all about what happens AFTER the
  initial disruption — but they can't prevent the disruption itself.

  The .mutedWhenTapped transition (step 6) makes it worse: after step 5, audio is actually flowing again
  through .unmuted taps, then we destroy them again at step 6 for the upgrade, causing a second muting
  event. Our inline permission probe (step 6) was supposed to consolidate this but still requires a
  destroy+recreate cycle.

  Bottom line: The coreaudiod restart itself mutes audio. FineTune then makes it worse with 1-2
  additional disruptions. The only way to avoid muting entirely would be to NOT destroy/recreate taps
  (impossible — the AudioObjectIDs are invalid after restart) or to use a create-before-destroy pattern
  (deferred as high-risk).

  Remaining Issue 2: Device picker still shows "MacBook Pr..." despite AirPods selected

  Why resolvedDeviceUIDForDisplay didn't help: Looking at the code flow:

  1. handleServiceRestarted() destroys all taps but does NOT clear appDeviceRouting (line 253: only taps,
   appliedPIDs, lastHealthSnapshots are cleared)
  2. After 1500ms, applyPersistedSettings() runs. At line 693-694:
  if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
     deviceMonitor.device(for: savedDeviceUID) != nil {
  3. If the saved device UID is the AirPods aggregate UID (not the real AirPods UID), the
  deviceMonitor.device(for:) check fails because the aggregate was destroyed. This causes the fallback
  path (lines 698-719) which reads the current macOS default — MacBook Pro Speakers — and writes it to
  both appDeviceRouting AND settingsManager.

  The critical question: what UID is being persisted? If it's the aggregate device UID (which changes
  every time a tap is created), then every recreation cycle would fail the deviceMonitor.device(for:)
  check and overwrite routing to the current default.

  But looking at setDevice (line 571): appDeviceRouting[app.id] = deviceUID — this stores whatever UID
  was passed in. And routeAllApps calls setDevice for each app. The UIDs in appDeviceRouting should be
  real device UIDs (like the AirPods UID), not aggregate UIDs.

  So the real culprit is more likely: DeviceVolumeMonitor.handleServiceRestarted() at line 493-512 — it
  reads the default device on a background thread and updates defaultDeviceUID to MacBook Pro Speakers
  (because AirPods may not have reconnected yet after the coreaudiod restart). This happens independently
   of AudioEngine.handleServiceRestarted(). Then when the UI renders, resolvedDeviceUIDForDisplay is
  called with defaultDeviceUID already set to MacBook Pro Speakers.

  BUT — our fix should handle this. Priority 3 in our resolvedDeviceUIDForDisplay returns
  appDeviceRouting[app.id] even if the device isn't in availableDevices. Unless appDeviceRouting itself
  was already overwritten to MacBook Pro Speakers by:
  - A previous routeAllApps that slipped through before our fix was deployed
  - The applyPersistedSettings fallback path (line 698-719) writing the wrong default

  Most likely explanation: The persisted settings were already corrupted from a previous session (before
  our fix). The settings file had MacBook Pro Speakers as the saved routing. On this launch,
  applyPersistedSettings read the corrupted saved routing (MacBook Pro = line 696) and applied it. Our
  resolvedDeviceUIDForDisplay fix then correctly showed the saved routing — which was already wrong.

  Confirming: settings.json was not found on disk, which means either it's in a different location, or
  this was a fresh launch with no prior settings. If no prior settings exist, applyPersistedSettings
  takes the "no saved settings" path (line 686-689) and skips the app entirely — appDeviceRouting never
  gets set. Then resolvedDeviceUIDForDisplay falls through all priorities to Priority 5:
  defaultDeviceUID, which DeviceVolumeMonitor has set to MacBook Pro Speakers after the coreaudiod
  restart.

  Root cause confirmed: On fresh launch, appDeviceRouting is empty for Spotify.
  resolvedDeviceUIDForDisplay falls through Priorities 1-4 (all nil) and hits Priority 5:
  defaultDeviceUID — which DeviceVolumeMonitor updated to MacBook Pro Speakers during the coreaudiod
  restart. Our fix added Priorities 3-4 (trust in-memory/persisted routing even if device invisible), but
   those are nil on fresh launch because no routing was ever set.

  Remaining Issue 3: Volume jumps far on single keyboard press

  The keyboard volume keys control the system output device volume, not the per-app volume. Looking at
  the screenshot: AirPods shows 50% in the OUTPUT DEVICES section. The volume jump could be caused by:

  1. DeviceRow slider mapping (line 40): sliderValue = State(initialValue: Double(volume)) — the device
  row uses linear 0-1 mapping (line 93: Int(sliderValue * 100)%), which is correct for system volume.
  2. But the keyboard volume step size is macOS-controlled (~6.25% per press = 1/16). If FineTune's
  onVolumeChange callback (via deviceVolumeMonitor.setVolume) is interacting with macOS's own volume
  change, you could get a feedback loop: macOS changes volume → FineTune listener fires → FineTune reads
  new volume → FineTune sets volume → macOS listener fires again.
  3. The volumeDebounceMs: 30 may not be sufficient to prevent this feedback loop for keyboard-driven
  changes, which fire multiple kAudioDevicePropertyVolumeScalar notifications in rapid succession.
  4. Another possibility: after coreaudiod restart, the volume state read by readAllStates() could be
  stale (1.0 = max, which is what the HAL reports for Bluetooth devices before initialization). If the
  slider was showing a stale max volume and the real volume was 50%, the first keyboard press would cause
   the slider to snap from the displayed (wrong) value to the real value.

  ---
  Summary of remaining gaps
  Issue: Audio muting
  Our fix addressed: Reduced from 3 cycles to 2
  Actual cause: Fundamental: aggregate destruction + coreaudiod restart interrupts audio. Cannot fix
    without create-before-destroy.
  ────────────────────────────────────────
  Issue: Wrong device display
  Our fix addressed: Added fallback priorities 2-4
  Actual cause: On fresh launch, no routing exists, so all fallbacks are nil. Falls through to
    defaultDeviceUID which DeviceVolumeMonitor sets to MacBook Speakers during restart.
  ────────────────────────────────────────
  Issue: Volume jump
  Our fix addressed: Not addressed
  Actual cause: Likely stale volume state after coreaudiod restart (HAL reports 1.0 for BT devices before

    init), or feedback loop between macOS volume keys and FineTune's volume listener.
  The device display issue needs a different approach for the fresh-launch case: when appDeviceRouting is
   empty and no persisted routing exists, resolvedDeviceUIDForDisplay has nothing to fall back on except
  defaultDeviceUID — which is transiently wrong.

---

## Status Update (2026-02-08)

### Issue 1: Audio muting on permission grant

**Status: PARTIALLY MITIGATED**

- `isRecreatingTaps` flag with `recreationGracePeriod` + `recreationEndedAt` now gates `routeAllApps` during recreation (`AudioEngine.swift:61-70, 117, 888`).
- `routeAllApps` skips apps in `followsDefault` set (`AudioEngine.swift:1255`), reducing spurious re-routing.
- `routeAllApps` has early-exit when all routings already match (`AudioEngine.swift:900`).
- The fundamental issue (aggregate device destruction causes audio interruption) remains. Neither "lazy permission transition" (Option A) nor "create-before-destroy for permission" (Option B) from the potential resolutions doc has been implemented.
- `recreateAllTaps()` still sets `isRecreatingTaps` inside the Task (`AudioEngine.swift:349`), not before — the race condition described in the potential resolutions doc is still present (though mitigated by the grace period).

### Issue 2: Device picker shows wrong device

**Status: PARTIALLY MITIGATED**

- `followsDefault` tracking added (`AudioEngine.swift:29`), `isFollowingDefault()` in `SettingsManager.swift:119`.
- Device reconnection handler added (`AudioEngine.swift:1248-1311`) — restores persisted routing when a device reconnects.
- The fresh-launch case (no persisted routing → falls through to `defaultDeviceUID`) remains unaddressed.
- `routeAllApps` still exists and fires on default device change — not yet replaced with `handleDefaultDeviceChanged` as recommended in Session 4.

### Issue 3: Volume jumps on keyboard press

**Status: OPEN — no investigation or fix applied**

- `_deviceVolumeCompensation` exists with clamping logic (0.1-4.0 range) and is set to 1.0 during crossfade, but no dedicated investigation of the volume jump behavior has been done.
- No hysteresis or debounce improvements to the keyboard volume path.