// FineTune/Audio/AudioDeviceMonitor.swift
import AppKit
import AudioToolbox
import Observation
import os

// Use shared CoreAudio listener queue
private let coreAudioListenerQueue = CoreAudioQueues.listenerQueue

@Observable
@MainActor
final class AudioDeviceMonitor {
    // MARK: - Output Devices

    private(set) var outputDevices: [AudioDevice] = []

    /// O(1) device lookup by UID (nonisolated for cross-actor reads from ProcessTapController).
    /// Marked ObservationIgnored so @Observable does not actor-isolate this cache field.
    @ObservationIgnored
    nonisolated(unsafe) private(set) var devicesByUID: [String: AudioDevice] = [:] // Cross-actor reads only; updated on MainActor

    /// O(1) device lookup by AudioDeviceID (nonisolated for cross-actor reads from ProcessTapController).
    /// Marked ObservationIgnored so @Observable does not actor-isolate this cache field.
    @ObservationIgnored
    nonisolated(unsafe) private(set) var devicesByID: [AudioDeviceID: AudioDevice] = [:] // Cross-actor reads only; updated on MainActor

    /// Called immediately when device disappears (passes UID and name)
    var onDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)?

    /// Called when an output device appears (passes UID and name)
    var onDeviceConnected: ((_ uid: String, _ name: String) -> Void)?

    /// Called when coreaudiod restarts (e.g., after system audio permission is granted).
    /// All AudioObjectIDs (taps, aggregates) become invalid and must be recreated.
    var onServiceRestarted: (() -> Void)?

    // MARK: - Input Devices

    private(set) var inputDevices: [AudioDevice] = []

    /// O(1) input device lookup by UID
    @ObservationIgnored
    nonisolated(unsafe) private(set) var inputDevicesByUID: [String: AudioDevice] = [:]

    /// O(1) input device lookup by AudioDeviceID
    @ObservationIgnored
    nonisolated(unsafe) private(set) var inputDevicesByID: [AudioDeviceID: AudioDevice] = [:]

    /// Called immediately when input device disappears (passes UID and name)
    var onInputDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)?

    /// Called when an input device appears (passes UID and name)
    var onInputDeviceConnected: ((_ uid: String, _ name: String) -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioDeviceMonitor")

    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var serviceRestartListenerBlock: AudioObjectPropertyListenerBlock?
    private var serviceRestartAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyServiceRestarted,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var knownDeviceUIDs: Set<String> = []
    private var knownInputDeviceUIDs: Set<String> = []

    func start() {
        guard deviceListListenerBlock == nil else { return }

        logger.debug("Starting audio device monitor")

        refresh()

        let deviceListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task.detached { [weak self] in
                await self?.handleDeviceListChangedAsync()
            }
        }
        deviceListListenerBlock = AudioObjectID.system.addPropertyListener(
            address: &deviceListAddress, queue: coreAudioListenerQueue, block: deviceListBlock
        )

        let restartBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task.detached { [weak self] in
                await self?.handleServiceRestartedAsync()
            }
        }
        serviceRestartListenerBlock = AudioObjectID.system.addPropertyListener(
            address: &serviceRestartAddress, queue: coreAudioListenerQueue, block: restartBlock
        )
    }

    func stop() {
        logger.debug("Stopping audio device monitor")

        if let block = deviceListListenerBlock {
            AudioObjectID.system.removePropertyListener(address: &deviceListAddress, queue: coreAudioListenerQueue, block: block)
            deviceListListenerBlock = nil
        }

        if let block = serviceRestartListenerBlock {
            AudioObjectID.system.removePropertyListener(address: &serviceRestartAddress, queue: coreAudioListenerQueue, block: block)
            serviceRestartListenerBlock = nil
        }
    }

    /// O(1) lookup by device UID
    nonisolated func device(for uid: String) -> AudioDevice? {
        devicesByUID[uid]
    }

    /// O(1) lookup by AudioDeviceID
    nonisolated func device(for id: AudioDeviceID) -> AudioDevice? {
        devicesByID[id]
    }

    /// O(1) lookup by input device UID
    nonisolated func inputDevice(for uid: String) -> AudioDevice? {
        inputDevicesByUID[uid]
    }

    /// O(1) lookup by input AudioDeviceID
    nonisolated func inputDevice(for id: AudioDeviceID) -> AudioDevice? {
        inputDevicesByID[id]
    }

    /// Resolves an AudioDeviceID for a UID. Tries cached O(1) lookup first,
    /// falls back to a fresh CoreAudio device list read on cache miss.
    nonisolated func resolveDeviceID(for uid: String) -> AudioDeviceID? {
        if let cached = devicesByUID[uid] {
            return cached.id
        }
        // Fallback: device may have disconnected or cache not yet populated
        return (try? AudioObjectID.readDeviceList())?.first(where: { (try? $0.readDeviceUID()) == uid })
    }

    private func refresh() {
        do {
            let deviceIDs = try AudioObjectID.readDeviceList()
            var outputDeviceList: [AudioDevice] = []
            var inputDeviceList: [AudioDevice] = []

            for deviceID in deviceIDs {
                guard !deviceID.isAggregateDevice() else { continue }
                // Filter virtual audio devices (e.g., Microsoft Teams Audio, BlackHole)
                // To include virtual devices, remove or comment out this line:
                guard !deviceID.isVirtualDevice() else { continue }

                guard let uid = try? deviceID.readDeviceUID(),
                      let name = try? deviceID.readDeviceName() else {
                    continue
                }

                // Strictly ignore our own private aggregate devices to prevent recursion/loops.
                // Even though we set kAudioAggregateDeviceIsPrivateKey: true, they can sometimes leak into the list.
                if name.hasPrefix("FineTune-") {
                    continue
                }

                // Output devices
                if deviceID.hasOutputStreams() {
                    let icon = DeviceIconCache.shared.icon(for: uid) {
                        deviceID.readDeviceIcon()
                    } ?? NSImage(systemSymbolName: deviceID.suggestedIconSymbol(), accessibilityDescription: name)

                    let device = AudioDevice(
                        id: deviceID,
                        uid: uid,
                        name: name,
                        icon: icon
                    )
                    outputDeviceList.append(device)
                }

                // Input devices
                if deviceID.hasInputStreams() {
                    let icon = DeviceIconCache.shared.icon(for: "\(uid)-input") {
                        deviceID.readDeviceIcon()
                    } ?? NSImage(systemSymbolName: deviceID.suggestedInputIconSymbol(), accessibilityDescription: name)

                    let device = AudioDevice(
                        id: deviceID,
                        uid: uid,
                        name: name,
                        icon: icon
                    )
                    inputDeviceList.append(device)
                }
            }

            // Update output devices
            outputDevices = outputDeviceList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            knownDeviceUIDs = Set(outputDeviceList.map(\.uid))
            devicesByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
            devicesByID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.id, $0) })

            // Update input devices
            inputDevices = inputDeviceList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            knownInputDeviceUIDs = Set(inputDeviceList.map(\.uid))
            inputDevicesByUID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.uid, $0) })
            inputDevicesByID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.id, $0) })

        } catch {
            logger.error("Failed to refresh device list: \(error.localizedDescription)")
        }
    }

    private func handleDeviceListChanged() {
        let previousOutputUIDs = knownDeviceUIDs
        let previousInputUIDs = knownInputDeviceUIDs

        // Capture names before refresh removes devices from list
        var outputDeviceNames: [String: String] = [:]
        for device in outputDevices {
            outputDeviceNames[device.uid] = device.name
        }
        var inputDeviceNames: [String: String] = [:]
        for device in inputDevices {
            inputDeviceNames[device.uid] = device.name
        }

        refresh()

        // Handle output device changes
        let currentOutputUIDs = knownDeviceUIDs
        let disconnectedOutputUIDs = previousOutputUIDs.subtracting(currentOutputUIDs)
        for uid in disconnectedOutputUIDs {
            let name = outputDeviceNames[uid] ?? uid
            logger.info("Output device disconnected: \(name) (\(uid))")
            onDeviceDisconnected?(uid, name)
        }
        let connectedOutputUIDs = currentOutputUIDs.subtracting(previousOutputUIDs)
        for uid in connectedOutputUIDs {
            if let device = devicesByUID[uid] {
                logger.info("Output device connected: \(device.name) (\(uid))")
                onDeviceConnected?(uid, device.name)
            }
        }

        // Handle input device changes
        let currentInputUIDs = knownInputDeviceUIDs
        let disconnectedInputUIDs = previousInputUIDs.subtracting(currentInputUIDs)
        for uid in disconnectedInputUIDs {
            let name = inputDeviceNames[uid] ?? uid
            logger.info("Input device disconnected: \(name) (\(uid))")
            onInputDeviceDisconnected?(uid, name)
        }
        let connectedInputUIDs = currentInputUIDs.subtracting(previousInputUIDs)
        for uid in connectedInputUIDs {
            if let device = inputDevicesByUID[uid] {
                logger.info("Input device connected: \(device.name) (\(uid))")
                onInputDeviceConnected?(uid, device.name)
            }
        }
    }

    private func handleServiceRestartedAsync() async {
        logger.warning("coreaudiod service restarted - refreshing device list")

        // Capture MainActor state before going to background
        let previousOutputUIDs = knownDeviceUIDs
        let previousInputUIDs = knownInputDeviceUIDs
        let outputDeviceNames = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0.name) })
        let inputDeviceNames = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.uid, $0.name) })

        // CRITICAL: Run CoreAudio reads OFF the main thread.
        // During coreaudiod restart, these calls can block for seconds.
        // Running them on MainActor would freeze the UI.
        let deviceData = await Task.detached { Self.readDeviceDataFromCoreAudio() }.value

        // Back on MainActor -- update state
        let (outputList, inputList) = createAudioDevicesWithInput(from: deviceData)
        outputDevices = outputList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        knownDeviceUIDs = Set(outputList.map(\.uid))
        devicesByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
        devicesByID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.id, $0) })

        inputDevices = inputList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        knownInputDeviceUIDs = Set(inputList.map(\.uid))
        inputDevicesByUID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.uid, $0) })
        inputDevicesByID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.id, $0) })

        // Output device disconnect/connect events
        let disconnectedOutputUIDs = previousOutputUIDs.subtracting(knownDeviceUIDs)
        for uid in disconnectedOutputUIDs {
            let name = outputDeviceNames[uid] ?? uid
            logger.info("Output device disconnected after restart: \(name) (\(uid))")
            onDeviceDisconnected?(uid, name)
        }

        let connectedOutputUIDs = knownDeviceUIDs.subtracting(previousOutputUIDs)
        for uid in connectedOutputUIDs {
            if let device = devicesByUID[uid] {
                logger.info("Output device connected after restart: \(device.name) (\(uid))")
                onDeviceConnected?(uid, device.name)
            }
        }

        // Input device disconnect/connect events
        let disconnectedInputUIDs = previousInputUIDs.subtracting(knownInputDeviceUIDs)
        for uid in disconnectedInputUIDs {
            let name = inputDeviceNames[uid] ?? uid
            logger.info("Input device disconnected after restart: \(name) (\(uid))")
            onInputDeviceDisconnected?(uid, name)
        }

        let connectedInputUIDs = knownInputDeviceUIDs.subtracting(previousInputUIDs)
        for uid in connectedInputUIDs {
            if let device = inputDevicesByUID[uid] {
                logger.info("Input device connected after restart: \(device.name) (\(uid))")
                onInputDeviceConnected?(uid, device.name)
            }
        }

        // Notify listeners that coreaudiod restarted (taps/aggregates are now invalid)
        onServiceRestarted?()
    }

    /// Async handler that reads CoreAudio on background thread, updates UI on MainActor
    private func handleDeviceListChangedAsync() async {
        // Capture MainActor state before going to background
        let previousOutputUIDs = knownDeviceUIDs
        let previousInputUIDs = knownInputDeviceUIDs
        let outputDeviceNames = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0.name) })
        let inputDeviceNames = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.uid, $0.name) })

        // CRITICAL: Run CoreAudio reads OFF the main thread.
        // Device list changes can trigger during coreaudiod churn where reads may block.
        let deviceData = await Task.detached { Self.readDeviceDataFromCoreAudio() }.value

        // Back on MainActor -- update state
        let (outputList, inputList) = createAudioDevicesWithInput(from: deviceData)
        outputDevices = outputList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        knownDeviceUIDs = Set(outputList.map(\.uid))
        devicesByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
        devicesByID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.id, $0) })

        inputDevices = inputList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        knownInputDeviceUIDs = Set(inputList.map(\.uid))
        inputDevicesByUID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.uid, $0) })
        inputDevicesByID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.id, $0) })

        // Notify disconnected output devices
        let disconnectedOutputUIDs = previousOutputUIDs.subtracting(knownDeviceUIDs)
        for uid in disconnectedOutputUIDs {
            let name = outputDeviceNames[uid] ?? uid
            logger.info("Output device disconnected: \(name) (\(uid))")
            onDeviceDisconnected?(uid, name)
        }

        // Notify connected output devices
        let connectedOutputUIDs = knownDeviceUIDs.subtracting(previousOutputUIDs)
        for uid in connectedOutputUIDs {
            if let device = devicesByUID[uid] {
                logger.info("Output device connected: \(device.name) (\(uid))")
                onDeviceConnected?(uid, device.name)
            }
        }

        // Notify disconnected input devices
        let disconnectedInputUIDs = previousInputUIDs.subtracting(knownInputDeviceUIDs)
        for uid in disconnectedInputUIDs {
            let name = inputDeviceNames[uid] ?? uid
            logger.info("Input device disconnected: \(name) (\(uid))")
            onInputDeviceDisconnected?(uid, name)
        }

        // Notify connected input devices
        let connectedInputUIDs = knownInputDeviceUIDs.subtracting(previousInputUIDs)
        for uid in connectedInputUIDs {
            if let device = inputDevicesByUID[uid] {
                logger.info("Input device connected: \(device.name) (\(uid))")
                onInputDeviceConnected?(uid, device.name)
            }
        }
    }

    /// Intermediate struct for device data read on background thread
    private struct DeviceData: Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let iconSymbol: String
        let inputIconSymbol: String
        let hasOutput: Bool
        let hasInput: Bool
    }

    /// Reads device list from CoreAudio - can be called from any thread.
    /// Returns raw data; icons are resolved on MainActor.
    private nonisolated static func readDeviceDataFromCoreAudio() -> [DeviceData] {
        // NOTE: Do not call @MainActor helpers from this nonisolated context (e.g., isVirtualDevice()).
        do {
            let deviceIDs = try AudioObjectID.readDeviceList()
            var devices: [DeviceData] = []

            for deviceID in deviceIDs {
                let hasOutput = deviceID.hasOutputStreams()
                let hasInput = deviceID.hasInputStreams()
                guard hasOutput || hasInput else { continue }
                guard !deviceID.isAggregateDevice() else { continue }

                guard let uid = try? deviceID.readDeviceUID(),
                      let name = try? deviceID.readDeviceName() else {
                    continue
                }

                if name.hasPrefix("FineTune-") { continue }

                let iconSymbol = deviceID.suggestedIconSymbol()
                let inputIconSymbol = deviceID.suggestedInputIconSymbol()
                devices.append(DeviceData(
                    id: deviceID, uid: uid, name: name,
                    iconSymbol: iconSymbol, inputIconSymbol: inputIconSymbol,
                    hasOutput: hasOutput, hasInput: hasInput
                ))
            }

            return devices
        } catch {
            return []
        }
    }

    /// Converts DeviceData to AudioDevice arrays on MainActor (for icon cache access)
    /// Returns (outputDevices, inputDevices)
    private func createAudioDevicesWithInput(from deviceData: [DeviceData]) -> ([AudioDevice], [AudioDevice]) {
        var outputList: [AudioDevice] = []
        var inputList: [AudioDevice] = []

        for data in deviceData {
            // Safe to call @MainActor helpers here
            guard !data.id.isVirtualDevice() else { continue }

            if data.hasOutput {
                let icon = DeviceIconCache.shared.icon(for: data.uid) {
                    data.id.readDeviceIcon()
                } ?? NSImage(systemSymbolName: data.iconSymbol, accessibilityDescription: data.name)

                outputList.append(AudioDevice(
                    id: data.id, uid: data.uid, name: data.name, icon: icon
                ))
            }

            if data.hasInput {
                let icon = DeviceIconCache.shared.icon(for: "\(data.uid)-input") {
                    data.id.readDeviceIcon()
                } ?? NSImage(systemSymbolName: data.inputIconSymbol, accessibilityDescription: data.name)

                inputList.append(AudioDevice(
                    id: data.id, uid: data.uid, name: data.name, icon: icon
                ))
            }
        }

        return (outputList, inputList)
    }

    /// Converts DeviceData to AudioDevice on MainActor (for icon cache access) -- output only
    private func createAudioDevices(from deviceData: [DeviceData]) -> [AudioDevice] {
        deviceData
            .filter { data in
                // Safe to call @MainActor helpers here
                !data.id.isVirtualDevice() && data.hasOutput
            }
            .map { data in
                let icon = DeviceIconCache.shared.icon(for: data.uid) {
                    data.id.readDeviceIcon()
                } ?? NSImage(systemSymbolName: data.iconSymbol, accessibilityDescription: data.name)

                return AudioDevice(
                    id: data.id,
                    uid: data.uid,
                    name: data.name,
                    icon: icon
                )
            }
    }

    // MARK: - Test Helpers

    /// Test-only hook to inject output devices without CoreAudio.
    @MainActor
    func setOutputDevicesForTests(_ devices: [AudioDevice]) {
        outputDevices = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        knownDeviceUIDs = Set(outputDevices.map(\.uid))
        devicesByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
        devicesByID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.id, $0) })
    }

    deinit {
        // WARNING: Can't call stop() here due to MainActor isolation.
        // Callers MUST call stop() before releasing this object to remove CoreAudio listeners.
        // Orphaned listeners can corrupt coreaudiod state and break System Settings.
        // AudioEngine.stopSync() handles this for normal app termination.
    }
}
