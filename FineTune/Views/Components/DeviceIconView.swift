// FineTune/Views/Components/DeviceIconView.swift
import SwiftUI

/// Shared device icon view with NSImage → SF Symbol fallback.
/// Used by DeviceRow, DevicePicker, and DevicePickerView.
struct DeviceIconView: View {
    let icon: NSImage?
    let size: CGFloat
    let fallbackSymbol: String

    init(icon: NSImage?, size: CGFloat = DesignTokens.Dimensions.iconSize, fallbackSymbol: String = "speaker.wave.2") {
        self.icon = icon
        self.size = size
        self.fallbackSymbol = fallbackSymbol
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallbackSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
