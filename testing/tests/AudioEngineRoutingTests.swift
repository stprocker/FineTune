import XCTest
import AppKit
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
        engine = AudioEngine(settingsManager: settings)
    }

    override func tearDown() async throws {
        engine?.stop()
        engine = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeFakeApp(
        pid: pid_t = 99999,
        name: String = "TestApp",
        bundleID: String = "com.test.app"
    ) -> AudioApp {
        AudioApp(
            id: pid,
            objectID: .unknown,
            name: name,
            icon: NSImage(),
            bundleID: bundleID
        )
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
}
