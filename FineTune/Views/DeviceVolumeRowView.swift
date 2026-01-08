// FineTune/Views/DeviceVolumeRowView.swift
import SwiftUI

struct DeviceVolumeRowView: View {
    let device: AudioDevice
    let volume: Float  // 0-1
    let isMuted: Bool
    let isDefault: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let onSetAsDefault: () -> Void

    @State private var sliderValue: Double  // 0-1
    @State private var isEditing = false    // True while user is dragging

    init(
        device: AudioDevice,
        volume: Float,
        isMuted: Bool,
        isDefault: Bool,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        onSetAsDefault: @escaping () -> Void
    ) {
        self.device = device
        self.volume = volume
        self.isMuted = isMuted
        self.isDefault = isDefault
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.onSetAsDefault = onSetAsDefault
        self._sliderValue = State(initialValue: Double(volume))
    }

    var body: some View {
        HStack(spacing: 12) {
            // Clickable radio button for default selection
            Button {
                if !isDefault {
                    onSetAsDefault()
                }
            } label: {
                Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDefault ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .help(isDefault ? "Current default output" : "Set as default output device")

            // Icon - use device.icon with SF Symbol fallback
            if let icon = device.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "speaker.wave.2")
                    .frame(width: 24, height: 24)
            }

            // Name - bolder if default
            Text(device.name)
                .fontWeight(isDefault ? .semibold : .regular)
                .lineLimit(1)

            // Mute button
            Button {
                onMuteToggle()
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(isMuted ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute" : "Mute")

            // Slider - decoupled from external updates during user interaction
            Slider(
                value: $sliderValue,
                in: 0...1,
                onEditingChanged: { editing in
                    isEditing = editing
                }
            )
            .frame(minWidth: 120)
            .tint(.white.opacity(0.7))
            .opacity(isMuted ? 0.5 : 1.0)
            .onChange(of: sliderValue) { _, newValue in
                // Auto-unmute when slider is moved while muted
                if isMuted && newValue != Double(volume) {
                    onMuteToggle()
                }
                onVolumeChange(Float(newValue))
            }

            // Percentage
            Text("\(Int(sliderValue * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .onChange(of: volume) { _, newValue in
            // Only sync from external changes when user is NOT dragging.
            // This prevents feedback loops from Bluetooth latency causing jitter.
            guard !isEditing else { return }
            sliderValue = Double(newValue)
        }
    }
}
