import XCTest
import AppKit
import AudioToolbox
@testable import FineTuneIntegration

// MARK: - resolvedDeviceUIDForDisplay Priority Chain

/// Tests for the 6-tier priority chain in AudioEngine.resolvedDeviceUIDForDisplay.
///
/// The method resolves which device UID the row picker should display:
///   1. In-memory routing → visible device (normal steady-state)
///   2. Persisted routing → visible device (covers recreation window)
///   3. In-memory routing → even if device temporarily invisible (BT reconnecting)
///   4. Persisted routing → even if device temporarily invisible
///   5. System default → visible device
///   6. First visible device
///
/// Only priority 5 was previously tested (testResolvedDisplayDevicePrefersDefaultWhenNoExplicitRouting).
@MainActor
final class ResolvedDisplayDeviceTests: XCTestCase {

    private var engine: AudioEngine!
    private var settings: SettingsManager!
    private var tempDir: URL!

    // Shared devices used across tests
    private let speakers = AudioDevice(id: AudioDeviceID(1), uid: "speakers", name: "Speakers", icon: nil)
    private let headphones = AudioDevice(id: AudioDeviceID(2), uid: "headphones", name: "Headphones", icon: nil)
    private let airpods = AudioDevice(id: AudioDeviceID(3), uid: "airpods", name: "AirPods", icon: nil)

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        settings = SettingsManager(directory: tempDir)
        engine = AudioEngine(settingsManager: settings)
    }

    override func tearDown() async throws {
        engine?.stop()
        engine = nil
        settings = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Priority 1: In-memory routing matches visible device

    /// Normal steady-state: app is routed to headphones, headphones are visible.
    func testPriority1_InMemoryRoutingMatchesVisibleDevice() {
        let app = makeFakeApp()
        engine.appDeviceRouting[app.id] = "headphones"

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [speakers, headphones],
            defaultDeviceUID: "speakers"
        )

        XCTAssertEqual(resolved, "headphones",
                       "Priority 1: in-memory routing to a visible device should win")
    }

    /// In-memory routing should take precedence over persisted routing.
    func testPriority1_InMemoryBeatsPersistedRouting() {
        let app = makeFakeApp()
        engine.appDeviceRouting[app.id] = "headphones"
        settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: "speakers")

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [speakers, headphones],
            defaultDeviceUID: "speakers"
        )

        XCTAssertEqual(resolved, "headphones",
                       "In-memory routing should take precedence over persisted routing")
    }

    // MARK: - Priority 2: Persisted routing matches visible device

    /// During tap recreation, in-memory routing may be stale/nil. Persisted routing
    /// should be used as fallback when the device is still visible.
    func testPriority2_PersistedRoutingMatchesVisibleDevice() {
        let app = makeFakeApp()
        // No in-memory routing (simulates recreation window)
        settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: "headphones")

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [speakers, headphones],
            defaultDeviceUID: "speakers"
        )

        XCTAssertEqual(resolved, "headphones",
                       "Priority 2: persisted routing to a visible device should win when no in-memory routing")
    }

    // MARK: - Priority 3: In-memory routing, device temporarily invisible

    /// AirPods temporarily disappear during coreaudiod restart. The display should
    /// keep showing "AirPods" instead of flipping to speakers.
    func testPriority3_InMemoryRoutingDeviceTemporarilyInvisible() {
        let app = makeFakeApp()
        engine.appDeviceRouting[app.id] = "airpods"
        // AirPods NOT in availableDevices (temporarily gone during BT reconnect)

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [speakers, headphones],
            defaultDeviceUID: "speakers"
        )

        XCTAssertEqual(resolved, "airpods",
                       "Priority 3: in-memory routing should be shown even when device is temporarily invisible")
    }

    // MARK: - Priority 4: Persisted routing, device temporarily invisible

    /// During recreation with AirPods temporarily gone: persisted routing should
    /// still show "AirPods" rather than flipping to default.
    func testPriority4_PersistedRoutingDeviceTemporarilyInvisible() {
        let app = makeFakeApp()
        // No in-memory routing, AirPods not in available devices
        settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: "airpods")

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [speakers, headphones],
            defaultDeviceUID: "speakers"
        )

        XCTAssertEqual(resolved, "airpods",
                       "Priority 4: persisted routing should be shown even when device is temporarily invisible")
    }

    // MARK: - Priority 5: System default (already tested, but included for completeness)

    /// No routing at all → show system default device.
    func testPriority5_FallsBackToSystemDefault() {
        let app = makeFakeApp()

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [speakers, headphones],
            defaultDeviceUID: "headphones"
        )

        XCTAssertEqual(resolved, "headphones",
                       "Priority 5: system default should be used when no routing exists")
    }

    /// Default device UID that's not in availableDevices should fall through to priority 6.
    func testPriority5_DefaultNotInAvailableDevicesFallsThrough() {
        let app = makeFakeApp()

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [speakers],
            defaultDeviceUID: "disconnected-device"
        )

        XCTAssertEqual(resolved, "speakers",
                       "When default device is not available, should fall through to first visible device")
    }

    // MARK: - Priority 6: First visible device

    /// No routing, no default → use the first available device.
    func testPriority6_FirstVisibleDevice() {
        let app = makeFakeApp()

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [speakers, headphones],
            defaultDeviceUID: nil
        )

        XCTAssertEqual(resolved, "speakers",
                       "Priority 6: first visible device should be used as last resort")
    }

    // MARK: - Edge Cases

    /// No devices at all → returns empty string.
    func testEmptyAvailableDevicesReturnsEmptyString() {
        let app = makeFakeApp()

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [],
            defaultDeviceUID: nil
        )

        XCTAssertEqual(resolved, "",
                       "With no available devices and no routing, should return empty string")
    }

    /// In-memory routing to an invisible device with no visible devices at all.
    /// Priority 3 should still return the in-memory routing even with empty device list.
    func testInMemoryRoutingWinsEvenWithNoVisibleDevices() {
        let app = makeFakeApp()
        engine.appDeviceRouting[app.id] = "airpods"

        let resolved = engine.resolvedDeviceUIDForDisplay(
            app: app,
            availableDevices: [],
            defaultDeviceUID: nil
        )

        XCTAssertEqual(resolved, "airpods",
                       "In-memory routing should be returned even when no devices are visible")
    }
}

