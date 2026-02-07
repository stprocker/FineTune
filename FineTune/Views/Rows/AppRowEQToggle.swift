// FineTune/Views/Rows/AppRowEQToggle.swift
import SwiftUI

/// Animated EQ toggle button: shows slider icon when collapsed, X when expanded.
struct AppRowEQToggle: View {
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    private var buttonColor: Color {
        if isExpanded {
            return DesignTokens.Colors.interactiveActive
        } else if isHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }

    var body: some View {
        Button {
            onToggle()
        } label: {
            ZStack {
                Image(systemName: "slider.vertical.3")
                    .opacity(isExpanded ? 0 : 1)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Image(systemName: "xmark")
                    .opacity(isExpanded ? 1 : 0)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .font(.system(size: 12))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(buttonColor)
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isExpanded ? "Close Equalizer" : "Equalizer")
        .animation(DesignTokens.Animation.eqButton, value: isExpanded)
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}
