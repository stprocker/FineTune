// FineTune/Views/MenuBarPopupViewModel.swift
import AppKit
import Foundation
import SwiftUI

/// Manages presentation state for MenuBarPopupView.
///
/// Owns EQ expansion state, animation debounce, popup visibility tracking,
/// device sorting, and app activation — keeping the view purely presentational.
@Observable
@MainActor
final class MenuBarPopupViewModel {
    let audioEngine: AudioEngine
    let deviceVolumeMonitor: DeviceVolumeMonitor

    /// Which app has its EQ panel expanded (only one at a time).
    /// Uses String (DisplayableApp.id / persistenceIdentifier) to work with both active and inactive apps.
    var expandedEQAppID: String?

    /// Debounce EQ toggle to prevent rapid clicks during animation.
    private(set) var isEQAnimating = false

    /// Track popup visibility to pause VU meter polling when hidden.
    var isPopupVisible = true

    /// Which device tab is selected (false = output, true = input)
    var showingInputDevices = false

    /// Track whether settings panel is open
    var isSettingsOpen = false

    /// Debounce settings toggle to prevent rapid clicks during animation
    private(set) var isSettingsAnimating = false

    /// Local copy of app settings for binding
    var localAppSettings: AppSettings = AppSettings()

    /// Update manager for Sparkle integration
    let updateManager: UpdateManager

    /// Callback to update the menu bar icon live (wired by MenuBarStatusController)
    var onIconChanged: ((MenuBarIconStyle) -> Void)?

    init(audioEngine: AudioEngine, deviceVolumeMonitor: DeviceVolumeMonitor) {
        self.audioEngine = audioEngine
        self.deviceVolumeMonitor = deviceVolumeMonitor
        self.updateManager = UpdateManager()
        self.localAppSettings = audioEngine.settingsManager.appSettings
    }

    // MARK: - Settings Toggle

    /// Toggles the settings panel with animation debounce.
    func toggleSettings() {
        guard !isSettingsAnimating else { return }
        isSettingsAnimating = true

        isSettingsOpen.toggle()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.isSettingsAnimating = false
        }
    }

    /// Syncs local app settings back to the settings manager.
    func syncSettings() {
        audioEngine.settingsManager.updateAppSettings(localAppSettings)
    }

    // MARK: - EQ Toggle

    /// Toggles EQ expansion for the given app with animation debounce.
    /// Returns the app ID to scroll to (if expanding), or nil.
    func toggleEQ(for appID: String) -> String? {
        guard !isEQAnimating else { return nil }
        isEQAnimating = true

        let isExpanding = expandedEQAppID != appID
        if expandedEQAppID == appID {
            expandedEQAppID = nil
        } else {
            expandedEQAppID = appID
        }

        // Re-enable after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.isEQAnimating = false
        }

        return isExpanding ? appID : nil
    }

    // MARK: - Device Sorting

    /// Output devices sorted with the default device first, then alphabetically.
    var sortedDevices: [AudioDevice] {
        let devices = audioEngine.outputDevices
        let defaultID = deviceVolumeMonitor.defaultDeviceID
        return devices.sorted { lhs, rhs in
            if lhs.id == defaultID { return true }
            if rhs.id == defaultID { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Input devices sorted with the default input device first, then alphabetically.
    var sortedInputDevices: [AudioDevice] {
        let devices = audioEngine.inputDevices
        let defaultID = deviceVolumeMonitor.defaultInputDeviceID
        return devices.sorted { lhs, rhs in
            if lhs.id == defaultID { return true }
            if rhs.id == defaultID { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Default Device Names

    /// Name of the current default output device
    var defaultOutputDeviceName: String {
        guard let uid = deviceVolumeMonitor.defaultDeviceUID,
              let device = sortedDevices.first(where: { $0.uid == uid }) else {
            return "No Output"
        }
        return device.name
    }

    /// Name of the current default input device
    var defaultInputDeviceName: String {
        guard let uid = deviceVolumeMonitor.defaultInputDeviceUID,
              let device = sortedInputDevices.first(where: { $0.uid == uid }) else {
            return "No Input"
        }
        return device.name
    }

    // MARK: - App Activation

    /// Activates an app, bringing it to foreground and restoring minimized windows.
    func activateApp(pid: pid_t, bundleID: String?) {
        let runningApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        runningApp?.activate()

        if let bundleID {
            let script = NSAppleScript(source: """
                tell application id "\(bundleID)"
                    reopen
                    activate
                end tell
                """)
            script?.executeAndReturnError(nil)
        }
    }
}
