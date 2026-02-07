// FineTune/Views/Components/DevicePicker.swift
import SwiftUI

/// A styled device picker dropdown using DropdownMenu
struct DevicePicker: View {
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let onDeviceSelected: (String) -> Void

    private var selectedDevice: AudioDevice? {
        devices.first { $0.uid == selectedDeviceUID }
    }

    var body: some View {
        DropdownMenu(
            items: devices,
            selectedItem: selectedDevice,
            maxVisibleItems: 8,
            width: 128,
            popoverWidth: 180,
            onSelect: { device in onDeviceSelected(device.uid) }
        ) { selected in
            HStack(spacing: DesignTokens.Spacing.xs) {
                DeviceIconView(icon: selected?.icon, size: 16)
                Text(selected?.name ?? "Select")
                    .lineLimit(1)
            }
        } itemContent: { device, isSelected in
            HStack {
                DeviceIconView(icon: device.icon, size: 16)
                Text(device.name)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }
        }
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
