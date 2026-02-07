// FineTune/Views/Rows/AppRow.swift
import SwiftUI
import Combine

/// A row displaying an app with volume controls and VU meter
/// Used in the Apps section
struct AppRow: View {
    let app: AudioApp
    let volume: Float  // Linear gain 0-2
    let audioLevel: Float
    let isPaused: Bool
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let isMutedExternal: Bool  // Mute state from AudioEngine
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onAppActivate: () -> Void
    let eqSettings: EQSettings
    let onEQChange: (EQSettings) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void

    @State private var sliderValue: Double  // 0-1, log-mapped position
    @State private var isEditing = false
    @State private var isIconHovered = false
    @State private var isEQButtonHovered = false
    @State private var localEQSettings: EQSettings

    /// Show muted icon when explicitly muted OR volume is 0
    private var showMutedIcon: Bool { isMutedExternal || sliderValue == 0 }
    private var controlsOpacity: Double { isPaused ? 0.82 : 1.0 }
    private var rowTitleOpacity: Double { isPaused ? 0.92 : 1.0 }

    /// EQ button color following same pattern as MuteButton
    private var eqButtonColor: Color {
        if isEQExpanded {
            return DesignTokens.Colors.interactiveActive
        } else if isEQButtonHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }

    /// Default volume to restore when unmuting from 0 (50% = unity gain)
    private var defaultUnmuteVolume: Double { DesignTokens.Volume.defaultUnmuteSliderPosition }

    init(
        app: AudioApp,
        volume: Float,
        audioLevel: Float = 0,
        isPaused: Bool = false,
        devices: [AudioDevice],
        selectedDeviceUID: String,
        isMuted: Bool = false,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onAppActivate: @escaping () -> Void = {},
        eqSettings: EQSettings = EQSettings(),
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {}
    ) {
        self.app = app
        self.volume = volume
        self.audioLevel = audioLevel
        self.isPaused = isPaused
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.isMutedExternal = isMuted
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onAppActivate = onAppActivate
        self.eqSettings = eqSettings
        self.onEQChange = onEQChange
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        // Convert linear gain to slider position
        self._sliderValue = State(initialValue: VolumeMapping.gainToSlider(volume))
        // Initialize local EQ state for reactive UI updates
        self._localEQSettings = State(initialValue: eqSettings)
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded) {
            // Header: Main row content (always visible)
            HStack(spacing: DesignTokens.Spacing.sm) {
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
                        // Auto-unmute when slider moved while muted
                        if isMutedExternal {
                            onMuteChange(false)
                        }
                    }

                    // Volume percentage (0-200% matching slider position)
                    Text("\(Int(sliderValue * 200))%")
                        .percentageStyle()

                    // VU Meter (shows gray bars when muted or volume is 0)
                    VUMeter(level: audioLevel, isMuted: showMutedIcon)

                    // Device picker
                    DevicePicker(
                        devices: devices,
                        selectedDeviceUID: selectedDeviceUID,
                        onDeviceSelected: onDeviceSelected
                    )

                    // EQ button at end of row (animates to X when expanded)
                    Button {
                        onEQToggle()
                    } label: {
                        ZStack {
                            Image(systemName: "slider.vertical.3")
                                .opacity(isEQExpanded ? 0 : 1)
                                .rotationEffect(.degrees(isEQExpanded ? 90 : 0))

                            Image(systemName: "xmark")
                                .opacity(isEQExpanded ? 1 : 0)
                                .rotationEffect(.degrees(isEQExpanded ? 0 : -90))
                        }
                        .font(.system(size: 12))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(eqButtonColor)
                        .frame(
                            minWidth: DesignTokens.Dimensions.minTouchTarget,
                            minHeight: DesignTokens.Dimensions.minTouchTarget
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isEQButtonHovered = $0 }
                    .help(isEQExpanded ? "Close Equalizer" : "Equalizer")
                    .animation(DesignTokens.Animation.eqButton, value: isEQExpanded)
                    .animation(DesignTokens.Animation.hover, value: isEQButtonHovered)
                }
                .opacity(controlsOpacity)
                .frame(width: DesignTokens.Dimensions.controlsWidth)
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            // EQ panel - shown when expanded
            // SwiftUI calculates natural height via conditional rendering
            EQPanelView(
                settings: $localEQSettings,
                onPresetSelected: { preset in
                    localEQSettings = preset.settings
                    onEQChange(preset.settings)
                },
                onSettingsChanged: { settings in
                    onEQChange(settings)
                }
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

// MARK: - App Row with Timer-based Level Updates

/// App row that polls audio levels at regular intervals
struct AppRowWithLevelPolling: View {
    let app: AudioApp
    let volume: Float
    let isMuted: Bool
    let isPaused: Bool
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let getAudioLevel: () -> Float
    let isPopupVisible: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onAppActivate: () -> Void
    let eqSettings: EQSettings
    let onEQChange: (EQSettings) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void

    @State private var displayLevel: Float = 0
    @State private var levelPollingTask: Task<Void, Never>?

    init(
        app: AudioApp,
        volume: Float,
        isMuted: Bool,
        isPaused: Bool = false,
        devices: [AudioDevice],
        selectedDeviceUID: String,
        getAudioLevel: @escaping () -> Float,
        isPopupVisible: Bool = true,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onAppActivate: @escaping () -> Void = {},
        eqSettings: EQSettings = EQSettings(),
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {}
    ) {
        self.app = app
        self.volume = volume
        self.isMuted = isMuted
        self.isPaused = isPaused
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.getAudioLevel = getAudioLevel
        self.isPopupVisible = isPopupVisible
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onAppActivate = onAppActivate
        self.eqSettings = eqSettings
        self.onEQChange = onEQChange
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
    }

    var body: some View {
        AppRow(
            app: app,
            volume: volume,
            audioLevel: displayLevel,
            isPaused: isPaused,
            devices: devices,
            selectedDeviceUID: selectedDeviceUID,
            isMuted: isMuted,
            onVolumeChange: onVolumeChange,
            onMuteChange: onMuteChange,
            onDeviceSelected: onDeviceSelected,
            onAppActivate: onAppActivate,
            eqSettings: eqSettings,
            onEQChange: onEQChange,
            isEQExpanded: isEQExpanded,
            onEQToggle: onEQToggle
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
                displayLevel = 0  // Reset meter when hidden
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
        // Guard against duplicate tasks
        guard levelPollingTask == nil else { return }

        // Capture getAudioLevel to avoid implicit self capture
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
