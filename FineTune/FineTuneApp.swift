// FineTune/FineTuneApp.swift
import SwiftUI
import UserNotifications
import ScreenCaptureKit
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
    private var onboardingController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("[APPDELEGATE] applicationDidFinishLaunching fired")

        // FIRST: bail immediately if another instance is running.
        // Must happen before OrphanedTapCleanup, which would destroy
        // the running instance's live aggregate devices.
        if SingleInstanceGuard.shouldTerminateCurrentInstance() {
            logger.warning("Another FineTune instance detected; terminating this process.")
            NSApplication.shared.terminate(nil)
            return
        }

        // Clean up any orphaned aggregate devices from a previous crash,
        // then install crash signal handlers for this session
        OrphanedTapCleanup.destroyOrphanedDevices()
        CrashGuard.install()

        let settings = SettingsManager()
        self.settings = settings

        installSignalHandlers()

        // Request notification authorization (for device disconnect alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
        }

        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        let skipOnboarding = CommandLine.arguments.contains("--skip-onboarding")

        if !settings.appSettings.onboardingCompleted && !skipOnboarding {
            logger.info("[APPDELEGATE] Showing onboarding window")
            let controller = OnboardingWindowController { [weak self] in
                guard let self, let settings = self.settings else { return }
                var appSettings = settings.appSettings
                appSettings.onboardingCompleted = true
                settings.updateAppSettings(appSettings)
                self.onboardingController = nil
                logger.info("[APPDELEGATE] Onboarding completed")
                self.createAndStartAudioEngine(settings: settings)
            }
            self.onboardingController = controller
            controller.show()
        } else {
            createAndStartAudioEngine(settings: settings)
        }
    }

    private func createAndStartAudioEngine(settings: SettingsManager) {
        // Check permission BEFORE creating the engine (engine init triggers tap creation)
        let hasAccess = CGPreflightScreenCaptureAccess()
        logger.info("[APPDELEGATE] Screen capture permission: \(hasAccess)")

        if !hasAccess && settings.appSettings.onboardingCompleted {
            // User completed onboarding but permission is missing — show our alert
            // instead of letting CoreAudio trigger the system dialog
            let alert = NSAlert()
            alert.messageText = "Audio Permission Required"
            alert.informativeText = "FineTune needs the \"Screen & System Audio Recording\" permission to capture and control per-app audio.\n\nPlease enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch FineTune."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Continue Anyway")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        let engine = AudioEngine(settingsManager: settings)
        self.audioEngine = engine

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
