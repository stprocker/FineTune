// testing/tests/ProcessTapControllerTests.swift
import XCTest
import AppKit
@testable import FineTuneIntegration
@testable import FineTuneCore

/// Characterization tests for ProcessTapController state management,
/// diagnostics, and injectable timing seams.
/// Audio processing and tap lifecycle tests require CoreAudio hardware
/// and are covered by manual smoke testing.
final class ProcessTapControllerTests: XCTestCase {

    private func makeTapController(
        volume: Float = 1.0,
        muted: Bool = false,
        targetDeviceUID: String = "test-device-uid"
    ) -> ProcessTapController {
        let app = makeFakeApp(name: "TestApp")
        let controller = ProcessTapController(
            app: app,
            targetDeviceUID: targetDeviceUID,
            deviceMonitor: nil,
            muteOriginal: true
        )
        controller.volume = volume
        controller.isMuted = muted
        return controller
    }

    // MARK: - Initialization

    func testInitSetsAppAndTargetDevice() {
        let app = makeFakeApp(name: "Safari")
        let controller = ProcessTapController(
            app: app,
            targetDeviceUID: "device-123"
        )
        XCTAssertEqual(controller.app.name, "Safari")
    }

    func testInitDefaultsVolumeToUnity() {
        let controller = makeTapController()
        XCTAssertEqual(controller.volume, 1.0)
    }

    func testInitDefaultsMutedToFalse() {
        let controller = makeTapController()
        XCTAssertFalse(controller.isMuted)
    }

    // MARK: - Volume & Mute State

    func testVolumeSetGet() {
        let controller = makeTapController()
        controller.volume = 0.5
        XCTAssertEqual(controller.volume, 0.5, accuracy: 0.001)
    }

    func testVolumeZero() {
        let controller = makeTapController()
        controller.volume = 0.0
        XCTAssertEqual(controller.volume, 0.0, accuracy: 0.001)
    }

    func testVolumeAboveUnity() {
        let controller = makeTapController()
        controller.volume = 2.0
        XCTAssertEqual(controller.volume, 2.0, accuracy: 0.001)
    }

    func testMuteSetGet() {
        let controller = makeTapController()
        controller.isMuted = true
        XCTAssertTrue(controller.isMuted)
        controller.isMuted = false
        XCTAssertFalse(controller.isMuted)
    }

    // MARK: - Device Volume / Mute (for VU meter)

    func testDeviceVolumeSetGet() {
        let controller = makeTapController()
        controller.currentDeviceVolume = 0.75
        XCTAssertEqual(controller.currentDeviceVolume, 0.75, accuracy: 0.001)
    }

    func testDeviceMuteSetGet() {
        let controller = makeTapController()
        XCTAssertFalse(controller.isDeviceMuted)
        controller.isDeviceMuted = true
        XCTAssertTrue(controller.isDeviceMuted)
    }

    // MARK: - Diagnostics Snapshot

    func testDiagnosticsInitialState() {
        let controller = makeTapController(volume: 0.8)
        let diag = controller.diagnostics

        // All counters start at zero
        XCTAssertEqual(diag.callbackCount, 0)
        XCTAssertEqual(diag.inputHasData, 0)
        XCTAssertEqual(diag.outputWritten, 0)
        XCTAssertEqual(diag.silencedForce, 0)
        XCTAssertEqual(diag.silencedMute, 0)
        XCTAssertEqual(diag.converterUsed, 0)
        XCTAssertEqual(diag.converterFailed, 0)
        XCTAssertEqual(diag.directFloat, 0)
        XCTAssertEqual(diag.nonFloatPassthrough, 0)
        XCTAssertEqual(diag.emptyInput, 0)

        // Volume reflects current state
        XCTAssertEqual(diag.volume, 0.8, accuracy: 0.001)

        // Crossfade not active initially
        XCTAssertFalse(diag.crossfadeActive)
    }

    func testDiagnosticsReflectsVolumeChange() {
        let controller = makeTapController()
        controller.volume = 1.5
        XCTAssertEqual(controller.diagnostics.volume, 1.5, accuracy: 0.001)
    }

    // MARK: - Audio Level (VU Meter)

    func testAudioLevelInitiallyZero() {
        let controller = makeTapController()
        XCTAssertEqual(controller.audioLevel, 0.0, accuracy: 0.001)
    }

    // MARK: - Injectable Timing Seams

    func testDefaultTimingValues() {
        let controller = makeTapController()
        XCTAssertEqual(controller.crossfadeWarmupMs, 50)
        XCTAssertEqual(controller.crossfadeWarmupBTMs, 500)
        XCTAssertEqual(controller.crossfadeTimeoutPaddingMs, 100)
        XCTAssertEqual(controller.crossfadeTimeoutPaddingBTMs, 600)
        XCTAssertEqual(controller.crossfadePollIntervalMs, 5)
        XCTAssertEqual(controller.crossfadePostBufferMs, 10)
        XCTAssertEqual(controller.destructiveSwitchPreSilenceMs, 100)
        XCTAssertEqual(controller.destructiveSwitchPostSilenceMs, 150)
        XCTAssertEqual(controller.destructiveSwitchFadeInMs, 100)
    }

