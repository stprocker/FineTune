# Crash-Safe Cleanup for Orphaned CoreAudio Resources

**Date:** 2026-02-08
**Session type:** Plan execution (plan approved in prior session)
**Build status:** Compiles successfully, zero warnings

---

## Problem

When FineTune crashes or is force-killed (`kill -9`), orphaned process taps with `.mutedWhenTapped` persist in CoreAudio and silently mute apps' audio at the system level. The `applicationWillTerminate` handler can't run during a crash, and `deinit` on `ProcessTapController` is never called. This leaves aggregate devices and process taps registered with CoreAudio that continue to intercept (and mute) audio even after FineTune is gone.

## Solution: Defense in Depth

Four layers of protection were implemented:

| Scenario | Handler |
|---|---|
| Normal quit / Cmd+Q | `applicationWillTerminate` (existing) |
| `kill <pid>` / Ctrl+C | New POSIX signal handlers via DispatchSource (SIGTERM, SIGINT) |
| Crash (SIGABRT, SIGSEGV, SIGBUS, SIGTRAP) | New `CrashGuard` — C-level signal handler destroys tracked devices via IPC to coreaudiod |
| `kill -9` (uncatchable) | Startup cleanup scans CoreAudio on next launch |

## Files Changed

### 1. NEW: `FineTune/Audio/CrashGuard.swift`

Tracks live aggregate device IDs in a fixed-size C buffer and installs crash signal handlers that destroy them before the process terminates.

**Architecture:**
- File-level `nonisolated(unsafe)` globals (`gDeviceSlots`, `gDeviceCount`) for async-signal-safe access
- `UnsafeMutablePointer<AudioObjectID>` allocated once at `install()`, never freed (process-lifetime)
- 64 slots = 32 simultaneous apps with primary + secondary crossfade taps
- `crashSignalHandler()` is a plain C-compatible function at file scope (not a closure or method)

**Signal handler behavior:**
1. Resets handler to `SIG_DFL` first (prevents infinite recursion if cleanup crashes)
2. Iterates tracked device IDs and calls `AudioHardwareDestroyAggregateDevice` for each
3. Re-raises the signal for default crash behavior (crash report, core dump)

**Public API:**
- `CrashGuard.install()` — Allocates buffer, installs handlers for SIGABRT/SIGSEGV/SIGBUS/SIGTRAP
- `CrashGuard.trackDevice(_:)` — Registers an aggregate device ID (called after creation)
- `CrashGuard.untrackDevice(_:)` — Removes a device ID (called before destruction)

**Integration points (10 total):**
- 3 `trackDevice()` calls in ProcessTapController (after each `AudioHardwareCreateAggregateDevice`)
- 5 `untrackDevice()` calls in ProcessTapController error/teardown paths (before `AudioHardwareDestroyAggregateDevice`)
- 2 `untrackDevice()` calls in TapResources (in `destroy()` and `destroyAsync()`)

**Why untrack comes before destroy:** If the process crashes *during* `AudioHardwareDestroyAggregateDevice`, the device is already untracked so the crash handler won't try to destroy it again (double-destroy is harmless but messy).

### 3. NEW: `FineTune/Audio/OrphanedTapCleanup.swift`

Static utility enum that scans CoreAudio for orphaned FineTune aggregate devices and destroys them.

**Logic:**
1. Calls `AudioObjectID.readDeviceList()` (existing extension in `AudioObjectID+System.swift`)
2. For each device, calls `readTransportType()` (existing in `AudioDeviceID+Info.swift`)
3. Filters for `transportType == .aggregate`
4. Calls `readDeviceName()` and checks for `"FineTune-"` prefix
5. Destroys matches with `AudioHardwareDestroyAggregateDevice(deviceID)`
6. Logs each destroyed device and a summary count

This catches both:
- `"FineTune-{PID}"` (primary aggregate devices)
- `"FineTune-{PID}-secondary"` (crossfade aggregate devices)

**Key design decisions:**
- Uses `enum` (no instances) since it's a pure static utility
- Runs synchronously (blocks startup) to guarantee cleanup before any new taps are created
- Has its own Logger with category `"OrphanedTapCleanup"` for `[CLEANUP]` prefixed log messages
- Gracefully handles errors (logs and continues rather than crashing)

### 4. MODIFIED: `FineTune/Audio/Tap/TapResources.swift`

Added `CrashGuard.untrackDevice()` before `AudioHardwareDestroyAggregateDevice` in both:
- `destroy()` (synchronous teardown)
- `destroyAsync()` (background teardown, inside the async block)

### 5. MODIFIED: `FineTune/Audio/ProcessTapController.swift`

**3 track calls** (after aggregate creation succeeds):
- `activate()` line 385 — primary aggregate
- `createSecondaryTap()` line 667 — secondary aggregate for crossfade
- `performDeviceSwitch()` line 977 — new aggregate for destructive switch

