
Unaddressed Items Worth Tackling

  1. The recreateAllTaps() Race Condition (Bug 1, still open)

  The flag is still set inside the nested Task at line 843 of AudioEngine.swift. The grace period helps
  catch late-arriving notifications, but there's a window during the very first moments of permission
  confirmation where a queued MainActor debounce task can slip through before the flag is set. This is a
  one-line fix:

  Idea: Move isRecreatingTaps = true to be set before the Task is created in recreateAllTaps(), matching
  what handleServiceRestarted() already does correctly.

  ---
  2. No Snapshot/Restore of Routing State (Bug 1, architectural gap)

  This is the bigger concern. Right now, if a spurious kAudioHardwarePropertyDefaultOutputDevice
  notification fires and routeAllApps(to: speakersUID) runs before suppression kicks in, that write
  overwrites the in-memory appDeviceRouting and potentially the persisted settings too. There's no way to
   recover the "correct" routing after the fact.

  Idea: Before any recreation event, snapshot appDeviceRouting into a savedRouting variable. After
  recreation completes, restore from the snapshot instead of reading from disk. This makes the in-memory
  state the source of truth during transitions, not the persisted settings (which may have been corrupted
   by the spurious notification).

  ---
  3. Permission Grant Still Recreates Immediately (Bug 2)

  The research identifies two options, and neither is implemented:

  Option A — "Lazy Transition" (my favorite, simplest): When permission is confirmed, just flip the
  permissionConfirmed flag and don't recreate existing taps. They keep running as .unmuted. Only new taps
   created from that point forward use .mutedWhenTapped. The next time taps are naturally recreated
  (device switch, app launch, coreaudiod restart), they'll pick up the new mute behavior. This completely
   sidesteps the muting bug with zero audio interruption.

  The trade-off the research mentions (additive volume with .unmuted) is real but mild — the user only
  has .unmuted taps until the next natural recreation event, which typically happens within minutes. And
  .unmuted taps already work fine pre-permission.

  Option B — Create-Before-Destroy for Permission Recreation: Port the same create-before-destroy logic
  from ProcessTapController.switchDevice() into recreateAllTaps(). Create all new .mutedWhenTapped taps
  first, let them warm up, then destroy the old .unmuted taps. This is more complex but gives immediate
  .mutedWhenTapped behavior without a gap.

  ---
  4. No State Machine (Architectural, Section 7.4)

  The research recommends replacing the boolean flags (isRecreatingTaps, permissionConfirmed) with an
  explicit state machine enum. The current code has multiple independent booleans + timestamps that
  interact in subtle ways. An AudioEngineState enum would make the suppression logic self-documenting and
   prevent impossible state combinations.

  Creative expansion: I'd go further than the research suggests. Instead of just three states, consider
  something like:

  idle → awaitingPermission → confirmedRunning
                           ↘ recreatingForPermission → confirmedRunning
  confirmedRunning → recreatingForDeviceChange → confirmedRunning
  confirmedRunning → handlingServiceRestart → confirmedRunning

  Each state carries its own associated data (saved routing, reason for recreation, suppression rules).
  This makes the entire permission + recreation + suppression flow a single, testable state machine
  rather than scattered flag checks.

  ---
  5. No MediaRemote Integration (Bug 3)

  This is the biggest untouched item. The current play/pause detection is purely VU-based with a 400ms
  safety poll. The research identifies MediaRemote.framework as the authoritative source for play/pause
  state, at least for the active now-playing app.

  Creative ideas:

  A — Hybrid "confidence" model: Instead of binary playing/paused, maintain a confidence score per app:
  - Audio above threshold → high confidence "playing"
  - MediaRemote says playing → high confidence "playing" (for the active media app)
  - kAudioProcessPropertyIsRunning says running → medium confidence
  - Audio below threshold for 0.5s → high confidence "paused"
  - Combine signals: if MediaRemote says playing but audio is silent, show "playing" (maybe buffering).
  If audio is loud but MediaRemote says paused, trust the audio (MediaRemote might be stale).

  B — MediaRemote as "fast path" for the active app: Use MediaRemote to get instant play/pause
  transitions for the one app macOS considers the "now playing" client (usually the most recently active
  media app). For all other apps, fall back to VU-based detection. This gives you the best of both worlds
   — instant state changes for the app the user most likely cares about, and broad coverage for
  everything else.

  C — The entitlement problem: Research notes macOS 15.4+ requires
  com.apple.mediaremote.set-playback-state. But FineTune only needs to read state, not set it. The
  MRMediaRemoteGetNowPlayingApplicationIsPlaying() and notification registration functions may work
  without the entitlement. Worth testing on 15.4+ before ruling it out.

  ---
  6. No Hysteresis for Play/Pause Thresholds (Bug 3)

  Single threshold (0.002) with a single grace period (0.5s). The research suggests separate thresholds
  for entering vs. exiting paused state.

  Idea: Use asymmetric transitions:
  - Playing → Paused: Level below 0.001 for 0.4s (strict, avoids false "paused" during quiet passages)
  - Paused → Playing: Level above 0.005 for 0.05s (loose, nearly instant response when audio resumes)

  This eliminates the flickering problem the research identifies during between-song silence.

  ---
  7. Device UID Validation in onDefaultDeviceChangedExternally (Bug 1)

  The current callback checks suppression but doesn't validate whether the device change is meaningful.
  If all apps are already routed to the "new" default device, the call to routeAllApps() is a no-op that
  still triggers unnecessary work.

  Idea: Before calling routeAllApps(to:), check if any app's current routing differs from the incoming
  device UID. If nobody needs to move, skip the call entirely.

  ---
  Section 4: Should We Mimic Other Programs?

  This is the most interesting question. Let me break it down by project:

  BackgroundMusic / eqMac Approach (Virtual Audio Driver)

  Both use a virtual audio device as the system default, intercepting all audio at the driver level. This
   avoids the tap recreation problem entirely — no taps to recreate because you own the entire audio
  pipeline.

  Should FineTune adopt this? I'd say no for the core architecture, but consider a hybrid:

  - A full virtual driver requires a System Extension, which means notarization headaches, user trust
  dialogs, and Apple could break it with any OS update. FineTune's tap-based approach is lighter and more
   Apple-aligned (taps are the official API).
  - However: A "lightweight virtual device" approach — where FineTune creates a single persistent
  aggregate device that stays the system default, and routes through it — could give you the persistence
  benefits without a driver extension. The aggregate device survives coreaudiod restarts if recreated
  quickly, and you avoid per-app tap recreation entirely because the aggregate is always there.

  AudioCap / AudioTee / Sudara (Tap-Only Aggregate)

  The research notes AudioTee uses the tap as the only input to the aggregate — no real device
  sub-device. FineTune includes the real output device as a sub-device.

  Creative idea — "Tap-Only" Aggregates: If FineTune switched to tap-only aggregates (like AudioTee), the
   aggregate device becomes simpler and potentially more stable during device changes. The tap itself
  references the output device UID, so you don't need the aggregate to also reference it. This might
  reduce the "device graph perturbation" that causes spurious default device change notifications during
  aggregate teardown (Path C in Section 3.1).

  SoundSource (Rogue Amoeba)

  The gold standard. Closed source, so we can only infer. Key observations:

  Creative ideas inspired by SoundSource:

  A — "Persistent Tap Pool": Instead of creating/destroying taps on demand, maintain a pool of
  pre-created taps that can be reassigned to different processes. When a new app starts playing, assign
  an existing idle tap to it rather than creating one from scratch. This eliminates creation latency and
  the permission-grant muting issue entirely — taps already exist, you just redirect them.

  B — "Output Device Proxy": SoundSource handles device changes seamlessly. One approach: instead of
  routing each app's tap to the real output device, route all taps to a single "proxy" aggregate device.
  When the output device changes, only update the proxy's sub-device — no tap recreation needed. The taps
   continue pointing at the proxy, which now forwards to the new device.

  This is arguably the highest-impact architectural change. If taps never need to be recreated for device
   changes, you eliminate Bugs 1 and 2 entirely for the device-change case. The only remaining recreation
   trigger would be coreaudiod restart (unavoidable) and initial permission grant.

  C — "Never Recreate, Just Reconfigure": The deepest version of this idea. What if recreateAllTaps()
  didn't exist at all? Instead:
  - Permission grant: flip the mute behavior on existing taps (if CoreAudio allows changing
  CATapDescription.muteBehavior on a live tap without recreation)
  - Device change: update the aggregate's sub-device list (if CoreAudio allows hot-swapping sub-devices)
  - coreaudiod restart: this is the only case where full recreation is truly necessary

  I don't know if CoreAudio supports live reconfiguration of tap properties and aggregate sub-devices.
  But if it does, this eliminates nearly all recreation events.

  ---
  Priority Ranking (My Take)

  1. Output Device Proxy / single aggregate — highest impact if feasible; eliminates the root cause of
  Bugs 1 and 2 for device changes
  2. Lazy permission transition (Option A from item 3) — easiest fix for Bug 2, zero risk
  3. isRecreatingTaps synchronous flag fix — one-line fix for the remaining Bug 1 race
  4. Snapshot/restore routing — safety net for any notification that slips through suppression
  5. MediaRemote hybrid play/pause — biggest improvement for Bug 3
  6. Hysteresis thresholds — small but noticeable improvement for Bug 3
  7. State machine refactor — best long-term maintainability investment
  8. Tap-only aggregates — worth investigating for reduced device graph perturbation

