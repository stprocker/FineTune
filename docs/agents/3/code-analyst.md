# Agent 2: code-analyst -- Aggregate Device Wiring Analysis

**Task:** Analyze aggregate device configuration differences between bundle-ID and PID-only taps. Determine why the output path dies with bundle-ID taps.

---

## Aggregate Device Configuration: Identical in Both Modes

The aggregate device creation dictionary in `ProcessTapController.activate()` (line ~390) is structurally identical regardless of tap mode:

```swift
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: "FineTune-\(app.id)",
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: outputUID]
    ],
    kAudioAggregateDeviceTapListKey: [
        [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapDesc.uuid.uuidString
        ]
    ]
]
```

The sub-device list, main sub-device, tap list, drift compensation, stacked/private flags -- all identical. The only difference between modes is internal to the `CATapDescription` object passed to `AudioHardwareCreateProcessTap()`.

## IOProc Buffer Analysis

The `processAudio()` callback (line ~1107) receives `inInputData` (from tap) and `outOutputData` (to output device). In both modes:

- Buffer layouts are the same structure
- Output buffers are allocated and sized correctly (`1x4096B`)
- The callback writes valid processed samples to output buffers

In **PID-only mode**: output buffers are connected to the physical device. Audio plays. Input is empty (tap missed the renderer PID).

In **bundle-ID mode**: output buffers exist and receive writes (`outputWritten > 0`), but `outPeak` stays at 0.000. The buffers are not connected to the physical device's audio stream. Input has real audio data (`inPeak > 0`, `inputHasData > 0`).

This means CoreAudio internally reconfigures the aggregate device's output stream topology when it detects a bundle-ID tap with `isProcessRestoreEnabled`. The output sub-device may be disconnected from hardware to avoid routing conflicts with the process restore mechanism.

## `shouldConfirmPermission` Gap

The original implementation at `AudioEngine.swift:143`:

```swift
nonisolated static func shouldConfirmPermission(from diagnostics: TapDiagnostics) -> Bool {
    guard diagnostics.callbackCount > 10 else { return false }
    guard diagnostics.outputWritten > 0 else { return false }
    return diagnostics.inputHasData > 0 || diagnostics.lastInputPeak > 0.0001
}
```

**The gap:** This checks `outputWritten > 0` (buffers written to) but NOT `lastOutputPeak > 0` (actual audio energy reaching hardware). In the bundle-ID failure mode, `outputWritten` is non-zero because the callback writes to output buffers. But `lastOutputPeak` is zero because those buffers are disconnected from hardware.

This allows promotion to `.mutedWhenTapped` -- which silences the app's original output path -- while the aggregate's output path is dead. Result: complete silence.

**The fix** (now implemented) adds an output peak check with volume awareness:

```swift
let userExpectsAudio = diagnostics.volume > 0.01
if userExpectsAudio {
    return diagnostics.lastOutputPeak > 0.0001
}
return true
```

When volume is near zero, `lastOutputPeak` is legitimately zero even with a working output path. The check skips the peak requirement in that case.

## TapAPITestRunner Test C Gap

`TapAPITestRunner.runTestC()` (line ~361) tests bundle-ID taps with `isProcessRestoreEnabled`:

- Creates a `CATapDescription` with `bundleIDs` and `isProcessRestoreEnabled = true`
- Creates a process tap via `AudioHardwareCreateProcessTap()`
- Creates an aggregate device with the tap
- Creates an IOProc
- Starts the device proc

**What it tests:** Tap creation succeeds, aggregate creation succeeds, IOProc starts.

**What it does NOT test:** Whether `outPeak > 0` -- whether audio actually flows through the output path. The test verifies API success codes but not audio flow verification. This means Test C passes even when the output path is dead.

A proper test would need to verify that after the IOProc runs for several callbacks, `lastOutputPeak` is non-zero (assuming the tapped app is playing audio with non-zero volume).

## Missing Diagnostic Logging

There is no diagnostic logging of the aggregate device's output stream properties after creation. Key data that should be logged:

- Output stream count on the aggregate device
- Output stream format (sample rate, channels, interleaved)
- Whether the output stream is active
- Physical device assignment of the output stream

This data would directly confirm whether CoreAudio is disconnecting the output stream in bundle-ID mode.

## Summary of Findings

1. Aggregate device dictionary is identical -- the output path difference is internal to CoreAudio's handling of the `CATapDescription` flags.
2. Output buffers exist and are written to, but are not connected to hardware in bundle-ID mode.
3. `isProcessRestoreEnabled` is the most likely culprit -- it may cause CoreAudio to detach the output sub-device from the physical device.
4. `shouldConfirmPermission` was the "real footgun" -- it allowed `.mutedWhenTapped` promotion with dead output.
5. Test C validates tap/aggregate creation but not audio flow, missing the output failure entirely.
6. No stream topology logging exists to diagnose the internal wiring difference.
