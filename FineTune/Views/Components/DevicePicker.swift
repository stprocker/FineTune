// FineTune/Views/Components/DevicePicker.swift
import SwiftUI

/// A styled device picker dropdown supporting both single-device and multi-device selection.
/// In single mode: standard dropdown, selects one device.
/// In multi mode: checkbox list, dropdown stays open, selects multiple devices.
struct DevicePicker: View {
    let devices: [AudioDevice]
    let selectedDeviceUID: String           // single mode
    let selectedDeviceUIDs: Set<String>     // multi mode
    let mode: DeviceSelectionMode
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onModeChange: (DeviceSelectionMode) -> Void

    @State private var isExpanded = false

    // Configuration
    private let itemHeight: CGFloat = 20
    private let cornerRadius: CGFloat = 8
    private let triggerWidth: CGFloat = 128
    private let popoverWidth: CGFloat = 200

    private var selectedDevice: AudioDevice? {
        devices.first { $0.uid == selectedDeviceUID }
    }

    /// Trigger label text for the dropdown button
    private var triggerText: String {
        switch mode {
        case .single:
            return selectedDevice?.name ?? "Select"
        case .multi:
            let count = selectedDeviceUIDs.count
            if count == 0 { return "Select" }
            if count == 1, let uid = selectedDeviceUIDs.first,
               let device = devices.first(where: { $0.uid == uid }) {
                return device.name
            }
            return "\(count) devices"
        }
    }

    /// Icon for the trigger label
    private var triggerIcon: NSImage? {
        switch mode {
        case .single:
            return selectedDevice?.icon
        case .multi:
            let count = selectedDeviceUIDs.count
            if count == 1, let uid = selectedDeviceUIDs.first {
                return devices.first(where: { $0.uid == uid })?.icon
            }
            return nil  // No single icon for multiple devices
        }
    }

    private var menuHeight: CGFloat {
        // Mode toggle row + device items
        let toggleHeight: CGFloat = 28
        let itemCount = CGFloat(devices.count)
        let maxVisible: CGFloat = 8
        return toggleHeight + min(itemCount, maxVisible) * itemHeight + 14
    }

    var body: some View {
        DropdownTriggerButton(isExpanded: $isExpanded, width: triggerWidth) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                DeviceIconView(icon: triggerIcon, size: 16)
                Text(triggerText)
                    .lineLimit(1)
            }
        }
        .background(
            PopoverHost(isPresented: $isExpanded) {
                VStack(spacing: 0) {
                    // Mode toggle: Single | Multi
                    modeToggle
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 4)

                    Divider()
                        .padding(.horizontal, 8)

                    // Device list
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 1) {
                            ForEach(devices) { device in
                                deviceRow(device)
                            }
                        }
                        .padding(5)
                    }
                    .frame(maxHeight: CGFloat(min(devices.count, 8)) * itemHeight + 10)
                }
                .frame(width: popoverWidth)
                .background(
                    VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
                }
            }
        )
    }

    // MARK: - Mode Toggle

    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeButton(label: "Single", targetMode: .single)
            modeButton(label: "Multi", targetMode: .multi)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(.white.opacity(0.05))
        )
    }

    private func modeButton(label: String, targetMode: DeviceSelectionMode) -> some View {
        Button {
            onModeChange(targetMode)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: mode == targetMode ? .semibold : .regular))
                .foregroundStyle(mode == targetMode ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background {
                    if mode == targetMode {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(0.1))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Device Row

    @ViewBuilder
    private func deviceRow(_ device: AudioDevice) -> some View {
        Button {
            handleDeviceTap(device)
        } label: {
            HStack {
                // Checkbox (multi) or nothing (single)
                if mode == .multi {
                    Image(systemName: selectedDeviceUIDs.contains(device.uid) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(selectedDeviceUIDs.contains(device.uid) ? Color.accentColor : Color.secondary)
                }

                DeviceIconView(icon: device.icon, size: 16)
                Text(device.name)
                    .font(.system(size: 11))
                    .lineLimit(1)

                Spacer()

                // Checkmark for single mode
                if mode == .single && device.uid == selectedDeviceUID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .frame(height: itemHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DevicePickerItemButtonStyle())
    }

    private func handleDeviceTap(_ device: AudioDevice) {
        switch mode {
        case .single:
            onDeviceSelected(device.uid)
            withAnimation(.easeOut(duration: 0.15)) {
                isExpanded = false
            }
        case .multi:
            var uids = selectedDeviceUIDs
            if uids.contains(device.uid) {
                // Don't allow deselecting the last device
                guard uids.count > 1 else { return }
                uids.remove(device.uid)
            } else {
                uids.insert(device.uid)
            }
            onDevicesSelected(uids)
            // Keep dropdown open in multi mode
        }
    }
}

/// Button style with hover highlighting for device picker items
private struct DevicePickerItemButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .onHover { isHovered = $0 }
    }
}

// MARK: - Convenience Init (backwards compatibility)

extension DevicePicker {
    /// Backwards-compatible initializer for single-mode-only callers.
    init(
        devices: [AudioDevice],
        selectedDeviceUID: String,
        onDeviceSelected: @escaping (String) -> Void
    ) {
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = []
        self.mode = .single
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = { _ in }
        self.onModeChange = { _ in }
    }
}

// MARK: - Previews

#Preview("Device Picker") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.md) {
            DevicePicker(
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[0].uid,
                onDeviceSelected: { _ in }
            )

            DevicePicker(
                devices: MockData.sampleDevices,
                selectedDeviceUID: MockData.sampleDevices[1].uid,
                onDeviceSelected: { _ in }
            )
        }
    }
}
