// FineTune/Views/Onboarding/OnboardingWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onComplete: () -> Void
    private var didComplete = false

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        super.init()
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
        window.delegate = self
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Bring FineTune to front so the window is visible
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func dismiss() {
        complete(closeWindow: true)
    }

    func windowWillClose(_ notification: Notification) {
        complete(closeWindow: false)
    }

    private func complete(closeWindow: Bool) {
        guard !didComplete else { return }
        didComplete = true

        let currentWindow = window
        window = nil
        currentWindow?.delegate = nil
        if closeWindow {
            currentWindow?.close()
        }
        let completion = onComplete
        Task { @MainActor in
            completion()
        }
    }
}