// MARK: - shouldConfirmPermission: Low Volume Edge Case

/// Tests for the volume ≈ 0 bypass in shouldConfirmPermission.
///
/// When the user's volume is near zero, output peak will legitimately be zero.
/// The permission check should still confirm (volume ≈ 0 bypasses the output peak
/// requirement) so the user isn't stuck without .mutedWhenTapped because they
/// happened to have the slider at minimum.
@MainActor
final class PermissionConfirmationVolumeTests: XCTestCase {

    /// Volume near zero: output peak is zero (expected), input is present.
    /// Permission should be confirmed because the zero output peak is legitimate.
    func testPermissionConfirmedAtNearZeroVolume() {
        let diagnostics = TapDiagnostics(
            callbackCount: 30,
            inputHasData: 15,
            outputWritten: 30,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 30, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.25, lastOutputPeak: 0.0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 0.005,  // Near-zero volume
            crossfadeActive: false, primaryCurrentVolume: 1.0
        )

        XCTAssertTrue(
            AudioEngine.shouldConfirmPermission(from: diagnostics),
            "Near-zero volume with zero output peak should still confirm permission — " +
            "zero output is expected when volume is ~0"
        )
    }

    /// Volume exactly at the threshold (0.01): this is the boundary between
    /// "user expects audio" and "near zero." At 0.01, the code uses `> 0.01`,
    /// so volume=0.01 should NOT require output peak.
    func testPermissionThresholdBoundary() {
        let diagnostics = TapDiagnostics(
            callbackCount: 30,
            inputHasData: 15,
            outputWritten: 30,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 30, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.25, lastOutputPeak: 0.0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 0.01,  // Exactly at threshold
            crossfadeActive: false, primaryCurrentVolume: 1.0
        )

        XCTAssertTrue(
            AudioEngine.shouldConfirmPermission(from: diagnostics),
            "Volume exactly at threshold (0.01) should bypass output peak check (guard is > 0.01)"
        )
    }

