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

    /// Called when coreaudiod restarts (e.g., after system audio permission is granted).
    /// All AudioObjectIDs (taps, aggregates) become invalid and must be recreated.
    var onServiceRestarted: (() -> Void)?

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

        // Capture MainActor state before going to background
        let previousUIDs = knownDeviceUIDs
        let deviceNames = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0.name) })

        // CRITICAL: Run CoreAudio reads OFF the main thread.
        // During coreaudiod restart, these calls can block for seconds.
        // Running them on MainActor would freeze the UI.
        let deviceData = await Task.detached { Self.readDeviceDataFromCoreAudio() }.value

        // Back on MainActor — update state
        let devices = createAudioDevices(from: deviceData)
        outputDevices = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        knownDeviceUIDs = Set(devices.map(\.uid))
        devicesByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
        devicesByID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.id, $0) })

        let disconnectedUIDs = previousUIDs.subtracting(knownDeviceUIDs)
        for uid in disconnectedUIDs {
            let name = deviceNames[uid] ?? uid
            logger.info("Device disconnected after restart: \(name) (\(uid))")
            onDeviceDisconnected?(uid, name)
        }

        // Notify listeners that coreaudiod restarted (taps/aggregates are now invalid)
        onServiceRestarted?()
    }

    /// Async handler that reads CoreAudio on background thread, updates UI on MainActor
    private func handleDeviceListChangedAsync() async {
        // Capture MainActor state before going to background
        let previousUIDs = knownDeviceUIDs
        let deviceNames = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0.name) })

        // CRITICAL: Run CoreAudio reads OFF the main thread.
        // Device list changes can trigger during coreaudiod churn where reads may block.
        let deviceData = await Task.detached { Self.readDeviceDataFromCoreAudio() }.value

        // Back on MainActor — update state
        let devices = createAudioDevices(from: deviceData)
        outputDevices = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        knownDeviceUIDs = Set(devices.map(\.uid))
        devicesByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
        devicesByID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.id, $0) })

        // Notify disconnected devices
        let disconnectedUIDs = previousUIDs.subtracting(knownDeviceUIDs)
        for uid in disconnectedUIDs {
            let name = deviceNames[uid] ?? uid
            logger.info("Device disconnected: \(name) (\(uid))")
            onDeviceDisconnected?(uid, name)
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
        // NOTE: Do not call @MainActor helpers from this nonisolated context (e.g., isVirtualDevice()).
        do {
            let deviceIDs = try AudioObjectID.readDeviceList()
            var devices: [DeviceData] = []

            for deviceID in deviceIDs {
                guard deviceID.hasOutputStreams() else { continue }
                guard !deviceID.isAggregateDevice() else { continue }
                // Removed guard !deviceID.isVirtualDevice() else { continue }

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
        deviceData
            .filter { data in
                // Safe to call @MainActor helpers here
                !data.id.isVirtualDevice()
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
