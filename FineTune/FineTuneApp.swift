// FineTune/FineTuneApp.swift
import SwiftUI
import UserNotifications
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "App")

@main
struct FineTuneApp: App {
    @State private var audioEngine: AudioEngine
    @State private var menuBarController: MenuBarStatusController

    var body: some Scene {
        Settings { EmptyView() }
    }

    init() {
        let settings = SettingsManager()
        let engine = AudioEngine(settingsManager: settings)
        let controller = MenuBarStatusController(audioEngine: engine)

        _audioEngine = State(initialValue: engine)
        _menuBarController = State(initialValue: controller)

        if SingleInstanceGuard.shouldTerminateCurrentInstance() {
            logger.warning("Another FineTune instance detected; terminating this process.")
            DispatchQueue.main.async {
                controller.stop()
                engine.stopSync()
                settings.flushSync()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // DeviceVolumeMonitor is now created and started inside AudioEngine
        // This ensures proper initialization order: deviceMonitor.start() -> deviceVolumeMonitor.start()

        // Request notification authorization (for device disconnect alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            // If not granted, notifications will silently not appear - acceptable behavior
        }

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            DispatchQueue.main.async {
                controller.start()
            }
        }

        // Clean up audio engine and flush settings on app termination
        // CRITICAL: Must stop audio engine to remove CoreAudio property listeners
        // Orphaned listeners can corrupt coreaudiod state and break System Settings
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [engine, settings, controller] _ in
            MainActor.assumeIsolated {
                controller.stop()
            }
            // Stop audio engine first to remove all CoreAudio listeners
            engine.stopSync()
            // Then flush settings to prevent data loss from debounced saves
            settings.flushSync()
        }
    }
}
