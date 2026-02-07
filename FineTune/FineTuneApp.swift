// FineTune/FineTuneApp.swift
import SwiftUI
import UserNotifications
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "App")

/// AppDelegate handles menu bar setup via NSApplicationDelegateAdaptor.
/// This ensures the NSStatusItem is created through the standard AppKit lifecycle,
/// which is more reliable than DispatchQueue.main.async from a SwiftUI App.init().
final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarStatusController?
    var audioEngine: AudioEngine?
    private var settings: SettingsManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.error("[APPDELEGATE] applicationDidFinishLaunching fired")

        let settings = SettingsManager()
        let engine = AudioEngine(settingsManager: settings)
        self.settings = settings
        self.audioEngine = engine

        if SingleInstanceGuard.shouldTerminateCurrentInstance() {
            logger.warning("Another FineTune instance detected; terminating this process.")
            engine.stopSync()
            settings.flushSync()
            NSApplication.shared.terminate(nil)
            return
        }

        // Request notification authorization (for device disconnect alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
        }

        // Create and start menu bar status item
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let controller = MenuBarStatusController(audioEngine: engine)
        controller.start()
        self.menuBarController = controller
        logger.error("[APPDELEGATE] menuBarController started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.error("[APPDELEGATE] applicationWillTerminate")
        menuBarController?.stop()
        audioEngine?.stopSync()
        settings?.flushSync()
    }
}

@main
struct FineTuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
