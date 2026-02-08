# Changelog

## [Unreleased] - 2026-02-08

### Multi-Device Audio Routing + Permission UX Fix

Implemented full multi-device audio routing (per-app audio to multiple output devices simultaneously via stacked aggregate devices), re-enabled DevicePicker on macOS 26, and added proactive permission checking to prevent disruptive system dialogs.
Full details: `docs/ai-chat-history/2026-02-08-multi-device-routing-and-permission-ux.md`

#### Added
- **Multi-device aggregate support in `ProcessTapController`** — `targetDeviceUIDs: [String]` replaces single device UID. First device is clock source, subsequent devices get drift compensation. `buildAggregateDescription()` helper replaces 3 inline aggregate dictionary copies. `updateDevices(to:)` method for live device set changes.
- **Mode-aware routing in `AudioEngine`** — `setDeviceSelectionMode()`, `setSelectedDeviceUIDs()`, `getDeviceSelectionMode()`, `getSelectedDeviceUIDs()`, `updateTapForCurrentMode()`. Multi-device disconnect removes one device from set (remaining keep playing). Reconnect adds device back if in persisted selection.
- **DevicePicker Single/Multi mode toggle** — segmented control at top of dropdown. Multi mode: checkboxes, dropdown stays open, "N devices" trigger text, can't deselect last device. Single mode: standard checkmark select, closes on tap.
- **Proactive audio permission check** — `CGPreflightScreenCaptureAccess()` called before `AudioEngine` creation. If permission missing (and onboarding completed), shows `NSAlert` with "Open System Settings" button linking to Privacy & Security → Screen & System Audio Recording. Prevents CoreAudio from triggering the disruptive system permission dialog mid-interaction.
- **Menu bar debug logging** — `[MENUBAR]` tagged logs in `MenuBarStatusController`: status item creation, icon application, button/window state, 3-second delayed health check for post-layout verification.

#### Changed
- **DevicePicker re-enabled on macOS 26** — removed `#available(macOS 26, *)` guards from `AppRow` and `InactiveAppRow` that disabled the device picker. The aggregate-based routing approach works fine on macOS 26 (guard was from an earlier device-specific `CATapDescription` constructor approach).
- **`DropdownTriggerButton`** access changed from `private` to `internal` in `DropdownMenu.swift` so `DevicePicker` can reuse it.
- **`AppRow` and `InactiveAppRow`** — 4 new properties each: `deviceSelectionMode`, `selectedDeviceUIDs`, `onModeChange`, `onDevicesSelected` (all with defaults for backward compatibility).
- **`MenuBarPopupView`** — wired up mode change and multi-device selection callbacks for both active and inactive app rows.
- **`FineTuneApp.swift`** — permission check runs before engine creation; `ScreenCaptureKit` import added.

#### Fixed
- **DevicePicker type error** — `DeviceIcon` (nonexistent type) replaced with `NSImage?` in `triggerIcon` computed property.
- **System permission dialog appearing mid-interaction** — now caught by proactive `CGPreflightScreenCaptureAccess()` check before engine starts, with user-friendly alert directing to System Settings.

#### Known Issues
- **Multi-device routing is compile-verified + Xcode build verified** — not yet runtime-tested with actual multi-device playback
- **Codesign error with stale `PlugIns/FineTuneTests.xctest`** — intermittent; clean build (`Cmd+Shift+K`) resolves it
- **`CGPreflightScreenCaptureAccess()` behavior on macOS 26** — passive check confirmed not to trigger system dialog, but needs broader testing
- **Test C (bundle-ID experiment)** — `tapDesc.bundleIDs = [bundleID]` without `isProcessRestoreEnabled` has not been tested yet. Orthogonal to multi-device routing.
- **Pre-existing test failures** — 19 tests fail with "0 unexpected" (CrossfadeState duration values: tests expect 50ms, code uses 200ms). Unrelated to multi-device changes.

### Safety & Reliability Fixes

Six safety and reliability fixes addressing hearing safety, resource lifecycle, startup ordering, and data integrity.
Full details: `docs/ai-chat-history/2026-02-08-safety-and-reliability-fixes.md`

