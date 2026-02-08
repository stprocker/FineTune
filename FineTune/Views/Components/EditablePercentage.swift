// FineTune/Views/Components/EditablePercentage.swift
import SwiftUI
import AppKit

/// A percentage display that can be clicked to edit the value directly
/// Features a refined edit state with subtle visual feedback
struct EditablePercentage: View {
    @Binding var percentage: Int
    let range: ClosedRange<Int>
    var onCommit: ((Int) -> Void)? = nil

    @State private var isEditing = false
    @State private var inputText = ""
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @State private var coordinator = ClickOutsideCoordinator()
    @State private var componentFrame: CGRect = .zero

    /// Text color adapts to state: accent when editing, secondary otherwise
    private var textColor: Color {
        isEditing ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
    }

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                // Edit mode: TextField + fixed "%" suffix
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .fixedSize()  // Size to content

                Text("%")
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
            } else {
                // Display mode: tappable percentage
                Text("\(percentage)%")
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(isHovered ? DesignTokens.Colors.textPrimary : textColor)
            }
        }
        .padding(.horizontal, isEditing ? 6 : 4)
        .padding(.vertical, isEditing ? 2 : 1)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(key: FramePreferenceKey.self, value: geo.frame(in: .global))
            }
        }
        .onPreferenceChange(FramePreferenceKey.self) { frame in
            updateScreenFrame(from: frame)
        }
        .background {
            if isEditing {
                // Subtle pill background when editing
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Colors.accentPrimary.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.4), lineWidth: 1)
                    }
            } else if isHovered {
                // Subtle hover background to indicate clickability
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .frame(minWidth: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { startEditing() } }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                coordinator.removeMonitors()
            }
        }
        .animation(.easeOut(duration: 0.15), value: isEditing)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private func startEditing() {
        inputText = "\(percentage)"
        isEditing = true

        // Install monitors via coordinator (handles local, global, and app deactivation)
        coordinator.install(
            excludingFrame: componentFrame,
            onClickOutside: { [self] in
                cancel()
            }
        )

        // Delay focus to next runloop to ensure TextField is rendered
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func commit() {
        let cleaned = inputText.replacingOccurrences(of: "%", with: "")
                               .trimmingCharacters(in: .whitespaces)

        if let value = Int(cleaned), range.contains(value) {
            percentage = value
            onCommit?(value)
        }
        isEditing = false
    }

    private func cancel() {
        isEditing = false
    }

    private func updateScreenFrame(from globalFrame: CGRect) {
        // Convert SwiftUI global coordinates to screen coordinates for hit testing
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            componentFrame = .zero
            return
        }

        // SwiftUI global: origin at top-left, Y increases downward
        // Screen: origin at bottom-left, Y increases upward
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let windowY = contentRect.height - globalFrame.origin.y - globalFrame.height

        let windowRect = CGRect(
            x: globalFrame.origin.x,
            y: windowY,
            width: globalFrame.width,
            height: globalFrame.height
        )
        componentFrame = window.convertToScreen(windowRect)
    }
}

// MARK: - Click Outside Coordinator

/// Manages event monitors for detecting clicks outside the component.
/// Uses the same pattern as PopoverHost for reliable click-outside detection.
private final class ClickOutsideCoordinator {
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var appDeactivateObserver: NSObjectProtocol?

    /// Installs monitors to detect clicks outside the specified frame.
    /// - Parameters:
    ///   - excludingFrame: The frame (in screen coordinates) to exclude from triggering
    ///   - onClickOutside: Callback invoked when a click outside is detected
    func install(excludingFrame: CGRect, onClickOutside: @escaping () -> Void) {
        // Remove any existing monitors first
        removeMonitors()

        // Local monitor: clicks within our app (outside component)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard self != nil else { return event }
            let mouseLocation = NSEvent.mouseLocation
            if !excludingFrame.contains(mouseLocation) {
                DispatchQueue.main.async {
                    onClickOutside()
                }
            }
            return event  // Don't consume
        }

        // Global monitor: clicks in OTHER apps
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard self != nil else { return }
            DispatchQueue.main.async {
                onClickOutside()
            }
        }

        // App deactivation: Command-Tab, clicking Dock, etc.
        appDeactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            onClickOutside()
        }
    }

    /// Removes all installed monitors and observers.
    func removeMonitors() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let observer = appDeactivateObserver {
            NotificationCenter.default.removeObserver(observer)
            appDeactivateObserver = nil
        }
    }

    deinit {
        removeMonitors()
    }
}

// MARK: - Preference Key for Frame Tracking

private struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Previews

#Preview("Editable Percentage") {
    struct PreviewWrapper: View {
        @State private var percentage = 100

        var body: some View {
            HStack {
                Text("Volume:")
                EditablePercentage(percentage: $percentage, range: 0...400)
            }
            .padding()
            .background(Color.black)
        }
    }
    return PreviewWrapper()
}
