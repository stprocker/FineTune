// FineTune/Audio/AudioEngine.swift
import AudioToolbox
import Darwin
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
    let mediaNotificationMonitor = MediaNotificationMonitor()
    let volumeState: VolumeState
    let settingsManager: SettingsManager
    private let defaultOutputDeviceUIDProvider: () throws -> String
    private let isProcessRunningProvider: (pid_t) -> Bool

    private var taps: [pid_t: ProcessTapController] = [:]
    private var appliedPIDs: Set<pid_t> = []
    var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    /// Apps temporarily displaced to the default device during disconnect.
    /// Tracks PIDs so we know which apps were involuntarily moved and should
    /// be switched back when their preferred device reconnects.
    private var followsDefault: Set<pid_t> = []
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private var switchTasks: [pid_t: Task<Void, Never>] = [:]  // In-flight device switch tasks (prevents concurrent switches)
    private var lastRouteAllAppsTimestamp: CFAbsoluteTime = 0
    private var lastRouteAllAppsDevice: String?
    private var lastDisplayedApp: AudioApp?
    private var previousActiveAppIDs: Set<pid_t> = []
    private var lastAudibleAtByPID: [pid_t: Date] = [:]
    private let pausedLevelThreshold: Float = 0.002
    /// Asymmetric hysteresis: strict threshold prevents false pauses during song gaps / brief silence
    private let playingToPausedGrace: TimeInterval = 1.5
    /// Asymmetric hysteresis: loose threshold for nearly instant recovery when audio resumes
    private let pausedToPlayingGrace: TimeInterval = 0.05

    enum PauseState {
        case playing
        case paused
    }
    /// Per-PID pause state for asymmetric hysteresis.
    /// Tracks whether each app is currently considered playing or paused,
    /// so the appropriate grace period is used for state transitions.
    private var pauseStateByPID: [pid_t: PauseState] = [:]
    private var pauseEligiblePIDsForTests: Set<pid_t>?

    /// Whether system audio recording permission has been confirmed THIS SESSION.
    /// Per-session flag (not persisted) — on each launch, taps start with `.unmuted`
    /// to prevent audio silence if the app is killed during permission grant.
    /// Once audio flows successfully, this flips to `true` and taps are recreated
    /// with `.mutedWhenTapped` for proper per-app volume control.
    /// Not persisted because permission can be revoked externally (tccutil reset).
    private var permissionConfirmed = false
    /// Suppresses `routeAllApps` during tap teardown/recreation to prevent
    /// aggregate-device destruction from triggering a bogus default-device-change
    /// notification that overwrites per-app routing (e.g. AirPods → MacBook speakers).
    private var isRecreatingTaps = false
    /// Timestamp when the last recreation cycle ended. Used with `recreationGracePeriod`
    /// to suppress late-arriving debounced device-change notifications that slip past
    /// the `isRecreatingTaps` flag (300ms debounce + async dispatch can outlast the flag).
    private var recreationEndedAt: Date = .distantPast
    /// Grace period (seconds) after recreation ends during which device-change
    /// notifications are still suppressed. Covers the debounce + async dispatch latency.
    private let recreationGracePeriod: TimeInterval = 2.0
    /// Stored task for `handleServiceRestarted` — cancelled on re-entry to prevent
    /// overlapping delayed tasks from clearing `isRecreatingTaps` prematurely.
    private var serviceRestartTask: Task<Void, Never>?
    private var diagnosticPollTask: Task<Void, Never>?
    private var pauseRecoveryPollTask: Task<Void, Never>?
    /// Snapshot of tap diagnostics from the previous health check cycle.
    /// Used to detect both stalled taps (callbacks stopped) and broken taps
    /// (callbacks running but reporter disconnected — empty input, no output).
    private struct TapHealthSnapshot {
        var callbackCount: UInt64 = 0
        var outputWritten: UInt64 = 0
        var emptyInput: UInt64 = 0
    }
    private var lastHealthSnapshots: [pid_t: TapHealthSnapshot] = [:]
    /// Routing snapshot taken before recreation events.
    /// Restored after recreation to prevent spurious notifications from corrupting persisted routing.
    private var routingSnapshot: (memory: [pid_t: String], persisted: [String: String])?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioEngine")
    /// Test-only hook for observing tap-creation attempts.
    var onTapCreationAttemptForTests: ((AudioApp, String) -> Void)?

    // MARK: - Injectable Timing

    /// Diagnostic + health check polling interval (seconds).
    var diagnosticPollInterval: Duration = .seconds(3)

    /// Startup delay before creating initial taps (seconds).
    var startupTapDelay: Duration = .seconds(2)

    /// Grace period for stale tap cleanup (seconds).
    var staleTapGracePeriod: Duration = .seconds(1)

    /// Service restart stabilization delay (ms).
    var serviceRestartDelay: Duration = .milliseconds(1500)

    /// Fast health check intervals after tap creation.
    var fastHealthCheckIntervals: [Duration] = [.milliseconds(300), .milliseconds(500), .milliseconds(700)]

    /// Lightweight pause-state recovery interval (seconds).
    /// Separate from the heavy diagnostic timer to provide faster pause→playing recovery
    /// without increasing the cost of diagnostics/health checks.
    var pauseRecoveryPollInterval: Duration = .seconds(1)

    // MARK: - Recreation Suppression

    /// Whether device-change notifications should be suppressed.
    /// True during active recreation OR within the grace period after recreation ends.
    /// This two-layer defense prevents both synchronous and late-arriving async notifications
    /// from corrupting persisted routing via `routeAllApps`.
    private var shouldSuppressDeviceNotifications: Bool {
        isRecreatingTaps || Date().timeIntervalSince(recreationEndedAt) < recreationGracePeriod
    }

    /// Captures a snapshot of both in-memory and persisted routing state.
    /// Call before any recreation event to preserve routing.
    private func snapshotRouting() {
        routingSnapshot = (
            memory: appDeviceRouting,
            persisted: settingsManager.snapshotDeviceRoutings()
        )
        logger.debug("[SNAPSHOT] Captured routing: \(self.appDeviceRouting.count) in-memory, \(self.routingSnapshot?.persisted.count ?? 0) persisted")
    }

    /// Restores routing state from the most recent snapshot, then discards it.
    /// Call after recreation completes to undo any spurious notification side-effects.
    private func restoreRouting() {
        guard let snapshot = routingSnapshot else { return }
        appDeviceRouting = snapshot.memory
        settingsManager.restoreDeviceRoutings(snapshot.persisted)
        routingSnapshot = nil
        logger.debug("[SNAPSHOT] Restored routing: \(snapshot.memory.count) in-memory, \(snapshot.persisted.count) persisted")
    }

    // MARK: - Permission Confirmation

    /// Permission is only considered confirmed once we see real input audio,
    /// not just callback/output activity (which can still be silent).
    /// Also requires non-zero output peak so we don't upgrade to `.mutedWhenTapped`
    /// when the aggregate output path is dead (the bundle-ID tap failure mode).
    /// Exception: when volume is ~0, zero output peak is expected/legitimate.
    nonisolated static func shouldConfirmPermission(from diagnostics: TapDiagnostics) -> Bool {
        guard diagnostics.callbackCount > 10 else { return false }
        guard diagnostics.outputWritten > 0 else { return false }

        let hasInput = diagnostics.inputHasData > 0 || diagnostics.lastInputPeak > 0.0001
        guard hasInput else { return false }

        // If user expects audible output (volume > ~0), require real output peak
        // to prevent promoting with dead output path (bundle-ID tap failure).
        // Volume ~0 legitimately produces zero output peak — don't block permission.
        let userExpectsAudio = diagnostics.volume > 0.01
        if userExpectsAudio {
            return diagnostics.lastOutputPeak > 0.0001
        }
        return true
    }

    // MARK: - Input Device Lock State

    /// Track if WE initiated the input change (to avoid revert loop)
    private var didInitiateInputSwitch = false

    /// Track when an input device was last connected (to distinguish auto-switch from user action)
    private var lastInputDeviceConnectTime: Date?

    /// Grace period to detect automatic device switching after connection (2 seconds)
    private let autoSwitchGracePeriod: TimeInterval = 2.0

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    var inputDevices: [AudioDevice] {
        deviceMonitor.inputDevices
    }

    // MARK: - Initialization

    init(
        settingsManager: SettingsManager? = nil,
        defaultOutputDeviceUIDProvider: @escaping () throws -> String = { try AudioDeviceID.readDefaultOutputDeviceUID() },
        isProcessRunningProvider: @escaping (pid_t) -> Bool = { pid in
            guard pid > 0 else { return false }
            if kill(pid, 0) == 0 { return true }
            return errno == EPERM
        }
    ) {
        let manager = settingsManager ?? SettingsManager()
        self.settingsManager = manager
        self.defaultOutputDeviceUIDProvider = defaultOutputDeviceUIDProvider
        self.isProcessRunningProvider = isProcessRunningProvider
        self.volumeState = VolumeState(settingsManager: manager)
        self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: deviceMonitor, settingsManager: manager)

        // Skip CoreAudio listener registration when launched as an Xcode test host.
        // Each test host instance registers listeners on coreaudiod; concurrent test runs
        // spawn multiple instances whose listeners corrupt coreaudiod state and freeze System Settings.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        Task { @MainActor in
            processMonitor.start()
            updateDisplayedAppsState(activeApps: processMonitor.activeApps)
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
            deviceVolumeMonitor.onDefaultDeviceChangedExternally = { [weak self] deviceUID, triggerSource in
                guard let self else { return }
                if self.shouldSuppressDeviceNotifications {
                    self.logger.info("Ignoring default device change to \(deviceUID) — recreation active or grace period (\(String(format: "%.1f", Date().timeIntervalSince(self.recreationEndedAt)))s since end)")
                    return
                }
                self.logger.info("[ROUTE-TRIGGER] System default device changed to: \(deviceUID) (trigger=\(triggerSource))")
                self.routeAllApps(to: deviceUID, source: "routeAllApps(\(triggerSource))")
            }

            deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
                self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            }

            deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
                self?.handleDeviceConnected(deviceUID, name: deviceName)
            }

            // Handle coreaudiod restarts (e.g., after granting system audio permission).
            // All AudioObjectIDs (taps, aggregates) become invalid and must be recreated.
            deviceMonitor.onServiceRestarted = { [weak self] in
                self?.handleServiceRestarted()
            }

            // Input device connect/disconnect monitoring
            deviceMonitor.onInputDeviceDisconnected = { [weak self] deviceUID, deviceName in
                self?.logger.info("Input device disconnected: \(deviceName) (\(deviceUID))")
                self?.handleInputDeviceDisconnected(deviceUID)
            }

            deviceMonitor.onInputDeviceConnected = { [weak self] deviceUID, deviceName in
                self?.logger.info("Input device connected: \(deviceName) (\(deviceUID))")
                self?.lastInputDeviceConnectTime = Date()
            }

            // Handle default input device changes (input lock feature)
            deviceVolumeMonitor.onDefaultInputDeviceChanged = { [weak self] newDefaultInputUID in
                Task { @MainActor [weak self] in
                    self?.handleDefaultInputDeviceChanged(newDefaultInputUID)
                }
            }

            // Delay initial tap creation to let apps initialize their audio sessions
            // and to avoid creating taps before system audio permission is granted.
            // The onAppsChanged callback is wired AFTER this delay to prevent it
            // from bypassing the wait by firing during processMonitor.start().
            logger.info("[STARTUP] Waiting before creating taps...")
            try? await Task.sleep(for: startupTapDelay)
            logger.info("[STARTUP] Creating initial taps")
            applyPersistedSettings()

            // Restore locked input device if feature is enabled
            if manager.appSettings.lockInputDevice {
                restoreLockedInputDevice()
            }

            // Wire up onAppsChanged AFTER initial tap creation to prevent early bypass
            processMonitor.onAppsChanged = { [weak self] apps in
                self?.updateDisplayedAppsState(activeApps: apps)
                self?.cleanupStaleTaps()
                self?.applyPersistedSettings()
            }

            // Diagnostic + health check timer (heavy, 3s)
            diagnosticPollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.diagnosticPollInterval ?? .seconds(3))
                    guard let self else { return }
                    self.logDiagnostics()
                    self.checkTapHealth()
                }
            }

            // Lightweight pause-state recovery timer (1s).
            // Breaks the circular dependency where isPaused→true stops VU polling,
            // which prevents lastAudibleAtByPID updates, which keeps isPaused→true forever.
            // This reads tap.audioLevel directly, independent of UI polling state.
            pauseRecoveryPollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.pauseRecoveryPollInterval ?? .seconds(1))
                    guard let self else { return }
                    self.updatePauseStates()
                }
            }

            // Spotify instant play/pause: bypass VU-level detection lag
            mediaNotificationMonitor.onPlaybackStateChanged = { [weak self] pid, isPlaying in
                guard let self else { return }
                if isPlaying {
                    self.lastAudibleAtByPID[pid] = Date()
                    self.pauseStateByPID[pid] = .playing
                } else {
                    self.pauseStateByPID[pid] = .paused
                }
            }
            mediaNotificationMonitor.start()
        }
    }

    // MARK: - Health & Diagnostics

    /// Handles coreaudiod restart by destroying all taps and recreating them.
    /// When coreaudiod restarts (e.g., after system audio permission is granted),
    /// all AudioObjectIDs become invalid. We must tear down everything and start fresh.
    private func handleServiceRestarted() {
        logger.warning("[SERVICE-RESTART] coreaudiod restarted — destroying all taps and recreating")

        // Cancel any previous restart task to prevent overlapping delayed tasks
        // from clearing isRecreatingTaps prematurely (reentrancy guard).
        serviceRestartTask?.cancel()

        isRecreatingTaps = true
        snapshotRouting()

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

        // Wait for coreaudiod to stabilize, then recreate all taps.
        // If permission was already confirmed in a previous cycle, taps are created
        // directly with .mutedWhenTapped — no extra .unmuted→confirm→recreate cycle.
        // On first launch (permission not yet confirmed), creates .unmuted taps,
        // then probes for audio data inline to confirm permission and upgrade
        // to .mutedWhenTapped in one consolidated flow (avoids double recreation).
        serviceRestartTask = Task { @MainActor [weak self] in
            self?.logger.info("[SERVICE-RESTART] Waiting for coreaudiod to stabilize...")
            try? await Task.sleep(for: self?.serviceRestartDelay ?? .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            self.logger.info("[SERVICE-RESTART] Recreating taps (permissionConfirmed=\(self.permissionConfirmed))")
            self.applyPersistedSettings()

            // If permission wasn't yet confirmed, probe for audio data now to avoid
            // the fast health check triggering a redundant recreateAllTaps() cycle.
            if !self.permissionConfirmed {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let confirmed = self.taps.values.contains { Self.shouldConfirmPermission(from: $0.diagnostics) }
                if confirmed {
                    self.permissionConfirmed = true
                    self.logger.info("[SERVICE-RESTART] Permission confirmed inline — upgrading to .mutedWhenTapped")
                    self.upgradeTapsToMutedWhenTapped()
                }
            }

            self.restoreRouting()
            self.isRecreatingTaps = false
            self.recreationEndedAt = Date()
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

            // Skip if we're in the middle of switching devices
            guard switchTasks[pid] == nil else { continue }

            // Case 0: Dead — IO proc never fired across two health cycles.
            // This catches taps targeting the wrong device or macOS 26 bundle-ID failures.
            // Need two cycles (prev exists with callbackCount=0) to avoid false positives on fresh taps.
            if prev.callbackCount == 0 && d.callbackCount == 0 && prev.outputWritten == 0 {
                pidsToRecreate.append((pid, "dead (callbacks=0 across two health cycles)"))
                continue
            }

            // Skip first real check (need a non-zero baseline for delta logic)
            guard prev.callbackCount > 0 else { continue }

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

            // If tap is dead (zero callbacks), it may be targeting the wrong device.
            // Try the system default device as fallback before recreating on the same device.
            if reason.hasPrefix("dead") {
                if let defaultUID = try? defaultOutputDeviceUIDProvider(), defaultUID != deviceUID {
                    logger.info("[HEALTH] Rerouting \(app.name) to system default \(defaultUID)")
                    appDeviceRouting[pid] = defaultUID
                    settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: defaultUID)
                    ensureTapExists(for: app, deviceUID: defaultUID)
                    continue
                }
            }

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
            outBuf=\(d.outputBufCount)x\(d.outputBuf0ByteSize)B \
            vol=\(String(format: "%.2f", d.volume)) curVol=\(String(format: "%.2f", d.primaryCurrentVolume)) \
            xfade=\(d.crossfadeActive) \
            fmt=\(d.formatChannels)ch/\(d.formatIsFloat ? "f32" : "int")/\
            \(d.formatIsInterleaved ? "ilv" : "planar")/\(Int(d.formatSampleRate))Hz \
            dev=\(self.appDeviceRouting[pid] ?? "none")
            """)
        }
    }

    // MARK: - Display State

    var apps: [AudioApp] {
        processMonitor.activeApps
    }

    /// Apps shown in the UI: active apps when playing, otherwise a single
    /// cached app row from the most recently active app (shown as paused).
    var displayedApps: [AudioApp] {
        if !apps.isEmpty { return apps }
        if let lastDisplayedApp { return [lastDisplayedApp] }
        return []
    }

    // MARK: - Displayable Apps (Active + Pinned Inactive)

    /// Combined list of active apps and pinned inactive apps for UI display.
    /// Sort order: pinned-active (alphabetical) -> pinned-inactive (alphabetical) -> unpinned-active (alphabetical).
    var displayableApps: [DisplayableApp] {
        let activeApps = apps
        let activeIdentifiers = Set(activeApps.map { $0.persistenceIdentifier })

        // Get pinned apps that are not currently active
        let pinnedInactiveInfos = settingsManager.getPinnedAppInfo()
            .filter { !activeIdentifiers.contains($0.persistenceIdentifier) }

        // Pinned active apps (sorted alphabetically)
        let pinnedActive = activeApps
            .filter { settingsManager.isPinned($0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        // Pinned inactive apps (sorted alphabetically)
        let pinnedInactive = pinnedInactiveInfos
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { DisplayableApp.pinnedInactive($0) }

        // Unpinned active apps (sorted alphabetically)
        let unpinnedActive = activeApps
            .filter { !settingsManager.isPinned($0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        return pinnedActive + pinnedInactive + unpinnedActive
    }

    // MARK: - Pinning

    /// Pin an active app so it remains visible when inactive.
    func pinApp(_ app: AudioApp) {
        let info = PinnedAppInfo(
            persistenceIdentifier: app.persistenceIdentifier,
            displayName: app.name,
            bundleID: app.bundleID
        )
        settingsManager.pinApp(app.persistenceIdentifier, info: info)
    }

    /// Unpin an app by its persistence identifier.
    func unpinApp(_ identifier: String) {
        settingsManager.unpinApp(identifier)
    }

    /// Check if an app is pinned.
    func isPinned(_ app: AudioApp) -> Bool {
        settingsManager.isPinned(app.persistenceIdentifier)
    }

    /// Check if an identifier is pinned (for inactive apps).
    func isPinned(identifier: String) -> Bool {
        settingsManager.isPinned(identifier)
    }

    // MARK: - Inactive App Settings (by persistence identifier)

    /// Get volume for an inactive app by persistence identifier.
    func getVolumeForInactive(identifier: String) -> Float {
        settingsManager.getVolume(for: identifier) ?? 1.0
    }

    /// Set volume for an inactive app by persistence identifier.
    func setVolumeForInactive(identifier: String, to volume: Float) {
        settingsManager.setVolume(for: identifier, to: volume)
    }

    /// Get mute state for an inactive app by persistence identifier.
    func getMuteForInactive(identifier: String) -> Bool {
        settingsManager.getMute(for: identifier) ?? false
    }

    /// Set mute state for an inactive app by persistence identifier.
    func setMuteForInactive(identifier: String, to muted: Bool) {
        settingsManager.setMute(for: identifier, to: muted)
    }

    /// Get EQ settings for an inactive app by persistence identifier.
    func getEQSettingsForInactive(identifier: String) -> EQSettings {
        settingsManager.getEQSettings(for: identifier)
    }

    /// Set EQ settings for an inactive app by persistence identifier.
    func setEQSettingsForInactive(_ settings: EQSettings, identifier: String) {
        settingsManager.setEQSettings(settings, for: identifier)
    }

    /// Get device routing for an inactive app by persistence identifier.
    func getDeviceRoutingForInactive(identifier: String) -> String? {
        settingsManager.getDeviceRouting(for: identifier)
    }

    /// Set device routing for an inactive app by persistence identifier.
    func setDeviceRoutingForInactive(identifier: String, deviceUID: String) {
        settingsManager.setDeviceRouting(for: identifier, deviceUID: deviceUID)
    }

    func isPausedDisplayApp(_ app: AudioApp) -> Bool {
        if apps.isEmpty && lastDisplayedApp?.id == app.id {
            return true
        }

        guard apps.contains(where: { $0.id == app.id }) else { return false }
        let isPauseEligible = taps[app.id] != nil || (pauseEligiblePIDsForTests?.contains(app.id) ?? false)
        guard isPauseEligible else { return false }
        let lastAudibleAt = lastAudibleAtByPID[app.id] ?? .distantPast
        let silenceDuration = Date().timeIntervalSince(lastAudibleAt)

        // Asymmetric hysteresis: use different thresholds based on current state
        let currentState = pauseStateByPID[app.id] ?? .playing
        switch currentState {
        case .playing:
            // Strict: require longer silence before declaring paused (prevents false pauses during song gaps)
            if silenceDuration >= playingToPausedGrace {
                pauseStateByPID[app.id] = .paused
                return true
            }
            return false
        case .paused:
            // Loose: nearly instant recovery when audio resumes
            if silenceDuration < pausedToPlayingGrace {
                pauseStateByPID[app.id] = .playing
                return false
            }
            return true
        }
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
        let level = taps[app.id]?.audioLevel ?? 0.0
        if level > pausedLevelThreshold {
            lastAudibleAtByPID[app.id] = Date()
            // Immediately mark as playing when audio detected (fast recovery path)
            if pauseStateByPID[app.id] == .paused {
                pauseStateByPID[app.id] = .playing
            }
        }
        return level
    }

    /// Updates `lastAudibleAtByPID` for all tapped apps by reading tap audio levels directly.
    /// Called from the 1s pause-recovery timer to break the circular dependency where
    /// the VU polling in AppRowWithLevelPolling stops when isPaused is true,
    /// which prevents getAudioLevel from being called, which prevents recovery.
    private func updatePauseStates() {
        for (pid, tap) in taps {
            if tap.audioLevel > pausedLevelThreshold {
                lastAudibleAtByPID[pid] = Date()
                // Immediately mark as playing when audio detected (fast recovery path)
                if pauseStateByPID[pid] == .paused {
                    pauseStateByPID[pid] = .playing
                }
            }
        }
    }

    /// Resolves which device UID should be shown in the row picker.
    /// Priority:
    ///  1. In-memory routing → visible device (normal case)
    ///  2. Persisted routing → visible device (fallback during recreation)
    ///  3. In-memory routing → even if device temporarily invisible (Bluetooth reconnecting)
    ///  4. Persisted routing → even if device temporarily invisible
    ///  5. System default → visible device
    ///  6. First visible device
    /// Priorities 3-4 prevent the display from flipping to "MacBook Pro Speakers"
    /// when AirPods temporarily disappear during coreaudiod restart.
    func resolvedDeviceUIDForDisplay(
        app: AudioApp,
        availableDevices: [AudioDevice],
        defaultDeviceUID: String?
    ) -> String {
        // 1: In-memory routing matching a visible device (normal steady-state)
        if let routedUID = appDeviceRouting[app.id], availableDevices.contains(where: { $0.uid == routedUID }) {
            return routedUID
        }
        // 2: Persisted routing matching a visible device (covers recreation window when appDeviceRouting is stale)
        if let savedUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
           availableDevices.contains(where: { $0.uid == savedUID }) {
            return savedUID
        }
        // 3: In-memory routing even if device temporarily invisible (BT transient absence)
        if let routedUID = appDeviceRouting[app.id] {
            return routedUID
        }
        // 4: Persisted routing even if device temporarily invisible
        if let savedUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier) {
            return savedUID
        }
        // 5: System default
        if let defaultDeviceUID, availableDevices.contains(where: { $0.uid == defaultDeviceUID }) {
            return defaultDeviceUID
        }
        // 6: First visible device
        return availableDevices.first?.uid ?? ""
    }

    // MARK: - Lifecycle

    func start() {
        // Monitors have internal guards against double-starting
        processMonitor.start()
        updateDisplayedAppsState(activeApps: processMonitor.activeApps)
        deviceMonitor.start()
        applyPersistedSettings()
        logger.info("AudioEngine started")
    }

    func stop() {
        processMonitor.stop()
        deviceMonitor.stop()
        deviceVolumeMonitor.stop()
        mediaNotificationMonitor.stop()
        diagnosticPollTask?.cancel()
        diagnosticPollTask = nil
        pauseRecoveryPollTask?.cancel()
        pauseRecoveryPollTask = nil
        for task in pendingCleanup.values { task.cancel() }
        pendingCleanup.removeAll()
        serviceRestartTask?.cancel()
        serviceRestartTask = nil
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

    // MARK: - Volume & EQ

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

    // MARK: - Routing

    func setDevice(for app: AudioApp, deviceUID: String, source: String = "unknown") {
        // Allow re-routing when tap is missing (e.g., previous activation failed)
        // so users can retry device selection instead of getting silently blocked.
        let tapExists = taps[app.id] != nil
        guard appDeviceRouting[app.id] != deviceUID || !tapExists else {
            logger.debug("[ROUTE] setDevice(\(app.name), \(deviceUID)) skipped — already routed (source=\(source))")
            return
        }

        let hasInflightSwitch = switchTasks[app.id] != nil
        logger.info("[ROUTE] setDevice(\(app.name), \(deviceUID)) source=\(source) current=\(self.appDeviceRouting[app.id] ?? "nil") hasInflightSwitch=\(hasInflightSwitch)")

        // Explicit device selection clears temporary follow-default state
        followsDefault.remove(app.id)

        // Cancel any in-flight switch for this app to prevent concurrent switches.
        // Concurrent switchDevice calls on the same ProcessTapController corrupt
        // crossfade state and can cause crackling, audio drops, or stuck taps.
        if hasInflightSwitch {
            logger.info("[ROUTE] Cancelling in-flight switch for \(app.name) (source=\(source), new target=\(deviceUID))")
        }
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
    func routeAllApps(to deviceUID: String, source: String = "unknown") {
        // SAFETY: Reject routing during recreation to prevent spurious device-change
        // notifications from corrupting all persisted routing data.
        // This is belt-and-suspenders with the callback guard — if a notification
        // slips past the callback check, this prevents data corruption.
        if shouldSuppressDeviceNotifications {
            logger.warning("routeAllApps(\(deviceUID)) blocked — recreation active or grace period")
            return
        }

        // PROTECTION: Detect rapid contradictory reroutes that indicate a feedback loop.
        // If routeAllApps was called very recently to a DIFFERENT device, something is
        // fighting over the default device. Log prominently for diagnostics.
        let now = CFAbsoluteTimeGetCurrent()
        if let lastDevice = lastRouteAllAppsDevice, lastDevice != deviceUID,
           now - lastRouteAllAppsTimestamp < 1.0 {
            logger.warning("[ROUTE-CONFLICT] routeAllApps(\(deviceUID)) contradicts recent routeAllApps(\(lastDevice)) from \(String(format: "%.0f", (now - self.lastRouteAllAppsTimestamp) * 1000))ms ago (source=\(source))")
        }
        lastRouteAllAppsTimestamp = now
        lastRouteAllAppsDevice = deviceUID

        // Early exit: if all in-memory routings already point at this device
        // AND all persisted routings match, skip the entire operation.
        // This prevents unnecessary settings writes from no-op device changes
        // (e.g., spurious notifications that slip past the grace period).
        let allMemoryMatch = appDeviceRouting.values.allSatisfy { $0 == deviceUID }
        let persistedSnapshot = settingsManager.snapshotDeviceRoutings()
        let allPersistedMatch = persistedSnapshot.isEmpty || persistedSnapshot.values.allSatisfy { $0 == deviceUID }
        if allMemoryMatch && allPersistedMatch && !appDeviceRouting.isEmpty {
            logger.debug("routeAllApps(\(deviceUID)) skipped — all routings already match")
            return
        }

        // Update persisted routing for ALL known app identifiers so that
        // inactive/paused apps will use the new device when they start playing again.
        settingsManager.updateAllDeviceRoutings(to: deviceUID)

        // Update in-memory routing for displayed-but-not-active apps
        // (e.g., paused app shown via lastDisplayedApp cache)
        if apps.isEmpty {
            for app in displayedApps {
                appDeviceRouting[app.id] = deviceUID
            }
            logger.debug("No active apps to route — updated \(self.displayedApps.count) displayed app(s)")
            return
        }

        var appsToSwitch = apps.filter { shouldRouteAllApps(for: $0) && appDeviceRouting[$0.id] != deviceUID }

        // PROTECTION: Skip apps with in-flight switches to prevent cancelling
        // a switch that's already in progress. The in-flight switch will complete
        // and route the app correctly; cancelling it mid-crossfade causes the
        // "already on target" stale-state bug.
        let appsWithInflightSwitch = appsToSwitch.filter { switchTasks[$0.id] != nil }
        if !appsWithInflightSwitch.isEmpty {
            let names = appsWithInflightSwitch.map(\.name).joined(separator: ", ")
            logger.warning("[ROUTE-PROTECT] Skipping \(appsWithInflightSwitch.count) app(s) with in-flight switches: \(names) (source=\(source))")
            appsToSwitch = appsToSwitch.filter { switchTasks[$0.id] == nil }
        }

        if appsToSwitch.isEmpty {
            logger.debug("All \(self.apps.count) app(s) already on device or have in-flight switches: \(deviceUID)")
            return
        }

        logger.info("Routing \(appsToSwitch.count)/\(self.apps.count) app(s) to device: \(deviceUID) (source=\(source))")
        for app in appsToSwitch {
            setDevice(for: app, deviceUID: deviceUID, source: source)
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

    // MARK: - Settings

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

            // Always route to the current macOS system default on startup.
            // Persisted device routing reflects "the last device used" which may be stale
            // (e.g., AirPods were default last session, now speakers are default).
            // Users expect apps to follow the system default when FineTune launches.
            let deviceUID: String
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
                logger.debug("App \(app.name) assigned to system default: \(deviceUID)")
            } catch {
                logger.error("Failed to get default device for \(app.name): \(error.localizedDescription)")
                continue
            }
            appDeviceRouting[app.id] = deviceUID

            // Load saved volume and mute state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)

            // Always create tap for audio apps (always-on strategy)
            ensureTapExists(for: app, deviceUID: deviceUID)

            // Mark as applied regardless of tap outcome to prevent retry storm:
            // without this, every onAppsChanged fires the full sequence again
            // (write routing → attempt tap → fail → clean up) for already-failed apps.
            // Recovery is handled by health checks, service restart, and app reappearance.
            appliedPIDs.insert(app.id)

            guard taps[app.id] != nil else {
                // Remove stale routing so UI falls back to showing default device
                // (no tap = audio goes through system default, not the saved device)
                appDeviceRouting.removeValue(forKey: app.id)
                continue
            }

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

    // MARK: - Tap Management

    private func ensureTapExists(for app: AudioApp, deviceUID: String) {
        guard taps[app.id] == nil else { return }
        onTapCreationAttemptForTests?(app, deviceUID)

        let tap = ProcessTapController(app: app, targetDeviceUID: deviceUID, deviceMonitor: deviceMonitor)
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
            let checkIntervals: [Duration] = fastHealthCheckIntervals
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
                    // Check current permissionConfirmed (not captured value) — the restart
                    // handler may have already confirmed and upgraded taps inline.
                    if needsPermissionConfirmation && !self.permissionConfirmed && Self.shouldConfirmPermission(from: d) {
                        self.permissionConfirmed = true
                        self.logger.info("[PERMISSION] System audio permission confirmed — upgrading taps to .mutedWhenTapped")
                        self.upgradeTapsToMutedWhenTapped()
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

                    // Dead = IO proc never fired at all (e.g., tap targeting wrong device,
                    // or macOS 26 bundle-ID tap failure). After all fast checks with zero
                    // callbacks, tear down and reroute to system default.
                    if checkNum == checkIntervals.count - 1 && d.callbackCount == 0 {
                        guard let app = self.apps.first(where: { $0.id == pid }) else { return }
                        let currentDeviceUID = self.appDeviceRouting[pid]

                        // Try system default device as fallback
                        let fallbackUID: String?
                        do {
                            let defaultUID = try self.defaultOutputDeviceUIDProvider()
                            fallbackUID = (defaultUID != currentDeviceUID) ? defaultUID : nil
                        } catch {
                            fallbackUID = nil
                        }

                        if let fallbackUID {
                            self.logger.warning("[HEALTH-FAST] \(appName) tap dead (callbacks=0 after \(checkIntervals.count) checks), rerouting to system default \(fallbackUID)")
                            tap.invalidate()
                            self.taps.removeValue(forKey: pid)
                            self.appliedPIDs.remove(pid)
                            self.lastHealthSnapshots.removeValue(forKey: pid)
                            self.appDeviceRouting[pid] = fallbackUID
                            self.settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: fallbackUID)
                            self.ensureTapExists(for: app, deviceUID: fallbackUID)
                        } else {
                            self.logger.warning("[HEALTH-FAST] \(appName) tap dead (callbacks=0), already on default device — recreating in place")
                            tap.invalidate()
                            self.taps.removeValue(forKey: pid)
                            self.appliedPIDs.remove(pid)
                            self.lastHealthSnapshots.removeValue(forKey: pid)
                            if let deviceUID = currentDeviceUID {
                                self.ensureTapExists(for: app, deviceUID: deviceUID)
                            }
                        }
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
    /// Uses async destruction to ensure CoreAudio resources are fully torn down before
    /// creating new taps, preventing resource conflicts with the old taps.
    private func recreateAllTaps() {
        // Set flag synchronously BEFORE entering the Task to prevent any interleaved
        // MainActor work (e.g., debounced device-change notifications) from firing
        // routeAllApps between this call and the Task body executing.
        isRecreatingTaps = true
        snapshotRouting()
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for (pid, tap) in taps {
                    let appName = apps.first(where: { $0.id == pid })?.name ?? "PID:\(pid)"
                    logger.info("[RECREATE] Destroying tap for \(appName)")
                    group.addTask { await tap.invalidateAsync() }
                }
            }
            taps.removeAll()
            appliedPIDs.removeAll()
            lastHealthSnapshots.removeAll()
            applyPersistedSettings()
            restoreRouting()
            isRecreatingTaps = false
            recreationEndedAt = Date()
        }
    }

    /// Upgrades all active taps to `.mutedWhenTapped` in place using live reconfiguration.
    /// No taps are destroyed — avoids audio gap and spurious device-change notifications.
    /// Falls back to `recreateAllTaps()` if any tap fails the live update.
    private func upgradeTapsToMutedWhenTapped() {
        var allSucceeded = true
        for (pid, tap) in taps {
            let appName = apps.first(where: { $0.id == pid })?.name ?? "PID:\(pid)"
            if tap.updateMuteBehavior(to: .mutedWhenTapped) {
                logger.info("[PERMISSION] Upgraded \(appName) to .mutedWhenTapped (live)")
            } else {
                logger.warning("[PERMISSION] Live upgrade failed for \(appName)")
                allSucceeded = false
            }
        }
        if !allSucceeded {
            logger.warning("[PERMISSION] Falling back to recreateAllTaps()")
            recreateAllTaps()
        }
    }

    // MARK: - Device Disconnect

    /// Called when device disappears - switches affected apps to fallback WITHOUT persisting.
    /// The original device preference is preserved in SettingsManager so that reconnect
    /// recovery can switch the app back when the device reappears.
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
        var tapsToSwitch: [(pid: pid_t, tap: ProcessTapController)] = []

        for app in apps {
            if appDeviceRouting[app.id] == deviceUID {
                affectedApps.append(app)

                // Cancel any in-flight switch to the now-disconnected device
                switchTasks[app.id]?.cancel()
                switchTasks.removeValue(forKey: app.id)

                // Update in-memory routing ONLY — do NOT persist the fallback.
                // This preserves the original device preference in SettingsManager
                // so handleDeviceConnected can restore it on reconnect.
                appDeviceRouting[app.id] = fallbackDevice.uid
                followsDefault.insert(app.id)

                if let tap = taps[app.id] {
                    tapsToSwitch.append((pid: app.id, tap: tap))
                }
            }
        }

        // Switch taps directly (bypassing setDevice which would persist)
        if !tapsToSwitch.isEmpty {
            for (pid, tap) in tapsToSwitch {
                switchTasks[pid] = Task {
                    do {
                        try await tap.switchDevice(to: fallbackDevice.uid)
                        tap.volume = self.volumeState.getVolume(for: pid)
                        tap.isMuted = self.volumeState.getMute(for: pid)
                        if let device = self.deviceMonitor.device(for: fallbackDevice.uid) {
                            tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                            tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                        }
                    } catch {
                        self.logger.error("Failed to switch PID \(pid) to fallback: \(error.localizedDescription)")
                    }
                    self.switchTasks.removeValue(forKey: pid)
                }
            }
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) disconnected, \(affectedApps.count) app(s) switched to \(fallbackDevice.name)")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showDisconnectNotification(deviceName: deviceName, fallbackName: fallbackDevice.name, affectedApps: affectedApps)
            }
        }
    }

    /// Called when a device reappears - switches apps back to their preferred device
    /// if their persisted routing matches the reconnected device UID.
    private func handleDeviceConnected(_ deviceUID: String, name deviceName: String) {
        var affectedApps: [AudioApp] = []
        var tapsToSwitch: [(pid: pid_t, tap: ProcessTapController)] = []

        for app in apps {
            // Skip apps that are persisted as following default — they chose default intentionally
            guard !settingsManager.isFollowingDefault(for: app.persistenceIdentifier) else { continue }

            // Check if this app's PERSISTED routing matches the reconnected device
            let persistedUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier)
            guard persistedUID == deviceUID else { continue }

            // Only switch back if the app is currently on a different device
            guard appDeviceRouting[app.id] != deviceUID else { continue }

            affectedApps.append(app)
            appDeviceRouting[app.id] = deviceUID
            followsDefault.remove(app.id)

            if let tap = taps[app.id] {
                tapsToSwitch.append((pid: app.id, tap: tap))
            }
        }

        // Switch taps back to the reconnected device
        if !tapsToSwitch.isEmpty {
            for (pid, tap) in tapsToSwitch {
                switchTasks[pid]?.cancel()
                switchTasks[pid] = Task {
                    do {
                        try await tap.switchDevice(to: deviceUID)
                        tap.volume = self.volumeState.getVolume(for: pid)
                        tap.isMuted = self.volumeState.getMute(for: pid)
                        if let device = self.deviceMonitor.device(for: deviceUID) {
                            tap.currentDeviceVolume = self.deviceVolumeMonitor.volumes[device.id] ?? 1.0
                            tap.isDeviceMuted = self.deviceVolumeMonitor.muteStates[device.id] ?? false
                        }
                        self.logger.debug("Switched PID \(pid) back to reconnected device: \(deviceName)")
                    } catch {
                        self.logger.error("Failed to switch PID \(pid) back to \(deviceName): \(error.localizedDescription)")
                    }
                    self.switchTasks.removeValue(forKey: pid)
                }
            }
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) reconnected, switched \(affectedApps.count) app(s) back")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showReconnectNotification(deviceName: deviceName, affectedApps: affectedApps)
            }
        }
    }

    /// Notification shown when a previously-disconnected device reappears and apps are switched back.
    private func showReconnectNotification(deviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Reconnected"
        content.body = "\"\(deviceName)\" is back. \(affectedApps.count) app(s) switched back."
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-reconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show reconnect notification: \(error.localizedDescription)")
            }
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

    // MARK: - Stale Tap Cleanup

    func cleanupStaleTaps() {
        let activePIDs = Set(apps.map { $0.id })
        let stalePIDs = Set(taps.keys).subtracting(activePIDs)

        // NOTE: Do NOT cancel in-flight switch tasks here. Processes can momentarily
        // disappear from the process list during aggregate device creation (crossfade).
        // Cancelling the switch task immediately causes the crossfade to abort, leaving
        // audio on the wrong device. Switch tasks are cancelled in the grace period
        // cleanup below, after we're confident the process is truly gone.

        // Cancel cleanup for PIDs that reappeared
        for pid in activePIDs {
            if let task = pendingCleanup.removeValue(forKey: pid) {
                task.cancel()
                logger.debug("Cancelled pending cleanup for PID \(pid) - app reappeared")
            }
        }

        // Schedule cleanup for newly stale PIDs (with grace period)
        // Grace period allows for brief audio interruptions without destroying taps
        // This is generous enough to handle most transient cases while still cleaning up promptly
        for pid in stalePIDs {
            guard pendingCleanup[pid] == nil else { continue }  // Already pending

            pendingCleanup[pid] = Task { @MainActor [staleTapGracePeriod] in
                try? await Task.sleep(for: staleTapGracePeriod)
                guard !Task.isCancelled else { return }

                // Double-check still stale - app may have reappeared during grace period
                let currentPIDs = Set(self.apps.map { $0.id })
                guard !currentPIDs.contains(pid) else {
                    self.pendingCleanup.removeValue(forKey: pid)
                    self.logger.debug("Cleanup cancelled for PID \(pid) - app reappeared during grace period")
                    return
                }

                // Process is confirmed gone — now safe to cancel switch tasks and cleanup
                self.switchTasks[pid]?.cancel()
                self.switchTasks.removeValue(forKey: pid)

                if let tap = self.taps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.logger.info("Cleaned up stale tap for PID \(pid) after grace period")
                }
                self.appDeviceRouting.removeValue(forKey: pid)
                self.followsDefault.remove(pid)
                self.pendingCleanup.removeValue(forKey: pid)
            }
        }

        // Include pending PIDs in cleanup exclusion to avoid premature state cleanup
        let pidsToKeep = activePIDs.union(Set(pendingCleanup.keys))
        appliedPIDs = appliedPIDs.intersection(pidsToKeep)
        followsDefault = followsDefault.intersection(pidsToKeep)
        volumeState.cleanup(keeping: pidsToKeep)
    }

    private func updateDisplayedAppsState(activeApps: [AudioApp]) {
        let activeIDs = Set(activeApps.map(\.id))
        var pidsToKeep = activeIDs
        if let cachedID = lastDisplayedApp?.id {
            pidsToKeep.insert(cachedID)
        }
        lastAudibleAtByPID = lastAudibleAtByPID.filter { pidsToKeep.contains($0.key) }
        pauseStateByPID = pauseStateByPID.filter { pidsToKeep.contains($0.key) }
        defer { previousActiveAppIDs = activeIDs }

        guard !activeApps.isEmpty else {
            guard let cached = lastDisplayedApp else { return }
            // In tests, fake PIDs are not OS processes; keep fallback deterministic.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            if !isProcessRunningProvider(cached.id) {
                lastDisplayedApp = nil
            }
            return
        }

        for pid in activeIDs where lastAudibleAtByPID[pid] == nil {
            lastAudibleAtByPID[pid] = Date()
        }

        let newlyActiveIDs = activeIDs.subtracting(previousActiveAppIDs)
        if let newest = activeApps.first(where: { newlyActiveIDs.contains($0.id) }) {
            lastDisplayedApp = newest
            return
        }

        if let cached = lastDisplayedApp,
           let refreshed = activeApps.first(where: { $0.id == cached.id }) {
            lastDisplayedApp = refreshed
            return
        }

        lastDisplayedApp = activeApps.first
    }

    // MARK: - Test Helpers

    /// Test-only hook to apply persisted settings to a controlled app list.
    @MainActor
    func applyPersistedSettingsForTests(apps: [AudioApp]) {
        applyPersistedSettings(for: apps)
    }

    @MainActor
    func updateDisplayedAppsStateForTests(activeApps: [AudioApp]) {
        processMonitor.setActiveAppsForTests(activeApps, notify: false)
        updateDisplayedAppsState(activeApps: activeApps)
    }

    @MainActor
    func setLastAudibleAtForTests(pid: pid_t, date: Date?) {
        lastAudibleAtByPID[pid] = date
    }

    @MainActor
    func setPauseEligibilityForTests(_ pids: Set<pid_t>?) {
        pauseEligiblePIDsForTests = pids
    }

    // MARK: - Input Device Lock

    /// Handles changes to the default input device.
    /// Uses timing heuristic to distinguish auto-switch (from device connection) vs user action.
    private func handleDefaultInputDeviceChanged(_ newDefaultInputUID: String) {
        // If WE initiated this change, just reset flag and return
        if didInitiateInputSwitch {
            didInitiateInputSwitch = false
            return
        }

        // If lock is disabled, let system control input
        guard settingsManager.appSettings.lockInputDevice else { return }

        // Check if this change happened right after a device connection
        let isAutoSwitch = lastInputDeviceConnectTime.map {
            Date().timeIntervalSince($0) < autoSwitchGracePeriod
        } ?? false

        if isAutoSwitch {
            // This is likely an automatic switch triggered by device connection
            // Restore our locked device
            logger.info("Auto-switch detected after device connection, restoring locked input device")
            restoreLockedInputDevice()
        } else {
            // This is likely a user-initiated change (System Settings, another app, etc.)
            // Respect their choice and update our locked device
            logger.info("User changed input device to: \(newDefaultInputUID) - updating lock")
            settingsManager.setLockedInputDeviceUID(newDefaultInputUID)
        }
    }

    /// Restores the locked input device, or falls back to built-in mic if unavailable.
    private func restoreLockedInputDevice() {
        guard let lockedUID = settingsManager.lockedInputDeviceUID,
              let lockedDevice = deviceMonitor.inputDevice(for: lockedUID) else {
            // No locked device or it's unavailable - fall back to built-in
            lockToBuiltInMicrophone()
            return
        }

        // Don't restore if already on the locked device
        guard deviceVolumeMonitor.defaultInputDeviceUID != lockedUID else { return }

        logger.info("Restoring locked input device: \(lockedDevice.name)")
        didInitiateInputSwitch = true
        deviceVolumeMonitor.setDefaultInputDevice(lockedDevice.id)
    }

    /// Locks the input device to the built-in microphone.
    private func lockToBuiltInMicrophone() {
        guard let builtInMic = deviceMonitor.inputDevices.first(where: {
            $0.id.readTransportType() == .builtIn
        }) else {
            logger.warning("No built-in microphone found")
            return
        }

        setLockedInputDevice(builtInMic)
    }

    /// Called when user explicitly selects an input device (via FineTune UI).
    /// Persists the choice and applies the change.
    func setLockedInputDevice(_ device: AudioDevice) {
        logger.info("User locked input device to: \(device.name)")

        // Persist the choice
        settingsManager.setLockedInputDeviceUID(device.uid)

        // Apply the change
        didInitiateInputSwitch = true
        deviceVolumeMonitor.setDefaultInputDevice(device.id)
    }

    /// Handles locked input device disconnect - falls back to built-in mic.
    private func handleInputDeviceDisconnected(_ deviceUID: String) {
        // If the locked device disconnected, fall back to built-in mic
        guard settingsManager.appSettings.lockInputDevice,
              settingsManager.lockedInputDeviceUID == deviceUID else { return }

        logger.info("Locked input device disconnected, falling back to built-in mic")
        lockToBuiltInMicrophone()
    }
}
