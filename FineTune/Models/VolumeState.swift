// FineTune/Models/VolumeState.swift
import Foundation

/// Device selection mode for an app's audio output
enum DeviceSelectionMode: String, Codable, Equatable {
    case single  // Route to one device (default)
    case multi   // Route to multiple devices simultaneously
}

/// Consolidated state for a single app's audio settings
struct AppAudioState {
    var volume: Float
    var muted: Bool
    var persistenceIdentifier: String
    var deviceSelectionMode: DeviceSelectionMode = .single
    var selectedDeviceUIDs: Set<String> = []
}

@Observable
@MainActor
final class VolumeState {
    private var states: [pid_t: AppAudioState] = [:]
    private let settingsManager: SettingsManager?

    init(settingsManager: SettingsManager? = nil) {
        self.settingsManager = settingsManager
    }

    // MARK: - Volume

    func getVolume(for pid: pid_t) -> Float {
        states[pid]?.volume ?? (settingsManager?.appSettings.defaultNewAppVolume ?? 1.0)
    }

    func setVolume(for pid: pid_t, to volume: Float, identifier: String? = nil) {
        modifyState(for: pid, identifier: identifier, update: { $0.volume = volume }) {
            if settingsManager?.appSettings.rememberVolumeMute == true {
                settingsManager?.setVolume(for: $0, to: volume)
            }
        }
    }

    func loadSavedVolume(for pid: pid_t, identifier: String) -> Float? {
        ensureState(for: pid, identifier: identifier)
        guard settingsManager?.appSettings.rememberVolumeMute != false else { return nil }
        if let saved = settingsManager?.getVolume(for: identifier) {
            states[pid]?.volume = saved
            return saved
        }
        return nil
    }

    // MARK: - Mute State

    func getMute(for pid: pid_t) -> Bool {
        states[pid]?.muted ?? false
    }

    func setMute(for pid: pid_t, to muted: Bool, identifier: String? = nil) {
        modifyState(for: pid, identifier: identifier, update: { $0.muted = muted }) {
            if settingsManager?.appSettings.rememberVolumeMute == true {
                settingsManager?.setMute(for: $0, to: muted)
            }
        }
    }

    func loadSavedMute(for pid: pid_t, identifier: String) -> Bool? {
        ensureState(for: pid, identifier: identifier)
        guard settingsManager?.appSettings.rememberVolumeMute != false else { return nil }
        if let saved = settingsManager?.getMute(for: identifier) {
            states[pid]?.muted = saved
            return saved
        }
        return nil
    }

    // MARK: - Device Selection Mode

    func getDeviceSelectionMode(for pid: pid_t) -> DeviceSelectionMode {
        states[pid]?.deviceSelectionMode ?? .single
    }

    func setDeviceSelectionMode(for pid: pid_t, to mode: DeviceSelectionMode, identifier: String? = nil) {
        modifyState(for: pid, identifier: identifier, update: { $0.deviceSelectionMode = mode }) {
            settingsManager?.setDeviceSelectionMode(for: $0, to: mode)
        }
    }

    func loadSavedDeviceSelectionMode(for pid: pid_t, identifier: String) -> DeviceSelectionMode? {
        ensureState(for: pid, identifier: identifier)
        if let saved = settingsManager?.getDeviceSelectionMode(for: identifier) {
            states[pid]?.deviceSelectionMode = saved
            return saved
        }
        return nil
    }

    // MARK: - Selected Device UIDs (Multi Mode)

    func getSelectedDeviceUIDs(for pid: pid_t) -> Set<String> {
        states[pid]?.selectedDeviceUIDs ?? []
    }

    func setSelectedDeviceUIDs(for pid: pid_t, to uids: Set<String>, identifier: String? = nil) {
        modifyState(for: pid, identifier: identifier, update: { $0.selectedDeviceUIDs = uids }) {
            settingsManager?.setSelectedDeviceUIDs(for: $0, to: uids)
        }
    }

    func loadSavedSelectedDeviceUIDs(for pid: pid_t, identifier: String) -> Set<String>? {
        ensureState(for: pid, identifier: identifier)
        if let saved = settingsManager?.getSelectedDeviceUIDs(for: identifier) {
            states[pid]?.selectedDeviceUIDs = saved
            return saved
        }
        return nil
    }

    // MARK: - Cleanup

    func removeVolume(for pid: pid_t) {
        states.removeValue(forKey: pid)
    }

    func cleanup(keeping pids: Set<pid_t>) {
        states = states.filter { pids.contains($0.key) }
    }

    // MARK: - Private

    /// Applies an update to the state for the given PID, creating it if needed.
    /// After the update, calls `persist` with the state's persistence identifier.
    private func modifyState(
        for pid: pid_t,
        identifier: String?,
        update: (inout AppAudioState) -> Void,
        persist: (String) -> Void
    ) {
        if var state = states[pid] {
            update(&state)
            if let identifier { state.persistenceIdentifier = identifier }
            states[pid] = state
            persist(state.persistenceIdentifier)
        } else if let identifier {
            let defaultVolume = settingsManager?.appSettings.defaultNewAppVolume ?? 1.0
            var newState = AppAudioState(volume: defaultVolume, muted: false, persistenceIdentifier: identifier)
            update(&newState)
            states[pid] = newState
            persist(identifier)
        }
    }

    private func ensureState(for pid: pid_t, identifier: String) {
        if states[pid] == nil {
            let defaultVolume = settingsManager?.appSettings.defaultNewAppVolume ?? 1.0
            states[pid] = AppAudioState(volume: defaultVolume, muted: false, persistenceIdentifier: identifier)
        } else if states[pid]?.persistenceIdentifier != identifier {
            states[pid]?.persistenceIdentifier = identifier
        }
    }
}
