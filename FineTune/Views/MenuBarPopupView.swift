// FineTune/Views/MenuBarPopupView.swift
import SwiftUI

struct MenuBarPopupView: View {
    @Bindable var viewModel: MenuBarPopupViewModel

    private var audioEngine: AudioEngine { viewModel.audioEngine }
    private var deviceVolumeMonitor: DeviceVolumeMonitor { viewModel.deviceVolumeMonitor }

    // MARK: - Scroll Thresholds (from DesignTokens)

    private var deviceScrollThreshold: Int { DesignTokens.ScrollThresholds.deviceCount }
    private var deviceScrollHeight: CGFloat { DesignTokens.ScrollThresholds.deviceScrollHeight }
    private var appScrollThreshold: Int { DesignTokens.ScrollThresholds.appCount }
    private var appScrollHeight: CGFloat { DesignTokens.ScrollThresholds.appScrollHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // Output Devices section
            devicesSection

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            // Apps section
            if audioEngine.displayedApps.isEmpty {
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

    // MARK: - Subviews

    @ViewBuilder
    private var devicesSection: some View {
        SectionHeader(title: "Output Devices")
            .padding(.bottom, DesignTokens.Spacing.xs)

        if viewModel.sortedDevices.count > deviceScrollThreshold {
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
            if audioEngine.displayedApps.count > appScrollThreshold {
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
            ForEach(audioEngine.displayedApps) { app in
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
                    eqSettings: audioEngine.getEQSettings(for: app),
                    onEQChange: { settings in
                        audioEngine.setEQSettings(settings, for: app)
                    },
                    isEQExpanded: viewModel.expandedEQAppID == app.id,
                    onEQToggle: {
                        withAnimation(DesignTokens.Animation.eqToggle) {
                            if let scrollTarget = viewModel.toggleEQ(for: app.id) {
                                scrollProxy.scrollTo(scrollTarget, anchor: .top)
                            }
                        }
                    }
                )
                .id(app.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
