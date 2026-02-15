# EQ Gain Impact + Limiter Threshold Session (2026-02-15)

## User Request
- Keep planning-focused initially (no code), then implement after approval.
- Address two concerns:
  1. Clarify that EQ slider values are not overall loudness dB.
  2. Make EQ sliders more audible.
- Apply all planned changes, but no separate mode.
- Raise limiter default slightly.

## Implemented Work Product
1. Fail-first tests were updated first for new expected defaults.
2. Core EQ and limiter defaults were changed.
3. EQ UI text was clarified for units.
4. Targeted test runs were executed pre-change (failing) and post-change (passing).

## Files Changed
- `FineTune/Models/EQSettings.swift`
- `FineTune/Audio/BiquadMath.swift`
- `FineTune/Audio/Processing/SoftLimiter.swift`
- `FineTune/Views/EQSliderView.swift`
- `FineTune/Views/EQPanelView.swift`
- `testing/tests/EQSettingsTests.swift`
- `testing/tests/BiquadMathTests.swift`
- `testing/tests/SoftLimiterTests.swift`
- `docs/architecture/finetune-architecture.md`
- `docs/known_issues/eq-panel-no-audible-change-troubleshooting.md`
- `CHANGELOG.md`

## Behavior Changes
- EQ band gain range: `±12 dB` -> `±18 dB`.
- Graphic EQ Q: `1.4` -> `1.8`.
- Soft limiter threshold: `0.8` -> `0.9` (ceiling remains `1.0`).
- EQ panel text now states `Band Gain (dB)`.
- EQ slider drag label now formats values with explicit spacing: `+6 dB`.

## Validation
- Fail-first verification (before code changes):
  - `swift test --filter 'FineTuneCoreTests\.(EQSettingsTests|BiquadMathTests|SoftLimiterTests)'`
  - Result: expected failures on updated constants/ranges.
- Post-implementation verification:
  - `swift test --filter 'FineTuneCoreTests\.(EQSettingsTests|BiquadMathTests|SoftLimiterTests|PostEQLimiterTests)'`
  - Result: all selected tests passed.
