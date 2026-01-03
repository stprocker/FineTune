// FineTune/FineTuneApp.swift
import SwiftUI
import UserNotifications

@main
struct FineTuneApp: App {
    @State private var audioEngine: AudioEngine

    var body: some Scene {
        MenuBarExtra("FineTune", systemImage: "slider.horizontal.3") {
            MenuBarPopupView(audioEngine: audioEngine)
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        let settings = SettingsManager()
        _audioEngine = State(initialValue: AudioEngine(settingsManager: settings))

        // Request notification authorization (for device disconnect alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                print("Notification authorization error: \(error.localizedDescription)")
            }
            // If not granted, notifications will silently not appear - acceptable behavior
        }

        // Flush settings on app termination to prevent data loss from debounced saves
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [settings] _ in
            settings.flushSync()
        }
    }
}
