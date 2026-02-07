# Menu Bar Icon Unclickable on macOS 26 — Fix Session

**Date:** 2026-02-06
**Duration:** ~1 hour
**Status:** Working (confirmed by user)
**Commits:** 1.24 (b239330), 1.25 (6425b38), + uncommitted restoration of MenuBarStatusController.swift

---

## Problem

The FineTune menu bar icon was visible but completely unclickable on macOS 26.3 beta (Darwin 25.3.0). The app used `FluidMenuBarExtra` v1.5.1 (from `https://github.com/wadetregaskis/FluidMenuBarExtra`) which relies on `NSEvent.addLocalMonitorForEvents` to intercept clicks on the NSStatusItem button. This event delivery mechanism is broken on macOS 26.

## Root Cause Analysis

### Why FluidMenuBarExtra failed
`FluidMenuBarExtraStatusItem.swift:89` uses a `LocalEventMonitor` that calls `NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])`. The handler checks `event.window == button.window` to detect clicks on the status bar button. On macOS 26, these local events are no longer delivered for status bar button clicks, so the handler never fires.

The library hasn't been updated since June 2024 (last tag: 1.5.1) and has no macOS 26 compatibility fixes.

### Why the first NSStatusItem attempt (Codex) also failed
A Codex agent attempted a fix using direct `NSStatusItem` + `NSPopover`, but it had two critical issues:
1. **`button.sendAction(on: [.leftMouseUp, .rightMouseUp])`** — overrode the default `.leftMouseDown` mask. On macOS 26, status bar buttons need mouse DOWN to trigger actions; the system's menu tracking consumes events before mouse UP reaches the button.
2. **`NSPopover`** — unreliable from status bar buttons on macOS 26.

### Why the second NSStatusItem attempt still didn't register clicks from Xcode
The controller was being created in `SwiftUI App.init()` and started via `DispatchQueue.main.async`. When launched from Xcode (vs `open` command), the SwiftUI App lifecycle timing is different — the async dispatch may not reliably run, or the NSApplication run loop state differs during init.

## Solution (3 iterations)

### Iteration 1: Replace FluidMenuBarExtra with native MenuBarExtra (partial fix)
- Removed `import FluidMenuBarExtra`
- Changed to `MenuBarExtra("FineTune", image: "MenuBarIcon", isInserted: $showMenuBarExtra) { ... }.menuBarExtraStyle(.window)`
- Removed FluidMenuBarExtra from `project.pbxproj` and `Package.resolved`
- **Result:** Still didn't work on macOS 26

### Iteration 2: Direct NSStatusItem + NSPanel + action/target (partial fix)
- Created `MenuBarStatusController` with `NSStatusItem`, `button.action = #selector(...)`, `button.target = self`
- Used default `sendAction(on:)` (`.leftMouseDown`) — critical fix over Codex's `.leftMouseUp`
- Used `NSPanel` instead of `NSPopover`
- **Result:** Worked when launched via `open` command, but NOT from Xcode

### Iteration 3: NSApplicationDelegateAdaptor (final fix)
- Moved all initialization from `SwiftUI App.init()` to `AppDelegate.applicationDidFinishLaunching()`
- Used `@NSApplicationDelegateAdaptor(AppDelegate.self)` in the SwiftUI App struct
- This guarantees the NSApplication run loop is fully active when the status item is created
- **Result:** Works from both Xcode and `open` command

### Additional fixes during iteration:
- **`KeyablePanel` subclass:** `NSPanel` with `.nonactivatingPanel` returns `false` from `canBecomeKey` by default. Overrode with `override var canBecomeKey: Bool { true }` to enable proper key window status and dismiss-on-deactivate behavior.
- **Panel size fallback:** `NSHostingView.fittingSize` can return zero before SwiftUI layout. Added fallback minimum size (320x400) and forced layout before display.
- **Right-click context menu:** Detects `.rightMouseDown` or Ctrl+click, temporarily assigns an `NSMenu` to the status item, triggers `performClick`, then removes the menu so left-click continues to use the action handler.

## Files Changed

### `FineTune/FineTuneApp.swift` (rewritten)
**Before:** SwiftUI `App.init()` created AudioEngine, SettingsManager, and used `FluidMenuBarExtra` scene. All lifecycle management in init closures.
**After:** Minimal SwiftUI App struct with `@NSApplicationDelegateAdaptor(AppDelegate.self)`. New `AppDelegate` class handles:
- AudioEngine + SettingsManager creation in `applicationDidFinishLaunching`
- SingleInstanceGuard check
- MenuBarStatusController creation and start
- Cleanup in `applicationWillTerminate`

### `FineTune/Views/MenuBar/MenuBarStatusController.swift` (new file)
Complete AppKit-based menu bar controller:
- `NSStatusItem` with `NSStatusItem.squareLength`
- `MenuBarIcon` asset as template image
- Left-click: toggle `KeyablePanel` popup containing `MenuBarPopupView`
- Right-click: context menu with "Quit FineTune"
- Panel positioning below status item with screen-edge clamping
- Global event monitor for outside-click dismissal
- `NSWindowDelegate.windowDidResignKey` for deactivation dismissal
- `KeyablePanel` subclass for proper key window behavior

### `FineTune.xcodeproj/project.pbxproj` (modified)
Removed all FluidMenuBarExtra references:
- PBXBuildFile section
- PBXFrameworksBuildPhase section
- packageProductDependencies
- packageReferences
- XCRemoteSwiftPackageReference section
- XCSwiftPackageProductDependency section

### `CHANGELOG.md` (updated)
Added entry under `[Unreleased]` documenting the FluidMenuBarExtra replacement.

## Diagnostic Approach

