# Research: Play/Pause Detection Strategies for FineTune

## Current State Analysis

FineTune currently detects play/pause state purely from audio levels:

- **Threshold**: `pausedLevelThreshold = 0.002` — audio level below this is considered silence
- **Grace period**: `pausedSilenceGraceInterval = 0.5s` — must be silent for 0.5s before showing "paused"
- **Recovery timer**: 1s background `updatePauseStates()` timer reads `tap.audioLevel` directly to break the circular dependency where isPaused=true stops VU polling, which prevents recovery
- **Process monitor**: `kAudioProcessPropertyIsRunning` listener on each `AudioObjectID`, plus a 400ms safety poll (`refreshTask`) because this notification doesn't reliably fire for all pause/resume transitions
- **`isPausedDisplayApp`**: Returns true if (a) app is in `lastDisplayedApp` cache with no active apps, or (b) app has a tap and `lastAudibleAtByPID` is older than `pausedSilenceGraceInterval`

### Problems with current approach

1. **0.5s lag** before showing "paused" — user presses pause, waits half a second
2. **False "paused" during silent passages** — classical music, podcasts with pauses, ambient tracks
3. **VU meter dependency** — audio levels are only updated when UI polls them (plus 1s recovery timer)
4. **`kAudioProcessPropertyIsRunning` unreliability** — many apps don't toggle this property on pause/resume; they keep their audio session "running" even when paused

---

## 1. MediaRemote.framework Deep Dive

### Overview

MediaRemote is Apple's private framework (`/System/Library/PrivateFrameworks/MediaRemote.framework`) for communicating with `mediaserverd`. It provides the Now Playing information shown in Control Center, Touch Bar, and the Lock Screen.

### Key Function Signatures

```c
// Query current playback state
void MRMediaRemoteGetNowPlayingApplicationIsPlaying(
    dispatch_queue_t queue,
    void (^completion)(Boolean isPlaying)
);

// Get the PID of the now-playing app
void MRMediaRemoteGetNowPlayingApplicationPID(
    dispatch_queue_t queue,
    void (^completion)(int pid)
);

// Get now playing metadata (title, artist, elapsed time, duration, etc.)
void MRMediaRemoteGetNowPlayingInfo(
    dispatch_queue_t queue,
    void (^completion)(CFDictionaryRef information)
);

// Get the now-playing client reference (short-lived, do not store)
void MRMediaRemoteGetNowPlayingClient(
    dispatch_queue_t queue,
    void (^completion)(id client)
);

// Register/unregister for notifications
void MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_queue_t queue);
void MRMediaRemoteUnregisterForNowPlayingNotifications(void);

// Control commands
Boolean MRMediaRemoteSendCommand(MRMediaRemoteCommand command, id userInfo);
void MRMediaRemoteSetElapsedTime(double elapsedTime);
void MRMediaRemoteSetPlaybackSpeed(int speed);

// Override control
void MRMediaRemoteSetCanBeNowPlayingApplication(Boolean can);
void MRMediaRemoteSetNowPlayingApplicationOverrideEnabled(Boolean enabled);
```

### Available Notifications (via NSNotificationCenter after registering)

| Notification | Fires when |
|---|---|
| `kMRMediaRemoteNowPlayingInfoDidChangeNotification` | Track info changes (title, elapsed time, etc.) |
| `kMRMediaRemoteNowPlayingApplicationDidChangeNotification` | Active now-playing app changes |
| `kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification` | Play/pause state changes |
| `kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification` | Queue changes |
| `kMRMediaRemotePickableRoutesDidChangeNotification` | AirPlay routes change |
| `kMRMediaRemoteRouteStatusDidChangeNotification` | Route status changes |

### Now Playing Info Dictionary Keys

The `MRMediaRemoteGetNowPlayingInfo` completion returns a dictionary with these keys:

- **Track info**: Title, Artist, Album, Composer, Genre, TrackNumber, TotalTrackCount, UniqueIdentifier
- **Timing**: Duration, ElapsedTime, PlaybackRate, StartTime, Timestamp
- **State**: RepeatMode, ShuffleMode
- **Media type**: ArtworkData, ArtworkMIMEType, IsAdvertisement, IsMusicApp, MediaType
- **Queue**: QueueIndex, TotalQueueCount
- **Capabilities**: SupportsFastForward15Seconds, SupportsRewind15Seconds, SupportsIsBanned, SupportsIsLiked, ProhibitsSkip
- **User prefs**: IsBanned, IsInWishList, IsLiked, RadioStationIdentifier, RadioStationHash

