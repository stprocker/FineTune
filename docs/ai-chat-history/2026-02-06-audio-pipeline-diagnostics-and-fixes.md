# Chat Log: Audio Pipeline Diagnostics, Sample Rate Fix, Virtual Device Filtering

**Date:** 2026-02-05 to 2026-02-06
**Topic:** Implementing RT-safe diagnostic counters, fixing AirPods silence (sample rate mismatch), and preventing virtual device routing

---

## Summary

This session implemented a comprehensive audio pipeline diagnostic system to troubleshoot two symptoms on macOS 26 Tahoe: (1) all audio goes silent, and (2) audio distortion. The diagnostics immediately revealed a sample rate mismatch causing silence on AirPods/Bluetooth devices, which was fixed. A second issue was discovered where FineTune followed macOS default device changes to virtual audio drivers (SRAudioDriver), causing silent routing. Three virtual device filtering fixes were applied across the codebase.

---

## Files Modified

### Core Changes
1. **`FineTune/Audio/ProcessTapController.swift`**
   - Added 15 `nonisolated(unsafe)` diagnostic counters (RT-safe atomic increments)
   - Added `TapDiagnostics` struct with all counter fields + volume/crossfade state
   - Added `diagnostics` computed property for main-thread snapshot reads
   - Added `computeOutputPeak()` helper (RT-safe float max scan of output buffers)
   - Instrumented `processAudio()` (primary callback) at every decision point
   - Instrumented `processAudioSecondary()` with same counters
   - Added `[DIAG] Activation complete` log after successful tap activation
   - **BUG FIX:** Changed aggregate device sample rate from tap rate to output device rate in `activate()` and `createSecondaryTap()`

2. **`FineTune/Audio/AudioEngine.swift`**
   - Added 5-second diagnostic timer (`Task` loop calling `logDiagnostics()`)
   - `logDiagnostics()` iterates all active taps and logs single-line summary per app
   - Enhanced log format: added `vol=`, `curVol=`, `xfade=`, `dev=` fields
   - **BUG FIX:** `applyPersistedSettings()` now validates default device UID exists in non-virtual device list; falls back to first real device if default is virtual

3. **`FineTune/Audio/DeviceVolumeMonitor.swift`**
   - **BUG FIX:** `handleDefaultDeviceChanged()` now checks `isVirtualDevice()` on the new default and ignores virtual devices to prevent silent routing

4. **`FineTune/Views/MenuBarPopupView.swift`**
   - **BUG FIX:** UI fallback for device UID now uses `outputDevices.first?.uid` (already filtered non-virtual) instead of `defaultDeviceUID` which could be virtual

---

## Timeline

### Phase 1: Diagnostic Implementation (Plan Execution)

**Plan:** Add RT-safe atomic counters to `ProcessTapController` written from the audio callback, periodically read from main thread and logged via `os.Logger` to Console.app.

**Step 1: Diagnostic counters and struct**
- Added 15 `nonisolated(unsafe)` counter vars after existing atomic vars (~line 43)
- Counters: `_diagCallbackCount`, `_diagInputHasData`, `_diagOutputWritten`, `_diagSilencedForce`, `_diagSilencedMute`, `_diagConverterUsed`, `_diagConverterFailed`, `_diagDirectFloat`, `_diagNonFloatPassthrough`, `_diagLastInputPeak`, `_diagLastOutputPeak`, `_diagFormatChannels`, `_diagFormatIsFloat`, `_diagFormatIsInterleaved`, `_diagFormatSampleRate`
- Later added: `volume`, `crossfadeActive`, `primaryCurrentVolume` to `TapDiagnostics`
- Added `TapDiagnostics` struct and `var diagnostics` computed property

**Step 2: Instrument processAudio callbacks**
- `processAudio()` (primary): counter increments at entry, force-silence branch, mute branch, input peak detection, converter path (used/failed), direct float path, non-float passthrough, output written, output peak
- `processAudioSecondary()`: same instrumentation pattern
- Added `computeOutputPeak()` RT-safe helper that scans output buffer float samples

**Step 3: Periodic diagnostic dump in AudioEngine**
- Added `Task { @MainActor [weak self] in while !Task.isCancelled { ... } }` in `init()`
- `logDiagnostics()` iterates `taps` dictionary, reads `tap.diagnostics`, logs one-line summary per app
- Log format: `[DIAG] AppName: callbacks=N input=N output=N silForce=N silMute=N conv=N convFail=N direct=N passthru=N inPeak=0.XXX outPeak=0.XXX vol=X.XX curVol=X.XX xfade=bool fmt=Nch/f32|int/ilv|planar/NHz dev=UID`

**Step 4: Activation diagnostic log**
- After `activated = true` in `activate()`, logs: `[DIAG] Activation complete: format=..., converter=..., aggDeviceID=..., rampCoeff=...`

