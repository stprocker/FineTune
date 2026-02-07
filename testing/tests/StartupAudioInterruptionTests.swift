import XCTest
import AppKit
import AudioToolbox
@testable import FineTuneIntegration

/// Tests for the startup audio interruption bug.
///
/// Bug: Launching FineTune silences all audio-producing apps even though the
/// output device doesn't change.
///
/// Root cause: `applyPersistedSettings()` eagerly creates a process tap for
/// EVERY audio app on startup, using `muteBehavior = .mutedWhenTapped`.
/// This immediately mutes each app's audio on its original output path.
/// The replacement path (aggregate device) may not start delivering audio
/// for several milliseconds — or at all if activation fails.
///
/// Observable in tests: Even when tap creation fails (test env has no real
/// audio hardware), `applyPersistedSettings` writes default device routing
/// to SettingsManager for apps that had NO saved settings. This proves the
/// engine treats every app as needing a tap, which in production would
/// mute audio via `.mutedWhenTapped`.
///
/// Fix direction: `applyPersistedSettings` should only create taps for apps
/// that have user-customized settings. Apps with no saved state should be
/// left alone until the user interacts with them in the FineTune UI.
@MainActor
final class StartupAudioInterruptionTests: XCTestCase {

    private var engine: AudioEngine!
    private var settings: SettingsManager!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        settings = SettingsManager(directory: tempDir)
        engine = AudioEngine(
            settingsManager: settings,
            defaultOutputDeviceUIDProvider: { "built-in-speakers" }
        )