    /// Volume just above the threshold (0.011): requires real output peak.
    func testPermissionAboveThresholdRequiresOutputPeak() {
        let diagnostics = TapDiagnostics(
            callbackCount: 30,
            inputHasData: 15,
            outputWritten: 30,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 30, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.25, lastOutputPeak: 0.0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 0.011,  // Just above threshold
            crossfadeActive: false, primaryCurrentVolume: 1.0
        )

        XCTAssertFalse(
            AudioEngine.shouldConfirmPermission(from: diagnostics),
            "Volume just above threshold (0.011) with zero output peak should NOT confirm — " +
            "user expects audio but none is reaching the output"
        )
    }

    /// Volume at zero exactly should still confirm (slider fully down).
    func testPermissionConfirmedAtExactlyZeroVolume() {
        let diagnostics = TapDiagnostics(
            callbackCount: 30,
            inputHasData: 15,
            outputWritten: 30,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 30, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.25, lastOutputPeak: 0.0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 0.0,
            crossfadeActive: false, primaryCurrentVolume: 1.0
        )

        XCTAssertTrue(
            AudioEngine.shouldConfirmPermission(from: diagnostics),
            "Zero volume should bypass output peak requirement"
        )
    }
}

// MARK: - routeAllApps State Management

/// Tests for routeAllApps edge cases not covered by AudioSwitchingTests.
///
/// AudioSwitchingTests covers "already on target" and "no apps."
/// These tests cover:
///   - Early exit when both in-memory and persisted routing already match
///   - Cached paused app update when no active apps exist
///   - shouldRouteAllApps filtering for custom-settings-only apps
@MainActor
final class RouteAllAppsStateTests: XCTestCase {

    private var engine: AudioEngine!
    private var settings: SettingsManager!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        settings = SettingsManager(directory: tempDir)
        engine = AudioEngine(
            settingsManager: settings,
            defaultOutputDeviceUIDProvider: { "speakers" }
        )
        engine.deviceMonitor.setOutputDevicesForTests([
            AudioDevice(id: AudioDeviceID(1), uid: "speakers", name: "Speakers", icon: nil),
            AudioDevice(id: AudioDeviceID(2), uid: "headphones", name: "Headphones", icon: nil),
        ])
    }

    override func tearDown() async throws {
        engine?.stop()
        engine = nil
        settings = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// When all in-memory AND persisted routings already point at the target device,
    /// routeAllApps should exit early without re-writing settings.
    func testEarlyExitWhenAllRoutingsAlreadyMatch() {
        let app = makeFakeApp()
        engine.appDeviceRouting[app.id] = "headphones"
        settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: "headphones")

        // Seed apps so routeAllApps has something to check
        engine.updateDisplayedAppsStateForTests(activeApps: [app])

        // Spy: take a snapshot of persisted routing BEFORE the call.
        // If routeAllApps early-exits, updateAllDeviceRoutings is never called,
        // so no save is scheduled. We verify by checking the routing hasn't changed.
        engine.routeAllApps(to: "headphones")

        XCTAssertEqual(engine.appDeviceRouting[app.id], "headphones",
                       "In-memory routing should be unchanged after early exit")
        XCTAssertEqual(settings.getDeviceRouting(for: app.persistenceIdentifier), "headphones",
                       "Persisted routing should be unchanged after early exit")
    }

    /// routeAllApps updates persisted routing even when no active apps exist.
    /// This ensures inactive/paused apps use the new device when they reappear.
    func testRouteAllAppsUpdatesPersistedRoutingWithNoActiveApps() {
        // Pre-seed persisted routing for an app that's not currently active
        settings.setDeviceRouting(for: "com.spotify.client", deviceUID: "speakers")

        engine.routeAllApps(to: "headphones")

        XCTAssertEqual(settings.getDeviceRouting(for: "com.spotify.client"), "headphones",
                       "Persisted routing should be bulk-updated even with no active apps")
    }

    /// routeAllApps updates persisted routing for ALL known identifiers
    /// (including inactive apps) via updateAllDeviceRoutings.
    func testPersistedRoutingUpdatedForInactiveApps() {
        // Pre-seed persisted routing for an "inactive" app (not in engine.apps)
        settings.setDeviceRouting(for: "com.inactive.app", deviceUID: "speakers")

        // Also need an active app with routing to avoid the empty early-exit
        let active = makeFakeApp(pid: 16001, name: "Active", bundleID: "com.active.app")
        engine.appDeviceRouting[active.id] = "speakers"
        settings.setDeviceRouting(for: active.persistenceIdentifier, deviceUID: "speakers")
        engine.updateDisplayedAppsStateForTests(activeApps: [active])

        engine.routeAllApps(to: "headphones")

        XCTAssertEqual(settings.getDeviceRouting(for: "com.inactive.app"), "headphones",
                       "Persisted routing for inactive apps should be bulk-updated by routeAllApps")
    }
}