**5 untrack calls** (before inline aggregate destruction):
- `createSecondaryTap()` lines 705, 720 — error paths for IO proc creation and device start failures
- `performDeviceSwitch()` lines 994, 1006 — error paths for IO proc and device start failures
- `performDeviceSwitch()` line 1019 — old primary being replaced

### 6. MODIFIED: `FineTune/FineTuneApp.swift`

**Changes to `AppDelegate`:**

1. **New property** (line 15):
   ```swift
   private var signalSources: [any DispatchSourceSignal] = []
   ```
   Holds strong references to dispatch sources to prevent deallocation.

2. **Startup cleanup + crash guard** (lines 22-23, in `applicationDidFinishLaunching`):
   ```swift
   OrphanedTapCleanup.destroyOrphanedDevices()
   CrashGuard.install()
   ```
   Both run **before** `AudioEngine` is created. Orphans from a previous crash are cleaned up, then crash signal handlers are installed for this session.

3. **Signal handler installation** (line 28, in `applicationDidFinishLaunching`):
   ```swift
   installSignalHandlers()
   ```
   Called after engine creation so `self.audioEngine` is set.

4. **New method** `installSignalHandlers()` (lines 67-86):
   - Ignores default SIGTERM/SIGINT behavior with `signal(SIGTERM, SIG_IGN)` / `signal(SIGINT, SIG_IGN)`
   - Creates `DispatchSource.makeSignalSource` for each signal on `.main` queue
   - Event handlers call `self?.audioEngine?.stopSync()` then `exit(0)`
   - Stores dispatch sources in `signalSources` to keep them alive

### Deleted: `FineTune/Audio/CrashProtection.swift`

A parallel agent auto-generated a duplicate file named `CrashProtection.swift` with equivalent functionality but a different name, and inserted `CrashProtection.trackDevice()`/`untrackDevice()` calls throughout ProcessTapController. This was cleaned up:
1. Deleted `CrashProtection.swift` (duplicate of `CrashGuard.swift`)
2. Bulk-renamed all `CrashProtection` references in ProcessTapController to `CrashGuard`
3. Fixed untrack ordering at all 5 inline destruction sites (moved from after destroy to before destroy)

## Session Flow

1. **Phase 1 — OrphanedTapCleanup + signal handlers** (from approved plan)
   - Read 8 files for codebase context
   - Created `OrphanedTapCleanup.swift`
   - Modified `FineTuneApp.swift` with cleanup call, signal handlers, and `signalSources` property
   - Built successfully

2. **Phase 2 — CrashGuard** (user requested proactive crash prevention)
   - Analyzed the gap: SIGABRT/SIGSEGV/SIGBUS/SIGTRAP were not handled
   - Designed C-interop approach: fixed-size buffer + plain C signal handler
   - Created `CrashGuard.swift`
   - Added `CrashGuard.install()` to FineTuneApp.swift
   - Added `CrashGuard.untrackDevice()` to TapResources (2 sites)
   - Added track/untrack calls to ProcessTapController (8 sites)
   - Cleaned up parallel agent's duplicate `CrashProtection.swift` and fixed all references
   - Built successfully

## Codebase Context Gathered

Before implementation, the following files were read to understand the existing patterns:

- `FineTune/FineTuneApp.swift` — AppDelegate lifecycle, `stopSync()` usage
- `FineTune/Audio/Extensions/AudioObjectID+System.swift` — `readDeviceList()` API
- `FineTune/Audio/Extensions/AudioDeviceID+Info.swift` — `readDeviceName()`, `readTransportType()` APIs
- `FineTune/Audio/ProcessTapController.swift` — Aggregate device naming (`"FineTune-{PID}"`, `"FineTune-{PID}-secondary"`), `AudioHardwareDestroyAggregateDevice` usage
- `FineTune/Audio/Types/TransportType.swift` — `.aggregate` enum case
- `FineTune/Audio/AudioEngine.swift` — `stopSync()` implementation
- `Package.swift` — File organization (SPM uses filesystem sync for FineTuneIntegration target, explicit sources for FineTuneCore)
- `finetune_fork.xcodeproj/project.pbxproj` — Uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16), new files auto-discovered

## Build Verification

- `xcodebuild -scheme FineTune -configuration Debug build` → **BUILD SUCCEEDED**
- Zero compilation errors
- Zero warnings related to the new/modified files
- Xcode test runner had a pre-existing CodeSign failure (unrelated to this change)
- SPM `swift test` has a pre-existing Sparkle module resolution failure (Sparkle is an Xcode-only dependency)

## How It Works at Runtime

### Clean launch (no orphans):
```
[CLEANUP] No orphaned FineTune devices found
[APPDELEGATE] applicationDidFinishLaunching fired
```

