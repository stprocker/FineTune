// FineTune/Views/Onboarding/OnboardingWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let onComplete: () -> Void

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    func show() {
        let view = OnboardingView { [weak self] in
            self?.dismiss()
        }

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame.size = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.frame.size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Bring FineTune to front so the window is visible
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func dismiss() {
        window?.close()
        window = nil
        onComplete()
    }
}
