// FineTune/Views/Rows/InactiveAppRow.swift
import SwiftUI

/// A row displaying a pinned but inactive app (not currently producing audio).
/// Similar to AppRow but:
/// - Uses PinnedAppInfo instead of AudioApp
/// - VU meter always shows 0 (no audio level polling)
/// - Slightly dimmed appearance to indicate inactive state
/// - All settings (volume/mute/EQ/device) work normally and are persisted
struct InactiveAppRow: View {

    // MARK: Properties

    let appInfo: PinnedAppInfo
    let icon: NSImage
    let volume: Float  // Linear gain 0-2
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let isMutedExternal: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onUnpin: () -> Void
    let eqSettings: EQSettings
    let onEQChange: (EQSettings) -> Void
    let customEQPresets: [CustomEQPreset]
    let onSaveCustomEQPreset: (String, [Float]) throws -> Void
    let onOverwriteCustomEQPreset: (UUID, [Float]) throws -> Void
    let onRenameCustomEQPreset: (UUID, String) throws -> Void
    let onDeleteCustomEQPreset: (UUID) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void
    let deviceSelectionMode: DeviceSelectionMode
    let selectedDeviceUIDs: Set<String>
    let onModeChange: (DeviceSelectionMode) -> Void
    let onDevicesSelected: (Set<String>) -> Void

    @State private var sliderValue: Double
    @State private var isEditing = false
    @State private var isPinButtonHovered = false
    @State private var localEQSettings: EQSettings

    /// Show muted icon when explicitly muted OR volume is 0
    private var showMutedIcon: Bool { isMutedExternal || sliderValue == 0 }

    /// Default volume to restore when unmuting from 0 (50% = unity gain)
    private var defaultUnmuteVolume: Double { DesignTokens.Volume.defaultUnmuteSliderPosition }

