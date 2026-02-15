// FineTune/Views/EQPanelView.swift
import SwiftUI

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
    @State private var activeNameEditor: CustomPresetNameEditorMode?
    @State private var showOverwriteDialog = false
    @State private var showRenameTargetDialog = false
    @State private var showDeleteDialog = false
    @State private var showDeleteTargetDialog = false
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

            Button(action: resetToFlat) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Reset To Flat")
                }
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(canResetToFlat ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                        .fill(Color.white.opacity(canResetToFlat ? 0.08 : 0.04))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                        .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canResetToFlat)
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
            if let mode = activeNameEditor {
                CustomPresetNameEditorOverlay(
                    title: mode.title,
                    primaryActionTitle: mode.primaryActionTitle,
                    name: mode == .save ? $saveName : $renameName,
                    onSubmit: {
                        switch mode {
                        case .save:
                            saveCurrentAsNew()
                        case .rename:
                            renamePendingPreset()
                        }
                    },
                    onCancel: {
                        activeNameEditor = nil
                        pendingRenamePreset = nil
                    }
                )
            }
        }
        // No outer background - parent ExpandableGlassRow provides the glass container
        .confirmationDialog("Overwrite Custom Preset", isPresented: $showOverwriteDialog, titleVisibility: .visible) {
            ForEach(customPresets) { preset in
                Button(preset.name) {
                    overwrite(with: preset)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a preset to replace with current EQ settings.")
        }
        .confirmationDialog("Select Preset to Rename", isPresented: $showRenameTargetDialog, titleVisibility: .visible) {
            ForEach(customPresets) { preset in
                Button(preset.name) {
                    pendingRenamePreset = preset
                    renameName = preset.name
                    activeNameEditor = .rename
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Select Preset to Delete", isPresented: $showDeleteTargetDialog, titleVisibility: .visible) {
            ForEach(customPresets) { preset in
                Button(preset.name, role: .destructive) {
                    pendingDeletePreset = preset
                    showDeleteDialog = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Custom Preset?", isPresented: $showDeleteDialog, presenting: pendingDeletePreset) { preset in
            Button("Delete", role: .destructive) {
                onDeleteCustomPreset(preset.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { preset in
            Text("\"\(preset.name)\" will be permanently removed.")
        }
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
                showOverwriteDialog = true
            } else {
                saveName = nextDefaultCustomName()
                activeNameEditor = .save
            }
        case .overwrite:
            guard !customPresets.isEmpty else {
                errorMessage = "No custom presets to overwrite."
                return
            }
            showOverwriteDialog = true
        case .rename:
            guard !customPresets.isEmpty else {
                errorMessage = "No custom presets to rename."
                return
            }
            if let currentCustom = resolvedSelection.customPreset {
                pendingRenamePreset = currentCustom
                renameName = currentCustom.name
                activeNameEditor = .rename
            } else {
                showRenameTargetDialog = true
            }
        case .delete:
            guard !customPresets.isEmpty else {
                errorMessage = "No custom presets to delete."
                return
            }
            if let currentCustom = resolvedSelection.customPreset {
                pendingDeletePreset = currentCustom
                showDeleteDialog = true
            } else {
                showDeleteTargetDialog = true
            }
        }
    }

    private func overwrite(with preset: CustomEQPreset) {
        do {
            try onOverwriteCustomPreset(preset.id, settings.bandGains)
        } catch {
            errorMessage = customPresetErrorMessage(for: error)
        }
    }

    private func saveCurrentAsNew() {
        do {
            try onSaveCustomPreset(saveName, settings.bandGains)
            activeNameEditor = nil
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
            activeNameEditor = nil
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

private enum CustomPresetNameEditorMode {
    case save
    case rename

    var title: String {
        switch self {
        case .save: return "Save Custom EQ Preset"
        case .rename: return "Rename Custom Preset"
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .save: return "Save"
        case .rename: return "Rename"
        }
    }
}

private struct CustomPresetNameEditorOverlay: View {
    let title: String
    let primaryActionTitle: String
    @Binding var name: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.32))
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)

                TextField("Preset Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSubmit)

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                    Button(primaryActionTitle, action: onSubmit)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 360)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .windowBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
        }
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