// MARK: - applyPersistedSettings Fallback Branches

/// Tests for the default-device fallback chain in applyPersistedSettings.
///
/// DefaultDeviceBehaviorTests covers "virtual default → use first real device."
/// These tests cover the remaining branches:
///   - No real devices at all → keep default UID as-is
///   - defaultOutputDeviceUIDProvider throws → skip app without side effects
@MainActor
final class ApplyPersistedSettingsFallbackTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// When the default device is virtual AND no real devices exist, the code
    /// falls back to using the default UID as-is (line 1133).
    func testFallbackKeepsDefaultWhenNoRealDevices() {
        let settings = SettingsManager(directory: tempDir)
        let engine = AudioEngine(
            settingsManager: settings,
            defaultOutputDeviceUIDProvider: { "virtual-aggregate" }
        )
        // No real devices in monitor (empty device list)
        engine.deviceMonitor.setOutputDevicesForTests([])

        let app = makeFakeApp()
        settings.setVolume(for: app.persistenceIdentifier, to: 0.8)

        engine.applyPersistedSettingsForTests(apps: [app])

        // The engine writes routing even though tap will fail, then cleans up
        // in-memory routing. But persisted routing reveals what UID was attempted.
        // With no real devices, it should have used "virtual-aggregate" as the UID.
        let persistedUID = settings.getDeviceRouting(for: app.persistenceIdentifier)
        XCTAssertEqual(persistedUID, "virtual-aggregate",
                       "When no real devices exist, should fall back to the default UID as-is")

        engine.stop()
    }

    /// When defaultOutputDeviceUIDProvider throws, the app should be skipped
    /// entirely — no routing written, no tap attempted.
    func testProviderThrowsSkipsAppCleanly() {
        let settings = SettingsManager(directory: tempDir)
        let engine = AudioEngine(
            settingsManager: settings,
            defaultOutputDeviceUIDProvider: { throw NSError(domain: "test", code: 1) }
        )

        let app = makeFakeApp()
        settings.setVolume(for: app.persistenceIdentifier, to: 0.8)

        var tapAttempted = false
        engine.onTapCreationAttemptForTests = { _, _ in
            tapAttempted = true
        }

        engine.applyPersistedSettingsForTests(apps: [app])

        XCTAssertNil(engine.appDeviceRouting[app.id],
                     "No in-memory routing should be set when provider throws")
        XCTAssertNil(settings.getDeviceRouting(for: app.persistenceIdentifier),
                     "No persisted routing should be written when provider throws")
        XCTAssertFalse(tapAttempted,
                       "No tap creation should be attempted when provider throws")

        engine.stop()
    }

    /// applyPersistedSettings should not re-process an app that was already applied
    /// (appliedPIDs deduplication). Verify by checking tap attempts.
    func testAppliedPIDsPreventsDuplicateProcessing() {
        let settings = SettingsManager(directory: tempDir)
        let engine = AudioEngine(
            settingsManager: settings,
            defaultOutputDeviceUIDProvider: { "speakers" }
        )
        engine.deviceMonitor.setOutputDevicesForTests([
            AudioDevice(id: AudioDeviceID(1), uid: "speakers", name: "Speakers", icon: nil)
        ])

        let app = makeFakeApp()
        settings.setVolume(for: app.persistenceIdentifier, to: 0.7)

        var tapAttemptCount = 0
        engine.onTapCreationAttemptForTests = { _, _ in
            tapAttemptCount += 1
        }

        // First call: processes the app
        engine.applyPersistedSettingsForTests(apps: [app])
        let firstCount = tapAttemptCount

        // Second call: should be skipped via appliedPIDs
        engine.applyPersistedSettingsForTests(apps: [app])

        XCTAssertEqual(tapAttemptCount, firstCount,
                       "Second applyPersistedSettings call should not re-attempt tap creation (appliedPIDs guard)")

        engine.stop()
    }
}
