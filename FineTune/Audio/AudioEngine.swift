// FineTune/Audio/AudioEngine.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

@Observable
@MainActor
final class AudioEngine {
    let processMonitor = AudioProcessMonitor()
    let deviceMonitor = AudioDeviceMonitor()
    let deviceVolumeMonitor: DeviceVolumeMonitor
    let volumeState: VolumeState
    let settingsManager: SettingsManager
    private let defaultOutputDeviceUIDProvider: () throws -> String

    private var taps: [pid_t: ProcessTapController] = [:]
    private var appliedPIDs: Set<pid_t> = []
    private(set) var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private var switchTasks: [pid_t: Task<Void, Never>] = [:]  // In-flight device switch tasks (prevents concurrent switches)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioEngine")
    /// Test-only hook for observing tap-creation attempts.
    var onTapCreationAttemptForTests: ((AudioApp, String) -> Void)?

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    init(
        settingsManager: SettingsManager? = nil,
        defaultOutputDeviceUIDProvider: @escaping () throws -> String = { try AudioDeviceID.readDefaultOutputDeviceUID() }
    ) {
        let manager = settingsManager ?? SettingsManager()
        self.settingsManager = manager
        self.defaultOutputDeviceUIDProvider = defaultOutputDeviceUIDProvider
        self.volumeState = VolumeState(settingsManager: manager)
        self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: deviceMonitor)

        // Skip CoreAudio listener registration when launched as an Xcode test host.
        // Each test host instance registers listeners on coreaudiod; concurrent test runs
        // spawn multiple instances whose listeners corrupt coreaudiod state and freeze System Settings.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        Task { @MainActor in
            processMonitor.start()
            deviceMonitor.start()

            // Start device volume monitor AFTER deviceMonitor.start() populates devices
            // This fixes the race condition where volumes were read before devices existed
            deviceVolumeMonitor.start()

