# Agent 5: Phase 5A - URL Scheme API

**Agent ID:** a4619fe
**Date:** 2026-02-07
**Task:** Implement `finetune://` URL scheme with 6 actions and plist registration

---

## Files Modified

### 1. Info.plist

Added `CFBundleURLTypes` to register the `finetune://` URL scheme:
```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>finetune</string>
        </array>
        <key>CFBundleURLName</key>
        <string>com.finetuneapp.FineTune</string>
    </dict>
</array>
```

### 2. Info-Debug.plist

Same `CFBundleURLTypes` addition for debug builds.

### 3. FineTuneApp.swift

Added `func application(_ application: NSApplication, open urls: [URL])` to `AppDelegate`:
- Guards against `audioEngine` being nil
- Creates `URLHandler` instance with the existing `audioEngine` reference
- Iterates over all received URLs and handles each one

---

## New Files

### 4. URLHandler.swift (NEW)

`@MainActor final class URLHandler` with `AudioEngine` dependency and `Logger`.

**URL format:** `finetune://<action>?<params>`

**6 actions implemented:**

| Action | Description | Example |
|--------|-------------|---------|
| `set-volumes` | Set volume for specific apps | `finetune://set-volumes?app=com.spotify&volume=80` |
| `step-volume` | Increment/decrement by 5% | `finetune://step-volume?app=com.spotify&direction=up` |
| `set-mute` | Set mute state | `finetune://set-mute?app=com.spotify&muted=true` |
| `toggle-mute` | Toggle mute | `finetune://toggle-mute?app=com.spotify` |
| `set-device` | Route app to device | `finetune://set-device?app=com.spotify&device=<UID>` |
| `reset` | Reset volume/mute | `finetune://reset` or `finetune://reset?app=com.spotify` |

**Key design decisions:**
- Volume range 0-200 (capped at local max boost, not upstream's 400)
- Linear mapping: `volume=100` -> gain `1.0`, `volume=200` -> gain `2.0`
- `step-volume` uses local `VolumeMapping.gainToSlider`/`sliderToGain` dB curve
- Inactive app handling falls back to `settingsManager` directly for persistence
- App lookup via `persistenceIdentifier` (which is `bundleID` or `"name:<appName>"`)
- `parseBool(_:)` handles `true`/`false`, `1`/`0`, `yes`/`no` (case-insensitive)

## Build Result

URLHandler.swift compiled successfully. Pre-existing errors in AudioDeviceMonitor.swift (referencing `suggestedInputIconSymbol`) were unrelated and resolved by another agent.