### Critical Limitation: Single "Now Playing" App

**MediaRemote only tracks ONE active "now playing" client at a time.** This is a fundamental architectural limitation. When multiple media apps are playing simultaneously (e.g., Spotify + YouTube in Safari), macOS picks one as the "now playing" app based on which most recently started playing or interacted with media keys. The others are invisible to MediaRemote.

This is confirmed by BetterTouchTool community reports: "When multiple apps are playing media, they appear in the NowPlaying menu, however only the first one is taken into consideration for now playing variables, even when the second app is actually playing media while the first one is on pause."

**Implication for FineTune**: MediaRemote can provide instant, accurate play/pause state for the ONE app that macOS considers the "now playing" app — but FineTune manages per-app audio for ALL audio-producing apps. MediaRemote alone cannot replace VU-level detection for non-active apps.

### macOS 15.4+ Entitlement Restriction

Starting with macOS 15.4 (released April 2025), Apple added entitlement verification in `mediaremoted`. Apps without the `com.apple.mediaremote.*` entitlement are denied access to now-playing information. This broke all third-party now-playing widgets.

**Workarounds discovered by the community:**

1. **`mediaremote-adapter` (Perl trick)**: Leverages `/usr/bin/perl`, which has `com.apple.perl5` bundle identifier and is granted MediaRemote access. A helper framework is dynamically loaded by Perl to relay MediaRemote data. Clever but fragile — depends on Apple not removing Perl's entitlement.

2. **`MediaRemoteWizard` (injection)**: Injects code into `mediaremoted` to bypass entitlement checks. Requires SIP disabled. Not viable for a shipping app.

3. **JXA (JavaScript for Automation)**: Uses `osascript -l JavaScript` to access MediaRemote indirectly. No artwork support, has polling delay.

4. **Apple Feedback FB17228659**: Developers have requested a public API with TCC prompt protection. No Apple response as of February 2026.

**Recommendation**: For macOS 15.4+, the Perl adapter approach is the most viable for a shipping app, but it's inherently fragile. FineTune should NOT depend solely on MediaRemote; it should be one signal among several.

### Can Elapsed Time Be Used as a "Playing" Signal?

Yes. If MediaRemote provides `ElapsedTime` and `Timestamp` (the time when the info was last updated), you can compute:

```
expectedElapsed = lastElapsedTime + (now - lastTimestamp)
```

If the actual `ElapsedTime` matches `expectedElapsed`, the app is playing. If it hasn't advanced, it's paused. Combined with `PlaybackRate` (0.0 when paused, 1.0 when playing), this is a strong signal.

**However**, this only works for the active now-playing client — the same limitation as above.

---

## 2. Alternative Detection Approaches

### 2A. NSDistributedNotificationCenter

Some media apps post distributed notifications when playback state changes:

| App | Notification Name | UserInfo Keys |
|---|---|---|
| **Spotify** | `com.spotify.client.PlaybackStateChanged` | Player State, Artist, Name, Album, Duration, Playback Position, Track ID |
| **Apple Music** | `com.apple.Music.playerInfo` | (similar track/state info) |

**Pros:**
- Instant notification (no polling)
- Includes metadata and play/pause state
- Works independently of MediaRemote entitlements

**Cons:**
- **Not universal** — only apps that post notifications (Spotify, Apple Music). Web browsers, VLC, mpv, QuickTime, etc. do not post these.
- **Reliability varies** — reports that `com.apple.Music.playerInfo` stopped firing on macOS Sonoma 14.2+
- **Notification names can change** — iTunes notifications broke when Apple renamed it to Music in Catalina
- **Discovery is hard** — no registry of which apps post what notifications

**Recommendation**: Good supplementary signal for Spotify and Apple Music specifically. Not a general solution.

### 2B. Accessibility API (AXUIElement)

Theoretically, you could read the play/pause button state of an app's UI:

```swift
let app = AXUIElementCreateApplication(pid)
// Traverse: app -> windows -> toolbar -> play/pause button -> value/title
```

