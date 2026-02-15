// FineTune/Settings/SettingsManager.swift
import Foundation
import os
import ServiceManagement
#if canImport(FineTuneCore)
import FineTuneCore
#endif

// MARK: - Pinned App Info

struct PinnedAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

// MARK: - App-Wide Settings Enums

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable {
    case `default` = "Default"
    case speaker = "Speaker"
    case waveform = "Waveform"
    case equalizer = "Equalizer"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .default: return "MenuBarIcon"
        case .speaker: return "speaker.wave.2.fill"
        case .waveform: return "waveform"
        case .equalizer: return "slider.vertical.3"
        }
    }

    var isSystemSymbol: Bool {
        self != .default
    }
}

enum StartupRoutingPolicy: String, Codable, CaseIterable, Identifiable {
    case preserveExplicitRouting = "preserveExplicitRouting"
    case followSystemDefault = "followSystemDefault"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preserveExplicitRouting:
            return "Preserve Explicit Routing"
        case .followSystemDefault:
            return "Follow System Default"
        }
    }

    var summary: String {
        switch self {
        case .preserveExplicitRouting:
            return "Keep per-app device choices on launch"
        case .followSystemDefault:
            return "Route all customized apps to current default on launch"
        }
    }
}

enum CustomEQPresetError: Error, Equatable {
    case nameRequired
    case nameTooLong
    case duplicateName
    case limitReached
    case notFound
}

// MARK: - App-Wide Settings Model

struct AppSettings: Codable, Equatable {
    // General
    var launchAtLogin: Bool = false
    var menuBarIconStyle: MenuBarIconStyle = .default

    // Audio
    var defaultNewAppVolume: Float = 1.0      // 100% (unity gain)
    var maxVolumeBoost: Float = 2.0           // 200% max

    // Input Device Lock
    var lockInputDevice: Bool = true

    // Persistence
    var rememberVolumeMute: Bool = true
    var rememberEQ: Bool = true
    var startupRoutingPolicy: StartupRoutingPolicy = .preserveExplicitRouting

    // Notifications
    var showDeviceDisconnectAlerts: Bool = true

    // Onboarding
    var onboardingCompleted: Bool = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin
        case menuBarIconStyle
        case defaultNewAppVolume
        case maxVolumeBoost
        case lockInputDevice
        case rememberVolumeMute
        case rememberEQ
        case startupRoutingPolicy
        case showDeviceDisconnectAlerts
        case onboardingCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        menuBarIconStyle = try container.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle) ?? .default
        defaultNewAppVolume = try container.decodeIfPresent(Float.self, forKey: .defaultNewAppVolume) ?? 1.0
        maxVolumeBoost = try container.decodeIfPresent(Float.self, forKey: .maxVolumeBoost) ?? 2.0
        lockInputDevice = try container.decodeIfPresent(Bool.self, forKey: .lockInputDevice) ?? true
        rememberVolumeMute = try container.decodeIfPresent(Bool.self, forKey: .rememberVolumeMute) ?? true
        rememberEQ = try container.decodeIfPresent(Bool.self, forKey: .rememberEQ) ?? true
        startupRoutingPolicy = try container.decodeIfPresent(StartupRoutingPolicy.self, forKey: .startupRoutingPolicy) ?? .preserveExplicitRouting
        showDeviceDisconnectAlerts = try container.decodeIfPresent(Bool.self, forKey: .showDeviceDisconnectAlerts) ?? true
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
    }
}

// MARK: - Settings Manager