#### Added
- **Post-EQ soft limiter** (hearing safety) — `SoftLimiter.processBuffer()` now runs after every `eqProcessor.process()` call across all three audio paths (primary tap, secondary tap, format converter). Prevents EQ bands at +12 dB from boosting output above 1.0. Signal chain is now: Gain -> SoftLimiter -> EQ -> SoftLimiter -> Output.
- **PostEQLimiterTests.swift** — 3 tests: boosted signal clamping, below-threshold passthrough, interleaved stereo mixed amplitudes
- **Thread-safe CrashGuard** — `os_unfair_lock` protects `trackDevice()`/`untrackDevice()` against data race between MainActor and `DispatchQueue.global(qos: .utility)` callers. Signal handler intentionally does not take the lock (standard signal-safe pattern).

#### Fixed
- **Post-EQ clipping (hearing safety):** EQ boost could push limited signal well above 1.0. Post-EQ `SoftLimiter.processBuffer()` now guarantees output <= 1.0 for any finite input.
- **Leaked polling tasks on AudioEngine.stop():** Diagnostic health check (3s) and pause-recovery (1s) polling loops, plus `pendingCleanup` grace-period tasks and `serviceRestartTask`, were fire-and-forget. Now stored as task handles and cancelled in `stop()`.
- **Second instance nukes first instance's audio:** `OrphanedTapCleanup.destroyOrphanedDevices()` ran before `SingleInstanceGuard` check, destroying the running instance's live aggregate devices. Reordered so single-instance check runs first; duplicate instance terminates immediately without creating any resources.
- **NaN in EQ settings maps to max boost:** Corrupted settings with NaN band gains were mapped to +12 dB (max) due to IEEE 754 `min`/`max` behavior. Now maps NaN and Infinity to 0 dB (flat).
- **CrashGuard data race:** `trackDevice()` (MainActor) and `untrackDevice()` (utility queue) had unsynchronized access to `gDeviceCount` and slot array. Now protected by `os_unfair_lock`.

#### Known Issues
- **PostEQLimiterTests not runnable via `swift test`** — compiles but can't execute due to pre-existing Sparkle dependency issue. Verified via standalone compilation.

### Settings Panel Restoration + System Sounds Device Port

Restored the missing Settings gear button and settings panel to the menu bar popup, and ported full system sounds device tracking from the original developer's codebase.
Full details: `docs/ai-chat-history/2026-02-08-settings-panel-and-system-sounds-device-port.md`

#### Added
- **Settings gear button** in menu bar popup header — morphs to X when settings are open, with spring rotation animation
- **Settings panel** slides in from the right with spring transition when gear is tapped; main content slides out to the left
- **`Cmd+,` keyboard shortcut** to toggle settings panel from within the popup
- **`UpdateManager` instantiation** — Sparkle update manager now created in `MenuBarPopupViewModel` and wired to `SettingsUpdateRow`
- **Live menu bar icon switching** — changing the icon style in Settings immediately updates the status bar icon (via `onIconChanged` callback from ViewModel through `MenuBarStatusController`)
- **System sounds device tracking** in `DeviceVolumeMonitor`:
  - `systemDeviceID`, `systemDeviceUID`, `isSystemFollowingDefault` state properties
  - CoreAudio listener for `kAudioHardwarePropertyDefaultSystemOutputDevice` with debouncing
  - `setSystemFollowDefault()` and `setSystemDeviceExplicit(_:)` public control methods
  - Automatic sync: when "follow default" is enabled, system sounds device updates whenever default output device changes
  - External change detection: if system sounds device is changed outside FineTune (e.g., System Settings), "follow default" state is properly broken and persisted
  - Startup validation: enforces persisted "follow default" preference if actual state drifted
  - coreaudiod restart recovery: system device state re-read on daemon restart

#### Changed
- **`MenuBarPopupViewModel`** — now owns settings panel state (`isSettingsOpen`, `localAppSettings`), `UpdateManager`, icon change callback, and `toggleSettings()`/`syncSettings()` methods
- **`MenuBarPopupView`** — body restructured with conditional settings/main content rendering and slide transitions
- **`MenuBarStatusController`** — stores `popupViewModel` reference, wires `onIconChanged` to `updateIcon(to:)`
- **`DeviceVolumeMonitor.init()`** — now loads persisted system sounds preference and reads initial system device
- **`DeviceVolumeMonitor.start()`** — registers system device listener, validates system sound state on startup
- **`DeviceVolumeMonitor.stop()`** — cleans up system device listener and state
- **`DeviceVolumeMonitor.applyDefaultDeviceChange()`** — syncs system sounds when following default
- **`DeviceVolumeMonitor.handleServiceRestarted()`** — refreshes system device on coreaudiod recovery

