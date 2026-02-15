# EQ Panel Shows No Audible Change (Troubleshooting)

## Status
Open, partially mitigated (diagnostics added on 2026-02-14; missing-tap persistence fix added on 2026-02-14; interaction-driven tap creation added on 2026-02-15)

## Observed Behavior
Users may move EQ sliders or select an EQ preset and hear no change.

## UI State Note (2026-02-15)
- Apps list empty-state handling was updated: when playback stops, the last active app now remains visible as an inactive fallback row instead of dropping immediately to `No apps playing audio`.

## Recent Tuning Changes (2026-02-15)
- EQ slider range increased from ±12 dB to ±18 dB.
- Graphic EQ Q increased from 1.4 to 1.8 for stronger per-band effect.
- Post-EQ soft limiter threshold raised from 0.8 to 0.9 (ceiling unchanged at 1.0).
- EQ panel now labels sliders as `Band Gain (dB)` to clarify units.

## Custom Preset Behavior (2026-02-15)
- Custom EQ presets are global (shared across app rows), not per-app.
- Maximum custom presets: 5.
- Preset matching precedence for label/checkmark:
  1. Built-in preset exact gain match
  2. Custom preset exact gain match
  3. Otherwise `Custom`
- When custom preset storage is full, save-new routes users to overwrite flow.
- Save/rename name entry now uses an inline editor overlay (not modal sheet) to avoid menu bar panel key-window issues.
- Preset action rows are shown at the top of the preset dropdown and remain unlabeled by design (no visible `Action` section title).
- Preset picker includes a session-level `Custom` item (separate from saved presets) that restores the last unsaved curve for the active row session.

## Likely Runtime Causes
1. EQ is disabled for that app (`isEnabled == false`).
2. No tap exists yet for the app PID, so realtime EQ apply is skipped until tap creation.
3. Crossfade is active during device switching, temporarily bypassing EQ.
4. Input format path is not eligible for direct EQ and converter path is not reached due upstream conditions.

## 2026-02-15 Mitigation
- Active app interactions now attempt tap creation on first control write (`EQ`, `volume`, `mute`), reducing "saved settings only" no-op behavior.
- Tap creation retries now use per-PID exponential backoff (0.35s base, 4.0s cap) to avoid retry storms during rapid slider drags.
- Explicit routing and mode-change actions bypass backoff so user-initiated retries remain immediate.

## What Was Added
- `TapDiagnostics.eqApplied`
- `TapDiagnostics.eqBypassed`
- `TapDiagnostics.eqBypassNoProcessor`
- `TapDiagnostics.eqBypassCrossfade`
- `TapDiagnostics.eqBypassNonInterleaved`
- `TapDiagnostics.eqBypassChannelMismatch`
- `TapDiagnostics.eqBypassBufferCount`
- `TapDiagnostics.eqBypassNoOutputData`

These counters now indicate whether EQ is being executed or bypassed on callback cycles.

## Verification
- If `eqApplied` increases while audio is playing, EQ path is active.
- If only `eqBypassed` increases, investigate toggle state, tap existence, and crossfade state.
- The periodic `[DIAG]` log now includes `eq=<applied>/<bypassed>` for each tap.
- The periodic `[DIAG]` log now includes `eqR=...` with per-reason bypass counts.
- If EQ is changed before tap creation, `AudioEngine` now persists settings and emits a throttled warning:
  - `[EQ] No active tap ... saved settings only`
- The periodic `[DIAG]` log now includes:
  - `eqBypassPct` = total EQ bypass percentage
  - `eqCfPct` = crossfade share of bypasses
