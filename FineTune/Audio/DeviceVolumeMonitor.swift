// FineTune/Audio/DeviceVolumeMonitor.swift
import AppKit
import AudioToolbox
import os

// coreAudioListenerQueue is now CoreAudioQueues.listenerQueue in Types/CoreAudioQueues.swift
private let coreAudioListenerQueue = CoreAudioQueues.listenerQueue

@Observable
@MainActor
final class DeviceVolumeMonitor {
    /// Volumes for all tracked output devices (keyed by AudioDeviceID)
    private(set) var volumes: [AudioDeviceID: Float] = [:]

    /// Mute states for all tracked output devices (keyed by AudioDeviceID)
    private(set) var muteStates: [AudioDeviceID: Bool] = [:]

    /// The current default output device ID
    private(set) var defaultDeviceID: AudioDeviceID = .unknown

    /// The current default output device UID (cached to avoid redundant Core Audio calls)
    private(set) var defaultDeviceUID: String?

    /// Called when any device's volume changes (deviceID, newVolume)
    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?

    /// Called when any device's mute state changes (deviceID, isMuted)
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?

    /// Called when default device changes externally (e.g., from System Settings)
    /// This allows AudioEngine to route all apps to the new device
    var onDefaultDeviceChangedExternally: ((_ deviceUID: String) -> Void)?

    /// Flag to track if WE initiated the default device change (prevents feedback loop)
    private var isSettingDefaultDevice = false

    /// Timestamp of the last self-initiated default device change
    /// Used to ignore subsequent listener callbacks that are just echoes of our own action
    private var lastSelfChangeTimestamp: TimeInterval = 0

