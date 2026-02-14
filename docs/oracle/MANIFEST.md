# Context Bundle Manifest

## Purpose
Debug macOS 26 process tap: bundle-ID taps capture audio but aggregate output is dead; PID-only taps have working output but can't capture.

## Consultation Type
macOS/CoreAudio Specialist — Debugging

## Files Included

| File | Purpose | Lines |
|------|---------|-------|
| FineTune/Audio/ProcessTapController.swift | Core audio tap lifecycle, IOProc callbacks, crossfade, lock-free state | 1605 |
| FineTune/Audio/AudioEngine.swift | Tap orchestration, permission confirmation, health checks, device switching | 1132 |
| FineTune/Audio/Tap/TapDiagnostics.swift | 21-field RT-safe diagnostic snapshot struct | 27 |
| FineTune/Audio/Tap/TapResources.swift | CoreAudio resource lifecycle (tap, aggregate, IOProc) | 91 |
| FineTune/Audio/Crossfade/CrossfadeState.swift | Lock-free crossfade state machine (warmup, crossfading, idle) | 140 |
| FineTune/Audio/Processing/AudioFormatConverter.swift | Format conversion (mono->stereo, non-float->float, planar->interleaved) | 264 |
| FineTune/Audio/Processing/GainProcessor.swift | Volume ramping + soft limiting | 168 |
| FineTune/Audio/Processing/AudioBufferProcessor.swift | Buffer operations (zero, copy, peak) | 77 |
| FineTune/Audio/TapAPITestRunner.swift | In-process CoreAudio API validation harness (Tests A, B, C) | 480 |
| FineTune/Audio/Types/TapFormat.swift | Tap format descriptor | 68 |
| tools/TapExperiment/main.swift | Standalone CoreAudio testing CLI (Tests A, B, C, D) | 1389 |
| docs/known_issues/bundle-id-tap-silent-output-macos26.md | Known issue writeup with evidence and investigation plan | 92 |
| docs/architecture/finetune-architecture.md | Mermaid architecture diagram + component descriptions | 331 |

## File Tree
```
finetune_fork/
├── FineTune/
│   └── Audio/
│       ├── ProcessTapController.swift      # THE core file
│       ├── AudioEngine.swift               # Orchestrator
│       ├── TapAPITestRunner.swift          # API validation
│       ├── Tap/
│       │   ├── TapDiagnostics.swift
│       │   └── TapResources.swift
│       ├── Crossfade/
│       │   └── CrossfadeState.swift
│       ├── Processing/
│       │   ├── AudioFormatConverter.swift
│       │   ├── GainProcessor.swift
│       │   └── AudioBufferProcessor.swift
│       └── Types/
│           └── TapFormat.swift
├── tools/
│   └── TapExperiment/
│       └── main.swift                      # Standalone test CLI
└── docs/
    ├── known_issues/
    │   └── bundle-id-tap-silent-output-macos26.md
    └── architecture/
        └── finetune-architecture.md
```

## Token Estimate
~64K tokens (255K characters)

## Notes
- Target OS: macOS 26 (Tahoe) only — backwards compatibility is NOT required
- The app uses CoreAudio HAL process taps (CATapDescription) to capture per-app audio
- The two failure modes are complementary: bundle-ID captures but output dies, PID-only outputs but can't capture
- `isProcessRestoreEnabled` is a new macOS 26 API — limited documentation exists
- The TapExperiment CLI tool may fail due to TCC permission issues; TapAPITestRunner runs inside the app with permission
