// FineTune/Views/Components/EQPresetPicker.swift
import SwiftUI

enum EQPresetPickerAction: String, CaseIterable, Identifiable, Hashable {
    case saveNew
    case overwrite
    case rename
    case delete

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .saveNew: return "plus.circle"
        case .overwrite: return "arrow.triangle.2.circlepath.circle"
        case .rename: return "pencil"
        case .delete: return "trash"
        }
    }
}

private enum EQPresetPickerSection: String, CaseIterable, Identifiable {
    case builtIn
    case custom
    case actions

    var id: String { rawValue }
}

private enum EQPresetPickerItem: Identifiable {
    case customUnsaved
    case builtIn(EQPreset)
    case custom(CustomEQPreset)
    case action(EQPresetPickerAction)

    var id: String {
        switch self {
        case .customUnsaved:
            return "custom-unsaved"
        case .builtIn(let preset):
            return "builtin-\(preset.id)"
        case .custom(let preset):
            return "custom-\(preset.id.uuidString)"
        case .action(let action):
            return "action-\(action.rawValue)"
        }
    }
}

struct EQPresetPicker: View {
    let selectedPreset: EQPresetSelection
    let customPresets: [CustomEQPreset]
    let disabledActions: Set<EQPresetPickerAction>
    let isCustomPresetCapacityReached: Bool
    let onPresetSelected: (EQPresetSelection) -> Void
    let onActionSelected: (EQPresetPickerAction) -> Void

    private var sections: [EQPresetPickerSection] { [.actions, .custom, .builtIn] }

    private var selectedItem: EQPresetPickerItem? {
        switch selectedPreset {
        case .builtIn(let preset):
            return .builtIn(preset)
        case .custom(let preset):
            return .custom(preset)
        case .customUnsaved:
            return .customUnsaved
        }
    }

    private func items(for section: EQPresetPickerSection) -> [EQPresetPickerItem] {
        switch section {
        case .builtIn:
            return EQPreset.allCases.map { .builtIn($0) }
        case .custom:
            return [.customUnsaved] + customPresets.map { .custom($0) }
        case .actions:
            return EQPresetPickerAction.allCases.map { .action($0) }
        }
    }

    private func sectionTitle(_ section: EQPresetPickerSection) -> String {
        switch section {
        case .builtIn:
            return "Built-in"
        case .custom:
            return "Custom (\(customPresets.count)/\(CustomEQPreset.maxCount))"
        case .actions:
            return ""
        }
    }

    private func actionTitle(_ action: EQPresetPickerAction) -> String {
        switch action {
        case .saveNew:
            return isCustomPresetCapacityReached ? "Save Current as New... (Full)" : "Save Current as New..."
        case .overwrite:
            return "Overwrite Custom Preset..."
        case .rename:
            return "Rename Custom Preset..."
        case .delete:
            return "Delete Custom Preset..."
        }
    }

    var body: some View {
        GroupedDropdownMenu(
            sections: sections,
            itemsForSection: items,
            sectionTitle: sectionTitle,
            selectedItem: selectedItem,
            maxHeight: 320,
            width: 100,
            popoverWidth: 210,
            onSelect: { item in
                switch item {
                case .customUnsaved:
                    onPresetSelected(.customUnsaved)
                case .builtIn(let preset):
                    onPresetSelected(.builtIn(preset))
                case .custom(let preset):
                    onPresetSelected(.custom(preset))
                case .action(let action):
                    guard !disabledActions.contains(action) else { return }
                    onActionSelected(action)
                }
            }
        ) { _ in
            Text(selectedPreset.displayName)
        } itemContent: { item, isSelected in
            switch item {
            case .customUnsaved:
                HStack {
                    Text("Custom")
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            case .builtIn(let preset):
                HStack {
                    Text(preset.name)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            case .custom(let preset):
                HStack {
                    Text(preset.name)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            case .action(let action):
                let isDisabled = disabledActions.contains(action)
                HStack(spacing: 6) {
                    Image(systemName: action.icon)
                        .font(.system(size: 10, weight: .medium))
                    Text(actionTitle(action))
                    Spacer()
                }
                .foregroundStyle(isDisabled ? Color.secondary.opacity(0.5) : Color.primary)
                .opacity(isDisabled ? 0.6 : 1.0)
                .contentShape(Rectangle())
                .allowsHitTesting(!isDisabled)
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        EQPresetPicker(
            selectedPreset: .builtIn(.rock),
            customPresets: [],
            disabledActions: [.overwrite, .rename, .delete],
            isCustomPresetCapacityReached: false,
            onPresetSelected: { _ in },
            onActionSelected: { _ in }
        )

        EQPresetPicker(
            selectedPreset: .customUnsaved,
            customPresets: [
                CustomEQPreset(name: "Podcast+", bandGains: [-4, -2, -1, -2, 0, 2, 4, 4, 2, 0]),
                CustomEQPreset(name: "Movie Night", bandGains: [4, 4, 3, -1, -1, 1, 3, 3, 2, 1])
            ],
            disabledActions: [],
            isCustomPresetCapacityReached: false,
            onPresetSelected: { _ in },
            onActionSelected: { _ in }
        )

        EQPresetPicker(
            selectedPreset: .customUnsaved,
            customPresets: [
                CustomEQPreset(name: "A", bandGains: Array(repeating: 0, count: EQSettings.bandCount)),
                CustomEQPreset(name: "B", bandGains: Array(repeating: 1, count: EQSettings.bandCount)),
                CustomEQPreset(name: "C", bandGains: Array(repeating: 2, count: EQSettings.bandCount)),
                CustomEQPreset(name: "D", bandGains: Array(repeating: 3, count: EQSettings.bandCount)),
                CustomEQPreset(name: "E", bandGains: Array(repeating: 4, count: EQSettings.bandCount))
            ],
            disabledActions: [.rename, .delete],
            isCustomPresetCapacityReached: true,
            onPresetSelected: { _ in },
            onActionSelected: { _ in }
        )
    }
    .padding()
    .background(Color.black)
}