    /// Pin button color - always visible for inactive (pinned) apps
    private var pinButtonColor: Color {
        if isPinButtonHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveActive  // Always active (pinned)
        }
    }

    /// Resolved device for the current selection (used for static label on macOS 26+)
    private var selectedDevice: AudioDevice? {
        devices.first { $0.uid == selectedDeviceUID }
    }

    // MARK: Initialization

    init(
        appInfo: PinnedAppInfo,
        icon: NSImage,
        volume: Float,
        devices: [AudioDevice],
        selectedDeviceUID: String,
        isMuted: Bool = false,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onUnpin: @escaping () -> Void,
        eqSettings: EQSettings = EQSettings(),
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        customEQPresets: [CustomEQPreset] = [],
        onSaveCustomEQPreset: @escaping (String, [Float]) throws -> Void = { _, _ in },
        onOverwriteCustomEQPreset: @escaping (UUID, [Float]) throws -> Void = { _, _ in },
        onRenameCustomEQPreset: @escaping (UUID, String) throws -> Void = { _, _ in },
        onDeleteCustomEQPreset: @escaping (UUID) -> Void = { _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {},
        deviceSelectionMode: DeviceSelectionMode = .single,
        selectedDeviceUIDs: Set<String> = [],
        onModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in }
    ) {
        self.appInfo = appInfo
        self.icon = icon
        self.volume = volume
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.isMutedExternal = isMuted
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onUnpin = onUnpin
        self.eqSettings = eqSettings
        self.onEQChange = onEQChange
        self.customEQPresets = customEQPresets
        self.onSaveCustomEQPreset = onSaveCustomEQPreset
        self.onOverwriteCustomEQPreset = onOverwriteCustomEQPreset
        self.onRenameCustomEQPreset = onRenameCustomEQPreset
        self.onDeleteCustomEQPreset = onDeleteCustomEQPreset
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        self.deviceSelectionMode = deviceSelectionMode
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.onModeChange = onModeChange
        self.onDevicesSelected = onDevicesSelected
        // Convert linear gain to slider position
        self._sliderValue = State(initialValue: VolumeMapping.gainToSlider(volume))
        // Initialize local EQ state for reactive UI updates
        self._localEQSettings = State(initialValue: eqSettings)
    }

    // MARK: Body

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded) {
            // Header: Main row content (always visible)
            HStack(spacing: DesignTokens.Spacing.sm) {
                // Unpin star button - always filled (pinned)
                Button {
                    onUnpin()
                } label: {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(pinButtonColor)
                        .frame(
                            minWidth: DesignTokens.Dimensions.minTouchTarget,
                            minHeight: DesignTokens.Dimensions.minTouchTarget
                        )
                        .contentShape(Rectangle())
                        .scaleEffect(isPinButtonHovered ? 1.1 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { isPinButtonHovered = $0 }
                .help("Unpin app")
                .animation(DesignTokens.Animation.hover, value: pinButtonColor)
                .animation(DesignTokens.Animation.quick, value: isPinButtonHovered)

                // App icon (no activation for inactive apps - can't bring to front what isn't running)
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)
                    .opacity(0.6)  // Dimmed to indicate inactive state

                // App name - expands to fill available space
                Text(appInfo.displayName)
                    .font(DesignTokens.Typography.rowName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)  // Dimmed text

                // Controls section - fixed width so sliders align across rows
                HStack(spacing: DesignTokens.Spacing.sm) {
                    // Mute button
                    MuteButton(isMuted: showMutedIcon) {
                        if showMutedIcon {
                            // Unmute: restore to default if at 0
                            if sliderValue == 0 {
                                sliderValue = defaultUnmuteVolume
                            }
                            onMuteChange(false)
                        } else {
                            // Mute
                            onMuteChange(true)
                        }
                    }

                    // Volume slider with unity marker (Liquid Glass)
                    LiquidGlassSlider(
                        value: $sliderValue,
                        showUnityMarker: true,
                        onEditingChanged: { editing in
                            isEditing = editing
                        }
                    )
                    .frame(width: DesignTokens.Dimensions.sliderWidth)
                    .opacity(showMutedIcon ? 0.5 : 1.0)
                    .onChange(of: sliderValue) { _, newValue in
                        let gain = VolumeMapping.sliderToGain(newValue)
                        onVolumeChange(gain)
                    }
                    .autoUnmuteOnSliderMove(
                        sliderValue: sliderValue,
                        isMuted: isMutedExternal,
                        onUnmute: { onMuteChange(false) }
                    )

                    // Volume percentage (0-200% matching slider position)
                    Text("\(Int(sliderValue * 200))%")
                        .percentageStyle()

                    // VU Meter (always level 0 for inactive apps)
                    VUMeter(level: 0, isMuted: showMutedIcon)

                    // Device picker (single or multi mode)
                    DevicePicker(
                        devices: devices,
                        selectedDeviceUID: selectedDeviceUID,
                        selectedDeviceUIDs: selectedDeviceUIDs,
                        mode: deviceSelectionMode,
                        onDeviceSelected: onDeviceSelected,
                        onDevicesSelected: onDevicesSelected,
                        onModeChange: onModeChange
                    )

                    // EQ button at end of row (animates to X when expanded)
                    AppRowEQToggle(isExpanded: isEQExpanded, onToggle: onEQToggle)
                }
                .frame(width: DesignTokens.Dimensions.controlsWidth)
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            // EQ panel - shown when expanded
            EQPanelView(
                settings: $localEQSettings,
                customPresets: customEQPresets,
                onPresetSelected: { selected in
                    switch selected {
                    case .builtIn(let preset):
                        localEQSettings = preset.settings
                        onEQChange(preset.settings)
                    case .custom(let preset):
                        localEQSettings = preset.eqSettings
                        onEQChange(preset.eqSettings)
                    case .customUnsaved:
                        break
                    }
                },
                onSettingsChanged: onEQChange,
                onSaveCustomPreset: onSaveCustomEQPreset,
                onOverwriteCustomPreset: onOverwriteCustomEQPreset,
                onRenameCustomPreset: onRenameCustomEQPreset,
                onDeleteCustomPreset: onDeleteCustomEQPreset
            )
            .padding(.top, DesignTokens.Spacing.sm)
        }
        .onChange(of: volume) { _, newValue in
            // Only sync from external changes when user is NOT dragging
            guard !isEditing else { return }
            sliderValue = VolumeMapping.gainToSlider(newValue)
        }
        .onChange(of: eqSettings) { _, newValue in
            // Sync from parent when external EQ settings change
            localEQSettings = newValue
        }
    }
}