@Observable
@MainActor
final class SettingsManager {
    private var settings: Settings
    private var saveTask: Task<Void, Never>?
    private let settingsURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "SettingsManager")

    struct Settings: Codable {
        var version: Int = 6
        var appVolumes: [String: Float] = [:]
        var appDeviceRouting: [String: String] = [:]  // bundleID → deviceUID
        var appMutes: [String: Bool] = [:]  // bundleID → isMuted
        var appEQSettings: [String: EQSettings] = [:]  // bundleID → EQ settings
        var customEQPresets: [CustomEQPreset] = []
        var appSettings: AppSettings = AppSettings()
        var systemSoundsFollowsDefault: Bool = true
        var appDeviceSelectionMode: [String: DeviceSelectionMode] = [:]
        var appSelectedDeviceUIDs: [String: [String]] = [:]
        var lockedInputDeviceUID: String? = nil
        var pinnedApps: Set<String> = []
        var pinnedAppInfo: [String: PinnedAppInfo] = [:]
    }

    init(directory: URL? = nil) {
        let baseDir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("FineTune")
        self.settingsURL = baseDir.appendingPathComponent("settings.json")
        self.settings = Settings()
        loadFromDisk()
    }

    // MARK: - Volume

    func getVolume(for identifier: String) -> Float? {
        settings.appVolumes[identifier]
    }

    func setVolume(for identifier: String, to volume: Float) {
        settings.appVolumes[identifier] = volume
        scheduleSave()
    }

    // MARK: - Device Routing

    func getDeviceRouting(for identifier: String) -> String? {
        settings.appDeviceRouting[identifier]
    }

    func setDeviceRouting(for identifier: String, deviceUID: String) {
        settings.appDeviceRouting[identifier] = deviceUID
        scheduleSave()
    }

    func clearDeviceRouting(for identifier: String) {
        if settings.appDeviceRouting.removeValue(forKey: identifier) != nil {
            scheduleSave()
        }
    }

    func isFollowingDefault(for identifier: String) -> Bool {
        settings.appDeviceRouting[identifier] == nil
    }

    func setFollowDefault(for identifier: String) {
        settings.appDeviceRouting.removeValue(forKey: identifier)
        scheduleSave()
    }

    func updateAllDeviceRoutings(to deviceUID: String) {
        guard !settings.appDeviceRouting.isEmpty else { return }
        var changed = false
        for identifier in settings.appDeviceRouting.keys {
            if settings.appDeviceRouting[identifier] != deviceUID {
                settings.appDeviceRouting[identifier] = deviceUID
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    func snapshotDeviceRoutings() -> [String: String] {
        settings.appDeviceRouting
    }

    func restoreDeviceRoutings(_ snapshot: [String: String]) {
        guard settings.appDeviceRouting != snapshot else { return }
        settings.appDeviceRouting = snapshot
        scheduleSave()
    }

    func hasCustomSettings(for identifier: String) -> Bool {
        settings.appDeviceRouting[identifier] != nil
            || settings.appVolumes[identifier] != nil
            || settings.appMutes[identifier] != nil
            || settings.appEQSettings[identifier] != nil
    }

    // MARK: - System Sounds Settings

    var isSystemSoundsFollowingDefault: Bool {
        settings.systemSoundsFollowsDefault
    }

    func setSystemSoundsFollowDefault(_ follows: Bool) {
        settings.systemSoundsFollowsDefault = follows
        scheduleSave()
    }

    // MARK: - Mute

    func getMute(for identifier: String) -> Bool? {
        settings.appMutes[identifier]
    }

    func setMute(for identifier: String, to muted: Bool) {
        settings.appMutes[identifier] = muted
        scheduleSave()
    }

    // MARK: - EQ

    func getEQSettings(for appIdentifier: String) -> EQSettings {
        return settings.appEQSettings[appIdentifier] ?? EQSettings.flat
    }

    func setEQSettings(_ eqSettings: EQSettings, for appIdentifier: String) {
        settings.appEQSettings[appIdentifier] = eqSettings
        scheduleSave()
    }

    // MARK: - Custom EQ Presets

    func getCustomEQPresets() -> [CustomEQPreset] {
        settings.customEQPresets.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func saveCustomEQPreset(name: String, bandGains: [Float]) throws -> CustomEQPreset {
        guard settings.customEQPresets.count < CustomEQPreset.maxCount else {
            throw CustomEQPresetError.limitReached
        }

        let validatedName = try validateCustomPresetName(name, excludingID: nil)
        let preset = CustomEQPreset(name: validatedName, bandGains: bandGains, updatedAt: Date())
        settings.customEQPresets.append(preset)
        scheduleSave()
        return preset
    }

    func overwriteCustomEQPreset(id: UUID, bandGains: [Float]) throws -> CustomEQPreset {
        guard let index = settings.customEQPresets.firstIndex(where: { $0.id == id }) else {
            throw CustomEQPresetError.notFound
        }

        settings.customEQPresets[index].bandGains = EQSettings(bandGains: bandGains).clampedGains
        settings.customEQPresets[index].updatedAt = Date()
        scheduleSave()
        return settings.customEQPresets[index]
    }

    func renameCustomEQPreset(id: UUID, to newName: String) throws -> CustomEQPreset {
        guard let index = settings.customEQPresets.firstIndex(where: { $0.id == id }) else {
            throw CustomEQPresetError.notFound
        }

        let validatedName = try validateCustomPresetName(newName, excludingID: id)
        settings.customEQPresets[index].name = validatedName
        settings.customEQPresets[index].updatedAt = Date()
        scheduleSave()
        return settings.customEQPresets[index]
    }

    @discardableResult
    func deleteCustomEQPreset(id: UUID) -> Bool {
        guard let index = settings.customEQPresets.firstIndex(where: { $0.id == id }) else {
            return false
        }

        settings.customEQPresets.remove(at: index)
        scheduleSave()
        return true
    }

    private func validateCustomPresetName(_ name: String, excludingID: UUID?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CustomEQPresetError.nameRequired
        }
        guard trimmed.count <= CustomEQPreset.maxNameLength else {
            throw CustomEQPresetError.nameTooLong
        }

        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let hasConflict = settings.customEQPresets.contains { preset in
            guard preset.id != excludingID else { return false }
            let existing = preset.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return existing == folded
        }
        guard !hasConflict else {
            throw CustomEQPresetError.duplicateName
        }

        return trimmed
    }

    // MARK: - Device Selection Mode

    func getDeviceSelectionMode(for identifier: String) -> DeviceSelectionMode? {
        settings.appDeviceSelectionMode[identifier]
    }

    func setDeviceSelectionMode(for identifier: String, to mode: DeviceSelectionMode) {
        settings.appDeviceSelectionMode[identifier] = mode
        scheduleSave()
    }

    // MARK: - Selected Device UIDs (Multi Mode)

    func getSelectedDeviceUIDs(for identifier: String) -> Set<String>? {
        guard let uids = settings.appSelectedDeviceUIDs[identifier] else { return nil }
        return Set(uids)
    }

    func setSelectedDeviceUIDs(for identifier: String, to uids: Set<String>) {
        settings.appSelectedDeviceUIDs[identifier] = Array(uids)
        scheduleSave()
    }

    // MARK: - Input Device Lock

    var lockedInputDeviceUID: String? {
        settings.lockedInputDeviceUID
    }

    func setLockedInputDeviceUID(_ uid: String?) {
        settings.lockedInputDeviceUID = uid
        scheduleSave()
    }

    // MARK: - Pinned Apps

    func pinApp(_ identifier: String, info: PinnedAppInfo) {
        settings.pinnedApps.insert(identifier)
        settings.pinnedAppInfo[identifier] = info
        scheduleSave()
    }

    func unpinApp(_ identifier: String) {
        settings.pinnedApps.remove(identifier)
        settings.pinnedAppInfo.removeValue(forKey: identifier)
        scheduleSave()
    }

    func isPinned(_ identifier: String) -> Bool {
        settings.pinnedApps.contains(identifier)
    }

    func getPinnedAppInfo() -> [PinnedAppInfo] {
        settings.pinnedApps.compactMap { settings.pinnedAppInfo[$0] }
    }

    // MARK: - App-Wide Settings

    var appSettings: AppSettings {
        settings.appSettings
    }

    func updateAppSettings(_ newSettings: AppSettings) {
        if newSettings.launchAtLogin != settings.appSettings.launchAtLogin {
            setLaunchAtLogin(newSettings.launchAtLogin)
        }
        settings.appSettings = newSettings
        scheduleSave()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Registered for launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered from launch at login")
            }
        } catch {
            logger.error("Failed to set launch at login: \(error.localizedDescription)")
        }
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Reset All Settings

    func resetAllSettings() {
        settings.appVolumes.removeAll()
        settings.appDeviceRouting.removeAll()
        settings.appMutes.removeAll()
        settings.appEQSettings.removeAll()
        settings.customEQPresets.removeAll()
        settings.appDeviceSelectionMode.removeAll()
        settings.appSelectedDeviceUIDs.removeAll()
        settings.pinnedApps.removeAll()
        settings.pinnedAppInfo.removeAll()
        settings.appSettings = AppSettings()
        settings.systemSoundsFollowsDefault = true
        settings.lockedInputDeviceUID = nil

        try? SMAppService.mainApp.unregister()

        scheduleSave()
        logger.info("Reset all settings to defaults")
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }

        do {
            let data = try Data(contentsOf: settingsURL)
            settings = try JSONDecoder().decode(Settings.self, from: data)
            logger.debug("Loaded settings with \(self.settings.appVolumes.count) volumes, \(self.settings.appDeviceRouting.count) device routings, \(self.settings.appMutes.count) mutes, \(self.settings.appEQSettings.count) EQ settings, \(self.settings.customEQPresets.count) custom EQ presets")
        } catch {
            logger.error("Failed to load settings: \(error.localizedDescription)")
            let backupURL = settingsURL.deletingPathExtension().appendingPathExtension("backup.json")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
            logger.warning("Backed up corrupted settings to \(backupURL.lastPathComponent)")
            settings = Settings()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            writeToDisk()
        }
    }

    /// Immediately writes pending changes to disk.
    /// Must be nonisolated to guarantee synchronous execution from termination handlers.
    nonisolated func flushSync() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                saveTask?.cancel()
                saveTask = nil
                writeToDisk()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self.saveTask?.cancel()
                    self.saveTask = nil
                    self.writeToDisk()
                }
            }
        }
    }

    private func writeToDisk() {
        do {
            let directory = settingsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)

            let routingMap = settings.appDeviceRouting.map { "\($0.key)→\($0.value)" }.joined(separator: ", ")
            logger.debug("Saved settings (routings: [\(routingMap)])")
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription)")
        }
    }
}
