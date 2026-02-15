import Foundation
#if canImport(FineTuneCore)
import FineTuneCore
#endif

struct CustomEQPreset: Codable, Equatable, Identifiable, Hashable, Sendable {
    static let maxCount = 5
    static let maxNameLength = 24

    let id: UUID
    var name: String
    var bandGains: [Float]
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        bandGains: [Float],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bandGains = EQSettings(bandGains: bandGains).clampedGains
        self.updatedAt = updatedAt
    }

    var eqSettings: EQSettings {
        EQSettings(bandGains: bandGains, isEnabled: true)
    }
}

enum EQPresetSelection: Equatable, Sendable {
    case builtIn(EQPreset)
    case custom(CustomEQPreset)
    case customUnsaved

    var displayName: String {
        switch self {
        case .builtIn(let preset):
            return preset.name
        case .custom(let preset):
            return preset.name
        case .customUnsaved:
            return "Custom"
        }
    }

    var customPreset: CustomEQPreset? {
        guard case .custom(let preset) = self else { return nil }
        return preset
    }
}

func resolveEQPresetSelection(
    bandGains: [Float],
    customPresets: [CustomEQPreset]
) -> EQPresetSelection {
    let normalizedGains = EQSettings(bandGains: bandGains).clampedGains

    if let builtIn = EQPreset.allCases.first(where: { $0.settings.bandGains == normalizedGains }) {
        return .builtIn(builtIn)
    }

    if let custom = customPresets.first(where: { $0.bandGains == normalizedGains }) {
        return .custom(custom)
    }

    return .customUnsaved
}

/// Updates the in-session unsaved custom curve cache.
/// Keeps the previous cache when current gains match a built-in or saved custom preset.
func updatedSessionCustomBandGains(
    currentBandGains: [Float],
    existingSessionCustomBandGains: [Float]?,
    customPresets: [CustomEQPreset]
) -> [Float]? {
    switch resolveEQPresetSelection(bandGains: currentBandGains, customPresets: customPresets) {
    case .customUnsaved:
        return EQSettings(bandGains: currentBandGains).clampedGains
    case .builtIn, .custom:
        return existingSessionCustomBandGains
    }
}

/// Resolves which band gains should be restored when user selects `Custom`.
func resolvedSessionCustomBandGains(
    currentBandGains: [Float],
    sessionCustomBandGains: [Float]?
) -> [Float] {
    sessionCustomBandGains ?? EQSettings(bandGains: currentBandGains).clampedGains
}
