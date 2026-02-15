// FineTune/Views/Rows/AppRow.swift
import SwiftUI
import Combine

// MARK: - AppRow

/// A row displaying an app with volume controls and VU meter
/// Used in the Apps section
struct AppRow: View {

    // MARK: Properties

    let app: AudioApp
    let volume: Float  // Linear gain 0-2
    let audioLevel: Float
    let isPaused: Bool
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let isMutedExternal: Bool  // Mute state from AudioEngine
    let isPinned: Bool  // Whether app is pinned to top
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onAppActivate: () -> Void
    let onPinToggle: () -> Void  // Toggle pin state
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

    @State private var sliderValue: Double  // 0-1, log-mapped position
    @State private var isEditing = false
    @State private var isIconHovered = false
    @State private var isRowHovered = false
    @State private var isPinButtonHovered = false
    @State private var localEQSettings: EQSettings
    @State private var sessionCustomBandGains: [Float]?

    /// Show muted icon when explicitly muted OR volume is 0
    private var showMutedIcon: Bool { isMutedExternal || sliderValue == 0 }
    private var controlsOpacity: Double { isPaused ? 0.82 : 1.0 }
    private var rowTitleOpacity: Double { isPaused ? 0.92 : 1.0 }

    /// Default volume to restore when unmuting from 0 (50% = unity gain)
    private var defaultUnmuteVolume: Double { DesignTokens.Volume.defaultUnmuteSliderPosition }

    /// Pin button color - visible when pinned or row is hovered
    private var pinButtonColor: Color {
        if isPinned {
            return DesignTokens.Colors.interactiveActive
        } else if isPinButtonHovered {
            return DesignTokens.Colors.interactiveHover
        } else if isRowHovered {
            return DesignTokens.Colors.interactiveDefault
        } else {
            return .clear
        }
    }

    /// Resolved device for the current selection (used for static label on macOS 26+)
    private var selectedDevice: AudioDevice? {
        devices.first { $0.uid == selectedDeviceUID }
    }

    // MARK: Initialization

    init(
        app: AudioApp,
        volume: Float,
        audioLevel: Float = 0,
        isPaused: Bool = false,
        devices: [AudioDevice],
        selectedDeviceUID: String,
        isMuted: Bool = false,
        isPinned: Bool = false,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onAppActivate: @escaping () -> Void = {},
        onPinToggle: @escaping () -> Void = {},
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
        self.app = app
        self.volume = volume
        self.audioLevel = audioLevel
        self.isPaused = isPaused
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.isMutedExternal = isMuted
        self.isPinned = isPinned
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onAppActivate = onAppActivate
        self.onPinToggle = onPinToggle
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
        // Cache the initial unsaved curve if current gains are not a built-in/saved preset.
        self._sessionCustomBandGains = State(
            initialValue: updatedSessionCustomBandGains(
                currentBandGains: eqSettings.bandGains,
                existingSessionCustomBandGains: nil,
                customPresets: customEQPresets
            )
        )
    }

    // MARK: Body

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded) {
            // Header: Main row content (always visible)
            HStack(spacing: DesignTokens.Spacing.sm) {
                // Pin/unpin star button - left of app icon
                Button {
                    onPinToggle()
                } label: {
                    Image(systemName: isPinned ? "star.fill" : "star")
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
                .help(isPinned ? "Unpin app" : "Pin app to top")
                .animation(DesignTokens.Animation.hover, value: pinButtonColor)
                .animation(DesignTokens.Animation.quick, value: isPinButtonHovered)

                // App icon - clickable to activate app
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)
                    .opacity(isIconHovered ? 0.7 : 1.0)
                    .onHover { hovering in
                        isIconHovered = hovering
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .onTapGesture {
                        onAppActivate()
                    }

                // App name - expands to fill available space
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(app.name)
                        .font(DesignTokens.Typography.rowName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)
                        .opacity(rowTitleOpacity)

                    if isPaused {
                        HStack(spacing: DesignTokens.Spacing.xxs) {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 8, weight: .semibold))
                            Text("Paused")
                                .font(DesignTokens.Typography.caption)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.10))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.primary.opacity(0.16), lineWidth: 0.5)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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

                    // VU Meter (shows gray bars when muted or volume is 0)
                    VUMeter(level: audioLevel, isMuted: showMutedIcon)

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
                .opacity(controlsOpacity)
                .frame(width: DesignTokens.Dimensions.controlsWidth)
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
            .onHover { isRowHovered = $0 }
        } expandedContent: {
            // EQ panel - shown when expanded
            // SwiftUI calculates natural height via conditional rendering
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
                        let restoredGains = resolvedSessionCustomBandGains(
                            currentBandGains: localEQSettings.bandGains,
                            sessionCustomBandGains: sessionCustomBandGains
                        )
                        let restored = EQSettings(
                            bandGains: restoredGains,
                            isEnabled: localEQSettings.isEnabled
                        )
                        localEQSettings = restored
                        onEQChange(restored)
                    }
                },
                onSettingsChanged: { updated in
                    onEQChange(updated)
                },
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
        .onChange(of: localEQSettings.bandGains) { _, newValue in
            sessionCustomBandGains = updatedSessionCustomBandGains(
                currentBandGains: newValue,
                existingSessionCustomBandGains: sessionCustomBandGains,
                customPresets: customEQPresets
            )
        }
        .onChange(of: customEQPresets) { _, _ in
            sessionCustomBandGains = updatedSessionCustomBandGains(
                currentBandGains: localEQSettings.bandGains,
                existingSessionCustomBandGains: sessionCustomBandGains,
                customPresets: customEQPresets
            )
        }
    }
}