#### Fixed
- **Settings panel not accessible (from 2026-02-07 known issues)** — settings gear button and panel navigation now work in the fork's `MenuBarPopupView`
- **Sound Effects device row non-functional** — previously wired with placeholder values (`nil`/`true`/no-ops); now connected to real `DeviceVolumeMonitor` system device properties

#### Known Issues
- **All changes are compile-verified only** — settings panel and system sounds device tracking have not been runtime-tested
- **`SystemSoundsDeviceChanges.swift` is dead code** — 200-line documentation stub should be deleted now that integration is complete
- **Settings panel doesn't auto-close on popup dismiss** — `isSettingsOpen` persists across popup show/hide cycles

### Crash-Safe Cleanup for Orphaned CoreAudio Resources

Ensures orphaned FineTune process taps are always cleaned up, even after crashes or `kill -9`.
Full details: `docs/ai-chat-history/2026-02-08-crash-safe-cleanup-orphaned-coreaudio-resources.md`

#### Added
- **`OrphanedTapCleanup.swift`** — Static utility that scans CoreAudio for aggregate devices named `"FineTune-*"` and destroys them. Runs on startup before any new taps are created, cleaning up orphans left by crashes or `kill -9`.
- **`CrashGuard.swift`** — Tracks live aggregate device IDs in a fixed-size C buffer and installs crash signal handlers (SIGABRT, SIGSEGV, SIGBUS, SIGTRAP) that destroy them before the process terminates. Uses async-signal-safe memory and IPC to coreaudiod. Prevents orphaned taps on actual crashes.
- **POSIX signal handlers** — `DispatchSource` handlers for SIGTERM and SIGINT in `AppDelegate` that call `audioEngine?.stopSync()` before `exit(0)`. Catches `kill <pid>` and Ctrl+C for clean shutdown.

#### Changed
- **`AppDelegate.applicationDidFinishLaunching`** — Now calls `OrphanedTapCleanup.destroyOrphanedDevices()` and `CrashGuard.install()` before creating `AudioEngine`, and `installSignalHandlers()` after engine creation.
- **`ProcessTapController`** — All 3 aggregate device creation sites now call `CrashGuard.trackDevice()`. All 5 inline destruction sites call `CrashGuard.untrackDevice()` before `AudioHardwareDestroyAggregateDevice`.
- **`TapResources.destroy()` / `destroyAsync()`** — Now call `CrashGuard.untrackDevice()` before destroying aggregate devices.

## [Unreleased] - 2026-02-07

### Sparkle Update Toggle + CATapDescription Constructor Fix

Added Sparkle auto-update settings UI and fixed the critical root cause of per-app volume control not working — the fork was using the wrong `CATapDescription` constructor.
Full details: `docs/ai-chat-history/2026-02-07-sparkle-update-toggle-and-tap-constructor-fix.md`

#### Added
- **`UpdateManager.swift`** — Sparkle `SPUStandardUpdaterController` wrapper with `checkForUpdates()`, `automaticallyChecksForUpdates`, and `lastUpdateCheckDate`
- **`SettingsUpdateRow.swift`** — Combined settings row with "Check for updates automatically" toggle + "Check for Updates" button, version display, and relative last-check date
- **Sparkle SPM dependency** — added to FineTune target