**Build:** Succeeded. Verified with `xcodebuild build`.

### Phase 2: Console.app Discovery

- User couldn't find Console.app initially
- Guided to Xcode debug console (`Cmd+Shift+Y`)
- `os.Logger` at `.info` level doesn't appear in Xcode console or `log show` by default
- Solution: `log show --predicate 'process == "FineTune"' --last 2m --info` (must pass `--info` flag)

### Phase 3: First Diagnostic Results - Sample Rate Bug Found

**Diagnostic output (before fix):**
```
[DIAG] Brave Browser: callbacks=5423 input=0 output=5423 silForce=0 silMute=0
conv=0 convFail=0 direct=5423 passthru=0 inPeak=0.000 outPeak=0.000
fmt=2ch/f32/ilv/24000Hz
```

**Analysis:**
- `callbacks>0, input=0` = IO proc fires but tap delivers no audio data
- `fmt=2ch/f32/ilv/24000Hz` = **24000 Hz sample rate** (Chromium's internal rate)
- AirPods require 48000 Hz
- CoreAudio error in system log: `HALC_ProxyIOContext::_StartIO(): Start failed - StartAndWaitForState returned error 35` (5 occurrences)

**Root cause:** `activate()` line 304: `let tapSampleRate = primaryFormat?.sampleRate ?? fallbackSampleRate` preferred the tap's 24000 Hz over the device's 48000 Hz. The aggregate device was set to 24000 Hz, which AirPods don't support, causing IO start failure.

**Why converter didn't help:** `AudioFormatConverter.configure()` only triggers for non-Float32, non-interleaved, or mono formats. It does NOT check sample rate — the format was already `2ch/f32/ilv` so no converter was created.

### Phase 4: Sample Rate Fix

**Changes in `ProcessTapController.swift`:**
1. `activate()`: Changed to use `let deviceSampleRate = fallbackSampleRate` (output device rate) for aggregate sample rate, ramp coefficient, and EQ processor
2. `createSecondaryTap()`: Same fix — uses `fallbackSampleRate` instead of `secondaryFormat?.sampleRate`
3. `performDeviceSwitch()`: Already used `fallbackSampleRate` — no change needed

**Verification after fix:**
```
[DIAG] Activation complete: format=48000 Hz, 2 ch, 32-bit, float, interleaved, lpcm,
converter=false, aggDeviceID=244, rampCoeff=0.000694

[DIAG] Brave Browser: callbacks=620 input=605 output=620 ... inPeak=0.041 outPeak=0.042
fmt=2ch/f32/ilv/48000Hz
```
- Format now correctly `48000Hz`
- `outPeak` now non-zero (was 0.000 before)
- No more `error 35`
- **Audio confirmed working on AirPods**

### Phase 5: Virtual Device Routing Issue

**User report:** Audio still silent in some scenarios. Brave routed to AirPods but no sound. YouTube playing, no audio before/after selecting AirPods, and after disconnecting AirPods.

**Diagnostic output (second session):**
```
[DIAG] Brave Browser: callbacks=5674 input=5674 output=5674 ... inPeak=0.460 outPeak=0.000
fmt=2ch/f32/ilv/48000Hz
```

**User observation:** "Pretty sure the issue is that it keeps switching to this SR audio driver" — SRAudioDriver 2ch (Virtual) was highlighted/selected in System Settings > Sound > Output.

**Root cause:** SRAudioDriver (from Screen Recorder Go) kept becoming the macOS default output device. FineTune's `DeviceVolumeMonitor.onDefaultDeviceChangedExternally` callback followed this change, routing all apps to the virtual device. The process tap muted the app's audio (`mutedWhenTapped`) but delivered it to SRAudioDriver which doesn't produce audible output.

**Three gaps identified and fixed:**

1. **`DeviceVolumeMonitor.handleDefaultDeviceChanged()`** — Added `isVirtualDevice()` check. When new default is virtual, logs warning and skips `onDefaultDeviceChangedExternally` callback.

2. **`AudioEngine.applyPersistedSettings()`** — When no saved routing exists, validates the default device UID exists in `deviceMonitor.outputDevices` (which already filters virtual devices). Falls back to `deviceMonitor.outputDevices.first?.uid` if default is virtual.

3. **`MenuBarPopupView.appsContent()`** — UI fallback changed from `deviceVolumeMonitor.defaultDeviceUID` (could be virtual) to `audioEngine.outputDevices.first?.uid` (guaranteed non-virtual).

### Phase 6: Enhanced Diagnostics

Added to `TapDiagnostics` struct:
- `volume: Float` — current `_volume` target
- `crossfadeActive: Bool` — `crossfadeState.isActive`
- `primaryCurrentVolume: Float` — current ramped volume

Added to log line:
- `vol=X.XX` — target volume
- `curVol=X.XX` — current ramped volume
- `xfade=bool` — crossfade state
- `dev=UID` — device UID from `appDeviceRouting`

---

## Diagnostic Reference Table

| Pattern | Diagnosis |
|---|---|
| `callbacks=0` | IO proc never fires — aggregate device broken |
| `callbacks>0, input=0` | IO proc fires but tap delivers no audio |
| `callbacks>0, input>0, output=0` | Audio arrives but processing drops it |
| `callbacks>0, convFail>0` | Format converter failing — format mismatch |
| `silForce>0 (growing)` | `_forceSilence` stuck true — device switch failed |
| `silMute>0 (growing)` | Mute state stuck — check VolumeState |
| `fmt=Nch/int/planar` | Unexpected format — converter needed but missing? |
| `inPeak>0, outPeak=0` | Processing zeroes audio — check vol/xfade/compensation |
| `inPeak>0, outPeak>0 but no sound` | Aggregate device output not reaching real device |
| `vol=0.00` | Volume target is zero |
| `xfade=true` stuck | Crossfade never completed — primary tap silenced |
| `dev=<virtual-uid>` | Routed to virtual device — no audible output |

---

## Known Issues / TODO

### Critical — `outPeak=0.000` Root Cause Still Unknown
- In the second test session (11:14 AM), diagnostics showed `inPeak=0.460, outPeak=0.000` consistently even after the sample rate fix
- This was likely caused by routing to SRAudioDriver (virtual device) — the virtual device filter wasn't in place yet
- **TODO:** After deploying the virtual device filter, re-test and confirm `outPeak` is non-zero when routed to a real device
- If `outPeak` is still zero with a real device, investigate `GainProcessor.processFloatBuffers` — the gain formula is `currentVolume * crossfadeMultiplier * compensation`. Check the new `vol=`, `curVol=`, `xfade=` diagnostics to identify which factor is zero

### High Priority
- **Bluetooth latency:** User reported Netflix audio slightly out of sync with video on AirPods. Likely inherent Bluetooth latency (~150-200ms) that Netflix normally compensates for but can't when FineTune is in the pipeline. User decided this is not related to the code. May need investigation if users report it.
- **`HALC_ProxyObject::SetPropertyData ('guse', 'inpt', 0, DI32): error 0x21686F67 ('!hog')`** — Device hog mode errors appear in logs during activation. Another process (possibly Screen Recorder Go) may have exclusive access. Impact unclear but may contribute to intermittent failures.
- **`AudioObjectRemovePropertyListenerBlock: no object with given ID`** — Multiple errors on app restart. Listeners referencing stale device IDs (from previous run's aggregate devices). Cosmetic but indicates cleanup could be improved.

### Medium Priority
- **Diagnostic timer lifecycle:** The diagnostic `Task` in `AudioEngine.init()` is never explicitly cancelled. It relies on `[weak self]` + `guard let self` to stop when engine is deallocated. Consider storing the task and cancelling it in `stop()`.
- **Diagnostic overhead:** The `computeOutputPeak()` scans all output buffer samples every callback. On high-sample-rate devices with large buffers this adds CPU in the RT thread. Consider making diagnostics toggleable or sampling every Nth callback.
- **CoreSpeech tap:** Diagnostics show `CoreSpeech: callbacks=0` — the tap activates but never fires. This is a system process that may not produce audio normally. Consider excluding system processes from tap creation to reduce resource usage.

### Low Priority / Future
- **Per-device sample rate awareness:** The current fix always uses the output device's sample rate. If a future device supports multiple rates, we may want to negotiate the best rate.
- **Converter for sample rate mismatch:** Currently CoreAudio's drift compensation handles resampling within the aggregate device. If quality issues arise, consider explicit `AudioConverter` for sample rate conversion.
- **Virtual device allowlist:** The current filter blocks ALL virtual devices from default routing. If a user intentionally uses a virtual device (e.g., BlackHole for audio routing), they'd need to manually select it per-app. Consider a user preference.

---

## Commands for Future Debugging

```bash
# Pull FineTune diagnostic logs (must include --info flag)
/usr/bin/log show --predicate 'process == "FineTune"' --last 2m --info 2>&1 | grep "DIAG"

# Pull errors and diagnostics together
/usr/bin/log show --predicate 'process == "FineTune"' --last 5m --info 2>&1 | grep -E "DIAG|error|Error|Failed|SWITCH|CROSSFADE|Activation|differs"

# Check for CoreAudio errors specifically
/usr/bin/log show --predicate 'process == "FineTune"' --last 2m 2>&1 | grep -i error

# Check if FineTune is running
ps aux | grep -i "[F]ineTune"
```

---

## Build Verification

All changes verified with:
```bash
xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS'
```
All builds succeeded. No compiler errors or warnings introduced.
