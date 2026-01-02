// FineTune/Audio/AudioDeviceMonitor.swift
import AppKit
import AudioToolbox
import os

@Observable
@MainActor
final class AudioDeviceMonitor {
    private(set) var outputDevices: [AudioDevice] = []

    var onDeviceDisconnected: ((String) -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioDeviceMonitor")

    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var knownDeviceUIDs: Set<String> = []
    private var disconnectTimers: [String: Task<Void, Never>] = [:]

    private let gracePeriodSeconds: UInt64 = 3

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

        for (_, task) in disconnectTimers {
            task.cancel()
        }
        disconnectTimers.removeAll()
    }

    func device(for uid: String) -> AudioDevice? {
        outputDevices.first { $0.uid == uid }
    }

    private func refresh() {
        do {
            let deviceIDs = try AudioObjectID.readDeviceList()
            var devices: [AudioDevice] = []

            for deviceID in deviceIDs {
                guard deviceID.hasOutputStreams() else { continue }
                guard !deviceID.isAggregateDevice() else { continue }

                guard let uid = try? deviceID.readDeviceUID(),
                      let name = try? deviceID.readDeviceName() else {
                    continue
                }

                let icon = deviceID.readDeviceIcon()

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

        } catch {
            logger.error("Failed to refresh device list: \(error.localizedDescription)")
        }
    }

    private func handleDeviceListChanged() {
        let previousUIDs = knownDeviceUIDs

        refresh()

        let currentUIDs = knownDeviceUIDs

        let disconnectedUIDs = previousUIDs.subtracting(currentUIDs)
        for uid in disconnectedUIDs {
            handleDeviceDisconnected(uid)
        }

        let reconnectedUIDs = currentUIDs.intersection(Set(disconnectTimers.keys))
        for uid in reconnectedUIDs {
            handleDeviceReconnected(uid)
        }
    }

    private func handleDeviceDisconnected(_ deviceUID: String) {
        logger.info("Device disconnected: \(deviceUID), starting grace period")

        disconnectTimers[deviceUID]?.cancel()

        disconnectTimers[deviceUID] = Task { [weak self, gracePeriodSeconds] in
            do {
                try await Task.sleep(for: .seconds(gracePeriodSeconds))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.logger.info("Grace period expired for device: \(deviceUID), triggering fallback")
                self.disconnectTimers.removeValue(forKey: deviceUID)
                self.onDeviceDisconnected?(deviceUID)
            }
        }
    }

    private func handleDeviceReconnected(_ deviceUID: String) {
        logger.info("Device reconnected within grace period: \(deviceUID)")
        disconnectTimers[deviceUID]?.cancel()
        disconnectTimers.removeValue(forKey: deviceUID)
    }

    deinit {
        // Note: Can't call stop() here due to MainActor isolation
        // Listeners will be cleaned up when the process exits
    }
}
