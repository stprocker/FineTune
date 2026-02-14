# Agent 4: Phase 4A - Pinned Apps + DisplayableApp

**Agent ID:** a5d22d0
**Date:** 2026-02-07
**Task:** Implement pinned apps with inactive app settings, DisplayableApp model, and UI integration

---

## New Files

### 1. DisplayableApp.swift (NEW)

Enum `DisplayableApp: Identifiable` with two cases:
- `.active(AudioApp)` -- currently running audio apps
- `.pinnedInactive(PinnedAppInfo)` -- pinned apps not currently running

Computed properties:
- `id: String` -- returns `persistenceIdentifier` for both cases
- `displayName: String` -- app name from either case
- `icon: NSImage` -- resolves from bundle ID via `NSWorkspace` with fallback to generic app icon
- `isPinnedInactive: Bool` / `isActive: Bool` -- case introspection

### 2. InactiveAppRow.swift (NEW)

Mirrors local `AppRow` styling but adapted for inactive apps:
- Takes `PinnedAppInfo` + `NSImage` instead of `AudioApp`
- Star button always filled (`star.fill`), action = unpin
- App icon at 0.6 opacity, name in `textSecondary` color
- VU meter always at level 0
- Same control bar: `MuteButton`, `LiquidGlassSlider`, percentage, `VUMeter`, `DevicePicker`, `AppRowEQToggle`
- Uses `ExpandableGlassRow` for EQ panel expansion (matching local pattern)
- Includes `autoUnmuteOnSliderMove` modifier

---

## Files Modified

### 3. AudioEngine.swift

Added sections after existing `displayedApps` property (preserved for backward compatibility):

**displayableApps computed property:**
Sort order: pinned-active (alphabetical) -> pinned-inactive (alphabetical) -> unpinned-active (alphabetical)

**Pinning methods:**
- `pinApp(_ app: AudioApp)` -- creates `PinnedAppInfo` and delegates to `settingsManager`
- `unpinApp(_ identifier: String)` -- delegates to `settingsManager`
- `isPinned(_ app: AudioApp) -> Bool`
- `isPinned(identifier: String) -> Bool`

**Inactive App Settings methods (all delegate to settingsManager):**
- `getVolumeForInactive(identifier:) -> Float`
- `setVolumeForInactive(identifier:to:)`
- `getMuteForInactive(identifier:) -> Bool`
- `setMuteForInactive(identifier:to:)`
- `getEQSettingsForInactive(identifier:) -> EQSettings`
- `setEQSettingsForInactive(_:identifier:)`
- `getDeviceRoutingForInactive(identifier:) -> String?`
- `setDeviceRoutingForInactive(identifier:deviceUID:)`

### 4. AppRow.swift (+79 lines)

- Added `isPinned: Bool` and `onPinToggle: () -> Void` properties
- Added `isRowHovered` and `isPinButtonHovered` state
- Added `pinButtonColor` computed property: filled when pinned, hover color when hovered, subtle when row hovered, clear otherwise
- Added star button (star.fill when pinned, star when not) left of app icon with scale animation on hover
- Added `.onHover { isRowHovered = $0 }` on the row frame
- Updated `AppRowWithLevelPolling` to pass through pin props

### 5. MenuBarPopupView.swift

- Empty state / scroll threshold checks changed from `displayedApps` to `displayableApps`
- `ForEach` replaced with `ForEach(audioEngine.displayableApps)` + `switch` pattern matching
- Added `activeAppRow(app:displayableApp:scrollProxy:)` method
- Added `inactiveAppRow(info:displayableApp:scrollProxy:)` method
- Both use `displayableApp.id` (String) for EQ expansion and scroll targets
- Pin toggle for active: toggles between `pinApp` and `unpinApp`

### 6. MenuBarPopupViewModel.swift

- `expandedEQAppID` changed from `pid_t?` to `String?` to work with both active PIDs and inactive persistence identifiers
- `toggleEQ(for:)` parameter changed from `pid_t` to `String`

## Build Result

BUILD SUCCEEDED -- 17 files changed, +1,644/-172 lines.