            // Sync device volume changes to taps for VU meter accuracy
            deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
                guard let self else { return }
                guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
                for (pid, tap) in self.taps {
                    if self.appDeviceRouting[pid] == deviceUID {
                        tap.currentDeviceVolume = newVolume
                    }
                }
            }

            // Sync device mute changes to taps for VU meter accuracy
            deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, isMuted in
                guard let self else { return }
                guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
                for (pid, tap) in self.taps {
                    if self.appDeviceRouting[pid] == deviceUID {
                        tap.isDeviceMuted = isMuted
                    }
                }
            }

            // Sync external default device changes (e.g., from System Settings) to all tapped apps
            deviceVolumeMonitor.onDefaultDeviceChangedExternally = { [weak self] deviceUID in
                guard let self else { return }
                self.logger.info("System default device changed externally to: \(deviceUID)")
                self.routeAllApps(to: deviceUID)
            }

            processMonitor.onAppsChanged = { [weak self] _ in
                self?.cleanupStaleTaps()
                self?.applyPersistedSettings()
            }

            deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
                self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            }

            applyPersistedSettings()

            // Diagnostic timer - logs tap state every 5 seconds
            Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard let self else { return }
                    self.logDiagnostics()
                }
            }
        }
    }

    private func logDiagnostics() {
        for (pid, tap) in taps {
            let d = tap.diagnostics
            let appName = apps.first(where: { $0.id == pid })?.name ?? "PID:\(pid)"
            logger.info("""
            [DIAG] \(appName): callbacks=\(d.callbackCount) \
            input=\(d.inputHasData) output=\(d.outputWritten) \
            silForce=\(d.silencedForce) silMute=\(d.silencedMute) \
            conv=\(d.converterUsed) convFail=\(d.converterFailed) \
            direct=\(d.directFloat) passthru=\(d.nonFloatPassthrough) \
            inPeak=\(String(format: "%.3f", d.lastInputPeak)) \
            outPeak=\(String(format: "%.3f", d.lastOutputPeak)) \
            vol=\(String(format: "%.2f", d.volume)) curVol=\(String(format: "%.2f", d.primaryCurrentVolume)) \
            xfade=\(d.crossfadeActive) \
            fmt=\(d.formatChannels)ch/\(d.formatIsFloat ? "f32" : "int")/\
            \(d.formatIsInterleaved ? "ilv" : "planar")/\(Int(d.formatSampleRate))Hz \
            dev=\(self.appDeviceRouting[pid] ?? "none")
            """)
        }
    }

    var apps: [AudioApp] {
        processMonitor.activeApps
    }

    /// Audio levels for all active apps (for VU meter visualization)
    /// Returns a dictionary mapping PID to peak audio level (0-1)
    var audioLevels: [pid_t: Float] {
        var levels: [pid_t: Float] = [:]
        for (pid, tap) in taps {
            levels[pid] = tap.audioLevel
        }
        return levels
    }

    /// Get audio level for a specific app
    func getAudioLevel(for app: AudioApp) -> Float {
        taps[app.id]?.audioLevel ?? 0.0
    }

    func start() {
        // Monitors have internal guards against double-starting
        processMonitor.start()
        deviceMonitor.start()
        applyPersistedSettings()
        logger.info("AudioEngine started")
    }

    func stop() {
        processMonitor.stop()
        deviceMonitor.stop()
        deviceVolumeMonitor.stop()
        for task in switchTasks.values { task.cancel() }
        switchTasks.removeAll()
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        logger.info("AudioEngine stopped")
    }

    /// Synchronous stop for use in app termination handlers.
    /// CRITICAL: Removes all CoreAudio property listeners to prevent corrupting coreaudiod state.
    /// Must be called before app exits to avoid orphaned listeners that can break System Settings.
    nonisolated func stopSync() {
        // Check if already on main thread to avoid deadlock.
        // NSApplication.willTerminateNotification fires on main thread, so we must handle this case.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.stop()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self.stop()
                }
            }
        }
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
        if let deviceUID = appDeviceRouting[app.id] {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }
        taps[app.id]?.volume = volume
    }

    func getVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        volumeState.setMute(for: app.id, to: muted, identifier: app.persistenceIdentifier)
        taps[app.id]?.isMuted = muted
    }

    func getMute(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    /// Update EQ settings for an app
    func setEQSettings(_ settings: EQSettings, for app: AudioApp) {
        guard let tap = taps[app.id] else { return }
        tap.updateEQSettings(settings)
        settingsManager.setEQSettings(settings, for: app.persistenceIdentifier)
    }

    /// Get EQ settings for an app
    func getEQSettings(for app: AudioApp) -> EQSettings {
        return settingsManager.getEQSettings(for: app.persistenceIdentifier)
    }

    func setDevice(for app: AudioApp, deviceUID: String) {
        guard appDeviceRouting[app.id] != deviceUID else { return }

        // Cancel any in-flight switch for this app to prevent concurrent switches.
        // Concurrent switchDevice calls on the same ProcessTapController corrupt
        // crossfade state and can cause crackling, audio drops, or stuck taps.
        switchTasks[app.id]?.cancel()

        let previousDeviceUID = appDeviceRouting[app.id]
        appDeviceRouting[app.id] = deviceUID
        settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)

        if let tap = taps[app.id] {
            switchTasks[app.id] = Task {
                do {
                    try await tap.switchDevice(to: deviceUID)
                    // Restore saved volume/mute state after device switch
                    tap.volume = self.volumeState.getVolume(for: app.id)
                    tap.isMuted = self.volumeState.getMute(for: app.id)
                    // Update device volume/mute for VU meter after switch
                    if let device = self.deviceMonitor.device(for: deviceUID) {
                        tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                        tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                    }
                    self.logger.debug("Switched \(app.name) to device: \(deviceUID)")
                } catch {
                    // Don't revert routing if cancelled — a newer switch has already
                    // updated appDeviceRouting and will handle the transition.
                    guard !Task.isCancelled else {
                        self.logger.debug("Switch cancelled for \(app.name) (superseded by newer switch)")
                        return
                    }
                    self.logger.error("Failed to switch device for \(app.name): \(error.localizedDescription)")
                    // Revert routing state so UI reflects where audio is actually playing
                    if let previousDeviceUID {
                        self.appDeviceRouting[app.id] = previousDeviceUID
                        self.settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: previousDeviceUID)
                        self.logger.info("Reverted \(app.name) routing to: \(previousDeviceUID)")
                    } else {
                        self.appDeviceRouting.removeValue(forKey: app.id)
                        self.settingsManager.clearDeviceRouting(for: app.persistenceIdentifier)
                    }
                }
                self.switchTasks.removeValue(forKey: app.id)
            }
        } else {
            ensureTapExists(for: app, deviceUID: deviceUID)
            // If tap creation failed, revert routing so UI matches reality
            // (no tap = audio goes through system default, not the selected device)
            if taps[app.id] == nil {
                if let previousDeviceUID {
                    appDeviceRouting[app.id] = previousDeviceUID
                    settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: previousDeviceUID)
                } else {
                    appDeviceRouting.removeValue(forKey: app.id)
                    settingsManager.clearDeviceRouting(for: app.persistenceIdentifier)
                }
                logger.warning("Tap creation failed for \(app.name), reverted routing")
            }
        }
    }

    func getDeviceUID(for app: AudioApp) -> String? {
        appDeviceRouting[app.id]
    }

    /// Routes all currently-active apps to the specified device.
    /// Called when user selects a device in the OUTPUT DEVICES section.
    /// This provides macOS-like "switch all audio" behavior.
    func routeAllApps(to deviceUID: String) {
        guard !apps.isEmpty else {
            logger.debug("No apps to route - only setting system default")
            return
        }

        let appsToSwitch = apps.filter { shouldRouteAllApps(for: $0) && appDeviceRouting[$0.id] != deviceUID }
        if appsToSwitch.isEmpty {
            logger.debug("All \(self.apps.count) app(s) already on device: \(deviceUID)")
            return
        }

        logger.info("Routing \(appsToSwitch.count)/\(self.apps.count) app(s) to device: \(deviceUID)")
        for app in appsToSwitch {
            setDevice(for: app, deviceUID: deviceUID)
        }
    }

    private func shouldRouteAllApps(for app: AudioApp) -> Bool {
        if taps[app.id] != nil {
            return true
        }
        if appDeviceRouting[app.id] != nil {
            return true
        }
        return settingsManager.hasCustomSettings(for: app.persistenceIdentifier)
    }

    func applyPersistedSettings() {
        applyPersistedSettings(for: apps)
    }

    private func applyPersistedSettings(for apps: [AudioApp]) {
        for app in apps {
            guard !appliedPIDs.contains(app.id) else { continue }
            guard settingsManager.hasCustomSettings(for: app.persistenceIdentifier) else {
                logger.debug("Skipping \(app.name) — no saved settings")
                continue
            }

            // Load saved device routing, or assign to current macOS default
            let deviceUID: String
            if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
               deviceMonitor.device(for: savedDeviceUID) != nil {
                // Saved device exists, use it
                deviceUID = savedDeviceUID
                logger.debug("Applying saved device routing to \(app.name): \(deviceUID)")
            } else {
                // New app or saved device no longer exists: assign to current macOS default output device
                // Validate the default isn't a virtual device (e.g., SRAudioDriver) — fall back to first real device
                do {
                    let defaultUID = try defaultOutputDeviceUIDProvider()
                    if deviceMonitor.device(for: defaultUID) != nil {
                        // Default device is in our filtered (non-virtual) list
                        deviceUID = defaultUID
                    } else if let firstReal = deviceMonitor.outputDevices.first?.uid {
                        // Default is virtual/aggregate — use first real device
                        logger.info("Default device \(defaultUID) is virtual/filtered, using \(firstReal) for \(app.name)")
                        deviceUID = firstReal
                    } else {
                        // No real devices available at all
                        deviceUID = defaultUID
                    }
                    settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)
                    logger.debug("App \(app.name) assigned to device: \(deviceUID)")
                } catch {
                    logger.error("Failed to get default device for \(app.name): \(error.localizedDescription)")
                    continue
                }
            }
            appDeviceRouting[app.id] = deviceUID

            // Load saved volume and mute state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)

            // Always create tap for audio apps (always-on strategy)
            ensureTapExists(for: app, deviceUID: deviceUID)

            // Only mark as applied if tap was successfully created
            // This allows retry on next applyPersistedSettings() call if tap failed
            guard taps[app.id] != nil else {
                // Remove stale routing so UI falls back to showing default device
                // (no tap = audio goes through system default, not the saved device)
                appDeviceRouting.removeValue(forKey: app.id)
                continue
            }
            appliedPIDs.insert(app.id)

            if let volume = savedVolume {
                let displayPercent = Int(VolumeMapping.gainToSlider(volume) * 200)
                logger.debug("Applying saved volume \(displayPercent)% to \(app.name)")
                taps[app.id]?.volume = volume
            }

            if let muted = savedMute, muted {
                logger.debug("Applying saved mute state to \(app.name)")
                taps[app.id]?.isMuted = true
            }
        }
    }

    // MARK: - Test Helpers

    /// Test-only hook to apply persisted settings to a controlled app list.
    @MainActor
    func applyPersistedSettingsForTests(apps: [AudioApp]) {
        applyPersistedSettings(for: apps)
    }

    private func ensureTapExists(for app: AudioApp, deviceUID: String) {
        guard taps[app.id] == nil else { return }
        onTapCreationAttemptForTests?(app, deviceUID)

        let tap = ProcessTapController(app: app, targetDeviceUID: deviceUID, deviceMonitor: deviceMonitor)
        tap.volume = volumeState.getVolume(for: app.id)

        // Set initial device volume/mute for VU meter accuracy
        if let device = deviceMonitor.device(for: deviceUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
        }

        do {
            try tap.activate()
            taps[app.id] = tap

            // Load and apply persisted EQ settings
            let eqSettings = settingsManager.getEQSettings(for: app.persistenceIdentifier)
            tap.updateEQSettings(eqSettings)

            logger.debug("Created tap for \(app.name)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Called when device disappears - routes affected apps through setDevice for serialized switching
    private func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
        // Get fallback device: macOS default output, or first available device
        let fallbackDevice: (uid: String, name: String)
        do {
            let uid = try AudioDeviceID.readDefaultOutputDeviceUID()
            let name = deviceMonitor.device(for: uid)?.name ?? "Default Output"
            fallbackDevice = (uid: uid, name: name)
        } catch {
            guard let firstDevice = deviceMonitor.outputDevices.first else {
                logger.error("No fallback device available")
                return
            }
            fallbackDevice = (uid: firstDevice.uid, name: firstDevice.name)
        }

        var affectedApps: [AudioApp] = []

        for app in apps {
            if appDeviceRouting[app.id] == deviceUID {
                affectedApps.append(app)
                // Route through setDevice for serialized switch handling.
                // This cancels any in-flight switch to the now-disconnected device.
                setDevice(for: app, deviceUID: fallbackDevice.uid)
            }
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) disconnected, \(affectedApps.count) app(s) switched to \(fallbackDevice.name)")
            showDisconnectNotification(deviceName: deviceName, fallbackName: fallbackDevice.name, affectedApps: affectedApps)
        }
    }

    private func showDisconnectNotification(deviceName: String, fallbackName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Disconnected"
        content.body = "\"\(deviceName)\" disconnected. \(affectedApps.count) app(s) switched to \(fallbackName)"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-disconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    func cleanupStaleTaps() {
        let activePIDs = Set(apps.map { $0.id })
        let stalePIDs = Set(taps.keys).subtracting(activePIDs)

        // Cancel in-flight switch tasks for stale PIDs
        for pid in stalePIDs {
            switchTasks[pid]?.cancel()
            switchTasks.removeValue(forKey: pid)
        }

        // Cancel cleanup for PIDs that reappeared
        for pid in activePIDs {
            if let task = pendingCleanup.removeValue(forKey: pid) {
                task.cancel()
                logger.debug("Cancelled pending cleanup for PID \(pid) - app reappeared")
            }
        }

        // Schedule cleanup for newly stale PIDs (with grace period)
        // Grace period of 1 second allows for brief audio interruptions without destroying taps
        // This is generous enough to handle most transient cases while still cleaning up promptly
        for pid in stalePIDs {
            guard pendingCleanup[pid] == nil else { continue }  // Already pending

            pendingCleanup[pid] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                // Double-check still stale - app may have reappeared during grace period
                let currentPIDs = Set(self.apps.map { $0.id })
                guard !currentPIDs.contains(pid) else {
                    self.pendingCleanup.removeValue(forKey: pid)
                    self.logger.debug("Cleanup cancelled for PID \(pid) - app reappeared during grace period")
                    return
                }

                // Now safe to cleanup
                if let tap = self.taps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.logger.info("Cleaned up stale tap for PID \(pid) after grace period")
                }
                self.appDeviceRouting.removeValue(forKey: pid)
                self.pendingCleanup.removeValue(forKey: pid)
            }
        }

        // Include pending PIDs in cleanup exclusion to avoid premature state cleanup
        let pidsToKeep = activePIDs.union(Set(pendingCleanup.keys))
        appliedPIDs = appliedPIDs.intersection(pidsToKeep)
        volumeState.cleanup(keeping: pidsToKeep)
    }
}
