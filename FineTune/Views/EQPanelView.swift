// FineTune/Views/EQPanelView.swift
import SwiftUI
#if canImport(FineTuneCore)
import FineTuneCore
#endif

struct EQPanelView: View {
    @Binding var settings: EQSettings
    let customPresets: [CustomEQPreset]
    let onPresetSelected: (EQPresetSelection) -> Void
    let onSettingsChanged: (EQSettings) -> Void
    let onSaveCustomPreset: (String, [Float]) throws -> Void
    let onOverwriteCustomPreset: (UUID, [Float]) throws -> Void
    let onRenameCustomPreset: (UUID, String) throws -> Void
    let onDeleteCustomPreset: (UUID) -> Void

    private let frequencyLabels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    @State private var saveName = ""
    @State private var renameName = ""
    @State private var pendingRenamePreset: CustomEQPreset?
    @State private var pendingDeletePreset: CustomEQPreset?
    @State private var activeOverlay: EQPanelOverlayMode?
    @State private var errorMessage: String?

    private var resolvedSelection: EQPresetSelection {
        resolveEQPresetSelection(bandGains: settings.bandGains, customPresets: customPresets)
    }

    private var customPresetLimitReached: Bool {
        customPresets.count >= CustomEQPreset.maxCount
    }

    private var disabledActions: Set<EQPresetPickerAction> {
        var disabled: Set<EQPresetPickerAction> = []
        if customPresets.isEmpty {
            disabled.insert(.overwrite)
            disabled.insert(.rename)
            disabled.insert(.delete)
        }
        return disabled
    }

    private var canResetToFlat: Bool {
        settings.bandGains != EQSettings.flat.bandGains
    }

