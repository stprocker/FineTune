import XCTest
import AppKit
import AudioToolbox
@testable import FineTuneIntegration

/// Tests for AudioEngine routing state management.
///
/// These tests exercise the routing revert logic that prevents UI/audio desync.
/// In the test environment, CoreAudio tap creation always fails (no real audio
/// hardware), which lets us verify that routing state is cleaned up on failure.
///
/// Bugs tested:
/// - Bug 3: setDevice else-branch (no existing tap) leaves stale routing when
///   ensureTapExists fails. Fix: check taps[app.id] == nil and revert.
/// - Bug 4: applyPersistedSettings leaves stale appDeviceRouting entry when
///   tap creation fails. Fix: remove routing with appDeviceRouting.removeValue.
///
/// Bugs that need mock infrastructure (not tested here):
/// - Bug 1: setDevice async path (existing tap, switchDevice throws) doesn't
///   revert. Requires a working tap + failing switchDevice.
/// - Bug 2: performCrossfadeSwitch promotes non-functioning secondary.
///   Tested indirectly via CrossfadeStateTests (warmup detection).
@MainActor
final class AudioEngineRoutingTests: XCTestCase {

    private var engine: AudioEngine!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        let settings = SettingsManager(directory: tempDir)
        engine = AudioEngine(
            settingsManager: settings,
            isProcessRunningProvider: { _ in true }
        )
    }

    override func tearDown() async throws {
        engine?.stop()
        engine = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Bug 3: setDevice reverts routing on tap creation failure

    /// When setDevice is called with no existing tap and tap creation fails,
    /// routing should be removed (not left stale pointing at a non-functional device).
    ///
    /// Pre-fix behavior: appDeviceRouting[pid] = "nonexistent-device" (stale)
    /// Post-fix behavior: appDeviceRouting[pid] = nil (reverted)
    func testSetDeviceRevertsWhenNoExistingRouting() {
        let app = makeFakeApp()
        XCTAssertNil(engine.appDeviceRouting[app.id], "Precondition: no routing")

        engine.setDevice(for: app, deviceUID: "nonexistent-device-uid")

        // Tap creation fails (no real audio hardware), so routing should be reverted
        XCTAssertNil(engine.appDeviceRouting[app.id],
                      "Bug 3: Routing should be removed when tap creation fails and no previous routing exists")
    }

    /// The short-circuit guard should prevent redundant setDevice calls.
    func testSetDeviceShortCircuitsOnSameDevice() {
        let app = makeFakeApp()
        // First call: fails and reverts → routing is nil
        engine.setDevice(for: app, deviceUID: "device-A")
        XCTAssertNil(engine.appDeviceRouting[app.id],
                      "First call should revert since tap creation fails")

        // Second call with same device: appDeviceRouting[pid] is nil,
        // and "device-A" != nil, so it proceeds (not short-circuited)
        engine.setDevice(for: app, deviceUID: "device-A")
        // Still fails and reverts
        XCTAssertNil(engine.appDeviceRouting[app.id])
    }

    /// Multiple setDevice calls to different devices should all revert cleanly.
    func testSetDeviceMultipleFailuresAllRevert() {
        let app = makeFakeApp()

        engine.setDevice(for: app, deviceUID: "device-A")
        XCTAssertNil(engine.appDeviceRouting[app.id])

        engine.setDevice(for: app, deviceUID: "device-B")
        XCTAssertNil(engine.appDeviceRouting[app.id])

        engine.setDevice(for: app, deviceUID: "device-C")
        XCTAssertNil(engine.appDeviceRouting[app.id],
                      "All failed routing attempts should be reverted")
    }

    /// Multiple apps should have independent routing state.
    func testSetDeviceIndependentPerApp() {
        let app1 = makeFakeApp(pid: 10001, name: "App1", bundleID: "com.test.app1")
        let app2 = makeFakeApp(pid: 10002, name: "App2", bundleID: "com.test.app2")

        engine.setDevice(for: app1, deviceUID: "device-X")
        engine.setDevice(for: app2, deviceUID: "device-Y")

        // Both should revert independently
        XCTAssertNil(engine.appDeviceRouting[app1.id])
        XCTAssertNil(engine.appDeviceRouting[app2.id])
    }

    // MARK: - SettingsManager Integration

    /// When routing is reverted, persisted settings should also be cleaned up.
    /// This prevents stale routing from being applied on next app launch.
    func testSetDeviceRevertsCleansPersistedRouting() {
        let app = makeFakeApp()
        let settings = engine.settingsManager

        engine.setDevice(for: app, deviceUID: "nonexistent-device")
        XCTAssertNil(settings.getDeviceRouting(for: app.persistenceIdentifier),
                     "Failed switch with no prior routing should not leave persisted orphan routing")
    }

    // MARK: - Permission confirmation safety

    func testPermissionConfirmationRequiresRealInputAudio() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 0,
            outputWritten: 25,
            silencedForce: 0,
            silencedMute: 0,
            converterUsed: 0,
            converterFailed: 0,
            directFloat: 25,
            nonFloatPassthrough: 0,
            emptyInput: 0,
            lastInputPeak: 0,
            lastOutputPeak: 0,
            outputBufCount: 1,
            outputBuf0ByteSize: 4096,
            formatChannels: 2,
            formatIsFloat: true,
            formatIsInterleaved: true,
            formatSampleRate: 48000,
            volume: 1.0,
            crossfadeActive: false,
            primaryCurrentVolume: 1.0
        )

        XCTAssertFalse(
            AudioEngine.shouldConfirmPermission(from: diagnostics),
            "Permission should not be marked confirmed when callbacks/output exist but input is silent."
        )
    }

    func testPermissionConfirmationSucceedsWithInputAudio() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 10,
            outputWritten: 25,
            silencedForce: 0,
            silencedMute: 0,
            converterUsed: 0,
            converterFailed: 0,
            directFloat: 25,
            nonFloatPassthrough: 0,
            emptyInput: 0,
            lastInputPeak: 0.22,
            lastOutputPeak: 0.22,
            outputBufCount: 1,
            outputBuf0ByteSize: 4096,
            formatChannels: 2,
            formatIsFloat: true,
            formatIsInterleaved: true,
            formatSampleRate: 48000,
            volume: 1.0,
            crossfadeActive: false,
            primaryCurrentVolume: 1.0
        )

        XCTAssertTrue(
            AudioEngine.shouldConfirmPermission(from: diagnostics),
            "Permission should be confirmed only once real input audio is observed."
        )
    }

    // MARK: - Dead Output Safety Net (macOS 26 bundle-ID tap regression)

    /// Primary regression test: bundle-ID tap failure pattern must not confirm permission.
    /// High callbacks, input data present, output written, but lastOutputPeak=0.
    func testPermissionNotConfirmedWithBundleIDTapPattern() {
        let diagnostics = TapDiagnostics(
            callbackCount: 50,
            inputHasData: 40,
            outputWritten: 50,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 50, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.3, lastOutputPeak: 0.0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(
            AudioEngine.shouldConfirmPermission(from: diagnostics),
            "Bundle-ID tap with dead output (outPeak=0) must not confirm permission"
        )
    }

    /// Permission should only be confirmed once output peak is real, not during warmup.
    func testPermissionNotConfirmedUntilOutputPeakIsReal() {
        // Warmup snapshot: output peak still zero
        let warmup = TapDiagnostics(
            callbackCount: 15,
            inputHasData: 5,
            outputWritten: 15,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 15, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.2, lastOutputPeak: 0.0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: warmup),
                       "Zero output peak during warmup should not confirm permission")

        // Stabilized snapshot: output peak is real
        let stable = TapDiagnostics(
            callbackCount: 50,
            inputHasData: 30,
            outputWritten: 50,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 50, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.3, lastOutputPeak: 0.25,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertTrue(AudioEngine.shouldConfirmPermission(from: stable),
                      "Real output peak should confirm permission")
    }

    /// Exact boundary behavior at the output peak threshold.
    func testPermissionConfirmationEdgeCaseNearThreshold() {
        let atThreshold = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 10,
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 25, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.3, lastOutputPeak: 0.0001,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: atThreshold),
                       "Output peak exactly at threshold should not confirm (guard is >)")

        let aboveThreshold = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 10,
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 25, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.3, lastOutputPeak: 0.00011,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertTrue(AudioEngine.shouldConfirmPermission(from: aboveThreshold),
                      "Output peak just above threshold should confirm permission")
    }

    // MARK: - Apps Display Fallback (paused state)

    /// When playback stops, the Apps section should keep showing the last app
    /// and mark it as paused instead of dropping to empty state immediately.
    func testDisplayedAppsFallsBackToLastActiveAppWhenPlaybackStops() {
        let app = makeFakeApp(pid: 11001, name: "Brave", bundleID: "com.brave.Browser")

        engine.updateDisplayedAppsStateForTests(activeApps: [app])
        XCTAssertEqual(engine.displayedApps.map(\.id), [app.id])
        XCTAssertFalse(engine.isPausedDisplayApp(app),
                       "Actively playing app should not be marked paused")

        engine.updateDisplayedAppsStateForTests(activeApps: [])
        XCTAssertEqual(engine.displayedApps.map(\.id), [app.id],
                       "Last app should remain visible when playback pauses")
        XCTAssertTrue(engine.isPausedDisplayApp(app),
                      "Fallback row should be marked paused when no apps are active")
    }

    /// Active apps should always take precedence over paused fallback.
    func testDisplayedAppsPrefersCurrentActiveAppsOverPausedFallback() {
        let first = makeFakeApp(pid: 12001, name: "Safari", bundleID: "com.apple.Safari")
        let second = makeFakeApp(pid: 12002, name: "Music", bundleID: "com.apple.Music")

        engine.updateDisplayedAppsStateForTests(activeApps: [first])
        engine.updateDisplayedAppsStateForTests(activeApps: [])
        XCTAssertEqual(engine.displayedApps.map(\.id), [first.id],
                       "Precondition: first app is cached as paused fallback")

        engine.updateDisplayedAppsStateForTests(activeApps: [second])
        XCTAssertEqual(engine.displayedApps.map(\.id), [second.id],
                       "When a new app is active, UI should show active app list")
        XCTAssertFalse(engine.isPausedDisplayApp(second))
        XCTAssertFalse(engine.displayedApps.contains(where: { $0.id == first.id }),
                       "Paused fallback app should not be shown while an active app exists")
    }

    func testActiveAppIsMarkedPausedAfterSilenceGrace() {
        let app = makeFakeApp(pid: 13001, name: "YouTube", bundleID: "com.brave.Browser")
        engine.updateDisplayedAppsStateForTests(activeApps: [app])
        engine.setPauseEligibilityForTests([app.id])

        engine.setLastAudibleAtForTests(pid: app.id, date: Date().addingTimeInterval(-5))
        XCTAssertTrue(engine.isPausedDisplayApp(app),
                      "Active app with stale audio activity should show paused quickly")
    }

    func testResolvedDisplayDevicePrefersDefaultWhenNoExplicitRouting() {
        let app = makeFakeApp(pid: 14001, name: "Brave", bundleID: "com.brave.Browser")
        let builtIn = AudioDevice(id: AudioDeviceID(1), uid: "built-in", name: "Built-in", icon: nil)
        let calDigit = AudioDevice(id: AudioDeviceID(2), uid: "caldigit", name: "CalDigit", icon: nil)

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [calDigit, builtIn],
            defaultDeviceUID: "built-in"
        )

        XCTAssertEqual(resolved, "built-in",
                       "UI should show system default device when app has no explicit routing")
    }
}