    private let deviceMonitor: AudioDeviceMonitor
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "DeviceVolumeMonitor")

    /// Volume listeners for each tracked device
    private var volumeListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    /// Mute listeners for each tracked device
    private var muteListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var serviceRestartListenerBlock: AudioObjectPropertyListenerBlock?

    /// Debounce tasks to coalesce rapid listener callbacks
    private var defaultDeviceDebounceTask: Task<Void, Never>?
    private var volumeDebounceTasks: [AudioDeviceID: Task<Void, Never>] = [:]
    private var muteDebounceTasks: [AudioDeviceID: Task<Void, Never>] = [:]

    /// Flag to control the recursive observation loop
    private var isObservingDeviceList = false
    /// Task handle for device list observation (allows explicit cancellation)
    private var observationTask: Task<Void, Never>?

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var serviceRestartAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyServiceRestarted,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(deviceMonitor: AudioDeviceMonitor) {
        self.deviceMonitor = deviceMonitor
        // Read default device synchronously so UI has correct value before first render
        refreshDefaultDevice()
    }

    func start() {
        guard defaultDeviceListenerBlock == nil else { return }

        logger.debug("Starting device volume monitor")

        // Read initial default device
        refreshDefaultDevice()

        // Read volumes for all devices and set up listeners
        refreshDeviceListeners()

        // Listen for default output device changes (with debouncing)
        defaultDeviceListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.defaultDeviceDebounceTask?.cancel()
                self?.defaultDeviceDebounceTask = Task { @MainActor [weak self] in
                    // Wait 300ms to let System Settings finish its handshake with coreaudiod
                    // before we potentially hammer the HAL with app re-routing.
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    self?.handleDefaultDeviceChanged()
                }
            }
        }

        let defaultDeviceStatus = AudioObjectAddPropertyListenerBlock(
            .system,
            &defaultDeviceAddress,
            coreAudioListenerQueue,
            defaultDeviceListenerBlock!
        )

        if defaultDeviceStatus != noErr {
            logger.error("Failed to add default device listener: \(defaultDeviceStatus)")
        }

        // Listen for coreaudiod restart to recover from daemon crashes
        serviceRestartListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleServiceRestarted()
            }
        }

        let serviceRestartStatus = AudioObjectAddPropertyListenerBlock(
            .system,
            &serviceRestartAddress,
            coreAudioListenerQueue,
            serviceRestartListenerBlock!
        )

        if serviceRestartStatus != noErr {
            logger.error("Failed to add service restart listener: \(serviceRestartStatus)")
        }

        // Observe device list changes from deviceMonitor using withObservationTracking
        startObservingDeviceList()
    }

    func stop() {
        logger.debug("Stopping device volume monitor")

        // Stop the device list observation loop and cancel the task
        isObservingDeviceList = false
        observationTask?.cancel()
        observationTask = nil

        // Cancel all debounce tasks
        defaultDeviceDebounceTask?.cancel()
        defaultDeviceDebounceTask = nil
        for task in volumeDebounceTasks.values {
            task.cancel()
        }
        volumeDebounceTasks.removeAll()
        for task in muteDebounceTasks.values {
            task.cancel()
        }
        muteDebounceTasks.removeAll()

        // Remove default device listener
        if let block = defaultDeviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &defaultDeviceAddress, coreAudioListenerQueue, block)
            defaultDeviceListenerBlock = nil
        }

        // Remove service restart listener
        if let block = serviceRestartListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &serviceRestartAddress, coreAudioListenerQueue, block)
            serviceRestartListenerBlock = nil
        }

        // Remove all volume listeners
        for deviceID in Array(volumeListeners.keys) {
            removeVolumeListener(for: deviceID)
        }

        // Remove all mute listeners
        for deviceID in Array(muteListeners.keys) {
            removeMuteListener(for: deviceID)
        }

        volumes.removeAll()
        muteStates.removeAll()
    }

    /// Sets the volume for a specific device
    func setVolume(for deviceID: AudioDeviceID, to volume: Float) {
        guard deviceID.isValid else {
            logger.warning("Cannot set volume: invalid device ID")
            return
        }

        let success = deviceID.setOutputVolumeScalar(volume)
        if success {
            volumes[deviceID] = volume
        } else {
            logger.warning("Failed to set volume on device \(deviceID)")
        }
    }

    /// Sets a device as the macOS system default output device
    @discardableResult
    func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID.isValid else {
            logger.warning("Cannot set default device: invalid device ID")
            return false
        }

        // Set flag to prevent our own change from triggering onDefaultDeviceChangedExternally
        isSettingDefaultDevice = true
        defer { isSettingDefaultDevice = false }

        do {
            try AudioDeviceID.setDefaultOutputDevice(deviceID)
            logger.debug("Set default output device to \(deviceID)")

            // Record timestamp to ignore the subsequent listener callback (feedback loop prevention)
            lastSelfChangeTimestamp = Date().timeIntervalSince1970

            // Manually trigger the notification so apps route immediately.
            // We ignore the listener callback, so this is required for apps to follow the selection.
            if let uid = try? deviceID.readDeviceUID() {
                // Update local state immediately for UI responsiveness
                self.defaultDeviceID = deviceID
                self.defaultDeviceUID = uid
                self.onDefaultDeviceChangedExternally?(uid)
            }

            Task.detached { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                let confirmedID = try? AudioDeviceID.readDefaultOutputDevice()
                let confirmedUID = try? confirmedID?.readDeviceUID()

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard let confirmedID, confirmedID.isValid else { return }
                    if confirmedID != deviceID {
                        self.defaultDeviceID = confirmedID
                        self.defaultDeviceUID = confirmedUID
                        if let uid = confirmedUID {
                            self.onDefaultDeviceChangedExternally?(uid)
                        }
                    }
                }
            }

            return true
        } catch {
            logger.error("Failed to set default device: \(error.localizedDescription)")
            return false
        }
    }

    /// Sets the mute state for a specific device
    func setMute(for deviceID: AudioDeviceID, to muted: Bool) {
        guard deviceID.isValid else {
            logger.warning("Cannot set mute: invalid device ID")
            return
        }

        let success = deviceID.setMuteState(muted)
        if success {
            muteStates[deviceID] = muted
        } else {
            logger.warning("Failed to set mute on device \(deviceID)")
        }
    }

    // MARK: - Internal Methods

    /// Re-reads the default output device from CoreAudio.
    /// Called on startup and when popup becomes visible to catch any missed updates.
    func refreshDefaultDevice() {
        do {
            let newDeviceID: AudioDeviceID = try AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultOutputDevice,
                defaultValue: AudioDeviceID.unknown
            )

            if newDeviceID.isValid {
                defaultDeviceID = newDeviceID
                defaultDeviceUID = try? newDeviceID.readDeviceUID()
                logger.debug("Default device ID: \(self.defaultDeviceID), UID: \(self.defaultDeviceUID ?? "nil")")
            } else {
                logger.warning("Default output device is invalid")
                defaultDeviceID = .unknown
                defaultDeviceUID = nil
            }

        } catch {
            logger.error("Failed to read default output device: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods

    /// Handles default device change notification by reading on background thread to avoid blocking MainActor
    private func handleDefaultDeviceChanged() {
        // Skip if we initiated this change (prevents feedback loop)
        // Check both the flag (for synchronous re-entry) and the timestamp (for async listener latency)
        let now = Date().timeIntervalSince1970
        if isSettingDefaultDevice || (now - lastSelfChangeTimestamp < 1.0) {
            logger.debug("Default device changed (self-initiated, ignoring)")
            return
        }

        logger.debug("Default output device changed externally")
        Task.detached { [weak self] in
            // Read CoreAudio properties on background thread to avoid blocking MainActor
            let newDeviceID = try? AudioDeviceID.readDefaultOutputDevice()
            let newDeviceUID = try? newDeviceID?.readDeviceUID()
            let isVirtual = newDeviceID?.isVirtualDevice() ?? false

            // Bluetooth devices need extra time for stream initialization after connection.
            // Without this, process tap creation may fail because output streams aren't ready yet,
            // causing audio to not play until the device is "poked" (e.g., by System Settings).
            let transport = newDeviceID?.readTransportType() ?? .unknown
            if transport == .bluetooth || transport == .bluetoothLE {
                try? await Task.sleep(for: .milliseconds(500))
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let id = newDeviceID, id.isValid {
                    self.applyDefaultDeviceChange(deviceID: id, deviceUID: newDeviceUID, isVirtual: isVirtual)
                }
            }
        }
    }

    @MainActor
    private func applyDefaultDeviceChange(
        deviceID: AudioDeviceID,
        deviceUID: String?,
        isVirtual: Bool
    ) {
        // Skip routing to virtual devices (e.g., SRAudioDriver, BlackHole)
        // These are typically audio capture/loopback drivers that don't produce audible output.
        // FineTune would mute the app's audio via process tap but deliver it to a silent virtual device.
        if isVirtual {
            logger.info("Default device changed to virtual device \(deviceUID ?? "nil") — ignoring to prevent silent routing")
            return
        }

        defaultDeviceID = deviceID
        defaultDeviceUID = deviceUID

        logger.debug("Default device updated: \(deviceID), UID: \(deviceUID ?? "nil")")

        // Notify AudioEngine to route all apps to the new device
        if let uid = deviceUID {
            onDefaultDeviceChangedExternally?(uid)
        }
    }

    // MARK: - Test Helpers

    /// Test-only hook to simulate default output device changes without CoreAudio.
    @MainActor
    func applyDefaultDeviceChangeForTests(
        deviceID: AudioDeviceID,
        deviceUID: String?,
        isVirtual: Bool
    ) {
        applyDefaultDeviceChange(deviceID: deviceID, deviceUID: deviceUID, isVirtual: isVirtual)
    }

    /// Synchronizes volume and mute listeners with the current device list from deviceMonitor
    private func refreshDeviceListeners() {
        let currentDeviceIDs = Set(deviceMonitor.outputDevices.map(\.id))
        let trackedVolumeIDs = Set(volumeListeners.keys)
        let trackedMuteIDs = Set(muteListeners.keys)

        // Add listeners for new devices
        let newDeviceIDs = currentDeviceIDs.subtracting(trackedVolumeIDs)
        for deviceID in newDeviceIDs {
            addVolumeListener(for: deviceID)
            addMuteListener(for: deviceID)
        }

        // Remove listeners for stale devices
        let staleVolumeIDs = trackedVolumeIDs.subtracting(currentDeviceIDs)
        for deviceID in staleVolumeIDs {
            removeVolumeListener(for: deviceID)
            volumes.removeValue(forKey: deviceID)
        }

        let staleMuteIDs = trackedMuteIDs.subtracting(currentDeviceIDs)
        for deviceID in staleMuteIDs {
            removeMuteListener(for: deviceID)
            muteStates.removeValue(forKey: deviceID)
        }

        // Read volumes and mute states for all current devices
        readAllStates()
    }

    private func addVolumeListener(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        guard volumeListeners[deviceID] == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleVolumeChanged(for: deviceID)
            }
        }

        volumeListeners[deviceID] = block

        var address = volumeAddress
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            coreAudioListenerQueue,
            block
        )

        if status != noErr {
            logger.warning("Failed to add volume listener for device \(deviceID): \(status)")
            volumeListeners.removeValue(forKey: deviceID)
        }
    }

    private func removeVolumeListener(for deviceID: AudioDeviceID) {
        guard let block = volumeListeners[deviceID] else { return }

        var address = volumeAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, coreAudioListenerQueue, block)
        volumeListeners.removeValue(forKey: deviceID)
    }

    /// Handles volume change notification with debouncing and background read
    private func handleVolumeChanged(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }

        // Cancel any pending debounce for this device
        volumeDebounceTasks[deviceID]?.cancel()
        volumeDebounceTasks[deviceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }

            // Read on background thread
            await Task.detached { [weak self] in
                let newVolume = deviceID.readOutputVolumeScalar()

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.volumes[deviceID] = newVolume
                    self.onVolumeChanged?(deviceID, newVolume)
                    self.logger.debug("Volume changed for device \(deviceID): \(newVolume)")
                }
            }.value
        }
    }

    private func addMuteListener(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        guard muteListeners[deviceID] == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleMuteChanged(for: deviceID)
            }
        }

        muteListeners[deviceID] = block

        var address = muteAddress
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            coreAudioListenerQueue,
            block
        )

        if status != noErr {
            logger.warning("Failed to add mute listener for device \(deviceID): \(status)")
            muteListeners.removeValue(forKey: deviceID)
        }
    }

    private func removeMuteListener(for deviceID: AudioDeviceID) {
        guard let block = muteListeners[deviceID] else { return }

        var address = muteAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, coreAudioListenerQueue, block)
        muteListeners.removeValue(forKey: deviceID)
    }

    /// Handles mute change notification with debouncing and background read
    private func handleMuteChanged(for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }

        // Cancel any pending debounce for this device
        muteDebounceTasks[deviceID]?.cancel()
        muteDebounceTasks[deviceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }

            // Read on background thread
            await Task.detached { [weak self] in
                let newMuteState = deviceID.readMuteState()

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.muteStates[deviceID] = newMuteState
                    self.onMuteChanged?(deviceID, newMuteState)
                    self.logger.debug("Mute changed for device \(deviceID): \(newMuteState)")
                }
            }.value
        }
    }

    /// Handles coreaudiod restart - re-reads all state to recover from daemon crash
    private func handleServiceRestarted() {
        logger.warning("coreaudiod service restarted - re-reading all device state")

        // Re-read default device on background thread
        Task.detached { [weak self] in
            let newDeviceID = try? AudioDeviceID.readDefaultOutputDevice()
            let newDeviceUID = try? newDeviceID?.readDeviceUID()

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let id = newDeviceID, id.isValid {
                    self.defaultDeviceID = id
                    self.defaultDeviceUID = newDeviceUID
                }
                // Re-read all device volumes and mute states
                self.readAllStates()
                self.logger.debug("Recovered from coreaudiod restart")
            }
        }
    }

    /// Reads the current volume and mute state for all tracked devices.
    /// For Bluetooth devices, schedules a delayed re-read because the HAL may report
    /// default volume (1.0) for 50-200ms after the device appears.
    private func readAllStates() {
        // Capture device IDs to read
        let devices = deviceMonitor.outputDevices

        // Do CoreAudio reads on background thread to avoid blocking MainActor
        Task.detached { [weak self] in
            var volumeResults: [AudioDeviceID: Float] = [:]
            var muteResults: [AudioDeviceID: Bool] = [:]
            var bluetoothDeviceIDs: [AudioDeviceID] = []

            for device in devices {
                let volume = device.id.readOutputVolumeScalar()
                let muted = device.id.readMuteState()
                volumeResults[device.id] = volume
                muteResults[device.id] = muted

                let transportType = device.id.readTransportType()
                if transportType == .bluetooth || transportType == .bluetoothLE {
                    bluetoothDeviceIDs.append(device.id)
                }
            }

            // Update state on MainActor
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (deviceID, volume) in volumeResults {
                    self.volumes[deviceID] = volume
                }
                for (deviceID, muted) in muteResults {
                    self.muteStates[deviceID] = muted
                }
            }

            // Schedule delayed re-read for Bluetooth devices
            for deviceID in bluetoothDeviceIDs {
                try? await Task.sleep(for: .milliseconds(200))

                // Check if device is still tracked before re-reading
                let stillTracked = await MainActor.run { [weak self] in
                    self?.volumes.keys.contains(deviceID) ?? false
                }
                guard stillTracked else { continue }

                let confirmedVolume = deviceID.readOutputVolumeScalar()
                let confirmedMute = deviceID.readMuteState()

                await MainActor.run { [weak self] in
                    guard let self, self.volumes.keys.contains(deviceID) else { return }
                    self.volumes[deviceID] = confirmedVolume
                    self.muteStates[deviceID] = confirmedMute
                    self.logger.debug("Bluetooth device \(deviceID) re-read volume: \(confirmedVolume), muted: \(confirmedMute)")
                }
            }
        }
    }

    /// Starts observing deviceMonitor.outputDevices for changes
    private func startObservingDeviceList() {
        guard !isObservingDeviceList else { return }
        isObservingDeviceList = true

        // Use a stored task that can be explicitly cancelled to prevent observation leaks
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let strongSelf = self, strongSelf.isObservingDeviceList else { break }

                // Wait for the next change using withObservationTracking
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = strongSelf.deviceMonitor.outputDevices
                    } onChange: {
                        continuation.resume()
                    }
                }

                // Check cancellation and self validity again after waking
                guard !Task.isCancelled, let strongSelf = self, strongSelf.isObservingDeviceList else { break }

                strongSelf.logger.debug("Device list changed, refreshing volume listeners")
                strongSelf.refreshDeviceListeners()
            }
        }
    }

    deinit {
        // WARNING: Can't call stop() here due to MainActor isolation.
        // Callers MUST call stop() before releasing this object to remove CoreAudio listeners.
        // Orphaned listeners can corrupt coreaudiod state and break System Settings.
        // AudioEngine.stopSync() handles this for normal app termination.
    }
}
