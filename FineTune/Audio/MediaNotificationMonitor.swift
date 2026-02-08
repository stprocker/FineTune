// FineTune/Audio/MediaNotificationMonitor.swift
import AppKit
import Foundation
import os

/// Monitors distributed notifications from media apps for instant play/pause detection.
///
/// Currently supports Spotify via `com.spotify.client.PlaybackStateChanged`.
/// This provides near-zero-latency state changes compared to VU-level detection
/// which has inherent lag from the 0.5-1.5s silence grace period.
///
/// Other apps rely on the VU-level path in AudioEngine.
@MainActor
final class MediaNotificationMonitor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "MediaNotificationMonitor")
    private var observer: NSObjectProtocol?

    /// Callback fired when a monitored app changes playback state.
    /// - Parameters:
    ///   - pid: The process ID of the app
    ///   - isPlaying: `true` if the app started playing, `false` if paused/stopped
    var onPlaybackStateChanged: ((_ pid: pid_t, _ isPlaying: Bool) -> Void)?

    func start() {
        guard observer == nil else { return }

        // Spotify posts com.spotify.client.PlaybackStateChanged on DistributedNotificationCenter
        // userInfo contains "Player State" key with values: "Playing", "Paused", "Stopped"
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleSpotifyNotification(notification)
            }
        }

        logger.info("Started monitoring Spotify playback notifications")
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
            logger.info("Stopped monitoring playback notifications")
        }
    }

    private func handleSpotifyNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let playerState = userInfo["Player State"] as? String else {
            logger.debug("Spotify notification missing Player State")
            return
        }

        // Resolve Spotify's PID from running applications
        let spotifyApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
        guard let spotifyApp = spotifyApps.first else {
            logger.debug("Spotify notification received but app not found in running apps")
            return
        }

        let pid = spotifyApp.processIdentifier
        let isPlaying = (playerState == "Playing")

        logger.debug("Spotify state: \(playerState) (PID: \(pid))")
        onPlaybackStateChanged?(pid, isPlaying)
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
