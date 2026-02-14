# Agent 1: api-researcher -- macOS 26 API Changes

**Task:** Research macOS 26 process tap API changes, WWDC documentation, Apple developer forums, and third-party compatibility patterns.

---

## macOS 26 CATapDescription Additions

Two new properties added to `CATapDescription` in macOS 26 (Mac Catalyst 26.0+):

- **`bundleIDs: [String]`** -- "An Array of Strings where each String holds the bundle ID of a process to tap or exclude." Targets all processes sharing a bundle ID (main process + renderers + helpers), solving the multi-process audio problem for Chromium-based browsers.
- **`isProcessRestoreEnabled: Bool`** -- "True if this tap should save tapped processes by bundle ID when they exit, and restore them to the tap when they start up again." Convenience for persistent taps across process restarts.

Apple's documentation is minimal -- just the property descriptions. No behavioral documentation on how these flags affect aggregate device output wiring.

## WWDC 2025 Coverage

No WWDC 2025 session covered CoreAudio process tap changes specifically. The API additions were shipped without dedicated session coverage. Apple's sample code ("Capturing System Audio with Core Audio Taps") was updated to require macOS 26.0+ but contains no bundle-ID tap examples in public code.

## Apple Developer Forums

No public developer forum posts specifically about bundle-ID tap output failure. One post (thread 798941) documented a potential error in Apple's sample code: the code for modifying `kAudioAggregateDevicePropertyTapList` incorrectly uses `tapID` as the target `AudioObjectID` in `AudioObjectSetPropertyData`, when it should target the aggregate device ID.

The Apple documentation page for "Capturing system audio with Core Audio taps" requires JavaScript to render and does not serve static content, limiting automated extraction.

## Rogue Amoeba Compatibility Patterns

Rogue Amoeba (SoundSource, Audio Hijack, Loopback) documented significant macOS 26 audio subsystem changes:

### macOS 26.0 Bugs (Fixed in 26.1)

1. **Sample rate mismatch silence** -- Applications playing audio to multiple devices with mismatched sample rates could be silenced during capture. SoundSource 5.8.7+ mitigates by matching secondary device sample rates to the default output.
2. **Communication app audio loss** -- FaceTime, Facebook Messenger, WhatsApp, Phone app audio lost in certain device configurations. SoundSource 5.8.8+ implemented an "alternate capture method" to work around this.
3. **Safari 44.1 kHz audio skipping** -- Skipping and clicks during Safari audio capture at 44.1 kHz.
4. **Low sample rate capture regression** -- From macOS 15 Sequoia, restored in 26.1.
5. **"Hey Siri" recognition** -- Failed during audio capture, fixed in 26.1.
6. **Advanced audio devices** -- Devices from MOTU and Apogee using stream groups had issues, fixed in 26.1.

### SoundSource Architecture Notes

SoundSource uses process taps as a supplement, not as the sole mechanism. The primary capture path uses a virtual audio device (the ACE driver, installed as a system component). The "alternate capture method" referenced for macOS 26 communication app workarounds is not documented publicly. Five Rogue Amoeba applications were affected: Airfoil, Audio Hijack, Loopback, Piezo, and SoundSource.

## Other Open-Source Process Tap Implementations

- **AudioTee** (github.com/makeusabrew/audiotee): Uses CATapDescription with global taps, PID include/exclude. Supports `--mute` flag for `.mutedWhenTapped`. Does not use `bundleIDs` or `isProcessRestoreEnabled`. Documents that tapping PIDs not currently outputting audio will cause failures.
- **AudioCap** (github.com/insidegui/AudioCap): System audio recording tool. No bundle-ID tap usage.
- **sudara's gist**: Reference Objective-C implementation of Core Audio Tap API. Uses a tap-only aggregate (no output sub-device) for monitoring only. Does not attempt capture + output in one aggregate.

## Key Conclusion

The `bundleIDs` and `isProcessRestoreEnabled` APIs are macOS 26-only with minimal documentation. No third-party app publicly documents using bundle-ID taps with aggregate device output. Rogue Amoeba's solutions rely on virtual audio devices rather than aggregate device output through process taps. The macOS 26.0 vs 26.1 distinction is critical -- testing should confirm which version is running.
