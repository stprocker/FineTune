# EQ Panel Shows No Audible Change (Troubleshooting)

## Status
Open (diagnostics added on 2026-02-14; missing-tap persistence fix added on 2026-02-14)

## Observed Behavior
Users may move EQ sliders or select an EQ preset and hear no change.

## Likely Runtime Causes
1. EQ is disabled for that app (`isEnabled == false`).
2. No tap exists yet for the app PID, so realtime EQ apply is skipped until tap creation.
3. Crossfade is active during device switching, temporarily bypassing EQ.
4. Input format path is not eligible for direct EQ and converter path is not reached due upstream conditions.

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
