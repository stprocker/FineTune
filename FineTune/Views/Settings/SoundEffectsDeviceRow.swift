// FineTune/Views/Settings/SoundEffectsDeviceRow.swift
import SwiftUI

/// Settings row for selecting the sound effects output device
struct SoundEffectsDeviceRow: View {
    let devices: [AudioDevice]
    let selectedDeviceUID: String?
    let defaultDeviceUID: String?
    let isFollowingDefault: Bool
    let onDeviceSelected: (String) -> Void
    let onSelectFollowDefault: () -> Void

    private var displayLabel: String {
        if isFollowingDefault {
            return "Follow Default"
        }
        if let uid = selectedDeviceUID,
           let device = devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return "Select Device"
    }

    var body: some View {
        SettingsRowView(
            icon: "bell.fill",
            title: "Sound Effects",
            description: "Output device for alerts, notifications, and Siri"
        ) {
            Menu {
                Button {
                    onSelectFollowDefault()
                } label: {
                    HStack {
                        Text("Follow Default")
                        if isFollowingDefault {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(devices) { device in
                    Button {
                        onDeviceSelected(device.uid)
                    } label: {
                        HStack {
                            Text(device.name)
                            if !isFollowingDefault && selectedDeviceUID == device.uid {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(displayLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                }
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

// MARK: - Previews

#Preview("Sound Effects Device Row") {
    VStack(spacing: DesignTokens.Spacing.sm) {
        SoundEffectsDeviceRow(
            devices: MockData.sampleDevices,
            selectedDeviceUID: MockData.sampleDevices[0].uid,
            defaultDeviceUID: MockData.sampleDevices[0].uid,
            isFollowingDefault: true,
            onDeviceSelected: { _ in },
            onSelectFollowDefault: {}
        )
    }
    .padding()
    .frame(width: 500)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
