// FineTune/Views/Components/SliderAutoUnmute.swift
import SwiftUI

/// Shared auto-unmute logic: when a slider moves while muted, fire unmute callback.
/// Used by AppRow and DeviceRow to DRY the identical unmute-on-slider-move pattern.
///
/// - `requireNonZero`: When true, only unmutes if the new value > 0 (DeviceRow behavior).
///   When false, unmutes on any slider movement (AppRow behavior).
struct SliderAutoUnmuteModifier: ViewModifier {
    let sliderValue: Double
    let isMuted: Bool
    let requireNonZero: Bool
    let onUnmute: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: sliderValue) { _, newValue in
                guard isMuted else { return }
                if requireNonZero {
                    guard newValue > 0 else { return }
                }
                onUnmute()
            }
    }
}

extension View {
    /// Auto-unmute when slider moves while muted.
    /// - Parameters:
    ///   - sliderValue: Current slider position to observe.
    ///   - isMuted: Whether the item is currently muted.
    ///   - requireNonZero: If true, only unmute when slider > 0 (DeviceRow).
    ///   - onUnmute: Callback to fire when auto-unmute triggers.
    func autoUnmuteOnSliderMove(
        sliderValue: Double,
        isMuted: Bool,
        requireNonZero: Bool = false,
        onUnmute: @escaping () -> Void
    ) -> some View {
        modifier(SliderAutoUnmuteModifier(
            sliderValue: sliderValue,
            isMuted: isMuted,
            requireNonZero: requireNonZero,
            onUnmute: onUnmute
        ))
    }
}
