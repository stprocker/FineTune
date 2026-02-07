// FineTune/Audio/AudioEngine.swift
import AudioToolbox
import Foundation
import os
import UserNotifications
#if canImport(FineTuneCore)
import FineTuneCore
#endif

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
    var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private var switchTasks: [pid_t: Task<Void, Never>] = [:]  // In-flight device switch tasks (prevents concurrent switches)

    /// Whether system audio recording permission has been confirmed THIS SESSION.
    /// Per-session flag (not persisted) — on each launch, taps start with `.unmuted`
    /// to prevent audio silence if the app is killed during permission grant.
    /// Once audio flows successfully, this flips to `true` and taps are recreated
    /// with `.mutedWhenTapped` for proper per-app volume control.
    /// Not persisted because permission can be revoked externally (tccutil reset).
    private var permissionConfirmed = false
    /// Snapshot of tap diagnostics from the previous health check cycle.
    /// Used to detect both stalled taps (callbacks stopped) and broken taps
    /// (callbacks running but reporter disconnected — empty input, no output).
    private struct TapHealthSnapshot {
        var callbackCount: UInt64 = 0
        var outputWritten: UInt64 = 0
        var emptyInput: UInt64 = 0
    }
    private var lastHealthSnapshots: [pid_t: TapHealthSnapshot] = [:]
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

            deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
                self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            }

            // Handle coreaudiod restarts (e.g., after granting system audio permission).
            // All AudioObjectIDs (taps, aggregates) become invalid and must be recreated.
            deviceMonitor.onServiceRestarted = { [weak self] in
                self?.handleServiceRestarted()
            }

            // Delay initial tap creation to let apps initialize their audio sessions
            // and to avoid creating taps before system audio permission is granted.
            // The onAppsChanged callback is wired AFTER this delay to prevent it
            // from bypassing the wait by firing during processMonitor.start().
            logger.info("[STARTUP] Waiting 2s before creating taps...")
            try? await Task.sleep(for: .seconds(2))
            logger.info("[STARTUP] Creating initial taps")
            applyPersistedSettings()

            // Wire up onAppsChanged AFTER initial tap creation to prevent early bypass
            processMonitor.onAppsChanged = { [weak self] _ in
                self?.cleanupStaleTaps()
                self?.applyPersistedSettings()
            }

            // Diagnostic + health check timer - every 3 seconds
            Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    self.logDiagnostics()
                    self.checkTapHealth()
                }
            }
        }
    }

    /// Handles coreaudiod restart by destroying all taps and recreating them.
    /// When coreaudiod restarts (e.g., after system audio permission is granted),
    /// all AudioObjectIDs become invalid. We must tear down everything and start fresh.
    private func handleServiceRestarted() {
        logger.warning("[SERVICE-RESTART] coreaudiod restarted — destroying all taps and recreating")

        // Cancel all in-flight switches
        for task in switchTasks.values { task.cancel() }
        switchTasks.removeAll()

        // Destroy all existing taps (their AudioObjectIDs are now invalid)
        for (pid, tap) in taps {
            let appName = apps.first(where: { $0.id == pid })?.name ?? "PID:\(pid)"
            logger.info("[SERVICE-RESTART] Destroying stale tap for \(appName)")
            tap.invalidate()
        }
        taps.removeAll()
        appliedPIDs.removeAll()
        lastHealthSnapshots.removeAll()

        // Wait for coreaudiod to stabilize, then recreate all taps
        Task { @MainActor [weak self] in
            self?.logger.info("[SERVICE-RESTART] Waiting 1.5s for coreaudiod to stabilize...")
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else { return }
            self.logger.info("[SERVICE-RESTART] Recreating taps")
            self.applyPersistedSettings()
        }
    }

    /// Detects broken taps and recreates them. Two failure modes are detected:
    /// 1. **Stalled**: callback count not changing (IO proc stopped running)
    /// 2. **Broken**: callbacks running but empty input / no output (reporter disconnected)
    /// This handles "Reporter disconnected" / IO overload scenarios where CoreAudio's
    /// process tap loses its connection after permission changes or coreaudiod issues.
    private func checkTapHealth() {
        var pidsToRecreate: [(pid_t, String)] = []  // (pid, reason)

        for (pid, tap) in taps {
            let d = tap.diagnostics
            let prev = lastHealthSnapshots[pid] ?? TapHealthSnapshot()
            lastHealthSnapshots[pid] = TapHealthSnapshot(
                callbackCount: d.callbackCount,
                outputWritten: d.outputWritten,
                emptyInput: d.emptyInput
            )

            // Skip first check (need a baseline)
            guard prev.callbackCount > 0 else { continue }

            // Skip if we're in the middle of switching devices
            guard switchTasks[pid] == nil else { continue }

            let callbackDelta = d.callbackCount - prev.callbackCount
            let outputDelta = d.outputWritten - prev.outputWritten
            let emptyDelta = d.emptyInput - prev.emptyInput

            // Case 1: Stalled — callback count not changing
            if callbackDelta == 0 {
                pidsToRecreate.append((pid, "stalled (callbacks stuck at \(d.callbackCount))"))
                continue
            }

            // Case 2: Broken — callbacks running but mostly empty input and no output
            // This detects "Reporter disconnected" where the tap's data source is gone
            // but the IO proc keeps firing with zero-length buffers
            if callbackDelta > 50 && outputDelta == 0 && emptyDelta > callbackDelta / 2 {
                pidsToRecreate.append((pid, "broken (callbacks=+\(callbackDelta) output=+0 empty=+\(emptyDelta))"))
                continue
            }
        }

        for (pid, reason) in pidsToRecreate {
            guard let app = apps.first(where: { $0.id == pid }),
                  let deviceUID = appDeviceRouting[pid] else { continue }

            logger.warning("[HEALTH] \(app.name) tap \(reason), recreating")

            taps[pid]?.invalidate()
            taps.removeValue(forKey: pid)
            appliedPIDs.remove(pid)
            lastHealthSnapshots.removeValue(forKey: pid)

            ensureTapExists(for: app, deviceUID: deviceUID)
        }

        // Clean up tracking for removed taps
        let activePIDs = Set(taps.keys)
        lastHealthSnapshots = lastHealthSnapshots.filter { activePIDs.contains($0.key) }
    }

    private func logDiagnostics() {
        for (pid, tap) in taps {
            let d = tap.diagnostics
            let appName = apps.first(where: { $0.id == pid })?.name ?? "PID:\(pid)"
            logger.info("""
            [DIAG] \(appName): callbacks=\(d.callbackCount) \
            input=\(d.inputHasData) output=\(d.outputWritten) empty=\(d.emptyInput) \
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
        // Allow re-routing when tap is missing (e.g., previous activation failed)
        // so users can retry device selection instead of getting silently blocked.
        let tapExists = taps[app.id] != nil
        guard appDeviceRouting[app.id] != deviceUID || !tapExists else { return }

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

        // On first launch (before permission is confirmed), use .unmuted so the app being
        // killed during the system permission dialog doesn't leave audio permanently muted.
        // After permission is confirmed, use .mutedWhenTapped for proper per-app control.
        let shouldMute = permissionConfirmed
        if !shouldMute {
            logger.info("[PERMISSION] Creating tap for \(app.name) with .unmuted (permission not yet confirmed)")
        }

        let tap = ProcessTapController(app: app, targetDeviceUID: deviceUID, deviceMonitor: deviceMonitor, muteOriginal: shouldMute)
        tap.volume = volumeState.getVolume(for: app.id)
        tap.isMuted = volumeState.getMute(for: app.id)

        // Set initial device volume/mute for VU meter accuracy
        if let device = deviceMonitor.device(for: deviceUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
        }

        do {
            try tap.activate()
            taps[app.id] = tap

            // Schedule fast health checks after tap creation.
            // Intervals: 0.3s (quick permission check), 0.8s, 1.5s (broken tap detection)
            let pid = app.id
            let appName = app.name
            let needsPermissionConfirmation = !permissionConfirmed
            let checkIntervals: [Duration] = [.milliseconds(300), .milliseconds(500), .milliseconds(700)]
            Task { @MainActor [weak self] in
                for (checkNum, interval) in checkIntervals.enumerated() {
                    try? await Task.sleep(for: interval)
                    guard let self, let tap = self.taps[pid] else {
                        self?.logger.debug("[HEALTH-FAST] \(appName) check #\(checkNum + 1): tap gone, stopping checks")
                        return
                    }
                    let d = tap.diagnostics
                    self.logger.info("[HEALTH-FAST] \(appName) check #\(checkNum + 1): callbacks=\(d.callbackCount) input=\(d.inputHasData) output=\(d.outputWritten) empty=\(d.emptyInput) silForce=\(d.silencedForce) silMute=\(d.silencedMute)")

                    // Confirm permission once we see audio flowing successfully.
                    // Recreates all taps with .mutedWhenTapped for proper per-app control.
                    if needsPermissionConfirmation && d.callbackCount > 10 && d.outputWritten > 0 {
                        self.permissionConfirmed = true
                        self.logger.info("[PERMISSION] System audio permission confirmed — recreating taps with .mutedWhenTapped")
                        self.recreateAllTaps()
                        return
                    }

                    // Broken = callbacks running but no output written (after enough time)
                    if checkNum >= 1 && d.callbackCount > 10 && d.outputWritten == 0 {
                        guard let app = self.apps.first(where: { $0.id == pid }),
                              let deviceUID = self.appDeviceRouting[pid] else { return }
                        self.logger.warning("[HEALTH-FAST] \(appName) tap broken (callbacks=\(d.callbackCount) output=0), recreating")
                        tap.invalidate()
                        self.taps.removeValue(forKey: pid)
                        self.appliedPIDs.remove(pid)
                        self.lastHealthSnapshots.removeValue(forKey: pid)
                        self.ensureTapExists(for: app, deviceUID: deviceUID)
                        return
                    }
                }
            }

            // Load and apply persisted EQ settings
            let eqSettings = settingsManager.getEQSettings(for: app.persistenceIdentifier)
            tap.updateEQSettings(eqSettings)

            logger.debug("Created tap for \(app.name)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Destroys all taps and recreates them (e.g., to upgrade from .unmuted to .mutedWhenTapped).
    private func recreateAllTaps() {
        for (pid, tap) in taps {
            let appName = apps.first(where: { $0.id == pid })?.name ?? "PID:\(pid)"
            logger.info("[RECREATE] Destroying tap for \(appName)")
            tap.invalidate()
        }
        taps.removeAll()
        appliedPIDs.removeAll()
        lastHealthSnapshots.removeAll()
        applyPersistedSettings()
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