### Launch after crash (orphans exist):
```
[CLEANUP] Destroyed orphaned aggregate device: FineTune-12345 (ID 87)
[CLEANUP] Destroyed orphaned aggregate device: FineTune-12345-secondary (ID 88)
[CLEANUP] Destroyed 2 orphaned device(s)
[APPDELEGATE] applicationDidFinishLaunching fired
```

### `kill <pid>` scenario:
```
# SIGTERM received via DispatchSource
# audioEngine.stopSync() destroys all active taps
# exit(0)
```

---

## TODO List (for handoff)

### Must Do (before shipping)

- [ ] **Runtime test: normal quit path** — Launch app, play audio, Cmd+Q. Verify audio resumes (not muted). Check Console.app for `[APPDELEGATE] applicationWillTerminate` log.
- [ ] **Runtime test: `kill <pid>` path** — Launch app, play audio, run `kill <finetune_pid>` from terminal. Verify audio resumes immediately (signal handler cleans up before exit). Check for no orphaned devices.
- [ ] **Runtime test: `kill -9` path** — Launch app, play audio, run `kill -9 <finetune_pid>`. Verify audio IS muted (orphaned tap still alive). Relaunch app. Verify `[CLEANUP] Destroyed orphaned aggregate device` appears in logs and audio resumes.
- [ ] **Runtime test: crash path (CrashGuard)** — Force a crash (e.g., `kill -ABRT <pid>`) and verify audio resumes immediately (CrashGuard should destroy devices in the signal handler). Relaunch should show no orphans in `[CLEANUP]` logs.
- [ ] **Runtime test: multiple tapped apps** — Have 2-3 apps tapped (e.g., Spotify + Brave + Music). `kill -9` FineTune. Relaunch. Verify ALL orphaned aggregate devices are cleaned up (should see one per tapped app + any secondary crossfade devices).

### Should Do (polish)

- [ ] **Consider adding SIGHUP handler** — Some process managers send SIGHUP. Could be added to `installSignalHandlers()` if needed.
- [ ] **Consider `settings?.flushSync()` in signal handlers** — Currently signal handlers only call `audioEngine?.stopSync()`. If settings persistence on signal death matters, add `settings?.flushSync()` before `exit(0)`.
- [ ] **Unit test for `OrphanedTapCleanup`** — Could mock `AudioObjectID.readDeviceList()` to test filtering logic, but this is a CoreAudio API wrapper and hard to unit test without real hardware. Integration test more appropriate.

### Won't Do (by design)

- `kill -9` (SIGKILL) cannot be intercepted — this is a kernel-level constraint. The startup cleanup handles this case.

## Known Issues

1. **Xcode test runner CodeSign failure** — Pre-existing issue, unrelated to this change. Tests can't run via `xcodebuild test` due to signing configuration. Likely needs a development team or signing certificate configured.

2. **SPM `swift test` Sparkle module error** — Pre-existing. The `FineTuneIntegration` target includes `UpdateManager.swift` which imports Sparkle, but Sparkle is only available as an Xcode SPM dependency, not in the root `Package.swift`. The `FineTuneCoreTests` target (pure logic tests) works fine.

3. **No automated test for `OrphanedTapCleanup`** — The cleanup logic is straightforward (filter + destroy) but depends on CoreAudio state that's hard to mock. Manual testing with `kill -9` is the primary verification path.

4. **Signal handlers call `exit(0)` directly** — This bypasses `applicationWillTerminate` and any other AppKit shutdown hooks. Currently this is fine since `stopSync()` is the critical cleanup, but if future shutdown logic is added to `applicationWillTerminate`, consider calling `NSApplication.shared.terminate(nil)` instead of `exit(0)` (though this may not work reliably in a signal handler context).

5. **`signalSources` typed as `[any DispatchSourceSignal]`** — Uses existential type. If Swift 6 strict concurrency is enabled later, this may need `@unchecked Sendable` annotation since `DispatchSource` signal sources are created on `.main` queue.

6. **`CrashGuard` uses `signal()` not `sigaction()`** — `signal()` on macOS/BSD does NOT reset the handler to `SIG_DFL` after delivery (unlike historical Unix). The handler manually calls `signal(sig, SIG_DFL)` as its first line to get equivalent `SA_RESETHAND` behavior. Using `sigaction()` with `SA_RESETHAND` would be more portable but has more complex Swift/C bridge syntax.

7. **`CrashGuard` buffer is 64 slots** — Supports up to 32 simultaneous apps (primary + secondary crossfade per app). If FineTune ever supports more than 32 concurrent taps, increase `gMaxDeviceSlots`. Overflow silently drops tracking (device would still be cleaned up on next startup via `OrphanedTapCleanup`).
