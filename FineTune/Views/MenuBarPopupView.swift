// FineTune/Views/MenuBarPopupView.swift
import SwiftUI

struct MenuBarPopupView: View {
    @Bindable var viewModel: MenuBarPopupViewModel

    private var audioEngine: AudioEngine { viewModel.audioEngine }
    private var deviceVolumeMonitor: DeviceVolumeMonitor { viewModel.deviceVolumeMonitor }

    /// Namespace for device toggle animation
    @Namespace private var deviceToggleNamespace

    // MARK: - Scroll Thresholds (from DesignTokens)

    private var deviceScrollThreshold: Int { DesignTokens.ScrollThresholds.deviceCount }
    private var deviceScrollHeight: CGFloat { DesignTokens.ScrollThresholds.deviceScrollHeight }
    private var appScrollThreshold: Int { DesignTokens.ScrollThresholds.appCount }
    private var appScrollHeight: CGFloat { DesignTokens.ScrollThresholds.appScrollHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // Header row with device tabs and default device status
            HStack(alignment: .top) {
                deviceTabsHeader
                Spacer()
                defaultDevicesStatus
            }
            .padding(.bottom, DesignTokens.Spacing.xs)

            // Devices section (tabbed: Output / Input)
            devicesSection

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            // Apps section (active + pinned inactive)
            if audioEngine.displayableApps.isEmpty {
                emptyStateView
            } else {
                appsSection
            }

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            // Quit button
            HStack {
                Spacer()
                Button("Quit FineTune") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .glassButtonStyle()
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: DesignTokens.Dimensions.popupWidth)
        .darkGlassBackground()
        .environment(\.colorScheme, .dark)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            viewModel.isPopupVisible = true
            // Re-sync default device in case of missed listener updates
            deviceVolumeMonitor.refreshDefaultDevice()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            viewModel.isPopupVisible = false
        }
    }

    // MARK: - Default Devices Status

    /// Subtle display of both default devices in header
    private var defaultDevicesStatus: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            // Output device
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9))
                Text(viewModel.defaultOutputDeviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Separator
            Text("\u{00B7}")

            // Input device
            HStack(spacing: 3) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 9))
                Text(viewModel.defaultInputDeviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(DesignTokens.Colors.textSecondary)
    }

    // MARK: - Device Toggle

    /// Icon-only pill toggle for switching between Output and Input devices
    private var deviceTabsHeader: some View {
        let iconSize: CGFloat = 13
        let buttonSize: CGFloat = 26

        return HStack(spacing: 2) {
            // Output (speaker) button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    viewModel.showingInputDevices = false
                }
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: iconSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(viewModel.showingInputDevices ? DesignTokens.Colors.textTertiary : DesignTokens.Colors.textPrimary)
                    .frame(width: buttonSize, height: buttonSize)
                    .background {
                        if !viewModel.showingInputDevices {
                            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                                .fill(.white.opacity(0.1))
                                .matchedGeometryEffect(id: "deviceToggle", in: deviceToggleNamespace)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Output Devices")

            // Input (mic) button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    viewModel.showingInputDevices = true
                }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(viewModel.showingInputDevices ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
                    .frame(width: buttonSize, height: buttonSize)
                    .background {
                        if viewModel.showingInputDevices {
                            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                                .fill(.white.opacity(0.1))
                                .matchedGeometryEffect(id: "deviceToggle", in: deviceToggleNamespace)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Input Devices")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 3)
                .fill(.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 3)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Subviews

    @ViewBuilder
    private var devicesSection: some View {
        let devices = viewModel.showingInputDevices ? viewModel.sortedInputDevices : viewModel.sortedDevices

        if devices.count > deviceScrollThreshold {
            ScrollView {
                devicesContent
            }
            .scrollIndicators(.never)
            .frame(height: deviceScrollHeight)
        } else {
            devicesContent
        }
    }

    private var devicesContent: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            if viewModel.showingInputDevices {
                ForEach(viewModel.sortedInputDevices) { device in
                    InputDeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultInputDeviceID,
                        volume: deviceVolumeMonitor.inputVolumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.inputMuteStates[device.id] ?? false,
                        onSetDefault: {
                            audioEngine.setLockedInputDevice(device)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setInputVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.inputMuteStates[device.id] ?? false
                            deviceVolumeMonitor.setInputMute(for: device.id, to: !currentMute)
                        }
                    )
                }
            } else {
                ForEach(viewModel.sortedDevices) { device in
                    DeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultDeviceID,
                        volume: deviceVolumeMonitor.volumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.muteStates[device.id] ?? false,
                        onSetDefault: {
                            deviceVolumeMonitor.setDefaultDevice(device.id)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.muteStates[device.id] ?? false
                            deviceVolumeMonitor.setMute(for: device.id, to: !currentMute)
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        HStack {
            Spacer()
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "speaker.slash")
                    .font(.title)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                Text("No apps playing audio")
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    @ViewBuilder
    private var appsSection: some View {
        SectionHeader(title: "Apps")
            .padding(.bottom, DesignTokens.Spacing.xs)

        // ScrollViewReader needed for EQ expand scroll-to behavior
        ScrollViewReader { scrollProxy in
            if audioEngine.displayableApps.count > appScrollThreshold {
                ScrollView {
                    appsContent(scrollProxy: scrollProxy)
                }
                .scrollIndicators(.never)
                .frame(height: appScrollHeight)
            } else {
                appsContent(scrollProxy: scrollProxy)
            }
        }
    }

    private func appsContent(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(audioEngine.displayableApps) { displayableApp in
                switch displayableApp {
                case .active(let app):
                    activeAppRow(app: app, displayableApp: displayableApp, scrollProxy: scrollProxy)

                case .pinnedInactive(let info):
                    inactiveAppRow(info: info, displayableApp: displayableApp, scrollProxy: scrollProxy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Row for an active app (currently producing audio)
    @ViewBuilder
    private func activeAppRow(app: AudioApp, displayableApp: DisplayableApp, scrollProxy: ScrollViewProxy) -> some View {
        // Use explicit device routing if available, otherwise fall back to first real (non-virtual) device
        let deviceUID = audioEngine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: audioEngine.outputDevices,
            defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID
        )
        AppRowWithLevelPolling(
            app: app,
            volume: audioEngine.getVolume(for: app),
            isMuted: audioEngine.getMute(for: app),
            isPaused: audioEngine.isPausedDisplayApp(app),
            devices: audioEngine.outputDevices,
            selectedDeviceUID: deviceUID,
            isPinned: audioEngine.isPinned(app),
            getAudioLevel: { audioEngine.getAudioLevel(for: app) },
            isPopupVisible: viewModel.isPopupVisible,
            onVolumeChange: { volume in
                audioEngine.setVolume(for: app, to: volume)
            },
            onMuteChange: { muted in
                audioEngine.setMute(for: app, to: muted)
            },
            onDeviceSelected: { newDeviceUID in
                audioEngine.setDevice(for: app, deviceUID: newDeviceUID)
            },
            onAppActivate: {
                viewModel.activateApp(pid: app.id, bundleID: app.bundleID)
            },
            onPinToggle: {
                if audioEngine.isPinned(app) {
                    audioEngine.unpinApp(app.persistenceIdentifier)
                } else {
                    audioEngine.pinApp(app)
                }
            },
            eqSettings: audioEngine.getEQSettings(for: app),
            onEQChange: { settings in
                audioEngine.setEQSettings(settings, for: app)
            },
            isEQExpanded: viewModel.expandedEQAppID == displayableApp.id,
            onEQToggle: {
                withAnimation(DesignTokens.Animation.eqToggle) {
                    if let scrollTarget = viewModel.toggleEQ(for: displayableApp.id) {
                        scrollProxy.scrollTo(scrollTarget, anchor: .top)
                    }
                }
            }
        )
        .id(displayableApp.id)
    }

    /// Row for a pinned inactive app (not currently producing audio)
    @ViewBuilder
    private func inactiveAppRow(info: PinnedAppInfo, displayableApp: DisplayableApp, scrollProxy: ScrollViewProxy) -> some View {
        let identifier = info.persistenceIdentifier
        let selectedDeviceUID = audioEngine.getDeviceRoutingForInactive(identifier: identifier)
            ?? deviceVolumeMonitor.defaultDeviceUID
            ?? audioEngine.outputDevices.first?.uid
            ?? ""
        InactiveAppRow(
            appInfo: info,
            icon: displayableApp.icon,
            volume: audioEngine.getVolumeForInactive(identifier: identifier),
            devices: audioEngine.outputDevices,
            selectedDeviceUID: selectedDeviceUID,
            isMuted: audioEngine.getMuteForInactive(identifier: identifier),
            onVolumeChange: { volume in
                audioEngine.setVolumeForInactive(identifier: identifier, to: volume)
            },
            onMuteChange: { muted in
                audioEngine.setMuteForInactive(identifier: identifier, to: muted)
            },
            onDeviceSelected: { newDeviceUID in
                audioEngine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: newDeviceUID)
            },
            onUnpin: {
                audioEngine.unpinApp(identifier)
            },
            eqSettings: audioEngine.getEQSettingsForInactive(identifier: identifier),
            onEQChange: { settings in
                audioEngine.setEQSettingsForInactive(settings, identifier: identifier)
            },
            isEQExpanded: viewModel.expandedEQAppID == displayableApp.id,
            onEQToggle: {
                withAnimation(DesignTokens.Animation.eqToggle) {
                    if let scrollTarget = viewModel.toggleEQ(for: displayableApp.id) {
                        scrollProxy.scrollTo(scrollTarget, anchor: .top)
                    }
                }
            }
        )
        .id(displayableApp.id)
    }

}

// MARK: - Previews

#Preview("Menu Bar Popup") {
    // Note: This preview requires mock AudioEngine and DeviceVolumeMonitor
    // For now, just show the structure
    PreviewContainer {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeader(title: "Output Devices")
                .padding(.bottom, DesignTokens.Spacing.xs)

            ForEach(MockData.sampleDevices.prefix(2)) { device in
                DeviceRow(
                    device: device,
                    isDefault: device == MockData.sampleDevices[0],
                    volume: 0.75,
                    isMuted: false,
                    onSetDefault: {},
                    onVolumeChange: { _ in },
                    onMuteToggle: {}
                )
            }

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            SectionHeader(title: "Apps")
                .padding(.bottom, DesignTokens.Spacing.xs)

            ForEach(MockData.sampleApps.prefix(3)) { app in
                AppRow(
                    app: app,
                    volume: Float.random(in: 0.5...1.5),
                    audioLevel: Float.random(in: 0...0.7),
                    devices: MockData.sampleDevices,
                    selectedDeviceUID: MockData.sampleDevices[0].uid,
                    isMuted: false,
                    onVolumeChange: { _ in },
                    onMuteChange: { _ in },
                    onDeviceSelected: { _ in }
                )
            }

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            Button("Quit FineTune") {}
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .font(DesignTokens.Typography.caption)
        }
    }
}
