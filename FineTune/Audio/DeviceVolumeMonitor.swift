// FineTune/Audio/DeviceVolumeMonitor.swift
import AppKit
import AudioToolbox
import os

// coreAudioListenerQueue is now CoreAudioQueues.listenerQueue in Types/CoreAudioQueues.swift
private let coreAudioListenerQueue = CoreAudioQueues.listenerQueue

@Observable
@MainActor
final class DeviceVolumeMonitor {
    // MARK: - Output Device State

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

    // MARK: - Input Device State

    /// Volumes for all tracked input devices (keyed by AudioDeviceID)
    private(set) var inputVolumes: [AudioDeviceID: Float] = [:]

    /// Mute states for all tracked input devices (keyed by AudioDeviceID)
    private(set) var inputMuteStates: [AudioDeviceID: Bool] = [:]

    /// The current default input device ID
    private(set) var defaultInputDeviceID: AudioDeviceID = .unknown

    /// The current default input device UID (cached to avoid redundant Core Audio calls)
    private(set) var defaultInputDeviceUID: String?

    /// Called when any input device's volume changes (deviceID, newVolume)
    var onInputVolumeChanged: ((AudioDeviceID, Float) -> Void)?

    /// Called when any input device's mute state changes (deviceID, isMuted)
    var onInputMuteChanged: ((AudioDeviceID, Bool) -> Void)?

    /// Called when the default input device changes (newDeviceUID)
    var onDefaultInputDeviceChanged: ((_ deviceUID: String) -> Void)?