**Pros:**
- Works for any app with a visible play/pause button
- No private API dependency

**Cons:**
- **Requires Accessibility permission** — TCC prompt, user must grant
- **Fragile** — button positions, labels, and hierarchy differ per app and per app version
- **Slow** — traversing AX trees is expensive
- **Not all apps have visible buttons** — background audio, headless players
- **Localization** — button labels change by language

**Recommendation**: Not viable. Too fragile and expensive for real-time detection across arbitrary apps.

### 2C. IOKit Power Assertions

Media apps often hold power assertions while playing:

```swift
// List all assertions by process
var assertionsByProcess: Unmanaged<CFDictionary>?
IOPMCopyAssertionsByProcess(&assertionsByProcess)
// Returns: { pid: [{ AssertionType, Name, Level }] }
```

Common assertion types held during media playback:
- `PreventUserIdleDisplaySleep` — video players
- `PreventUserIdleSystemSleep` — audio players
- `NoDisplaySleepAssertion` — fullscreen video

**Checking via command line**: `pmset -g assertions`

**Pros:**
- Public API (IOKit)
- Per-process granularity
- Some apps release assertions immediately on pause (e.g., mpv, VLC)

**Cons:**
- **Not all apps release on pause** — mpv has a known bug where it holds assertions even when paused
- **Not all apps create assertions** — web browsers playing audio often don't
- **Assertion type varies** — different apps use different types
- **Not instant** — requires polling

**Recommendation**: Useful as a supplementary signal, particularly for video players. Not reliable enough as a primary signal due to inconsistent app behavior.

### 2D. `kAudioProcessPropertyIsRunning` Deep Dive

This is what FineTune already uses. The property is set on `AudioObjectID` process objects and indicates whether the audio process has an active I/O proc running.

**When it fires:**
- App starts playing audio (process appears in `kAudioHardwarePropertyProcessObjectList`)
- App stops all audio output (process disappears from list)

**When it does NOT reliably fire:**
- **Pause/resume within the same audio session** — many apps keep their audio session "running" even when paused. The I/O proc continues to fire callbacks with silence rather than stopping. This is the root cause of FineTune's current problems.
- **Apps that use ring buffers** — audio continues to drain from the buffer even after the app "pauses"
- **Apps with background audio** — notification sounds, etc. keep the session alive

**Which apps respect it:**
- Apple Music: Generally transitions between running/not-running on play/pause
- Chrome/Safari: Keep audio sessions running across tab pauses
- Spotify: Tends to keep session running

**Recommendation**: Already in use; the 400ms safety poll covers its unreliability. Not improvable as a standalone signal.

---

## 3. How Other Apps Detect Now Playing

### Hammerspoon (hs.spotify, hs.itunes)

Uses **AppleScript** exclusively:
```lua
-- Detection method
local function tell(cmd)
    local _cmd = 'tell application "Spotify" to ' .. cmd
    local ok, result = as.applescript(_cmd)
    if ok then return result else return nil end
end

-- Playback state returns "kPSP" (playing), "kPSp" (paused), "kPSS" (stopped)
function spotify.getPlaybackState()
    return tell('get player state')
end
```

**Limitation**: Only works for apps with AppleScript dictionaries (Spotify, Music). Spotify has been deprecating AppleScript support — `hs.spotify` is reported broken with recent Spotify versions.

### SketchyBar

Uses `NSDistributedNotificationCenter` for media events:
- Subscribes to `com.spotify.client.PlaybackStateChanged`
- Subscribes to `com.apple.Music.playerInfo`
- Also supports MediaRemote via custom event plugins

Reports from users indicate `com.apple.Music.playerInfo` stopped working on macOS Sonoma 14.2+.

### BetterTouchTool

Uses MediaRemote with `BTTNowPlaying` variables. Acknowledges the single-app limitation: only the most recently active media app is tracked.

### Stats (exelban/stats)

macOS menu bar system monitor. Does not include a now-playing widget — focuses on CPU, memory, disk, network metrics.

---

## 4. Creative Approaches for FineTune

### Strategy A: Hybrid Confidence Model

Combine multiple signals into a weighted confidence score per app:

