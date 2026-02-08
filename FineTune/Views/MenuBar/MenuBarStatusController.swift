// FineTune/Views/MenuBar/MenuBarStatusController.swift
import AppKit
import SwiftUI
import os

@MainActor
final class MenuBarStatusController: NSObject {
    private let audioEngine: AudioEngine
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "MenuBarStatus")

    private var statusItem: NSStatusItem?
    private var panel: KeyablePanel?
    private var globalClickMonitor: Any?
    private var buttonHealthTimer: Timer?
    private var popupViewModel: MenuBarPopupViewModel?

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

        // Read icon style from settings (defaults to .default if not set)
        let iconStyle = audioEngine.settingsManager.appSettings.menuBarIconStyle
        applyIcon(style: iconStyle, to: button)

        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])

        statusItem = item
        logger.info("Menu bar status item created")

        // macOS 26: Control Center scene reconnections can reset button action/target.
        // Periodically verify and re-wire the button to ensure clicks keep working.
        buttonHealthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ensureButtonWired()
            }
        }
    }

    private func ensureButtonWired() {
        guard let button = statusItem?.button else { return }
        let sel = #selector(statusBarButtonClicked(_:))
        if button.target !== self || button.action != sel {
            logger.error("Button action/target was reset — re-wiring")
            button.target = self
            button.action = sel
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }

    func stop() {
        buttonHealthTimer?.invalidate()
        buttonHealthTimer = nil
        dismissPanel()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Icon Management

    /// Updates the menu bar icon to a new style (called live from Settings)
    func updateIcon(to style: MenuBarIconStyle) {
        guard let button = statusItem?.button else { return }
        applyIcon(style: style, to: button)
        logger.info("Menu bar icon updated to \(style.rawValue)")
    }

    /// Applies a MenuBarIconStyle to a status bar button
    private func applyIcon(style: MenuBarIconStyle, to button: NSStatusBarButton) {
        if style.isSystemSymbol {
            // SF Symbol icon
            if let image = NSImage(systemSymbolName: style.iconName, accessibilityDescription: "FineTune") {
                image.isTemplate = true
                button.image = image
            } else {
                // Fallback if symbol name is invalid
                button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "FineTune")
                logger.error("Invalid SF Symbol name '\(style.iconName)'; using fallback")
            }
        } else {
            // Asset catalog icon (the .default case uses "MenuBarIcon" asset)
            if let image = NSImage(named: style.iconName) {
                image.isTemplate = true
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "FineTune")
                logger.error("Asset '\(style.iconName)' missing; using fallback symbol")
            }
        }
    }

    // MARK: - Click handling

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            logger.error("statusBarButtonClicked: NSApp.currentEvent is nil")
            return
        }
        logger.info("Status bar button clicked (type=\(event.type.rawValue))")

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
        let testItem = NSMenuItem(title: "Run API Tests", action: #selector(runAPITests), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit FineTune", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func runAPITests() {
        NSSound.beep()
        DispatchQueue.global(qos: .userInitiated).async {
            let runner = TapAPITestRunner()
            runner.run()
            DispatchQueue.main.async {
                NSSound.beep() // second beep = done
            }
        }
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

        // Ensure minimum size if SwiftUI hasn't laid out yet
        if panelFrame.width < 10 || panelFrame.height < 10 {
            if let hostingView = panel.contentView {
                let fittedSize = hostingView.fittingSize
                if fittedSize.width > 10 {
                    panelFrame.size.width = fittedSize.width
                }
                if fittedSize.height > 10 {
                    panelFrame.size.height = fittedSize.height
                }
            }
            if panelFrame.width < 10 { panelFrame.size.width = 320 }
            if panelFrame.height < 10 { panelFrame.size.height = 400 }
        }

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
        panel.alphaValue = 1.0
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

    private func createPanel() -> KeyablePanel {
        let viewModel = MenuBarPopupViewModel(
            audioEngine: audioEngine,
            deviceVolumeMonitor: audioEngine.deviceVolumeMonitor
        )
        viewModel.onIconChanged = { [weak self] style in
            self?.updateIcon(to: style)
        }
        self.popupViewModel = viewModel
        let rootView = MenuBarPopupView(viewModel: viewModel)

        let hostingView = NSHostingView(rootView: rootView)
        let fitted = hostingView.fittingSize
        hostingView.frame.size = fitted.width > 10 ? fitted : CGSize(width: 320, height: 400)

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: hostingView.frame.size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self

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
        DispatchQueue.main.async { [weak self] in
            self?.dismissPanel()
        }
    }
}

// MARK: - Key-capable panel

/// NSPanel subclass that can become key window.
/// Required because `.nonactivatingPanel` style returns false from canBecomeKey by default,
/// but we need key status for proper keyboard interaction and dismiss-on-deactivate behavior.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
