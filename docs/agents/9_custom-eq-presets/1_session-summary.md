# Custom EQ Presets (Max 5) Session (2026-02-15)

## Scope
Implemented user-requested custom EQ preset support (no mode switch), with global storage and a hard cap of 5 presets.

## Key Decisions
- Presets are global (shared across apps), not per-app.
- Matching precedence for UI label/checkmark:
  1. Built-in preset exact match
  2. Custom preset exact match
  3. Unsaved `Custom`
- At capacity (5/5), save-new routes to overwrite flow.

## Implementation Summary
1. Added `CustomEQPreset` model and `EQPresetSelection` resolver logic.
2. Extended `SettingsManager` with custom preset CRUD + validation (name required, max length, duplicate prevention, limit enforcement).
3. Wired `MenuBarPopupViewModel` to expose and mutate custom presets.
4. Reworked `EQPresetPicker` to include:
   - Built-in section
   - Custom section with count
   - Action rows: Save/Overwrite/Rename/Delete
5. Reworked `EQPanelView` to handle custom preset actions and dialogs.
6. Updated `AppRow`, `InactiveAppRow`, and `MenuBarPopupView` to pass custom preset state/actions through.

## Tests (Fail-First Then Pass)
- Added/expanded `SettingsManagerRoutingTests` for:
  - save up to 5
  - sixth save rejected
  - overwrite behavior
  - rename duplicate rejection
  - delete behavior
  - persistence round-trip
  - legacy settings decode without custom preset key
  - selection precedence
- Validation commands:
  - `swift test --filter SettingsManagerRoutingTests`
  - `swift test`
  - `xcodebuild -project finetune_fork.xcodeproj -scheme FineTune -configuration Debug -sdk macosx build`

## Result
- Full test suite passed (`359` tests, `0` failures).
- App target builds successfully in Debug.