```
Signal                        | Weight | Latency  | Coverage
------------------------------|--------|----------|----------
VU level (tap.audioLevel)     | 0.4    | ~16ms    | All apps
MediaRemote isPlaying         | 0.3    | ~0ms     | Active NP app only
Distributed notification      | 0.2    | ~0ms     | Spotify, Music only
kAudioProcessPropertyIsRunning| 0.1    | ~0-400ms | Some apps
```

**Decision logic:**

```swift
struct PlaybackConfidence {
    var vuLevel: Float        // 0.0-1.0
    var mediaRemote: Bool?    // nil if not the active NP app
    var distributedNotif: Bool? // nil if no notification received
    var processIsRunning: Bool

    var isPlaying: Bool {
        // If we have MediaRemote data and it says paused, trust it immediately
        if let mr = mediaRemote, !mr { return false }

        // If we have a distributed notification saying paused, trust it
        if let dn = distributedNotif, !dn { return false }

        // If audio level is above threshold, definitely playing
        if vuLevel > 0.002 { return true }

        // If MediaRemote says playing but VU is silent, it's probably
        // a silent passage — trust MediaRemote
        if let mr = mediaRemote, mr { return true }

        // Fall back to VU-based detection with grace period
        return false // will be gated by pausedSilenceGraceInterval
    }
}
```

**Key insight**: MediaRemote and distributed notifications can provide **instant pause detection** (0ms latency) for supported apps, while VU level remains the universal fallback. The confidence model degrades gracefully — unsupported apps get the current behavior, supported apps get instant response.

### Strategy B: MediaRemote for Active App + VU for Others

**Architecture:**

1. On startup, call `MRMediaRemoteRegisterForNowPlayingNotifications()`
2. Listen for `kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification`
3. When fired, extract the PID from `kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey`
4. If that PID matches one of FineTune's managed apps, update its play/pause state instantly
5. For ALL other apps, continue using VU-level detection as today

**Handoff when active app changes:**

When `kMRMediaRemoteNowPlayingApplicationDidChangeNotification` fires:
- New active app: switch to MediaRemote-driven detection
- Previous active app: fall back to VU-level detection
- No disruption needed — VU detection is always running in the background

**Benefits over pure VU:**
- The most recently interacted-with media app gets instant pause/play transitions
- This is usually the app the user cares about most
- Zero cost for other apps — no change to existing behavior

### Strategy C: Elapsed Time Tracking

If MediaRemote provides `ElapsedTime` + `Timestamp` + `PlaybackRate`:

```swift
class ElapsedTimeTracker {
    var lastElapsedTime: Double = 0
    var lastTimestamp: Date = .distantPast
    var lastPlaybackRate: Double = 1.0

    func update(elapsedTime: Double, timestamp: Date, playbackRate: Double) {
        lastElapsedTime = elapsedTime
        lastTimestamp = timestamp
        lastPlaybackRate = playbackRate
    }

    var isAdvancing: Bool {
        guard lastPlaybackRate > 0 else { return false }
        let expectedElapsed = lastElapsedTime + Date().timeIntervalSince(lastTimestamp) * lastPlaybackRate
        // If elapsed time is advancing as expected, the app is playing
        // Allow 2s tolerance for update lag
        return abs(expectedElapsed - lastElapsedTime) < 2.0
    }
}
```

**However**: This only works for the active now-playing client (same MediaRemote limitation). And `PlaybackRate` already tells you directly — 0.0 = paused, 1.0 = playing. So elapsed time tracking is redundant if `PlaybackRate` or `isPlaying` is available.

**Verdict**: Not worth the complexity. `MRMediaRemoteGetNowPlayingApplicationIsPlaying` and the `kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification` notification are simpler and more direct.

### Strategy D: Hysteresis with Asymmetric Thresholds

**Current behavior**: Symmetric — same 0.002 threshold and 0.5s grace for both transitions.

**Proposed asymmetric approach:**

```swift
// Playing -> Paused: Be slow and cautious (avoid false pauses)
let playingToPausedThreshold: Float = 0.001   // Very low threshold
let playingToPausedGrace: TimeInterval = 1.5   // Longer grace period

// Paused -> Playing: Be fast (user wants immediate feedback)
let pausedToPlayingThreshold: Float = 0.005    // Slightly higher to avoid noise
let pausedToPlayingGrace: TimeInterval = 0.0   // Instant recovery
```