---

## Implementation Status (2026-02-08)

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | `recreateAllTaps()` race condition — move `isRecreatingTaps = true` before Task | NOT DONE | Flag is still set inside the Task at `AudioEngine.swift:349`. Grace period (`recreationGracePeriod`) provides partial mitigation. |
| 2 | Snapshot/restore routing state | NOT DONE | No `savedRouting` snapshot mechanism. `followsDefault` set provides partial protection by excluding follow-default apps from `routeAllApps`. |
| 3a | Lazy permission transition (Option A) | NOT DONE | `recreateAllTaps()` still runs on permission grant. |
| 3b | Create-before-destroy for permission (Option B) | NOT DONE | Only crossfade device switching uses create-before-destroy (in `ProcessTapController.switchDevice()`). |
| 4 | State machine refactor | NOT DONE | Still uses boolean flags (`isRecreatingTaps`, `permissionConfirmed`) + timestamps. |
| 5 | MediaRemote integration for play/pause | PARTIALLY DONE | `MediaNotificationMonitor` added for Spotify and Apple Music using distributed notifications (NSDistributedNotificationCenter). Not MediaRemote.framework — uses app-specific notification names instead. No hybrid confidence model. |
| 6 | Hysteresis for play/pause thresholds | NOT DONE | Single threshold with single grace period still in use. |
| 7 | `routeAllApps` skip if no routing differs | DONE | `AudioEngine.swift:900` — early exit when all routings already match. |

### Priority Ranking vs. Actual Progress

| Priority | Recommendation | Done? |
|----------|---------------|-------|
| 1 | Output Device Proxy / single aggregate | No |
| 2 | Lazy permission transition | No |
| 3 | `isRecreatingTaps` synchronous flag fix | No (grace period mitigates) |
| 4 | Snapshot/restore routing | No (`followsDefault` partially covers) |
| 5 | MediaRemote hybrid play/pause | Partial (distributed notifications, not MediaRemote.framework) |
| 6 | Hysteresis thresholds | No |
| 7 | State machine refactor | No |
| 8 | Tap-only aggregates | No |

The highest-impact items (Output Device Proxy, lazy permission transition) remain unimplemented. Most actual progress has been on safety-net improvements (recreation guards, `followsDefault`, `shouldConfirmPermission` output peak check) and new features (Session 5 upstream integration).