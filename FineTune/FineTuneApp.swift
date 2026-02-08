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
    private var signalSources: [any DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("[APPDELEGATE] applicationDidFinishLaunching fired")

        // Clean up any orphaned aggregate devices from a previous crash,
        // then install crash signal handlers for this session
        OrphanedTapCleanup.destroyOrphanedDevices()
        CrashGuard.install()

        let settings = SettingsManager()
        let engine = AudioEngine(settingsManager: settings)
        self.settings = settings
        self.audioEngine = engine

        installSignalHandlers()

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
        logger.info("[APPDELEGATE] menuBarController started")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let audioEngine else {
            logger.warning("[APPDELEGATE] URL received before audioEngine initialized")
            return
        }
        let urlHandler = URLHandler(audioEngine: audioEngine)
        for url in urls {
            urlHandler.handleURL(url)
        }
    }

    /// Installs POSIX signal handlers for SIGTERM and SIGINT so that `kill <pid>`
    /// and Ctrl+C trigger a clean shutdown (destroying process taps before exit).
    /// `kill -9` is uncatchable — startup cleanup handles that case.
    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in
            self?.audioEngine?.stopSync()
            exit(0)
        }
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [weak self] in
            self?.audioEngine?.stopSync()
            exit(0)
        }
        intSource.resume()

        signalSources = [termSource, intSource]
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("[APPDELEGATE] applicationWillTerminate")
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
