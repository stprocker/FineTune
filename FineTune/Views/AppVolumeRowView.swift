// FineTune/Views/AppVolumeRowView.swift
import SwiftUI

struct AppVolumeRowView: View {
    let app: AudioApp
    let volume: Float  // Linear gain 0-2
    let onVolumeChange: (Float) -> Void
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let onDeviceSelected: (String) -> Void

    @State private var sliderValue: Double  // 0-1, log-mapped position
    @State private var isEditing = false    // True while user is dragging

    init(
        app: AudioApp,
        volume: Float,
        onVolumeChange: @escaping (Float) -> Void,
        devices: [AudioDevice],
        selectedDeviceUID: String,
        onDeviceSelected: @escaping (String) -> Void
    ) {
        self.app = app
        self.volume = volume
        self.onVolumeChange = onVolumeChange
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.onDeviceSelected = onDeviceSelected
        // Convert linear gain to slider position
        self._sliderValue = State(initialValue: VolumeMapping.gainToSlider(volume))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)

            Text(app.name)
                .lineLimit(1)

            Slider(
                value: $sliderValue,
                in: 0...1,
                onEditingChanged: { editing in
                    isEditing = editing
                }
            )
            .frame(minWidth: 100)
            .tint(.white.opacity(0.7))
            .overlay(alignment: .center) {
                // Unity marker at center (100% = native volume)
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 1, height: 8)
                    .allowsHitTesting(false)
            }
            .onChange(of: sliderValue) { _, newValue in
                let gain = VolumeMapping.sliderToGain(newValue)
                onVolumeChange(gain)
            }

            // Show linear percentage (0-200%) matching slider position
            Text("\(Int(sliderValue * 200))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            DevicePickerView(
                devices: devices,
                selectedDeviceUID: selectedDeviceUID,
                onDeviceSelected: onDeviceSelected
            )
        }
        .onChange(of: volume) { _, newValue in
            // Only sync from external changes when user is NOT dragging
            guard !isEditing else { return }
            sliderValue = VolumeMapping.gainToSlider(newValue)
        }
    }
}
