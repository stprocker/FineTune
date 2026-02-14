// FineTune/Views/Components/VUMeter.swift
import SwiftUI

/// A vertical VU meter visualization for audio levels
/// Shows 8 bars that light up based on audio level with peak hold
struct VUMeter: View {
    let level: Float
    var isMuted: Bool = false

    @State private var peakLevel: Float = 0
    @State private var peakDecayTask: Task<Void, Never>?

    private let barCount = DesignTokens.Dimensions.vuMeterBarCount

    var body: some View {
        HStack(spacing: DesignTokens.Dimensions.vuMeterBarSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                VUMeterBar(
                    index: index,
                    level: level,
                    peakLevel: peakLevel,
                    barCount: barCount,
                    isMuted: isMuted
                )
            }
        }
        .frame(width: DesignTokens.Dimensions.vuMeterWidth)
        .onChange(of: level) { _, newLevel in
            if newLevel > peakLevel {
                // New peak - capture and start decay timer
                peakLevel = newLevel
                startPeakDecayTimer()
            } else if peakLevel > newLevel && peakDecayTask == nil {
                // Level dropped below peak and no task running - start decay
                startPeakDecayTimer()
            }
        }
        .onDisappear {
            peakDecayTask?.cancel()
            peakDecayTask = nil
        }
    }

    private func startPeakDecayTimer() {
        // Cancel any existing decay task
        peakDecayTask?.cancel()

        // Start new decay task - holds for a period then gradually decays
        peakDecayTask = Task { @MainActor in
            // Hold period before decay starts
            try? await Task.sleep(for: .seconds(DesignTokens.Timing.vuMeterPeakHold))
            guard !Task.isCancelled else { return }

            // Gradual decay at ~30fps
            // Decay ~24dB over 2.8 seconds (BBC PPM standard)
            let decayRate: Float = 0.012  // Per-frame decay
            let frameInterval: Duration = .seconds(1.0 / 30.0)

            while !Task.isCancelled && peakLevel > level {
                try? await Task.sleep(for: frameInterval)
                guard !Task.isCancelled else { return }

                withAnimation(DesignTokens.Animation.vuMeterLevel) {
                    peakLevel = max(level, peakLevel - decayRate)
                }
            }
        }
    }
}

/// Individual bar in the VU meter
private struct VUMeterBar: View {
    let index: Int
    let level: Float
    let peakLevel: Float
    let barCount: Int
    var isMuted: Bool = false

    /// dB thresholds for 8 bars covering 40dB range
    /// Matches professional audio meter standards (logarithmic scale)
    private static let dbThresholds: [Float] = [-40, -30, -20, -14, -10, -6, -3, 0]

    /// Pre-computed linear thresholds from dB values (avoids powf on every render)
    private static let linearThresholds: [Float] = dbThresholds.map { powf(10, $0 / 20) }

    /// Threshold for this bar (0-1) using pre-computed linear scale
    private var threshold: Float {
        Self.linearThresholds[min(index, Self.linearThresholds.count - 1)]
    }

    /// Whether this bar should be lit based on current level
    private var isLit: Bool {
        level >= threshold
    }

    /// Whether this bar is the peak indicator
    private var isPeakIndicator: Bool {
        var peakBarIndex = 0
        for i in 0..<Self.linearThresholds.count {
            if peakLevel >= Self.linearThresholds[i] {
                peakBarIndex = i
            }
        }
        return index == peakBarIndex && peakLevel > level
    }

    /// Color for this bar based on its position and mute state
    /// Split: 4 green (0-3), 2 yellow (4-5), 1 orange (6), 1 red (7)
    private var barColor: Color {
        // When muted, show gray to indicate "app is active but muted"
        if isMuted {
            return DesignTokens.Colors.vuMuted
        }
        if index < 4 {
            return DesignTokens.Colors.vuGreen
        } else if index < 6 {
            return DesignTokens.Colors.vuYellow
        } else if index < 7 {
            return DesignTokens.Colors.vuOrange
        } else {
            return DesignTokens.Colors.vuRed
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(isLit || isPeakIndicator ? barColor : DesignTokens.Colors.vuUnlit)
            .frame(
                width: (DesignTokens.Dimensions.vuMeterWidth - CGFloat(barCount - 1) * DesignTokens.Dimensions.vuMeterBarSpacing) / CGFloat(barCount),
                height: DesignTokens.Dimensions.vuMeterBarHeight
            )
            .animation(DesignTokens.Animation.vuMeterLevel, value: isLit)
    }
}

// MARK: - Previews

#Preview("VU Meter - Horizontal") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.md) {
            HStack {
                Text("0%")
                    .font(.caption)
                VUMeter(level: 0)
            }

            HStack {
                Text("25%")
                    .font(.caption)
                VUMeter(level: 0.25)
            }

            HStack {
                Text("50%")
                    .font(.caption)
                VUMeter(level: 0.5)
            }

            HStack {
                Text("75%")
                    .font(.caption)
                VUMeter(level: 0.75)
            }

            HStack {
                Text("100%")
                    .font(.caption)
                VUMeter(level: 1.0)
            }
        }
    }
}

#Preview("VU Meter - Animated") {
    struct AnimatedPreview: View {
        @State private var level: Float = 0

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.lg) {
                    VUMeter(level: level)

                    Slider(value: Binding(
                        get: { Double(level) },
                        set: { level = Float($0) }
                    ))
                }
            }
        }
    }
    return AnimatedPreview()
}