#### Fixed
- **Per-app volume not working (CRITICAL):** Replaced `CATapDescription(__processes:andDeviceUID:withStream:)` with `CATapDescription(stereoMixdownOfProcesses:)` across all three code paths (`activate()`, `createSecondaryTap`, `performDeviceSwitch`). The device-specific constructor caused CoreAudio to disconnect the reporter, resulting in zero input data despite callbacks firing. Stereo mixdown captures all audio from the process regardless of device.
- **Aggregate device configuration:** All three code paths now use `kAudioAggregateDeviceIsStackedKey: true` and `kAudioAggregateDeviceClockDeviceKey: outputUID` (matching the original dev's working implementation). Previously `isStacked` was `false` and `ClockDeviceKey` was missing.
- **Sample rate reads:** All paths now read sample rate from aggregate device after creation instead of from `resolveOutputStreamInfo` (which is no longer needed).

#### Changed
- **`ensureTapExists` in AudioEngine** — removed permission checking flow; taps now always use `.mutedWhenTapped` (matching original dev). `permissionConfirmed`, `upgradeTapsToMutedWhenTapped()`, `shouldConfirmPermission()` are now dead code.
- **`makeTapDescription()`** — changed from `makeTapDescription(for:streamIndex:)` (2 args) to `makeTapDescription()` (0 args); uses stereo mixdown instead of device-specific stream

#### Removed
- **`resolveOutputStreamInfo(for:)` wrapper** in ProcessTapController — no longer called from any code path after stereo mixdown change

#### Known Issues
- **Per-app volume fix is compile-verified only** — stereo mixdown constructor builds successfully but has not been runtime-tested yet
- **`SettingsView` not accessible in fork UI** — no settings gear button or panel navigation exists in the fork's `MenuBarPopupView`
- **Dead code in `AudioEngine.swift`** — `permissionConfirmed`, `upgradeTapsToMutedWhenTapped()`, `shouldConfirmPermission()` are unreachable but not yet removed

### Media Notification Generalization + Output Path Diagnostics

Generalized instant play/pause detection from Spotify-only to multi-app, and diagnosed/worked around a silent output path in macOS 26 bundle-ID taps.
Full details: `docs/ai-chat-history/2026-02-07-media-notification-generalization-and-output-path-debugging.md`
Known issue: `docs/known_issues/bundle-id-tap-silent-output-macos26.md`

#### Added
- **Table-driven `MediaNotificationMonitor`** — now monitors both Spotify (`com.spotify.client.PlaybackStateChanged`) and Apple Music (`com.apple.Music.playerInfo`) for instant play/pause detection via `DistributedNotificationCenter`
- **Output buffer metadata diagnostics** — new `outBuf=NxMB` field in DIAG logs showing IOProc output buffer count and byte size, for diagnosing dead-output-path issues
- **`FineTuneForcePIDOnlyTaps` defaults key** — A/B test toggle to bypass macOS 26 bundle-ID tap creation. Diagnostic-only, not a valid workaround (PID-only can't capture Brave audio on macOS 26).

#### Fixed
- **`outPeak` diagnostic now retain-non-zero** — previously used last-write-wins semantics, causing `outPeak=0.000` whenever the most recent callback had empty input. Now matches `inPeak` behavior (only updated when peak > 0), making the diagnostic actually useful.

#### Known Issues
- **Bundle-ID tap aggregate output dead on macOS 26** — bundle-ID taps (required for capture on macOS 26) create aggregate devices where the output path doesn't reach the physical device. PID-only taps have working output but can't capture audio. Neither mode fully works. Root cause under investigation. See `docs/known_issues/bundle-id-tap-silent-output-macos26.md`.
- **`shouldConfirmPermission` can false-positive** — `outputWritten > 0` doesn't confirm real audio output, can promote to `.mutedWhenTapped` and expose the dead output path

### Audio Wiring Overhaul (agent team review + 5-phase implementation)

Comprehensive review of audio switching/crossfade wiring by 4-agent team (best practices researcher, code reviewer, mediator, skeptical planner), followed by parallel implementation. 17 issues identified, 7 fixed. 269 tests, 0 failures.
Full details: `docs/ai-chat-history/2026-02-07-audio-wiring-agent-team-review-and-implementation.md`
Implementation plan: `docs/audio-wiring-plan.md`

#### Fixed
- **Bluetooth silence gap on device switch (CRITICAL):** Switching from speakers to AirPods no longer causes a ~200-400ms silence gap. Root cause: the 50ms crossfade completed (silencing speakers) before Bluetooth produced audible sound. Fix: introduced `CrossfadePhase` state machine (`.idle` -> `.warmingUp` -> `.crossfading`) where primary stays at full volume during warmup, and crossfade only begins after secondary device is confirmed producing audio. 7 new unit tests.
- **Diagnostic counter data races during crossfade (HIGH):** Both primary and secondary IO callbacks were incrementing shared `_diagCallbackCount` and 15 other counters simultaneously (multi-writer read-modify-write, not atomic). Split into per-tap counter sets with merge-on-promotion and reset-on-cleanup.
- **VU meter jitter during crossfade (HIGH):** Both callbacks were doing read-modify-write exponential smoothing on shared `_peakLevel`. Added separate `_secondaryPeakLevel` with merge-on-promotion. `audioLevel` getter returns `max()` of both during crossfade for smooth transitions.
- **Volume jump on device switch (HIGH):** Re-enabled device volume compensation with fresh `sourceVolume / destVolume` ratio at each switch (clamped [0.1, 4.0]). Previous implementation was disabled due to cumulative attenuation bug caused by not resetting ratio. Applied to both crossfade and destructive switch paths.
- **AirPlay not given extended warmup (MEDIUM):** AirPlay devices now receive the same 500ms extended warmup as Bluetooth. Renamed `isBluetoothDestination` to `needsExtendedWarmup` throughout.
- **`destroyAsync` race window in `recreateAllTaps` (MEDIUM):** Old taps were destroyed asynchronously while new taps were created immediately, risking duplicate taps for the same process. Added `destroyAsync(completion:)` handler, `invalidateAsync()` with `withCheckedContinuation`, and `recreateAllTaps` now awaits all destructions via `withTaskGroup` before recreating.
- **Duplicate `appliedPIDs.insert` (LOW):** Removed redundant insert in `AudioEngine.applyPersistedSettings` (L613). The unconditional insert at L605 already covers both success and failure paths.

#### Changed
- `CrossfadePhase` enum reduced from 4 cases to 3 (`completing` removed as unnecessary)
- `CrossfadeState.isActive` is now a computed property (true when `.warmingUp` or `.crossfading`) — backward compatible
- `performCrossfadeSwitch` restructured into two explicit phases: warmup (poll `isWarmupComplete`) then crossfade (poll `isCrossfadeComplete`)
- `TapResources.destroyAsync()` now accepts optional completion handler (backward compatible)

#### Added
- `ProcessTapController.invalidateAsync()` — async version of `invalidate()` that awaits CoreAudio resource destruction
- `CrossfadeState.beginCrossfading()` — transitions from `.warmingUp` to `.crossfading`, resets progress
- 16 secondary diagnostic counter fields (`_diagSecondary*`) for race-free crossfade diagnostics
- `_secondaryPeakLevel` for race-free VU metering during crossfade
- `resetSecondaryDiagnostics()` helper for counter cleanup

### Documentation
- **Architecture diagram comprehensive rewrite:** `docs/architecture/finetune-architecture.md` updated from 88-line single Mermaid flowchart to 332-line document with expanded diagram (12 subgraphs, ~50 nodes), data flow summary, 9 architectural pattern descriptions, and complete file layout. Reflects all changes from the 4-phase refactoring, FluidMenuBarExtra removal, ViewModel extraction, DesignTokens, and new component extractions.
  - Full details: `docs/ai-chat-history/2026-02-07-architecture-diagram-comprehensive-update.md`

### Refactoring (4-phase codebase restructuring)

Comprehensive internal refactoring for readability, DRY, complexity reduction, and architecture.
All public APIs preserved. 1,041 lines added, 951 lines removed across 37 files. 42 new tests.
Full details: `docs/ai-chat-history/2026-02-07-comprehensive-codebase-refactoring.md`

#### Phase 0 — Testability & Seam Setup
- Audited and documented all existing test injection points
- Added injectable timing properties on AudioEngine (diagnosticPollInterval, startupTapDelay, staleTapGracePeriod, serviceRestartDelay, fastHealthCheckIntervals)
- Added deterministic queue injection for ProcessTapController and DeviceVolumeMonitor
- Added 20 AppRow interaction tests (volume, mute, auto-unmute, device selection)

#### Phase 1 — Cleanup & Dead Code Removal
- Removed orphaned `FineTuneTests/` test files (720 lines — duplicates of `testing/tests/` with wrong imports)
- Removed deprecated `AppVolumeRowView.swift` and `DeviceVolumeRowView.swift` (189 lines, zero references)
- Added `.lancedb/` to `.gitignore`
- Centralized magic numbers into `DesignTokens.swift` (scroll thresholds, animation constants, VU meter interval, default unmute volume)

#### Phase 2 — DRY Extractions (serial, 8 steps)
- **SliderAutoUnmute.swift** — ViewModifier replacing duplicated auto-unmute patterns in AppRow/DeviceRow
- **DropdownMenu consolidation** — extracted shared trigger button, merged two near-identical variants (-110 lines)
- **DeviceIconView.swift** — shared NSImage/SF Symbol icon component replacing 3 duplicated renderers
- **AudioObjectID+Listener.swift** — CoreAudio listener add/remove factory used by 3 monitors
- **DevicePropertyKind enum** — consolidated 6 volume/mute listener methods to 3 in DeviceVolumeMonitor (-80 lines)
- **resolveDeviceID(for:)** — cache-then-fallback device lookup on AudioDeviceMonitor, replaces inline pattern in ProcessTapController and AudioDeviceID+Resolution
- **Volume read strategy loop** — replaced 3 near-identical read blocks in AudioDeviceID+Volume (-25 lines)
- **Shared test helpers** — AudioBufferTestHelpers.swift and IntegrationTestHelpers.swift, removed duplicates from 6 test files

#### Phase 3 — God-Class Breakup
- **ProcessTapController** (1414→1380 lines): 15 characterization tests, 10 MARK sections, extracted TapDiagnostics to standalone struct
- **AudioEngine** (838→870 lines): 7 characterization tests, 12 MARK sections, consolidated test helpers
- **AppRow** (437→415 lines): MARK grouping, extracted AppRowEQToggle sub-view

#### Phase 4 — ViewModel Extraction
- **MenuBarPopupViewModel.swift** — EQ expansion state, animation debounce, popup visibility, device sorting, app activation logic moved from MenuBarPopupView to dedicated ViewModel

### Added (new files)
- `FineTune/Views/Components/SliderAutoUnmute.swift`
- `FineTune/Views/Components/DeviceIconView.swift`
- `FineTune/Audio/Extensions/AudioObjectID+Listener.swift`
- `FineTune/Audio/Tap/TapDiagnostics.swift`
- `FineTune/Views/Rows/AppRowEQToggle.swift`
- `FineTune/Views/MenuBarPopupViewModel.swift`
- `FineTune/Views/DesignSystem/DesignTokens.swift`
- `testing/tests/AudioBufferTestHelpers.swift`
- `testing/tests/IntegrationTestHelpers.swift`
- `testing/tests/ProcessTapControllerTests.swift` (15 tests)
- `testing/tests/AudioEngineCharacterizationTests.swift` (7 tests)
- `testing/tests/AppRowInteractionTests.swift` (20 tests)

### Removed (deleted files)
- `FineTuneTests/StartupAudioInterruptionTests.swift` (orphaned, 585 lines)
- `FineTuneTests/SingleInstanceGuardTests.swift` (orphaned, 135 lines)
- `FineTune/Views/AppVolumeRowView.swift` (deprecated, 82 lines)
- `FineTune/Views/DeviceVolumeRowView.swift` (deprecated, 107 lines)

### Fixed
- **False-positive permission confirmation causing post-Allow mute risk:** `AudioEngine` permission confirmation now requires real input evidence (`inputHasData > 0` or `lastInputPeak > 0.0001`) in addition to callback/output activity. Prevents premature tap recreation with `.mutedWhenTapped` while input is still silent.
- **Menu bar panel sizing recursion trigger:** Removed forced `layoutSubtreeIfNeeded` path from `MenuBarStatusController` panel sizing logic and switched to `fittingSize` fallback sizing only.
- **SingleInstanceGuard actor-isolation warnings in Xcode debug flow:** Guard helper methods are now explicitly `nonisolated`, eliminating main-actor isolation warning calls from this utility path.
- **Additional Swift 6 actor/concurrency warnings in audio wrappers and monitors:** `AudioScope`/`TransportType` utilities, device volume/mute CoreAudio wrappers, and monitor callsites now use explicit nonisolated-safe access patterns. Also fixed captured mutable vars in async contexts (`DeviceVolumeMonitor`) via immutable snapshots before `MainActor.run`.
- **`AudioDeviceMonitor` cache warning noise with `@Observable`:** marked cache dictionaries as `@ObservationIgnored` while retaining explicit cross-actor lookup strategy.

### Added
- **Permission confirmation test coverage (fail-first then pass):**
  - `AudioEngineRoutingTests.testPermissionConfirmationRequiresRealInputAudio`
  - `AudioEngineRoutingTests.testPermissionConfirmationSucceedsWithInputAudio`
- **Resolved-issue and handoff docs for this incident:**
  - `docs/known_issues/resolved/xcode-permission-pause-menubar-audio-mute-2026-02-07.md`
  - `docs/ai-chat-history/2026-02-07-xcode-permission-pause-menubar-trace-and-audio-mute-fix.md`

### Changed
- **Concurrency annotation cleanup for CoreAudio utility types:** `AudioScope.propertyScope`, `TransportType.init(rawValue:)`, and `TransportType.defaultIconSymbol` now compile cleanly under default MainActor isolation when called from nonisolated codepaths.
- **Replaced FluidMenuBarExtra with native AppKit status item:** FluidMenuBarExtra v1.5.1 relied on `NSEvent.addLocalMonitorForEvents` to detect clicks on the status bar button, which is broken on macOS 26. Replaced with direct `NSStatusItem` + `button.action`/`target` pattern using `NSApplicationDelegateAdaptor` for reliable AppKit lifecycle initialization.
  - New `MenuBarStatusController` class (`FineTune/Views/MenuBar/MenuBarStatusController.swift`) — owns `NSStatusItem`, `KeyablePanel`, and popup lifecycle
  - New `AppDelegate` in `FineTuneApp.swift` — uses `@NSApplicationDelegateAdaptor` to set up AudioEngine and menu bar in `applicationDidFinishLaunching`
  - `KeyablePanel` subclass overrides `canBecomeKey` (required for `.nonactivatingPanel` style to properly receive key/resign events)
  - Left-click shows/hides popup panel; right-click (or Ctrl+click) shows context menu with "Quit FineTune"
  - Panel auto-dismisses on outside click (via global event monitor) and on `windowDidResignKey`
  - Removed FluidMenuBarExtra package dependency from `project.pbxproj` and `Package.resolved`

### Added
- **SPM integration test infrastructure:** All 59 integration tests now run via `swift test` alongside 161 pure-logic tests (220 total, ~1.1s wall time, zero app instances)
  - `FineTuneIntegration` library target — compiles all non-UI, non-@main source files with FineTuneCore dependency
  - `FineTuneIntegrationTests` test target — AudioEngineRouting, AudioSwitching, DefaultDeviceBehavior, StartupAudioInterruption, SingleInstanceGuard tests
  - Integration tests restored from `_local/archive/` to `testing/tests/` with updated module imports
- **Public API for FineTuneCore types:** EQSettings, CrossfadeState, CrossfadeConfig, CrossfadePhase, VolumeRamper, VolumeMapping, BiquadMath, AudioBufferProcessor, GainProcessor, SoftLimiter, EQPreset — all made `public` for cross-module use
- **coreaudiod restart handler:** `AudioEngine` now handles `kAudioHardwarePropertyServiceRestarted` — destroys all stale taps, waits 1.5s for daemon to stabilize, recreates all taps via `applyPersistedSettings()`
- **`onServiceRestarted` callback on `AudioDeviceMonitor`** — fires after coreaudiod restart and device list refresh, allows consumers to react to daemon restarts
- **Per-session permission confirmation:** Taps start with `.unmuted` on each launch, auto-upgrade to `.mutedWhenTapped` within ~300ms once audio flow is confirmed. Prevents audio loss if app is killed during first-time permission grant
- **`muteOriginal` parameter on `ProcessTapController`** — controls whether taps use `.mutedWhenTapped` (normal operation) or `.unmuted` (safe for pre-permission launches)
- **Enhanced tap health check:** Now detects both stalled taps (callbacks stopped) and broken taps (callbacks running but reporter disconnected — empty input, no output). Uses `TapHealthSnapshot` struct for delta analysis across check cycles
- **`recreateAllTaps()` in `AudioEngine`** — destroys and recreates all taps (used for `.unmuted` → `.mutedWhenTapped` upgrade after permission confirmation)
- **Empty input diagnostic counter:** `_diagEmptyInput` tracks callbacks with zero-length or nil input buffers, exposed in `TapDiagnostics.emptyInput`

### Changed
- Platform minimum bumped from macOS 14.0 to macOS 14.2 (required for AudioHardwareCreateProcessTap/DestroyProcessTap APIs)
- `AudioDeviceMonitor.devicesByUID`/`devicesByID` marked `nonisolated(unsafe)` with `nonisolated` lookup methods for safe cross-actor reads from ProcessTapController
- `AudioEngine.appDeviceRouting` access changed from `private(set)` to internal setter for `@testable import` compatibility
- FineTuneIntegration target uses `.swiftLanguageMode(.v5)` to accommodate existing concurrency patterns
- **CoreAudio reads moved off main thread:** `AudioDeviceMonitor.handleServiceRestartedAsync()` and `handleDeviceListChangedAsync()` now run `readDeviceDataFromCoreAudio()` via `Task.detached`. Previously ran on MainActor due to class annotation, causing UI freeze during coreaudiod restart
- Health check interval reduced from 5s to 3s for faster broken-tap detection
- Fast health check intervals changed from 1s/2s/3s to 300ms/500ms/700ms for faster permission confirmation
- `setDevice()` guard relaxed to allow re-routing when tap is missing (enables retry after failed activation)
- `onAppsChanged` callback wired AFTER initial `applyPersistedSettings()` to prevent startup delay bypass
- 2-second startup delay before initial tap creation to let apps initialize audio sessions

### Fixed
- **Audio mute on permission grant (critical):** Clicking "Allow" on the system audio recording permission dialog no longer causes permanent audio loss. Three interacting root causes fixed: (1) taps now use `.unmuted` before permission confirmation so app death doesn't mute audio, (2) `readDeviceDataFromCoreAudio()` runs off MainActor so coreaudiod restart doesn't freeze the UI, (3) `AudioEngine` handles coreaudiod restart by destroying and recreating all taps. See `docs/known_issues/resolved/audio-mute-on-permission-grant.md`.
- **AirPods/Bluetooth silence:** Aggregate device sample rate now uses output device rate instead of tap rate. Process taps may report the app's internal rate (e.g., Chromium 24kHz) which Bluetooth devices don't support (e.g., AirPods require 48kHz). CoreAudio's drift compensation handles resampling. Fixed in `activate()` and `createSecondaryTap()`.
- **Virtual device silent routing:** FineTune no longer follows macOS default device changes to virtual audio drivers (e.g., SRAudioDriver, BlackHole). Three entry points patched:
  - `DeviceVolumeMonitor.handleDefaultDeviceChanged()` — ignores virtual device as new default
  - `AudioEngine.applyPersistedSettings()` — validates default UID against non-virtual device list, falls back to first real device
  - `MenuBarPopupView` UI fallback — uses first real device instead of potentially-virtual default
- **Mute state not applied on new tap creation:** `ensureTapExists()` now sets `tap.isMuted` from persisted state
- **Destructive switch fade-in race:** Removed manual volume loop that raced with user changes; uses built-in exponential ramper
- **Non-float doubled audio during crossfade:** Non-float output now silenced when `crossfadeMultiplier < 1.0`
- **Secondary callback missing force-silence check:** `processAudioSecondary()` now checks `_forceSilence` at entry
- **Build failure from `import FineTuneCore`:** All 5 occurrences wrapped with `#if canImport(FineTuneCore)` for Xcode builds without SPM dependency

### Added
- Comprehensive audio pipeline diagnostics (RT-safe atomic counters)
  - `TapDiagnostics` struct with 19 fields: callback counts, silence flags, converter stats, peak levels, format info, volume/crossfade state, empty input count
  - Both `processAudio()` and `processAudioSecondary()` instrumented at every decision point
  - `computeOutputPeak()` RT-safe helper for output buffer peak measurement
  - 3-second diagnostic + health check timer in AudioEngine logs per-app state including device UID
  - Activation logging with format, converter, aggregate device ID, ramp coefficient
  - Enhanced log format: `vol=`, `curVol=`, `xfade=`, `dev=`, `empty=` fields for gain/state debugging

## [1.14] - 2026-02-05

### Added
- Device disconnect handling in AudioDeviceMonitor
- Enhanced volume/mute logging in DeviceVolumeMonitor

### Changed
- Simplified device display in MenuBarPopupView

## [1.13] - 2026-02-05

### Fixed
- **Bug 1:** `setDevice()` now reverts `appDeviceRouting` when async `switchDevice()` fails, preventing UI/audio desync
- **Bug 2:** Crossfade no longer promotes secondary tap that hasn't produced audio — checks `isWarmupComplete` before destroying primary, falls back to destructive switch if warmup incomplete
- **Bug 3:** `setDevice()` else-branch (no existing tap) now reverts routing when `ensureTapExists` fails
- **Bug 4:** `applyPersistedSettings()` removes stale `appDeviceRouting` entries when tap creation fails, so UI falls back to showing default device

## [1.12] - 2026-02-05

## [1.11] - 2026-02-05

## [1.10] - 2026-02-05

### Fixed
- Fix 'angry robot noise' and System Settings freeze
- Fix System Settings contention and feedback loop in device sync

## [1.09] - 2026-02-05

## [1.08] - 2026-02-05

## [1.07] - 2026-02-05

---

### Added (local only, gitignored)
- CrossfadeStateTests (31 tests) — validates warmup detection, equal-power curves, state lifecycle
- AudioEngineRoutingTests (5 tests) — validates routing revert on tap creation failure