**Why this works:**
- When music is playing and hits a silent passage, the 1.5s grace period rides through most gaps between songs or quiet moments
- When the user hits play, audio appears immediately — no waiting
- The higher playing threshold prevents background noise from triggering false "playing" states

**Per-app auto-calibration idea:**

```swift
class AppAudioProfile {
    var recentSilenceGaps: [TimeInterval] = []  // Duration of recent silence gaps
    var averageLevel: Float = 0                  // Running average audio level

    var adaptedGrace: TimeInterval {
        // If this app frequently has short silence gaps (between songs),
        // extend the grace period to cover them
        let typicalGap = recentSilenceGaps.percentile(90) ?? 0.5
        return max(0.5, min(typicalGap * 1.5, 5.0))  // Clamp to 0.5-5s
    }

    var adaptedThreshold: Float {
        // Scale threshold to app's typical audio level
        return max(0.001, averageLevel * 0.01)
    }
}
```

**Recommendation**: The asymmetric approach is simple and effective. Per-app calibration adds complexity — defer unless the simple approach proves insufficient.

### Strategy E: Per-App Audio Fingerprinting

**Concept**: Learn distinctive silence patterns per app to distinguish "paused" from "between tracks."

| Pattern | Example | Characteristic |
|---|---|---|
| Song gap | Spotify between tracks | 0.3-1.0s of silence, then audio resumes |
| True pause | User pressed pause | Indefinite silence |
| Podcast pause | Natural speech gap | 0.5-3s, irregular pattern |
| Video buffering | YouTube loading | Silence followed by audio at same volume |

**Implementation approach:**

```swift
class SilenceAnalyzer {
    var silenceStartTime: Date?
    var preSilenceLevel: Float = 0  // Audio level just before silence began

    func analyze(currentLevel: Float, threshold: Float) -> SilenceType {
        if currentLevel > threshold {
            if let start = silenceStartTime {
                let duration = Date().timeIntervalSince(start)
                recordSilenceGap(duration: duration, preSilenceLevel: preSilenceLevel)
                silenceStartTime = nil
            }
            preSilenceLevel = currentLevel
            return .playing
        }

        if silenceStartTime == nil {
            silenceStartTime = Date()
        }

        let duration = Date().timeIntervalSince(silenceStartTime!)

        // Short gaps are almost certainly between-track gaps, not pauses
        if duration < 0.3 { return .likelyPlaying }

        // Medium gaps could be either — use confidence
        if duration < 2.0 { return .uncertain }

        // Long silence is almost certainly paused
        return .likelyPaused
    }
}
```

**Verdict**: Interesting but over-engineered for the current problem. The asymmetric hysteresis (Strategy D) achieves 80% of the benefit with 10% of the complexity.

### Strategy F: Power Assertion Monitoring

**Concept**: Check if a media app holds IOKit power assertions as a "playing" signal.

```swift
import IOKit

func getAssertionsForProcess(pid: pid_t) -> [String]? {
    var assertionsByProcess: Unmanaged<CFDictionary>?
    let result = IOPMCopyAssertionsByProcess(&assertionsByProcess)
    guard result == kIOReturnSuccess,
          let dict = assertionsByProcess?.takeRetainedValue() as? [String: Any] else {
        return nil
    }
    // dict is keyed by process name, values are arrays of assertion dictionaries
    // Need to match by PID — requires parsing the assertion details
    // Each assertion has: AssertionType, Name, Level, PID, etc.
    return nil // simplified
}
```

**Via command line**: `pmset -g assertions` shows all active assertions with PIDs.

**Testing results (expected behavior):**
- **VLC**: Holds `PreventUserIdleSystemSleep` during playback, releases on pause
- **mpv**: Holds `PreventUserIdleDisplaySleep` during video — but has a known bug where it holds even when paused
- **Chrome**: Generally does NOT hold assertions for tab audio
- **Safari**: May hold assertions for fullscreen video
- **Spotify**: Behavior varies by version

**Verdict**: Useful for video players (VLC, QuickTime), unreliable for audio-only apps and browsers. Could be a supplementary signal in the confidence model but not worth the complexity as a primary approach.

---

## 5. Recommended Implementation Plan

### Phase 1: Asymmetric Hysteresis (Low effort, immediate improvement)