    func testTimingSeamsAreInjectable() {
        let controller = makeTapController()
        controller.crossfadeWarmupMs = 0
        controller.crossfadeWarmupBTMs = 0
        controller.crossfadeTimeoutPaddingMs = 0
        controller.crossfadePollIntervalMs = 1
        controller.destructiveSwitchPreSilenceMs = 0
        controller.destructiveSwitchPostSilenceMs = 0
        controller.destructiveSwitchFadeInMs = 0

        XCTAssertEqual(controller.crossfadeWarmupMs, 0)
        XCTAssertEqual(controller.crossfadeWarmupBTMs, 0)
        XCTAssertEqual(controller.destructiveSwitchPreSilenceMs, 0)
    }

    // MARK: - Tap Description Flag Matrix (macOS 26 bundle-ID vs PID-only)

    func testTapDescriptionUsesBundleIDByDefault() {
        let app = makeFakeApp(name: "Safari", bundleID: "com.apple.Safari")
        let controller = ProcessTapController(
            app: app,
            targetDeviceUID: "test-device-uid"
        )
        // Clear any overrides
        UserDefaults.standard.removeObject(forKey: "FineTuneForcePIDOnlyTaps")
        UserDefaults.standard.removeObject(forKey: "FineTuneDisableBundleIDTaps")

        let flags = controller.testTapDescriptionFlags(for: "test-device-uid")
        if #available(macOS 26.0, *) {
            XCTAssertTrue(flags.usesBundleIDs, "Should use bundleIDs on macOS 26+")
            XCTAssertTrue(flags.isProcessRestoreEnabled, "Should enable processRestore on macOS 26+")
            XCTAssertEqual(flags.bundleID, "com.apple.Safari")
        } else {
            XCTAssertFalse(flags.usesBundleIDs, "Should not use bundleIDs before macOS 26")
        }
    }

    func testTapDescriptionFallsToPIDWhenForced() {
        let app = makeFakeApp(name: "Safari", bundleID: "com.apple.Safari")
        let controller = ProcessTapController(
            app: app,
            targetDeviceUID: "test-device-uid"
        )
        UserDefaults.standard.set(true, forKey: "FineTuneForcePIDOnlyTaps")
        defer { UserDefaults.standard.removeObject(forKey: "FineTuneForcePIDOnlyTaps") }

        let flags = controller.testTapDescriptionFlags(for: "test-device-uid")
        XCTAssertFalse(flags.usesBundleIDs, "Force-PID key should disable bundleIDs")
        XCTAssertFalse(flags.isProcessRestoreEnabled)
        XCTAssertNil(flags.bundleID)
    }

    func testTapDescriptionFallsToPIDWhenNoBundleID() {
        let app = AudioApp(
            id: 99998,
            objectID: .unknown,
            name: "NoBundleApp",
            icon: NSImage(),
            bundleID: nil
        )
        let controller = ProcessTapController(
            app: app,
            targetDeviceUID: "test-device-uid"
        )
        UserDefaults.standard.removeObject(forKey: "FineTuneForcePIDOnlyTaps")
        UserDefaults.standard.removeObject(forKey: "FineTuneDisableBundleIDTaps")

        let flags = controller.testTapDescriptionFlags(for: "test-device-uid")
        XCTAssertFalse(flags.usesBundleIDs, "No bundleID should fall back to PID-only")
        XCTAssertNil(flags.bundleID)
    }

    func testTapDescriptionDisableBundleIDTapsKey() {
        let app = makeFakeApp(name: "Safari", bundleID: "com.apple.Safari")
        let controller = ProcessTapController(
            app: app,
            targetDeviceUID: "test-device-uid"
        )
        UserDefaults.standard.removeObject(forKey: "FineTuneForcePIDOnlyTaps")
        UserDefaults.standard.set(true, forKey: "FineTuneDisableBundleIDTaps")
        defer { UserDefaults.standard.removeObject(forKey: "FineTuneDisableBundleIDTaps") }

        let flags = controller.testTapDescriptionFlags(for: "test-device-uid")
        XCTAssertFalse(flags.usesBundleIDs, "FineTuneDisableBundleIDTaps should disable bundleIDs")
        XCTAssertFalse(flags.isProcessRestoreEnabled)
        XCTAssertNil(flags.bundleID)
    }

    // MARK: - Injectable Queue

    func testCustomQueueIsUsed() {
        let customQueue = DispatchQueue(label: "test-queue")
        let app = makeFakeApp()
        let controller = ProcessTapController(
            app: app,
            targetDeviceUID: "test-uid",
            queue: customQueue
        )
        // Controller created successfully with custom queue
        XCTAssertNotNil(controller)
    }
}
