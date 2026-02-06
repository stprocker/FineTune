// FineTune/Audio/AudioDeviceMonitor.swift
import AppKit
import AudioToolbox
import os

// Use shared CoreAudio listener queue
private let coreAudioListenerQueue = CoreAudioQueues.listenerQueue

@Observable
@MainActor
final class AudioDeviceMonitor {
    private(set) var outputDevices: [AudioDevice] = []

    /// O(1) device lookup by UID
    private(set) var devicesByUID: [String: AudioDevice] = [:]

    /// O(1) device lookup by AudioDeviceID
    private(set) var devicesByID: [AudioDeviceID: AudioDevice] = [:]

    /// Called immediately when device disappears (passes UID and name)
    var onDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)?

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

    func start() {
        guard deviceListListenerBlock == nil else { return }

        logger.debug("Starting audio device monitor")

        refresh()

        deviceListListenerBlock = { [weak self] _, _ in
            // Listener fires on coreAudioListenerQueue - do CoreAudio reads here, not on MainActor
            Task.detached { [weak self] in
                await self?.handleDeviceListChangedAsync()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            .system,
            &deviceListAddress,
            coreAudioListenerQueue,
            deviceListListenerBlock!
        )

        if status != noErr {
            logger.error("Failed to add device list listener: \(status)")
        }

        serviceRestartListenerBlock = { [weak self] _, _ in
            Task.detached { [weak self] in
                await self?.handleServiceRestartedAsync()
            }
        }

        let restartStatus = AudioObjectAddPropertyListenerBlock(
            .system,
            &serviceRestartAddress,
            coreAudioListenerQueue,
            serviceRestartListenerBlock!
        )

        if restartStatus != noErr {
            logger.error("Failed to add service restart listener: \(restartStatus)")
        }
    }

    func stop() {
        logger.debug("Stopping audio device monitor")

        if let block = deviceListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &deviceListAddress, coreAudioListenerQueue, block)
            deviceListListenerBlock = nil
        }

        if let block = serviceRestartListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &serviceRestartAddress, coreAudioListenerQueue, block)
            serviceRestartListenerBlock = nil
        }
    }

    /// O(1) lookup by device UID
    func device(for uid: String) -> AudioDevice? {
        devicesByUID[uid]
    }

    /// O(1) lookup by AudioDeviceID
    func device(for id: AudioDeviceID) -> AudioDevice? {
        devicesByID[id]
    }

    private func refresh() {
        do {
            let deviceIDs = try AudioObjectID.readDeviceList()
            var devices: [AudioDevice] = []

            for deviceID in deviceIDs {
                guard deviceID.hasOutputStreams() else { continue }
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

                // Try Core Audio icon first (via LRU cache), fall back to SF Symbol
                let icon = DeviceIconCache.shared.icon(for: uid) {
                    deviceID.readDeviceIcon()
                } ?? NSImage(systemSymbolName: deviceID.suggestedIconSymbol(), accessibilityDescription: name)

                let device = AudioDevice(
                    id: deviceID,
                    uid: uid,
                    name: name,
                    icon: icon
                )
                devices.append(device)
            }

            outputDevices = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            knownDeviceUIDs = Set(devices.map(\.uid))

            // Build O(1) lookup dictionaries
            devicesByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
            devicesByID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.id, $0) })

        } catch {
            logger.error("Failed to refresh device list: \(error.localizedDescription)")
        }
    }

    private func handleDeviceListChanged() {
        let previousUIDs = knownDeviceUIDs

        // Capture names before refresh removes devices from list
        var deviceNames: [String: String] = [:]
        for device in outputDevices {
            deviceNames[device.uid] = device.name
        }

        refresh()

        let currentUIDs = knownDeviceUIDs

        let disconnectedUIDs = previousUIDs.subtracting(currentUIDs)
        for uid in disconnectedUIDs {
            let name = deviceNames[uid] ?? uid
            logger.info("Device disconnected: \(name) (\(uid))")
            onDeviceDisconnected?(uid, name)
        }
    }

    private func handleServiceRestartedAsync() async {
        logger.warning("coreaudiod service restarted - refreshing device list")

        let previousUIDs = await MainActor.run { knownDeviceUIDs }
        let deviceNames = await MainActor.run {
            Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0.name) })
        }

        let deviceData = Self.readDeviceDataFromCoreAudio()

        await MainActor.run { [weak self] in
            guard let self else { return }
            let devices = self.createAudioDevices(from: deviceData)
            self.outputDevices = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.knownDeviceUIDs = Set(devices.map(\.uid))
            self.devicesByUID = Dictionary(uniqueKeysWithValues: self.outputDevices.map { ($0.uid, $0) })
            self.devicesByID = Dictionary(uniqueKeysWithValues: self.outputDevices.map { ($0.id, $0) })

            let disconnectedUIDs = previousUIDs.subtracting(self.knownDeviceUIDs)
            for uid in disconnectedUIDs {
                let name = deviceNames[uid] ?? uid
                self.logger.info("Device disconnected after restart: \(name) (\(uid))")
                self.onDeviceDisconnected?(uid, name)
            }
        }
    }

    /// Async handler that reads CoreAudio on background thread, updates UI on MainActor
    private func handleDeviceListChangedAsync() async {
        // Capture current state before background work
        let previousUIDs = await MainActor.run { knownDeviceUIDs }
        let deviceNames = await MainActor.run {
            Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0.name) })
        }

        // Do CoreAudio reads on current (background) thread
        let deviceData = Self.readDeviceDataFromCoreAudio()

        // Update UI state on MainActor (icon resolution happens here)
        await MainActor.run { [weak self] in
            guard let self else { return }
            let devices = self.createAudioDevices(from: deviceData)
            self.outputDevices = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.knownDeviceUIDs = Set(devices.map(\.uid))
            self.devicesByUID = Dictionary(uniqueKeysWithValues: self.outputDevices.map { ($0.uid, $0) })
            self.devicesByID = Dictionary(uniqueKeysWithValues: self.outputDevices.map { ($0.id, $0) })

            // Notify disconnected devices
            let disconnectedUIDs = previousUIDs.subtracting(self.knownDeviceUIDs)
            for uid in disconnectedUIDs {
                let name = deviceNames[uid] ?? uid
                self.logger.info("Device disconnected: \(name) (\(uid))")
                self.onDeviceDisconnected?(uid, name)
            }
        }
    }

    /// Intermediate struct for device data read on background thread
    private struct DeviceData: Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let iconSymbol: String
    }

    /// Reads device list from CoreAudio - can be called from any thread.
    /// Returns raw data; icons are resolved on MainActor.
    private nonisolated static func readDeviceDataFromCoreAudio() -> [DeviceData] {
        do {
            let deviceIDs = try AudioObjectID.readDeviceList()
            var devices: [DeviceData] = []

            for deviceID in deviceIDs {
                guard deviceID.hasOutputStreams() else { continue }
                guard !deviceID.isAggregateDevice() else { continue }
                guard !deviceID.isVirtualDevice() else { continue }

                guard let uid = try? deviceID.readDeviceUID(),
                      let name = try? deviceID.readDeviceName() else {
                    continue
                }

                if name.hasPrefix("FineTune-") { continue }

                let iconSymbol = deviceID.suggestedIconSymbol()
                devices.append(DeviceData(id: deviceID, uid: uid, name: name, iconSymbol: iconSymbol))
            }

            return devices
        } catch {
            return []
        }
    }

    /// Converts DeviceData to AudioDevice on MainActor (for icon cache access)
    private func createAudioDevices(from deviceData: [DeviceData]) -> [AudioDevice] {
        deviceData.map { data in
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