1. **Explored FluidMenuBarExtra source** (in Xcode DerivedData) — identified event monitor click detection mechanism
2. **Checked macOS version** (26.3 beta) and package age (last update June 2024) — confirmed compatibility gap
3. **Checked GitHub issues/releases** — no macOS 26 fixes available
4. **Used system `log` command** to verify:
   - Status item creation: `log show --process FineTune --info` confirmed `"Menu bar status item created"`
   - Click delivery: `log stream` confirmed `"Status bar button clicked"` on each click
   - Panel warnings: `"Warning: -[NSWindow makeKeyWindow] called on <NSPanel> which returned NO from -[NSWindow canBecomeKeyWindow]"` — led to KeyablePanel fix
5. **Compared Xcode launch vs `open` launch** — identified the SwiftUI App.init() lifecycle timing issue

## Architecture Decision: Why Not Native MenuBarExtra?

Apple's `MenuBarExtra` with `.menuBarExtraStyle(.window)` was tried first but didn't work on macOS 26. The direct AppKit approach (`NSStatusItem` + `NSPanel`) gives full control over:
- Click event handling (action/target vs event monitors)
- Panel window type and behavior
- Key window management
- Right-click context menus

---

## TODO List

### High Priority
- [ ] **Remove debug `.error` level logging:** `FineTuneApp.swift` lines 17, 44, 48 use `logger.error()` for debug messages (`[APPDELEGATE] applicationDidFinishLaunching fired`, etc.). These should be changed to `logger.info()` or removed before release.
- [ ] **Panel visual styling:** The popup panel uses `NSPanel` with clear background. Verify that `MenuBarPopupView`'s `.darkGlassBackground()` renders correctly in the panel (NSVisualEffectView with `.behindWindow` blending). If the glass effect is missing, may need to add an `NSVisualEffectView` as the panel's content view wrapper (similar to how FluidMenuBarExtraWindow did it).
- [ ] **Panel resize on content change:** When apps start/stop playing audio, the popup content changes height. The panel doesn't auto-resize. Need to observe content size changes via `NSHostingView` and call `setFrame(_:display:animate:)`. FluidMenuBarExtra had this via `onSizeUpdate` + `RootViewModifier`.
- [ ] **Verify right-click context menu works:** The `showContextMenu(from:)` method uses a temporary `statusItem.menu` assignment + `performClick(nil)` pattern. This needs testing — if it doesn't work, alternative is to use `NSMenu.popUp(positioning:at:in:)` directly.

### Medium Priority
- [ ] **Escape key to dismiss:** The panel should dismiss on Escape keypress. Add a local event monitor for `.keyDown` checking `event.keyCode == 53`.
- [ ] **Panel dismiss animation:** Currently uses instant `orderOut(nil)`. FluidMenuBarExtra had a 0.3s fade-out animation. Consider adding `NSAnimationContext.runAnimationGroup` with `animator().alphaValue = 0`.
- [ ] **Full-screen menu bar persistence:** FluidMenuBarExtra posted `com.apple.HIToolbox.beginMenuTrackingNotification` / `endMenuTrackingNotification` to persist the menu bar in full-screen mode. This is not implemented in the new controller.
- [ ] **PopoverHost child windows:** `PopoverHost.swift` creates child `NSPanel` windows for device picker dropdowns. Verify these still work correctly when the parent is a `KeyablePanel` instead of FluidMenuBarExtra's window.
- [ ] **Test cleanup:** Integration tests `DefaultDeviceBehaviorTests` and `StartupAudioInterruptionTests` have pre-existing failures unrelated to this change. These should be investigated separately.

### Low Priority
- [ ] **Remove FluidMenuBarExtra from Package.resolved:** The `Package.resolved` in `FineTune.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/` may still reference FluidMenuBarExtra indirectly. Run `xcodebuild -resolvePackageDependencies` to clean it up.
- [ ] **Update README.md and AGENTS.md:** These files still mention FluidMenuBarExtra. Update to reflect the new architecture.
- [ ] **Consider extracting KeyablePanel:** If `KeyablePanel` is useful elsewhere, consider moving it to a shared utilities location.

## Known Issues

1. **macOS 26 beta only:** This fix was developed and tested on macOS 26.3 beta. The original FluidMenuBarExtra approach may still work fine on macOS 14/15. If backward compatibility is needed, could conditionally use FluidMenuBarExtra on older OS versions.

2. **Panel sizing:** `NSHostingView.fittingSize` may return zero on first creation if SwiftUI hasn't laid out the view. The fallback size (320x400) is hardcoded. If `DesignTokens.Dimensions.popupWidth` changes, this fallback should be updated.

3. **Ghost status items:** If the app crashes or is force-killed (not cleanly terminated), the status item icon can linger in the menu bar as a "ghost" that doesn't respond to clicks. This is a macOS-level issue, not specific to our implementation. Clicking elsewhere in the menu bar area usually clears ghost icons.

4. **SingleInstanceGuard + Debug plist:** `Info-Debug.plist` does NOT have `LSMultipleInstancesProhibited = true` (unlike the release `Info.plist`). This means multiple debug instances can run simultaneously. `SingleInstanceGuard` handles this by terminating the new instance, but during rapid Xcode re-launches, race conditions can leave ghost icons.

5. **`canBecomeKey` warning resolved but behavior needs verification:** The `KeyablePanel` subclass resolves the `"Warning: -[NSWindow makeKeyWindow] called on <NSPanel> which returned NO from -[NSWindow canBecomeKeyWindow]"` message. However, making the panel key means it will steal keyboard focus from other apps. This is the expected behavior for menu bar popups, but should be verified that it doesn't interfere with the user's workflow.

6. **No `windowDidResignKey` delegate set in commit 1.24:** The original commit 1.24 version of the controller had `panel.delegate = self` missing from `createPanel()`. The restored version includes it, but this should be verified.
