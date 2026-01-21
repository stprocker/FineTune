// FineTune/Audio/AudioDeviceMonitor.swift
import AppKit
import AudioToolbox
import os

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

    private var knownDeviceUIDs: Set<String> = []

    func start() {
        guard deviceListListenerBlock == nil else { return }

        logger.debug("Starting audio device monitor")

        refresh()

        deviceListListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDeviceListChanged()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            .system,
            &deviceListAddress,
            .main,
            deviceListListenerBlock!
        )

        if status != noErr {
            logger.error("Failed to add device list listener: \(status)")
        }
    }

    func stop() {
        logger.debug("Stopping audio device monitor")

        if let block = deviceListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &deviceListAddress, .main, block)
            deviceListListenerBlock = nil
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

    deinit {
        // WARNING: Can't call stop() here due to MainActor isolation.
        // Callers MUST call stop() before releasing this object to remove CoreAudio listeners.
        // Orphaned listeners can corrupt coreaudiod state and break System Settings.
        // AudioEngine.stopSync() handles this for normal app termination.
    }
}
