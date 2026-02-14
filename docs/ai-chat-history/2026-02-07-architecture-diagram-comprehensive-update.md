# Architecture Diagram Comprehensive Update

**Date:** 2026-02-07
**File updated:** `docs/architecture/finetune-architecture.md`
**Scope:** Complete rewrite of the Mermaid architecture diagram and addition of prose documentation sections

---

## What Was Done

### Task
The user requested a comprehensive update to `docs/architecture/finetune-architecture.md` to reflect all recent changes to the codebase. The existing diagram was a single Mermaid flowchart from before the 4-phase refactoring effort and several major feature additions.

### Research Phase
1. Read the existing architecture document (88 lines, single Mermaid flowchart)
2. Retrieved the last 30 git commits to understand the scope of changes
3. Launched a thorough codebase exploration agent that:
   - Globbed all `**/*.swift` files to map the full directory structure
   - Read key files: `FineTuneApp.swift`, `MenuBarPopupViewModel.swift`, `MenuBarPopupView.swift`, `AudioEngine.swift`, `ProcessTapController.swift`, `AppRow.swift`, `AppRowEQToggle.swift`, `DeviceIconView.swift`, `DesignTokens.swift`, `SliderAutoUnmute.swift`, `CoreAudioQueues.swift`, `TapDiagnostics.swift`, `MenuBarStatusController.swift`, `DeviceVolumeMonitor.swift`
   - Identified all MARK sections in AudioEngine, ProcessTapController, AppRow, and MenuBarPopupViewModel
   - Mapped all type relationships, property ownership, and data flow paths
4. Read the full CHANGELOG.md to cross-reference all documented changes

### Changes Made to Architecture Document

#### Before (88 lines)
- Single Mermaid flowchart with 6 subgraphs
- Referenced "SwiftUI + FluidMenuBarExtra" (now removed)
- No ViewModel layer shown
- Missing ~20 components added since original diagram
- No prose documentation
- No file layout

#### After (332 lines)
The document was completely rewritten with:

**1. Expanded Mermaid Diagram (181 lines)**
- **12 subgraphs** (was 6): App Entry, ViewModel, UI (with nested Rows/Components/DesignSystem), State & Orchestration, Monitors, Audio Routing, Audio Processing (DSP), Models, CoreAudio Utilities, macOS Audio Services, Persistence, Utilities
- **~50 nodes** (was ~20), each with inline annotation of key responsibilities
- **~50 edges** with labeled relationships showing data flow direction
- Dotted lines for ViewModifier usage (SliderAutoUnmute)
- Removed `AVFoundation` (not used), `FluidMenuBarExtra` (removed)
- Added: `MenuBarStatusController`, `MenuBarPopupViewModel`, `AppRowEQToggle`, `DeviceIconView`, `SliderAutoUnmute`, `DesignTokens`, `EQSliderView`, `LiquidGlassSlider`, `MuteButton`, `DropdownMenu`, `TapDiagnostics`, `CrossfadeState`, `AudioBufferProcessor`, `GainProcessor`, `VolumeRamper`, `SoftLimiter`, `BiquadMath`, `CoreAudioQueues`, `AudioScope`, `TransportType`, `TapFormat`, `Extensions`, `DeviceIconCache`, `SingleInstanceGuard`

**2. Data Flow Summary (new section)**
- ASCII pipeline: User → SwiftUI → ViewModel/AudioEngine → ProcessTapController → CoreAudio HAL → RT callback → DSP chain → Output Device

**3. Key Architectural Patterns (new section, 9 subsections)**
- App Lifecycle (AppKit, not SwiftUI Scene) — AppDelegate, MenuBarStatusController, KeyablePanel
- ViewModel Layer — MenuBarPopupViewModel responsibilities
- Per-App Audio Taps — `[pid_t: ProcessTapController]` dictionary
- Permission Confirmation — `.unmuted` → `.mutedWhenTapped` upgrade flow
- Crossfade Device Switching — lock-free state machine, BT warmup
- Real-Time Safety — `nonisolated(unsafe)` atomic properties, no locks/allocations
- Tap Health & Diagnostics — 3s timer, 19-field TapDiagnostics, stalled/broken detection
- coreaudiod Restart Recovery — service restart listener, 1.5s wait, tap recreation
- Design System — DesignTokens coverage summary
- Shared Utilities — SliderAutoUnmute, DeviceIconView, CoreAudioQueues, AudioObjectID+Listener