// MARK: - App Row with Timer-based Level Updates

/// App row that polls audio levels at regular intervals for VU meter display.
struct AppRowWithLevelPolling: View {
    let app: AudioApp
    let volume: Float
    let isMuted: Bool
    let isPaused: Bool
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let isPinned: Bool
    let getAudioLevel: () -> Float
    let isPopupVisible: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onAppActivate: () -> Void
    let onPinToggle: () -> Void
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

    @State private var displayLevel: Float = 0
    @State private var levelPollingTask: Task<Void, Never>?

    var body: some View {
        AppRow(
            app: app,
            volume: volume,
            audioLevel: displayLevel,
            isPaused: isPaused,
            devices: devices,
            selectedDeviceUID: selectedDeviceUID,
            isMuted: isMuted,
            isPinned: isPinned,
            onVolumeChange: onVolumeChange,
            onMuteChange: onMuteChange,
            onDeviceSelected: onDeviceSelected,
            onAppActivate: onAppActivate,
            onPinToggle: onPinToggle,
            eqSettings: eqSettings,
            onEQChange: onEQChange,
            customEQPresets: customEQPresets,
            onSaveCustomEQPreset: onSaveCustomEQPreset,
            onOverwriteCustomEQPreset: onOverwriteCustomEQPreset,
            onRenameCustomEQPreset: onRenameCustomEQPreset,
            onDeleteCustomEQPreset: onDeleteCustomEQPreset,
            isEQExpanded: isEQExpanded,
            onEQToggle: onEQToggle,
            deviceSelectionMode: deviceSelectionMode,
            selectedDeviceUIDs: selectedDeviceUIDs,
            onModeChange: onModeChange,
            onDevicesSelected: onDevicesSelected
        )
        .onAppear {
            if isPopupVisible && !isPaused {
                startLevelPolling()
            } else {
                displayLevel = 0
            }
        }
        .onDisappear {
            stopLevelPolling()
        }
        .onChange(of: isPopupVisible) { _, visible in
            if visible && !isPaused {
                startLevelPolling()
            } else {
                stopLevelPolling()
                displayLevel = 0
            }
        }
        .onChange(of: isPaused) { _, paused in
            if paused {
                stopLevelPolling()
                displayLevel = 0
            } else if isPopupVisible {
                startLevelPolling()
            }
        }
    }

    private func startLevelPolling() {
        guard levelPollingTask == nil else { return }
        let pollLevel = getAudioLevel
        let interval = DesignTokens.Timing.vuMeterUpdateInterval

        levelPollingTask = Task { @MainActor in
            while !Task.isCancelled {
                displayLevel = pollLevel()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func stopLevelPolling() {
        levelPollingTask?.cancel()
        levelPollingTask = nil
    }
}

// MARK: - Previews

#Preview("App Row") {
    PreviewContainer {
        VStack(spacing: 4) {
            AppRow(
                app: MockData.sampleApps[0],
                volume: 1.0,
                audioLevel: 0.65,
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[0].uid,
                onVolumeChange: { _ in },
                onMuteChange: { _ in },
                onDeviceSelected: { _ in }
            )

            AppRow(
                app: MockData.sampleApps[1],
                volume: 0.5,
                audioLevel: 0.25,
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[1].uid,
                onVolumeChange: { _ in },
                onMuteChange: { _ in },
                onDeviceSelected: { _ in }
            )

            AppRow(
                app: MockData.sampleApps[2],
                volume: 1.5,
                audioLevel: 0.85,
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[2].uid,
                onVolumeChange: { _ in },
                onMuteChange: { _ in },
                onDeviceSelected: { _ in }
            )
        }
    }
}

#Preview("App Row - Multiple Apps") {
    PreviewContainer {
        VStack(spacing: 4) {
            ForEach(MockData.sampleApps) { app in
                AppRow(
                    app: app,
                    volume: Float.random(in: 0.5...1.5),
                    audioLevel: Float.random(in: 0...0.8),
                    devices: MockData.sampleDevices,
                    selectedDeviceUID: MockData.sampleDevices.randomElement()!.uid,
                    onVolumeChange: { _ in },
                    onMuteChange: { _ in },
                    onDeviceSelected: { _ in }
                )
            }
        }
    }
}