    private let deviceMonitor: AudioDeviceMonitor
    private let settingsManager: SettingsManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "DeviceVolumeMonitor")

    // MARK: - Injectable Timing (for deterministic tests)

    /// Debounce delay for default device change handling (ms).
    var defaultDeviceDebounceMs: Int = 300

    /// Debounce delay for volume change handling (ms).
    var volumeDebounceMs: Int = 30

    /// Debounce delay for mute change handling (ms).
    var muteDebounceMs: Int = 30

    /// Bluetooth stream initialization delay (ms).
    var bluetoothInitDelayMs: Int = 500

    /// Post-setDefaultDevice confirmation delay (ms).
    var setDefaultConfirmationDelayMs: Int = 250

    /// Bluetooth re-read delay after initial state read (ms).
    var bluetoothReReadDelayMs: Int = 200

    /// Volume listeners for each tracked output device
    private var volumeListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    /// Mute listeners for each tracked output device
    private var muteListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var serviceRestartListenerBlock: AudioObjectPropertyListenerBlock?

    /// Volume listeners for each tracked input device
    private var inputVolumeListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    /// Mute listeners for each tracked input device
    private var inputMuteListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var defaultInputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Debounce tasks to coalesce rapid listener callbacks
    private var defaultDeviceDebounceTask: Task<Void, Never>?
    private var volumeDebounceTasks: [AudioDeviceID: Task<Void, Never>] = [:]
    private var muteDebounceTasks: [AudioDeviceID: Task<Void, Never>] = [:]

    /// Flag to control the recursive observation loop
    private var isObservingDeviceList = false
    private var isObservingInputDeviceList = false
    /// Task handle for device list observation (allows explicit cancellation)
    private var observationTask: Task<Void, Never>?
    private var inputObservationTask: Task<Void, Never>?

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

    private var defaultInputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var inputVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var inputMuteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    init(deviceMonitor: AudioDeviceMonitor, settingsManager: SettingsManager) {
        self.deviceMonitor = deviceMonitor
        self.settingsManager = settingsManager
        // Read default device synchronously so UI has correct value before first render
        refreshDefaultDevice()
        refreshDefaultInputDevice()
    }

    func start() {
        guard defaultDeviceListenerBlock == nil else { return }

        logger.debug("Starting device volume monitor")

        // Read initial default device
        refreshDefaultDevice()

        // Read volumes for all devices and set up listeners
        refreshDeviceListeners()

        // Listen for default output device changes (with debouncing)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.defaultDeviceDebounceTask?.cancel()
                self?.defaultDeviceDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(self?.defaultDeviceDebounceMs ?? 300))
                    guard !Task.isCancelled else { return }
                    self?.handleDefaultDeviceChanged()
                }
            }
        }
        defaultDeviceListenerBlock = AudioObjectID.system.addPropertyListener(
            address: &defaultDeviceAddress, queue: coreAudioListenerQueue, block: defaultBlock
        )

        // Listen for coreaudiod restart to recover from daemon crashes
        let restartBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleServiceRestarted()
            }
        }
        serviceRestartListenerBlock = AudioObjectID.system.addPropertyListener(
            address: &serviceRestartAddress, queue: coreAudioListenerQueue, block: restartBlock
        )

        // Observe device list changes from deviceMonitor using withObservationTracking
        startObservingDeviceList()

        // Input device monitoring
        refreshDefaultInputDevice()
        refreshInputDeviceListeners()

        // Listen for default input device changes
        let defaultInputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDefaultInputDeviceChanged()
            }
        }
        defaultInputDeviceListenerBlock = AudioObjectID.system.addPropertyListener(
            address: &defaultInputDeviceAddress, queue: coreAudioListenerQueue, block: defaultInputBlock
        )

        startObservingInputDeviceList()
    }

    func stop() {
        logger.debug("Stopping device volume monitor")

        // Stop the device list observation loops and cancel tasks
        isObservingDeviceList = false
        isObservingInputDeviceList = false
        observationTask?.cancel()
        observationTask = nil
        inputObservationTask?.cancel()
        inputObservationTask = nil

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
            AudioObjectID.system.removePropertyListener(address: &defaultDeviceAddress, queue: coreAudioListenerQueue, block: block)
            defaultDeviceListenerBlock = nil
        }

        // Remove service restart listener
        if let block = serviceRestartListenerBlock {
            AudioObjectID.system.removePropertyListener(address: &serviceRestartAddress, queue: coreAudioListenerQueue, block: block)
            serviceRestartListenerBlock = nil
        }

        // Remove default input device listener
        if let block = defaultInputDeviceListenerBlock {
            AudioObjectID.system.removePropertyListener(address: &defaultInputDeviceAddress, queue: coreAudioListenerQueue, block: block)
            defaultInputDeviceListenerBlock = nil
        }

        // Remove all output volume listeners
        for deviceID in Array(volumeListeners.keys) {
            removeDeviceListener(.volume, for: deviceID)
        }

        // Remove all output mute listeners
        for deviceID in Array(muteListeners.keys) {
            removeDeviceListener(.mute, for: deviceID)
        }

        // Remove all input volume listeners
        for deviceID in Array(inputVolumeListeners.keys) {
            removeInputDeviceListener(.volume, for: deviceID)
        }

        // Remove all input mute listeners
        for deviceID in Array(inputMuteListeners.keys) {
            removeInputDeviceListener(.mute, for: deviceID)
        }

        volumes.removeAll()
        muteStates.removeAll()
        inputVolumes.removeAll()
        inputMuteStates.removeAll()
        defaultInputDeviceID = .unknown
        defaultInputDeviceUID = nil
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

            Task.detached { [weak self, setDefaultConfirmationDelayMs] in
                try? await Task.sleep(for: .milliseconds(setDefaultConfirmationDelayMs))
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

    // MARK: - Input Device Control

    /// Sets the volume for a specific input device
    func setInputVolume(for deviceID: AudioDeviceID, to volume: Float) {
        guard deviceID.isValid else {
            logger.warning("Cannot set input volume: invalid device ID")
            return
        }

        let success = deviceID.setInputVolumeScalar(volume)
        if success {
            inputVolumes[deviceID] = volume
        } else {
            logger.warning("Failed to set input volume on device \(deviceID)")
        }
    }

    /// Sets the mute state for a specific input device
    func setInputMute(for deviceID: AudioDeviceID, to muted: Bool) {
        guard deviceID.isValid else {
            logger.warning("Cannot set input mute: invalid device ID")
            return
        }

        let success = deviceID.setInputMuteState(muted)
        if success {
            inputMuteStates[deviceID] = muted
        } else {
            logger.warning("Failed to set input mute on device \(deviceID)")
        }
    }

    /// Sets a device as the macOS system default input device
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) {
        guard deviceID.isValid else {
            logger.warning("Cannot set default input device: invalid device ID")
            return
        }

        do {
            try AudioDeviceID.setDefaultInputDevice(deviceID)
            logger.debug("Set default input device to \(deviceID)")
        } catch {
            logger.error("Failed to set default input device: \(error.localizedDescription)")
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
                let btDelay = await MainActor.run { [weak self] in self?.bluetoothInitDelayMs ?? 500 }
                try? await Task.sleep(for: .milliseconds(btDelay))
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
            logger.info("Default device changed to virtual device \(deviceUID ?? "nil") -- ignoring to prevent silent routing")
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

    // MARK: - Input Device Private Methods

    private func refreshDefaultInputDevice() {
        do {
            let newDeviceID: AudioDeviceID = try AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultInputDevice,
                defaultValue: AudioDeviceID.unknown
            )

            if newDeviceID.isValid {
                defaultInputDeviceID = newDeviceID
                defaultInputDeviceUID = try? newDeviceID.readDeviceUID()
                logger.debug("Default input device ID: \(self.defaultInputDeviceID), UID: \(self.defaultInputDeviceUID ?? "nil")")
            } else {
                logger.warning("Default input device is invalid")
                defaultInputDeviceID = .unknown
                defaultInputDeviceUID = nil
            }

        } catch {
            logger.error("Failed to read default input device: \(error.localizedDescription)")
        }
    }

    private func handleDefaultInputDeviceChanged() {
        let oldUID = defaultInputDeviceUID
        logger.debug("Default input device changed")
        refreshDefaultInputDevice()
        if let newUID = defaultInputDeviceUID, newUID != oldUID {
            onDefaultInputDeviceChanged?(newUID)
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
            addDeviceListener(.volume, for: deviceID)
            addDeviceListener(.mute, for: deviceID)
        }

        // Remove listeners for stale devices
        let staleVolumeIDs = trackedVolumeIDs.subtracting(currentDeviceIDs)
        for deviceID in staleVolumeIDs {
            removeDeviceListener(.volume, for: deviceID)
            volumes.removeValue(forKey: deviceID)
        }

        let staleMuteIDs = trackedMuteIDs.subtracting(currentDeviceIDs)
        for deviceID in staleMuteIDs {
            removeDeviceListener(.mute, for: deviceID)
            muteStates.removeValue(forKey: deviceID)
        }

        // Read volumes and mute states for all current devices
        readAllStates()
    }

    /// Synchronizes input volume and mute listeners with the current input device list
    private func refreshInputDeviceListeners() {
        let currentDeviceIDs = Set(deviceMonitor.inputDevices.map(\.id))
        let trackedVolumeIDs = Set(inputVolumeListeners.keys)
        let trackedMuteIDs = Set(inputMuteListeners.keys)

        // Add listeners for new devices
        let newDeviceIDs = currentDeviceIDs.subtracting(trackedVolumeIDs)
        for deviceID in newDeviceIDs {
            addInputDeviceListener(.volume, for: deviceID)
            addInputDeviceListener(.mute, for: deviceID)
        }

        // Remove listeners for stale devices
        let staleVolumeIDs = trackedVolumeIDs.subtracting(currentDeviceIDs)
        for deviceID in staleVolumeIDs {
            removeInputDeviceListener(.volume, for: deviceID)
            inputVolumes.removeValue(forKey: deviceID)
        }

        let staleMuteIDs = trackedMuteIDs.subtracting(currentDeviceIDs)
        for deviceID in staleMuteIDs {
            removeInputDeviceListener(.mute, for: deviceID)
            inputMuteStates.removeValue(forKey: deviceID)
        }

        // Read volumes and mute states for all current input devices
        readAllInputStates()
    }

    /// Identifies which device property listener to manage (volume or mute).
    private enum DevicePropertyKind {
        case volume, mute
    }

    private func addDeviceListener(_ kind: DevicePropertyKind, for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        let listeners = kind == .volume ? volumeListeners : muteListeners
        guard listeners[deviceID] == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDevicePropertyChanged(kind, for: deviceID)
            }
        }

        var address = kind == .volume ? volumeAddress : muteAddress
        if deviceID.addPropertyListener(address: &address, queue: coreAudioListenerQueue, block: block) != nil {
            switch kind {
            case .volume: volumeListeners[deviceID] = block
            case .mute:   muteListeners[deviceID] = block
            }
        }
    }

    private func removeDeviceListener(_ kind: DevicePropertyKind, for deviceID: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock?
        switch kind {
        case .volume: block = volumeListeners[deviceID]
        case .mute:   block = muteListeners[deviceID]
        }
        guard let block else { return }

        var address = kind == .volume ? volumeAddress : muteAddress
        deviceID.removePropertyListener(address: &address, queue: coreAudioListenerQueue, block: block)

        switch kind {
        case .volume: volumeListeners.removeValue(forKey: deviceID)
        case .mute:   muteListeners.removeValue(forKey: deviceID)
        }
    }

    private func addInputDeviceListener(_ kind: DevicePropertyKind, for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }
        let listeners = kind == .volume ? inputVolumeListeners : inputMuteListeners
        guard listeners[deviceID] == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleInputDevicePropertyChanged(kind, for: deviceID)
            }
        }

        var address = kind == .volume ? inputVolumeAddress : inputMuteAddress
        if deviceID.addPropertyListener(address: &address, queue: coreAudioListenerQueue, block: block) != nil {
            switch kind {
            case .volume: inputVolumeListeners[deviceID] = block
            case .mute:   inputMuteListeners[deviceID] = block
            }
        }
    }

    private func removeInputDeviceListener(_ kind: DevicePropertyKind, for deviceID: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock?
        switch kind {
        case .volume: block = inputVolumeListeners[deviceID]
        case .mute:   block = inputMuteListeners[deviceID]
        }
        guard let block else { return }

        var address = kind == .volume ? inputVolumeAddress : inputMuteAddress
        deviceID.removePropertyListener(address: &address, queue: coreAudioListenerQueue, block: block)

        switch kind {
        case .volume: inputVolumeListeners.removeValue(forKey: deviceID)
        case .mute:   inputMuteListeners.removeValue(forKey: deviceID)
        }
    }

    /// Handles volume or mute change notification with debouncing and background read
    private func handleDevicePropertyChanged(_ kind: DevicePropertyKind, for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }

        let debounceMs = kind == .volume ? volumeDebounceMs : muteDebounceMs
        let debounceTasks = kind == .volume ? volumeDebounceTasks : muteDebounceTasks
        debounceTasks[deviceID]?.cancel()

        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard !Task.isCancelled else { return }

            await Task.detached { [weak self] in
                switch kind {
                case .volume:
                    let newVolume = deviceID.readOutputVolumeScalar()
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.volumes[deviceID] = newVolume
                        self.onVolumeChanged?(deviceID, newVolume)
                        self.logger.debug("Volume changed for device \(deviceID): \(newVolume)")
                    }
                case .mute:
                    let newMuteState = deviceID.readMuteState()
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.muteStates[deviceID] = newMuteState
                        self.onMuteChanged?(deviceID, newMuteState)
                        self.logger.debug("Mute changed for device \(deviceID): \(newMuteState)")
                    }
                }
            }.value
        }

        switch kind {
        case .volume: volumeDebounceTasks[deviceID] = task
        case .mute:   muteDebounceTasks[deviceID] = task
        }
    }

    /// Handles input volume or mute change notification
    private func handleInputDevicePropertyChanged(_ kind: DevicePropertyKind, for deviceID: AudioDeviceID) {
        guard deviceID.isValid else { return }

        Task.detached { [weak self] in
            switch kind {
            case .volume:
                let newVolume = deviceID.readInputVolumeScalar()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.inputVolumes[deviceID] = newVolume
                    self.onInputVolumeChanged?(deviceID, newVolume)
                    self.logger.debug("Input volume changed for device \(deviceID): \(newVolume)")
                }
            case .mute:
                let newMuteState = deviceID.readInputMuteState()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.inputMuteStates[deviceID] = newMuteState
                    self.onInputMuteChanged?(deviceID, newMuteState)
                    self.logger.debug("Input mute changed for device \(deviceID): \(newMuteState)")
                }
            }
        }
    }

    /// Handles coreaudiod restart - re-reads all state to recover from daemon crash
    private func handleServiceRestarted() {
        logger.warning("coreaudiod service restarted - re-reading all device state")

        // Re-read default device on background thread
        Task.detached { [weak self] in
            let newDeviceID = try? AudioDeviceID.readDefaultOutputDevice()
            let newDeviceUID = try? newDeviceID?.readDeviceUID()
            let newInputDeviceID = try? AudioDeviceID.readDefaultInputDevice()
            let newInputDeviceUID = try? newInputDeviceID?.readDeviceUID()

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let id = newDeviceID, id.isValid {
                    self.defaultDeviceID = id
                    self.defaultDeviceUID = newDeviceUID
                }
                if let id = newInputDeviceID, id.isValid {
                    self.defaultInputDeviceID = id
                    self.defaultInputDeviceUID = newInputDeviceUID
                }
                // Re-read all device volumes and mute states
                self.readAllStates()
                self.readAllInputStates()
                self.logger.debug("Recovered from coreaudiod restart")
            }
        }
    }

    /// Reads the current volume and mute state for all tracked output devices.
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

            let volumeSnapshot = volumeResults
            let muteSnapshot = muteResults

            // Update state on MainActor
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (deviceID, volume) in volumeSnapshot {
                    self.volumes[deviceID] = volume
                }
                for (deviceID, muted) in muteSnapshot {
                    self.muteStates[deviceID] = muted
                }
            }

            // Schedule delayed re-read for Bluetooth devices
            let btReReadDelay = await MainActor.run { [weak self] in self?.bluetoothReReadDelayMs ?? 200 }
            for deviceID in bluetoothDeviceIDs {
                try? await Task.sleep(for: .milliseconds(btReReadDelay))

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

    /// Reads the current volume and mute state for all tracked input devices
    private func readAllInputStates() {
        let devices = deviceMonitor.inputDevices

        Task.detached { [weak self] in
            var volumeResults: [AudioDeviceID: Float] = [:]
            var muteResults: [AudioDeviceID: Bool] = [:]
            var bluetoothDeviceIDs: [AudioDeviceID] = []

            for device in devices {
                let volume = device.id.readInputVolumeScalar()
                let muted = device.id.readInputMuteState()
                volumeResults[device.id] = volume
                muteResults[device.id] = muted

                let transportType = device.id.readTransportType()
                if transportType == .bluetooth || transportType == .bluetoothLE {
                    bluetoothDeviceIDs.append(device.id)
                }
            }

            let volumeSnapshot = volumeResults
            let muteSnapshot = muteResults

            await MainActor.run { [weak self] in
                guard let self else { return }
                for (deviceID, volume) in volumeSnapshot {
                    self.inputVolumes[deviceID] = volume
                }
                for (deviceID, muted) in muteSnapshot {
                    self.inputMuteStates[deviceID] = muted
                }
            }

            // Bluetooth input devices re-read
            let btReReadDelay = await MainActor.run { [weak self] in self?.bluetoothReReadDelayMs ?? 200 }
            for deviceID in bluetoothDeviceIDs {
                try? await Task.sleep(for: .milliseconds(btReReadDelay))

                let stillTracked = await MainActor.run { [weak self] in
                    self?.inputVolumes.keys.contains(deviceID) ?? false
                }
                guard stillTracked else { continue }

                let confirmedVolume = deviceID.readInputVolumeScalar()
                let confirmedMute = deviceID.readInputMuteState()

                await MainActor.run { [weak self] in
                    guard let self, self.inputVolumes.keys.contains(deviceID) else { return }
                    self.inputVolumes[deviceID] = confirmedVolume
                    self.inputMuteStates[deviceID] = confirmedMute
                    self.logger.debug("Bluetooth input device \(deviceID) re-read volume: \(confirmedVolume), muted: \(confirmedMute)")
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

    /// Starts observing deviceMonitor.inputDevices for changes
    private func startObservingInputDeviceList() {
        guard !isObservingInputDeviceList else { return }
        isObservingInputDeviceList = true

        inputObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let strongSelf = self, strongSelf.isObservingInputDeviceList else { break }

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = strongSelf.deviceMonitor.inputDevices
                    } onChange: {
                        continuation.resume()
                    }
                }

                guard !Task.isCancelled, let strongSelf = self, strongSelf.isObservingInputDeviceList else { break }

                strongSelf.logger.debug("Input device list changed, refreshing input volume listeners")
                strongSelf.refreshInputDeviceListeners()
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
