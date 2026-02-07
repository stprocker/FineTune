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
    var expandedEQAppID: pid_t?

    /// Debounce EQ toggle to prevent rapid clicks during animation.
    private(set) var isEQAnimating = false

    /// Track popup visibility to pause VU meter polling when hidden.
    var isPopupVisible = true

    init(audioEngine: AudioEngine, deviceVolumeMonitor: DeviceVolumeMonitor) {
        self.audioEngine = audioEngine
        self.deviceVolumeMonitor = deviceVolumeMonitor
    }

    // MARK: - EQ Toggle

    /// Toggles EQ expansion for the given app with animation debounce.
    /// Returns the app ID to scroll to (if expanding), or nil.
    func toggleEQ(for appID: pid_t) -> pid_t? {
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

    /// Devices sorted with the default device first, then alphabetically.
    var sortedDevices: [AudioDevice] {
        let devices = audioEngine.outputDevices
        let defaultID = deviceVolumeMonitor.defaultDeviceID
        return devices.sorted { lhs, rhs in
            if lhs.id == defaultID { return true }
            if rhs.id == defaultID { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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
