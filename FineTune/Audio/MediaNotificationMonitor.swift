// FineTune/Audio/MediaNotificationMonitor.swift
import AppKit
import Foundation
import os

/// Monitors distributed notifications from media apps for instant play/pause detection.
///
/// Supports Spotify and Apple Music via their respective `DistributedNotificationCenter`
/// notifications. This provides near-zero-latency state changes compared to VU-level
/// detection which has inherent lag from the 0.5-1.5s silence grace period.
///
/// Other apps (browsers, VLC, etc.) rely on the VU-level path in AudioEngine.
@MainActor
final class MediaNotificationMonitor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "MediaNotificationMonitor")
    private var observers: [NSObjectProtocol] = []

    private static let monitoredApps: [(notificationName: String, bundleID: String, stateKey: String, playingValue: String)] = [
        ("com.spotify.client.PlaybackStateChanged", "com.spotify.client", "Player State", "Playing"),
        ("com.apple.Music.playerInfo", "com.apple.Music", "Player State", "Playing"),
    ]

    /// Callback fired when a monitored app changes playback state.
    /// - Parameters:
    ///   - pid: The process ID of the app
    ///   - isPlaying: `true` if the app started playing, `false` if paused/stopped
    var onPlaybackStateChanged: ((_ pid: pid_t, _ isPlaying: Bool) -> Void)?

    func start() {
        guard observers.isEmpty else { return }

        for app in Self.monitoredApps {
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(app.notificationName),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handlePlaybackNotification(notification, bundleID: app.bundleID, stateKey: app.stateKey, playingValue: app.playingValue)
                }
            }
            observers.append(observer)
        }

        let appNames = Self.monitoredApps.map(\.bundleID).joined(separator: ", ")
        logger.info("Started monitoring playback notifications for: \(appNames)")
    }

    func stop() {
        guard !observers.isEmpty else { return }
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        logger.info("Stopped monitoring playback notifications")
    }

    private func handlePlaybackNotification(_ notification: Notification, bundleID: String, stateKey: String, playingValue: String) {
        guard let userInfo = notification.userInfo,
              let playerState = userInfo[stateKey] as? String else {
            logger.debug("Notification from \(bundleID) missing \(stateKey)")
            return
        }

        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let app = apps.first else {
            logger.debug("Notification from \(bundleID) but app not found in running apps")
            return
        }

        let pid = app.processIdentifier
        let isPlaying = (playerState == playingValue)

        logger.debug("\(bundleID) state: \(playerState) (PID: \(pid))")
        onPlaybackStateChanged?(pid, isPlaying)
    }

    deinit {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
