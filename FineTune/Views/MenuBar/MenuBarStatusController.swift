// FineTune/Views/MenuBar/MenuBarStatusController.swift
import AppKit
import SwiftUI
import os

@MainActor
final class MenuBarStatusController: NSObject {
    private let audioEngine: AudioEngine
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "MenuBarStatus")

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var globalClickMonitor: Any?

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            logger.error("Failed to create status bar button")
            NSStatusBar.system.removeStatusItem(item)
            return
        }

        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "FineTune")
            logger.error("MenuBarIcon asset missing; using fallback symbol")
        }

        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])

        statusItem = item
        logger.info("Menu bar status item created")
    }

    func stop() {
        dismissPanel()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Click handling

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            showContextMenu(from: sender)
        } else if let panel, panel.isVisible {
            dismissPanel()
        } else {
            showPanel()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit FineTune", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        button.performClick(nil) // triggers the menu
        statusItem?.menu = nil   // remove so left-click uses action again
    }

    // MARK: - Panel management

    private func showPanel() {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        let panel = self.panel ?? createPanel()
        self.panel = panel

        // Position below the status item
        let buttonFrame = buttonWindow.frame
        var panelFrame = panel.frame
        panelFrame.origin.x = buttonFrame.midX - panelFrame.width / 2
        panelFrame.origin.y = buttonFrame.minY - panelFrame.height

        // Clamp to screen edges
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            if panelFrame.maxX > visibleFrame.maxX {
                panelFrame.origin.x = visibleFrame.maxX - panelFrame.width - 2
            }
            if panelFrame.minX < visibleFrame.minX {
                panelFrame.origin.x = visibleFrame.minX + 2
            }
        }

        panel.setFrame(panelFrame, display: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(true)

        // Dismiss when user clicks outside the panel
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissPanel()
        }
    }

    private func dismissPanel() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
    }

    private func createPanel() -> NSPanel {
        let rootView = MenuBarPopupView(
            audioEngine: audioEngine,
            deviceVolumeMonitor: audioEngine.deviceVolumeMonitor
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame.size = hostingView.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        // Hide standard window buttons
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.contentView = hostingView

        return panel
    }
}

// MARK: - NSWindowDelegate

extension MenuBarStatusController: NSWindowDelegate {
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            dismissPanel()
        }
    }
}