        // Populate device monitor so routing logic proceeds normally
        let speakers = AudioDevice(
            id: AudioDeviceID(42),
            uid: "built-in-speakers",
            name: "Built-in Speakers",
            icon: nil
        )
        engine.deviceMonitor.setOutputDevicesForTests([speakers])
    }

    override func tearDown() async throws {
        engine?.stop()
        engine = nil
        settings = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - 1. Core Bug: Startup eagerly taps apps with no saved settings

    /// On first launch, an app with no saved settings should NOT have its
    /// routing written to SettingsManager. The current code (AudioEngine.swift:324)
    /// writes `setDeviceRouting(for:deviceUID:)` for EVERY app, even those with
    /// no prior saved state. This is the entry point to the always-on tapping
    /// strategy that mutes audio via `.mutedWhenTapped`.
    ///
    /// FAILS: applyPersistedSettings writes "built-in-speakers" to settings
    /// for an app that had no saved routing.
    func testStartupDoesNotPersistRoutingForUnsavedApp() {
        let app = makeFakeApp()

        // Precondition: clean slate
        XCTAssertNil(settings.getDeviceRouting(for: app.persistenceIdentifier),
                      "Precondition: no saved device routing")
        XCTAssertNil(settings.getVolume(for: app.persistenceIdentifier),
                      "Precondition: no saved volume")
        XCTAssertNil(settings.getMute(for: app.persistenceIdentifier),
                      "Precondition: no saved mute state")

        engine.applyPersistedSettingsForTests(apps: [app])

        // BUG: Line 324 writes "built-in-speakers" to settings even though
        // the app had no saved routing. This proves the engine intends to tap
        // this app, which in production mutes audio via .mutedWhenTapped.
        XCTAssertNil(settings.getDeviceRouting(for: app.persistenceIdentifier),
                      "Startup should not persist default routing for apps with no saved settings — " +
                      "persisting routing means the engine attempted to tap the app, which " +
                      "mutes audio via .mutedWhenTapped on the system default device")
    }

    /// Same bug across multiple apps.
    func testStartupDoesNotPersistRoutingForMultipleUnsavedApps() {
        let spotify = makeFakeApp(pid: 1001, name: "Spotify", bundleID: "com.spotify.client")
        let chrome = makeFakeApp(pid: 1002, name: "Chrome", bundleID: "com.google.Chrome")
        let safari = makeFakeApp(pid: 1003, name: "Safari", bundleID: "com.apple.Safari")

        engine.applyPersistedSettingsForTests(apps: [spotify, chrome, safari])

        XCTAssertNil(settings.getDeviceRouting(for: spotify.persistenceIdentifier),
                      "Spotify (no saved settings) should not get default routing persisted")
        XCTAssertNil(settings.getDeviceRouting(for: chrome.persistenceIdentifier),
                      "Chrome (no saved settings) should not get default routing persisted")
        XCTAssertNil(settings.getDeviceRouting(for: safari.persistenceIdentifier),
                      "Safari (no saved settings) should not get default routing persisted")
    }

    /// Unsaved apps should not even attempt tap creation.
    func testStartupDoesNotAttemptTapForUnsavedApp() {
        let app = makeFakeApp()
        var attemptedIdentifiers: [String] = []
        engine.onTapCreationAttemptForTests = { attemptedApp, _ in
            attemptedIdentifiers.append(attemptedApp.persistenceIdentifier)
        }

        engine.applyPersistedSettingsForTests(apps: [app])

        XCTAssertFalse(attemptedIdentifiers.contains(app.persistenceIdentifier),
                       "Unsaved app should not attempt tap creation on startup")
    }

    // MARK: - 2. Settings pollution: default routing becomes "explicit" on next startup

    /// Once applyPersistedSettings writes default routing for an unsaved app
    /// (bug #1), that routing persists across restarts. On the NEXT startup,
    /// `getDeviceRouting` returns non-nil, so the engine takes the `if` branch
    /// (line 303) instead of `else`, treating it as if the USER explicitly
    /// chose that device. The auto-assigned default is now indistinguishable
    /// from an explicit user choice.
    ///
    /// FAILS: After a simulated restart, the engine treats the auto-assigned
    /// routing as "saved" routing, taking the wrong code path.
    func testAutoAssignedRoutingBecomesExplicitOnRestart() {
        let app = makeFakeApp()

        // First "startup" — writes default routing for unsaved app (bug #1)
        engine.applyPersistedSettingsForTests(apps: [app])

        // Simulate restart: create a new engine with the same settings
        engine.stop()
        let engine2 = AudioEngine(
            settingsManager: settings,
            defaultOutputDeviceUIDProvider: { "built-in-speakers" }
        )
        engine2.deviceMonitor.setOutputDevicesForTests([
            AudioDevice(id: AudioDeviceID(42), uid: "built-in-speakers", name: "Built-in Speakers", icon: nil)
        ])

        // On second startup, the app should STILL be treated as unsaved.
        // But because bug #1 wrote "built-in-speakers" to settings, the engine
        // now thinks the user explicitly chose this device.
        let routingBeforeApply = settings.getDeviceRouting(for: app.persistenceIdentifier)
        XCTAssertNil(routingBeforeApply,
                      "After restart, an app that was never customized by the user should " +
                      "have no saved routing — but bug #1 left a stale 'built-in-speakers' entry")

        engine2.stop()
    }

    // MARK: - 3. Retry storm: failed taps retry on every onAppsChanged

    /// When tap creation fails, `appliedPIDs` does NOT include the app's PID
    /// (line 342-346 skips the insert). This means every subsequent call to
    /// `applyPersistedSettings` (triggered by `onAppsChanged`) retries the
    /// full sequence: write routing → attempt tap → fail → clean up routing.
    ///
    /// In production (where taps do activate), each retry re-creates a tap
    /// with `.mutedWhenTapped`, potentially causing repeated audio dropouts
    /// if the tap setup is flaky.
    ///
    /// FAILS: Settings are re-written on every retry, proving the engine
    /// retries the full tap-creation sequence for apps it already failed on.
    func testRetryStormWritesSettingsRepeatedly() {
        let app = makeFakeApp()

        // First call writes routing to settings (bug #1)
        engine.applyPersistedSettingsForTests(apps: [app])
        let routingAfterFirst = settings.getDeviceRouting(for: app.persistenceIdentifier)

        // Manually clear the persisted routing to detect if the second call re-writes it
        // (simulates what would happen if cleanup did clear settings)
        settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: "CLEARED")

        // Second call (simulates onAppsChanged firing)
        engine.applyPersistedSettingsForTests(apps: [app])

        // BUG: The engine re-runs the full sequence because appliedPIDs doesn't
        // contain this PID (tap creation failed). It overwrites our "CLEARED" marker.
        let routingAfterSecond = settings.getDeviceRouting(for: app.persistenceIdentifier)
        XCTAssertEqual(routingAfterSecond, "CLEARED",
                        "After initial failure, subsequent applyPersistedSettings calls should not " +
                        "retry tap creation for the same app — each retry risks muting audio. " +
                        "Got '\(routingAfterSecond ?? "nil")' instead of 'CLEARED'")
    }

    // MARK: - 4. routeAllApps taps untouched apps on default device change

    /// When the macOS default output device changes externally (e.g., user
    /// plugs in headphones via System Settings), `onDefaultDeviceChangedExternally`
    /// calls `routeAllApps(to:)`. This iterates over ALL active apps and calls
    /// `setDevice` for each one whose `appDeviceRouting` doesn't match.
    ///
    /// For untapped apps (no saved settings, nil routing), nil != newDeviceUID,
    /// so `routeAllApps` tries to route them. `setDevice` then attempts to
    /// create a tap — muting audio via `.mutedWhenTapped` for apps that were
    /// happily playing through the system default.
    ///
    /// FAILS: After routeAllApps, untapped apps get routing persisted (proving
    /// a tap was attempted via setDevice → ensureTapExists path).
    func testRouteAllAppsDoesNotTapUntouchedApps() {
        let app = makeFakeApp()

        // App is untapped — no routing, no settings
        XCTAssertNil(engine.appDeviceRouting[app.id])
        XCTAssertNil(settings.getDeviceRouting(for: app.persistenceIdentifier))

        // Headphones connected: need to add device to monitor and simulate
        // the processMonitor having this app active
        let headphones = AudioDevice(
            id: AudioDeviceID(43),
            uid: "external-headphones",
            name: "External Headphones",
            icon: nil
        )
        engine.deviceMonitor.setOutputDevicesForTests([
            AudioDevice(id: AudioDeviceID(42), uid: "built-in-speakers", name: "Built-in Speakers", icon: nil),
            headphones
        ])

        // Seed the app list so routeAllApps can see it
        engine.applyPersistedSettingsForTests(apps: [app])

        // Clear the pollution from applyPersistedSettings (bug #1) so we can
        // isolate the routeAllApps behavior
        // Note: we can't fully clear because applyPersistedSettings already wrote settings.
        // Instead, we'll check that routeAllApps doesn't write ADDITIONAL routing.

        // Simulate external default device change → routeAllApps
        // routeAllApps filters: apps.filter { appDeviceRouting[$0.id] != deviceUID }
        // For our app, appDeviceRouting is nil (cleaned up after tap failure),
        // so nil != "external-headphones" → setDevice is called.
        engine.routeAllApps(to: "external-headphones")

        // BUG: setDevice was called for an untouched app. In the no-tap path
        // (line 252), it calls ensureTapExists, which would mute audio.
        // We can observe this through settings: setDevice writes to settings at line 220.
        let routing = settings.getDeviceRouting(for: app.persistenceIdentifier)
        XCTAssertNotEqual(routing, "external-headphones",
                           "routeAllApps should not route an untapped app to the new device — " +
                           "creating a tap would mute audio via .mutedWhenTapped. " +
                           "The app should follow the system default naturally.")
    }

    /// routeAllApps should skip untouched apps from the real active-apps list.
    func testRouteAllAppsSkipsUntouchedActiveAppsFromProcessMonitor() {
        let app = makeFakeApp()
        engine.processMonitor.setActiveAppsForTests([app], notify: false)
        var tapAttempts: [String] = []
        engine.onTapCreationAttemptForTests = { attemptedApp, _ in
            tapAttempts.append(attemptedApp.persistenceIdentifier)
        }

        let headphones = AudioDevice(
            id: AudioDeviceID(44),
            uid: "headphones",
            name: "Headphones",
            icon: nil
        )
        engine.deviceMonitor.setOutputDevicesForTests([
            AudioDevice(id: AudioDeviceID(42), uid: "built-in-speakers", name: "Built-in Speakers", icon: nil),
            headphones
        ])

        XCTAssertNil(settings.getDeviceRouting(for: app.persistenceIdentifier))
        XCTAssertNil(engine.appDeviceRouting[app.id])

        engine.routeAllApps(to: "headphones")

        XCTAssertTrue(tapAttempts.isEmpty,
                      "Untouched app from process monitor should not be routed/tapped by routeAllApps")
        XCTAssertNil(settings.getDeviceRouting(for: app.persistenceIdentifier),
                      "Untouched app should not get persisted routing from routeAllApps")
    }

    // MARK: - 5. Orphaned settings: tap failure doesn't clean up persisted routing

    /// When tap creation fails (line 342), the engine cleans up in-memory
    /// `appDeviceRouting` (line 345) but does NOT revert the settings write
    /// from line 324. This leaves an orphaned routing entry in settings.json
    /// that will be loaded on every subsequent startup forever.
    ///
    /// FAILS: After tap failure, settings still contain the routing entry
    /// that was written before the tap was attempted.
    func testTapFailureCleansUpPersistedRouting() {
        let app = makeFakeApp()

        engine.applyPersistedSettingsForTests(apps: [app])

        // In-memory routing was cleaned up (line 345)
        XCTAssertNil(engine.appDeviceRouting[app.id],
                      "Precondition: in-memory routing cleaned up after tap failure")

        // BUG: Persisted routing was NOT cleaned up
        XCTAssertNil(settings.getDeviceRouting(for: app.persistenceIdentifier),
                      "When tap creation fails, the persisted routing entry written at line 324 " +
                      "should also be removed — otherwise it pollutes settings.json forever")
    }

    // MARK: - 6. Mixed: only apps with saved settings should be tapped

    /// When startup processes a mix of customized and untouched apps, only
    /// the customized ones should get routing persisted and taps attempted.
    ///
    /// FAILS: The untouched app gets routing persisted (same as bug #1).
    func testStartupOnlyPersistsRoutingForAppsWithSavedSettings() {
        let customized = makeFakeApp(pid: 2001, name: "Customized", bundleID: "com.test.customized")
        let untouched = makeFakeApp(pid: 2002, name: "Untouched", bundleID: "com.test.untouched")

        // Only the customized app has saved settings
        settings.setVolume(for: customized.persistenceIdentifier, to: 0.7)

        engine.applyPersistedSettingsForTests(apps: [customized, untouched])

        XCTAssertNotNil(settings.getDeviceRouting(for: customized.persistenceIdentifier),
                         "App with saved volume should get routing (needs tap for volume control)")

        XCTAssertNil(settings.getDeviceRouting(for: untouched.persistenceIdentifier),
                      "App with no saved settings should not get default routing persisted")
    }

    // MARK: - 7. Settings grow unboundedly with app churn

    /// Every audio app that appears during a session gets its default routing
    /// written to settings.json (bug #1). Over time, this accumulates entries
    /// for apps the user never customized, apps that were uninstalled, and
    /// one-off audio producers (notification sounds, browser tabs, etc.).
    ///
    /// FAILS: After cycling through several apps, settings accumulate
    /// routing entries for all of them — even though none were customized.
    func testSettingsDoNotGrowWithUncustomizedAppChurn() {
        // Simulate 5 different apps appearing over time (typical session)
        let apps = (1...5).map { i in
            makeFakeApp(pid: pid_t(3000 + i), name: "App\(i)", bundleID: "com.test.app\(i)")
        }

        for app in apps {
            engine.applyPersistedSettingsForTests(apps: [app])
        }

        // Count how many routing entries were written
        var routingCount = 0
        for app in apps {
            if settings.getDeviceRouting(for: app.persistenceIdentifier) != nil {
                routingCount += 1
            }
        }

        XCTAssertEqual(routingCount, 0,
                        "None of these apps were customized, yet \(routingCount) got default " +
                        "routing persisted. Settings should not grow with uncustomized app churn.")
    }

    // MARK: - Passing tests: verify correct behaviors are preserved

    /// Apps with saved device routing preserve it through startup.
    func testStartupPreservesExplicitDeviceRouting() {
        let app = makeFakeApp()
        let headphones = AudioDevice(
            id: AudioDeviceID(43),
            uid: "external-headphones",
            name: "External Headphones",
            icon: nil
        )
        engine.deviceMonitor.setOutputDevicesForTests([
            AudioDevice(id: AudioDeviceID(42), uid: "built-in-speakers", name: "Built-in Speakers", icon: nil),
            headphones
        ])

        settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: "external-headphones")

        engine.applyPersistedSettingsForTests(apps: [app])

        XCTAssertEqual(settings.getDeviceRouting(for: app.persistenceIdentifier),
                        "external-headphones",
                        "Explicit user routing should be preserved through startup")
    }

    /// Apps with saved volume get routing (need a tap to apply volume).
    func testStartupAttemptsTapForAppWithSavedVolume() {
        let app = makeFakeApp()
        settings.setVolume(for: app.persistenceIdentifier, to: 0.5)

        engine.applyPersistedSettingsForTests(apps: [app])

        XCTAssertNotNil(settings.getDeviceRouting(for: app.persistenceIdentifier),
                         "App with saved volume should get routing (needs tap for volume control)")
    }

    /// Apps with saved mute get routing (need a tap to enforce mute).
    func testStartupAttemptsTapForAppWithSavedMute() {
        let app = makeFakeApp()
        settings.setMute(for: app.persistenceIdentifier, to: true)

        engine.applyPersistedSettingsForTests(apps: [app])

        XCTAssertNotNil(settings.getDeviceRouting(for: app.persistenceIdentifier),
                         "Muted app should get routing (needs tap to enforce mute)")
    }

    /// In test env, tap failure cleans up in-memory routing (documents behavior).
    func testStartupRoutingCleanedUpAfterTapFailure() {
        let app = makeFakeApp()

        engine.applyPersistedSettingsForTests(apps: [app])

        // In test env: tap fails → in-memory routing cleaned up → nil
        // In production: tap succeeds → routing stays → audio muted
        XCTAssertNil(engine.appDeviceRouting[app.id],
                      "In test env, routing is cleaned up after tap failure. " +
                      "In production, this would be non-nil and the app's audio would be muted.")
    }
}
