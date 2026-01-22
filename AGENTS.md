# AGENTS.md  ──  Ground Rules for AI Assistants

# Applies to: Claude / Gemini / Codex CLIs, Cursor / Windsurf IDEs, etc

──────────────────────────────────────────────────────────────────────────────

1. PROJECT INFO
──────────────────────────────────────────────────────────────────────────────

  A. Executive Summary

    1. FineTune is a per-application audio control utility for macOS.
    2. It enables granular control over volume levels for individual running apps,
       routing specific apps to different output devices, and applying 10-band EQ settings.
    3. It runs as a menu bar application with a "Glassmorphic" native macOS UI.

  B. Architecture Summary

    1. Entry Point: `FineTune/FineTuneApp.swift`
    2. UI Framework: SwiftUI with `FluidMenuBarExtra` for the menubar window.
    3. Core Logic:
       - Audio routing and volume control via `CoreAudio` and `AudioToolbox`.
       - Data models and settings persistence in `FineTune/Settings/` & `FineTune/Models/`.
       - Views distributed under `FineTune/Views/`.

  C. Dependencies and System Integrations

    1. External Dependencies
       - FluidMenuBarExtra (Swift Package): For window-based menu bar experience.

    2. System Frameworks
       - CoreAudio: Low-level audio hardware interaction.
       - AudioToolbox: Audio session management.
       - AVFoundation: Higher-level audio handling.
       - SwiftUI: User Interface.
       - Combine: Reactive programming for audio state updates.

──────────────────────────────────────────────────────────────────────────────
2.  AGENT BEHAVIOR
──────────────────────────────────────────────────────────────────────────────
  A.  **Prohibited without express permission**

    1. Removing/replacing dependencies (FluidMenuBarExtra) or system frameworks.
    2. Replacing native SwiftUI components with non-native looking custom views unless strictly required for specific "Glassmorphic" designs.
    3. Adding code that requires online access.
    4. Hard-coding audio device IDs or app bundle IDs (must be dynamic).
    5. Editing AGENTS.MD file other than "1.  PROJECT INFO" section.

  B.  **Before you generate new code**

    1. Fully understand the Swift/SwiftUI context and existing View hierarchy.
    2. Check `FineTune/Utilities` for existing helpers (e.g., audio wrappers).
    3. Confirm whether a native SwiftUI view modifier exists before writing custom layouts.

  C.  **After generating new code**

    1. Ensure Swift code is formatted (standard Swift linting rules).
    2. Check that new Views respect the "Glassmorphic" design system (translucency, blur materials).
    3. Ensure clean separation between View and ViewModel/Model logic.
    4. Verify that strings are localized or localizable.

──────────────────────────────────────────────────────────────────────────────
3.  CODING STANDARDS
──────────────────────────────────────────────────────────────────────────────

  A. Code Style & Structure

    1. Follow standard Swift API Design Guidelines.
    2. Use `camelCase` for variables/functions, `PascalCase` for types.
    3. Prefer `struct` for Views and Models; `class` for Observables/ViewModels.
    4. Use `private`/`fileprivate` access control to limit scope where possible.
    5. Avoid forced unwrapping (`!`)—use `guard let`, `if let`, or default values.

  B. SwiftUI & UI Code

    1. Prefer `NavigationStack` or `NavigationSplitView` for hierarchy.
    2. Use `@State`, `@Binding`, `@ObservedObject`/`@StateObject` correctly to manage data flow.
    3. Keep `body` properties concise; extract subviews into separate structs or properties.
    4. Use standard SF Symbols for iconography.
    5. Implement Dark Mode support (FineTune is Dark Mode first).

  C. Reference Ordering Rules
    1. Views should depend on ViewModels/Models.
    2. Models should not import Views.
    3. Core Audio logic should be encapsulated in Managers/Services, not directly in Views.

──────────────────────────────────────────────────────────────────────────────
4.  PROJECT-SPECIFIC INSTRUCTIONS
──────────────────────────────────────────────────────────────────────────────

  A. Technical Documentation (Apple)

    1. Core Audio:
       [Core Audio Documentation](https://developer.apple.com/documentation/coreaudio)
       - Primary resource for low-level audio graph and HAL (Hardware Abstraction Layer) manipulation.

    2. AVFoundation:
       [AVFoundation Documentation](https://developer.apple.com/documentation/avfoundation)
       - For higher-level audio session management if applicable.

    3. AudioToolbox:
       [AudioToolbox Documentation](https://developer.apple.com/documentation/audiotoolbox)

  B. Design Philosophy

    1. **Aesthetics First**: The app must look "Premium" and "Glassmorphic".
    2. **Animations**: Use fluid transitions (e.g., `.animation(.spring(), value: ...)`).
    3. **Native Feel**: It should feel like a part of macOS Control Center.

  C. Development Notes

    1. Audio Permissions: The app requires Microphone access to monitor system audio levels.
    2. Testing: Verify audio routing changes by actually checking system output (if possible to verify via script, otherwise manual).