**4. Complete File Layout (new section)**
- Every Swift source file in `FineTune/` with directory tree and annotations
- Full test suite listing in `testing/tests/` with test counts and categories (unit, characterization, integration, UI)

---

## What Was NOT Changed

- No source code was modified — this was documentation only
- CHANGELOG was updated separately (see below)
- No tests were added or modified

---

## TODO List (Handoff)

### Architecture Diagram Improvements
- [ ] **Add SPM package structure to diagram** — The `Package.swift` defines `FineTuneCore`, `FineTuneIntegration`, and test targets. These module boundaries are not yet shown in the architecture diagram.
- [ ] **Add sequence diagrams** for key flows:
  - [ ] App startup sequence (AppDelegate → AudioEngine → monitors → initial tap creation)
  - [ ] Permission confirmation flow (`.unmuted` → detect audio → `.mutedWhenTapped`)
  - [ ] Device switch crossfade sequence (primary tap → secondary tap → crossfade → promote)
  - [ ] coreaudiod restart recovery sequence
- [ ] **Add state diagram for CrossfadeState** — The crossfade state machine (idle → warmup → active → completing) is complex and would benefit from a dedicated state diagram
- [ ] **Add state diagram for tap lifecycle** — activate → running → deactivate, with error/retry paths
- [ ] **Document the `#if canImport(FineTuneCore)` dual-build pattern** — Source files compile under both Xcode (no SPM) and `swift test` (SPM). This conditional import pattern is not documented in the architecture doc.

### Codebase Maintenance
- [ ] **ProcessTapController is still 1,380 lines** — Phase 3 reduced it from 1,414 but it remains the largest file. Further extraction candidates:
  - Device switching logic (crossfade orchestration)
  - Audio callback processing (`processAudio` / `processAudioSecondary`)
  - Aggregate device creation/configuration
- [ ] **AudioEngine is 870 lines and growing** — Further ViewModel or coordinator extraction may be needed as features are added
- [ ] **MenuBarPopupView still contains some layout logic** that could move to the ViewModel or dedicated layout helpers
- [ ] **Test coverage gaps:**
  - No unit tests for MenuBarPopupViewModel
  - No unit tests for MenuBarStatusController
  - No unit tests for DeviceVolumeMonitor (only integration tests)
  - No unit tests for AudioDeviceMonitor
  - No tests for DeviceIconView, DeviceIconCache, DropdownMenu, LiquidGlassSlider
  - EQ processing path has limited test coverage (EQProcessor has no dedicated tests)

### Known Issues

1. **FineTuneIntegration uses `.swiftLanguageMode(.v5)`** — The integration test target cannot yet compile under Swift 6 strict concurrency due to existing patterns in AudioEngine and ProcessTapController. This is a tech debt item to eventually resolve.

2. **`nonisolated(unsafe)` usage in ProcessTapController** — While correct for real-time audio safety (no locks on RT thread), this pattern bypasses Swift's concurrency safety guarantees. Future Swift versions may provide better RT-safe primitives (e.g., `Atomic<T>`).

3. **Virtual device filtering is heuristic-based** — Detection of virtual audio drivers (BlackHole, SRAudioDriver, etc.) uses transport type checks. New virtual drivers may not be correctly detected.

4. **VU meter polling is timer-based** — `AppRowWithLevelPolling` uses a 30fps timer when the popup is visible. This works but is not the most efficient approach. A push-based model from the audio callback could reduce CPU usage.

5. **No automated UI tests** — `AppRowInteractionTests` test SwiftUI view interactions in isolation but there are no end-to-end UI tests for the full popup flow.

6. **DesignTokens has no dark/light mode variants** — Currently assumes dark glass aesthetic. If a light mode or theme system is needed, DesignTokens would need conditional color definitions.

7. **Diagram may drift from code** — The architecture diagram is manually maintained Mermaid. There is no automated validation that the diagram matches the actual file/type structure. Consider adding a CI check or generation script.

---

## Session Context

- **Branch:** `main`
- **Starting state:** CHANGELOG.md was the only modified file (staged from prior session)
- **Commits in scope:** 0.1 through 4.1 (the 4-phase refactoring series), plus all prior unreleased changes
- **Total files in codebase:** ~60 Swift source files + 19 test files
- **Test count:** 220 tests (~1.1s via `swift test`)
