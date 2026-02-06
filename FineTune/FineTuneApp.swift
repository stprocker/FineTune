// FineTune/FineTuneApp.swift
import SwiftUI
import UserNotifications
import FluidMenuBarExtra
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "App")

@main
struct FineTuneApp: App {
    @State private var audioEngine: AudioEngine
    @State private var showMenuBarExtra = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    var body: some Scene {
        FluidMenuBarExtra("FineTune", image: "MenuBarIcon", isInserted: $showMenuBarExtra, menu: Self.createContextMenu()) {
            MenuBarPopupView(
                audioEngine: audioEngine,
                deviceVolumeMonitor: audioEngine.deviceVolumeMonitor
            )
        }

        Settings { EmptyView() }
    }

    private static func createContextMenu() -> NSMenu {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit FineTune", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }

    init() {
        let settings = SettingsManager()
        let engine = AudioEngine(settingsManager: settings)
        _audioEngine = State(initialValue: engine)

        if SingleInstanceGuard.shouldTerminateCurrentInstance() {
            logger.warning("Another FineTune instance detected; terminating this process.")
            DispatchQueue.main.async {
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

        // Clean up audio engine and flush settings on app termination
        // CRITICAL: Must stop audio engine to remove CoreAudio property listeners
        // Orphaned listeners can corrupt coreaudiod state and break System Settings
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [engine, settings] _ in
            // Stop audio engine first to remove all CoreAudio listeners
            engine.stopSync()
            // Then flush settings to prevent data loss from debounced saves
            settings.flushSync()
        }
    }
}