Change `isPausedDisplayApp` logic:
- **Playing -> Paused**: Increase grace to 1.0-1.5s (from 0.5s) to ride through between-track gaps
- **Paused -> Playing**: Make instant (0ms grace) — as soon as audio level exceeds threshold, show playing
- Raises the effective "paused" threshold slightly to reduce false positives from background noise

**Estimated effort**: ~15 minutes. Modify `pausedSilenceGraceInterval` and add asymmetric logic to `isPausedDisplayApp`.

### Phase 2: MediaRemote Integration (Medium effort, major improvement for active app)

1. Add MediaRemote bridge (dynamically load the framework, define function signatures)
2. Register for `kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification`
3. When the notification fires, check if the PID matches a managed app
4. If so, update that app's play/pause state instantly (bypass VU-level detection)
5. For non-active apps, fall back to VU-level detection as today

**Key consideration for macOS 15.4+**: Use the Perl adapter approach or accept that MediaRemote may not work on latest macOS without workarounds. Design the system so MediaRemote is an optional enhancement, not a requirement.

**Estimated effort**: 2-4 hours for initial integration. Additional time for macOS 15.4+ workaround if needed.

### Phase 3: Distributed Notification Listeners (Low effort, targeted improvement)

Add listeners for known app-specific notifications:
- `com.spotify.client.PlaybackStateChanged` — extract "Player State" from userInfo
- `com.apple.Music.playerInfo` — extract playback state

These provide instant, reliable play/pause detection for the two most popular music apps without any private API dependency.

**Estimated effort**: ~30 minutes.

### Phase 4 (Optional): Hybrid Confidence Model

If Phases 1-3 don't provide sufficient coverage, implement the full weighted confidence model from Strategy A. This would combine:
- VU level (universal, 16ms latency)
- MediaRemote (active NP app, 0ms latency)
- Distributed notifications (Spotify/Music, 0ms latency)
- `kAudioProcessPropertyIsRunning` (some apps, 0-400ms latency)

**Estimated effort**: 2-4 hours.

---

## 6. Summary Table

| Approach | Latency | Coverage | Reliability | macOS 15.4+ | Effort |
|---|---|---|---|---|---|
| VU level (current) | ~500ms | All apps | Medium (false pauses) | Works | In place |
| Asymmetric hysteresis | ~1.5s pause / 0ms play | All apps | Good | Works | 15 min |
| MediaRemote | 0ms | Active NP app only | High | Requires workaround | 2-4 hr |
| Distributed notifications | 0ms | Spotify, Music | High (when it works) | Works | 30 min |
| `kAudioProcessPropertyIsRunning` | 0-400ms | Some apps | Low | Works | In place |
| Accessibility API | N/A | Apps with buttons | Very low | Works | Not recommended |
| Power assertions | Polling | Video players | Medium | Works | Not recommended |
| AppleScript | Polling | Spotify, Music | Declining | Works | Not recommended |

### Recommended priority order:
1. **Asymmetric hysteresis** — immediate, universal improvement
2. **Distributed notifications** — instant Spotify/Music improvement, no private API
3. **MediaRemote integration** — best possible UX for the active app, but private API dependency
4. **Confidence model** — only if needed after 1-3

---

## Implementation Status (as of 2026-02-08)

| Phase | Recommendation | Status | Notes |
|-------|---------------|--------|-------|
| 1 | Asymmetric hysteresis (1.5s pause / 0ms play) | NOT IMPLEMENTED | Simple change, still open. Current grace is 0.5s symmetric. |
| 2 | Distributed notifications (Spotify + Apple Music) | IMPLEMENTED | `MediaNotificationMonitor` added 2026-02-07. Table-driven: monitors `com.spotify.client.PlaybackStateChanged` and `com.apple.Music.playerInfo`. See CHANGELOG "Media Notification Generalization". |
| 3 | MediaRemote integration | NOT IMPLEMENTED | Deferred due to private API risk + macOS 15.4+ entitlement restrictions. |
| 4 | Hybrid confidence model | NOT IMPLEMENTED | Not needed yet — Phase 2 addresses the two most common media apps. |

**Additional implementation note:** A 1s `updatePauseStates()` recovery timer was added to AudioEngine to break the circular VU polling dependency (Bug 3 from Session 1). This wasn't in this research doc's recommendations but addresses the same problem from a different angle.