    var body: some View {
        // Entire EQ panel content inside recessed background
        VStack(spacing: 12) {
            // Header: Toggle left, Preset right
            HStack {
                // EQ toggle on left
                HStack(spacing: 6) {
                    Toggle("", isOn: $settings.isEnabled)
                        .toggleStyle(.switch)
                        .scaleEffect(0.7)
                        .labelsHidden()
                        .onChange(of: settings.isEnabled) { _, _ in
                            onSettingsChanged(settings)
                        }
                    Text("EQ")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundColor(.primary)
                }

                Spacer()

                Button("Reset", action: resetToFlat)
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(canResetToFlat ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background {
                        Capsule()
                            .fill(Color.white.opacity(canResetToFlat ? 0.08 : 0.04))
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canResetToFlat)

                Spacer()

                // Preset picker on right
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text("Preset")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundColor(DesignTokens.Colors.textSecondary)

                    EQPresetPicker(
                        selectedPreset: resolvedSelection,
                        customPresets: customPresets,
                        disabledActions: disabledActions,
                        isCustomPresetCapacityReached: customPresetLimitReached,
                        onPresetSelected: handlePresetSelection,
                        onActionSelected: handlePresetAction
                    )
                }
            }
            .zIndex(1)  // Ensure dropdown renders above sliders

            HStack {
                Text("Band Gain (dB)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(DesignTokens.Colors.textTertiary)
                Spacer()
            }

            // 10-band sliders
            HStack(spacing: 22) {
                ForEach(0..<10, id: \.self) { index in
                    EQSliderView(
                        frequency: frequencyLabels[index],
                        gain: Binding(
                            get: { settings.bandGains[index] },
                            set: { newValue in
                                settings.bandGains[index] = newValue
                                onSettingsChanged(settings)
                            }
                        )
                    )
                    .frame(width: 26, height: 100)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .overlay {
            if let mode = activeOverlay {
                EQPanelOverlayView(
                    mode: mode,
                    presets: customPresets,
                    saveName: $saveName,
                    renameName: $renameName,
                    pendingRenamePreset: pendingRenamePreset,
                    pendingDeletePreset: pendingDeletePreset,
                    onSave: saveCurrentAsNew,
                    onRename: renamePendingPreset,
                    onOverwrite: { preset in
                        overwrite(with: preset)
                    },
                    onSelectRenameTarget: { preset in
                        pendingRenamePreset = preset
                        renameName = preset.name
                        activeOverlay = .renameName
                    },
                    onSelectDeleteTarget: { preset in
                        pendingDeletePreset = preset
                        activeOverlay = .deleteConfirmation
                    },
                    onConfirmDelete: {
                        if let preset = pendingDeletePreset {
                            onDeleteCustomPreset(preset.id)
                        }
                        activeOverlay = nil
                        pendingDeletePreset = nil
                    },
                    onCancel: {
                        activeOverlay = nil
                        pendingRenamePreset = nil
                        pendingDeletePreset = nil
                    }
                )
            }
        }
        // Error alert is kept as it is for actual errors
        .alert("EQ Preset", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func handlePresetSelection(_ selection: EQPresetSelection) {
        onPresetSelected(selection)
    }

    private func handlePresetAction(_ action: EQPresetPickerAction) {
        switch action {
        case .saveNew:
            if customPresetLimitReached {
                activeOverlay = .overwriteSelector
            } else {
                saveName = nextDefaultCustomName()
                activeOverlay = .saveName
            }
        case .overwrite:
            guard !customPresets.isEmpty else {
                errorMessage = "No custom presets to overwrite."
                return
            }
            activeOverlay = .overwriteSelector
        case .rename:
            guard !customPresets.isEmpty else {
                errorMessage = "No custom presets to rename."
                return
            }
            if let currentCustom = resolvedSelection.customPreset {
                pendingRenamePreset = currentCustom
                renameName = currentCustom.name
                activeOverlay = .renameName
            } else {
                activeOverlay = .renameSelector
            }
        case .delete:
            guard !customPresets.isEmpty else {
                errorMessage = "No custom presets to delete."
                return
            }
            if let currentCustom = resolvedSelection.customPreset {
                pendingDeletePreset = currentCustom
                activeOverlay = .deleteConfirmation
            } else {
                activeOverlay = .deleteSelector
            }
        }
    }

    private func overwrite(with preset: CustomEQPreset) {
        do {
            try onOverwriteCustomPreset(preset.id, settings.bandGains)
            activeOverlay = nil
        } catch {
            errorMessage = customPresetErrorMessage(for: error)
        }
    }

    private func saveCurrentAsNew() {
        do {
            try onSaveCustomPreset(saveName, settings.bandGains)
            activeOverlay = nil
        } catch {
            errorMessage = customPresetErrorMessage(for: error)
        }
    }

    private func renamePendingPreset() {
        guard let pendingRenamePreset else {
            errorMessage = "Could not determine which preset to rename."
            return
        }
        do {
            try onRenameCustomPreset(pendingRenamePreset.id, renameName)
            activeOverlay = nil
            self.pendingRenamePreset = nil
        } catch {
            errorMessage = customPresetErrorMessage(for: error)
        }
    }

    private func resetToFlat() {
        settings.bandGains = EQSettings.flat.bandGains
        onSettingsChanged(settings)
    }

    private func nextDefaultCustomName() -> String {
        let existing = Set(customPresets.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        for i in 1...CustomEQPreset.maxCount {
            let candidate = "Custom \(i)"
            let folded = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if !existing.contains(folded) {
                return candidate
            }
        }
        return "Custom"
    }

    private func customPresetErrorMessage(for error: Error) -> String {
        guard let presetError = error as? CustomEQPresetError else {
            return "Unable to complete the preset action."
        }
        switch presetError {
        case .nameRequired:
            return "Enter a preset name."
        case .nameTooLong:
            return "Preset name must be \(CustomEQPreset.maxNameLength) characters or fewer."
        case .duplicateName:
            return "A custom preset with that name already exists."
        case .limitReached:
            return "You can save up to \(CustomEQPreset.maxCount) custom presets."
        case .notFound:
            return "That preset no longer exists."
        }
    }
}

private enum EQPanelOverlayMode {
    case saveName
    case renameName
    case overwriteSelector
    case renameSelector
    case deleteSelector
    case deleteConfirmation
}

private struct EQPanelOverlayView: View {
    let mode: EQPanelOverlayMode
    let presets: [CustomEQPreset]
    @Binding var saveName: String
    @Binding var renameName: String
    let pendingRenamePreset: CustomEQPreset?
    let pendingDeletePreset: CustomEQPreset?

    let onSave: () -> Void
    let onRename: () -> Void
    let onOverwrite: (CustomEQPreset) -> Void
    let onSelectRenameTarget: (CustomEQPreset) -> Void
    let onSelectDeleteTarget: (CustomEQPreset) -> Void
    let onConfirmDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Semi-transparent dimming background
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(alignment: .leading, spacing: 16) {
                headerView

                contentView

                footerView
            }
            .padding(16)
            .frame(width: 320)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.clear)
                    .background(VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
        }
    }

    @ViewBuilder
    private var headerView: some View {
        Text(title)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(DesignTokens.Colors.textPrimary)
    }

    @ViewBuilder
    private var contentView: some View {
        switch mode {
        case .saveName:
            TextField("Preset Name", text: $saveName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSave)

        case .renameName:
            TextField("Preset Name", text: $renameName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onRename)

        case .overwriteSelector, .renameSelector, .deleteSelector:
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(presets) { preset in
                        Button {
                            switch mode {
                            case .overwriteSelector: onOverwrite(preset)
                            case .renameSelector: onSelectRenameTarget(preset)
                            case .deleteSelector: onSelectDeleteTarget(preset)
                            default: break
                            }
                        } label: {
                            HStack {
                                Text(preset.name)
                                    .font(DesignTokens.Typography.pickerText)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PresetRowButtonStyle())
                    }
                }
            }
            .frame(maxHeight: 180)
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .deleteConfirmation:
            if let preset = pendingDeletePreset {
                Text("Are you sure you want to delete \"\(preset.name)\"? This action cannot be undone.")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.08)))

            if showPrimaryAction {
                Button(primaryActionTitle) {
                    primaryAction()
                }
                .buttonStyle(.plain)
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(mode == .deleteConfirmation ? Color.red : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(mode == .deleteConfirmation ? Color.red.opacity(0.2) : Color.white.opacity(0.12)))
            }
        }
    }

    private var title: String {
        switch mode {
        case .saveName: return "Save Custom Preset"
        case .renameName: return "Rename Preset"
        case .overwriteSelector: return "Select Preset to Overwrite"
        case .renameSelector: return "Select Preset to Rename"
        case .deleteSelector: return "Select Preset to Delete"
        case .deleteConfirmation: return "Delete Preset?"
        }
    }

    private var showPrimaryAction: Bool {
        switch mode {
        case .saveName, .renameName, .deleteConfirmation: return true
        default: return false
        }
    }

    private var primaryActionTitle: String {
        switch mode {
        case .saveName: return "Save"
        case .renameName: return "Rename"
        case .deleteConfirmation: return "Delete"
        default: return ""
        }
    }

    private func primaryAction() {
        switch mode {
        case .saveName: onSave()
        case .renameName: onRename()
        case .deleteConfirmation: onConfirmDelete()
        default: break
        }
    }
}

private struct PresetRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
    }
}

#Preview {
    // Simulating how it appears inside ExpandableGlassRow
    VStack {
        EQPanelView(
            settings: .constant(EQSettings()),
            customPresets: [],
            onPresetSelected: { _ in },
            onSettingsChanged: { _ in },
            onSaveCustomPreset: { _, _ in },
            onOverwriteCustomPreset: { _, _ in },
            onRenameCustomPreset: { _, _ in },
            onDeleteCustomPreset: { _ in }
        )
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .padding(.vertical, DesignTokens.Spacing.xs)
    .background {
        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
            .fill(DesignTokens.Colors.recessedBackground)
    }
    .frame(width: 550)
    .padding()
    .background(Color.black)
}
