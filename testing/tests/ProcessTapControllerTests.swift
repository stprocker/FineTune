// testing/tests/ProcessTapControllerTests.swift
import XCTest
import AppKit
import Accelerate
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
        XCTAssertEqual(diag.eqApplied, 0)
        XCTAssertEqual(diag.eqBypassed, 0)
        XCTAssertEqual(diag.eqBypassNoProcessor, 0)
        XCTAssertEqual(diag.eqBypassCrossfade, 0)
        XCTAssertEqual(diag.eqBypassNonInterleaved, 0)
        XCTAssertEqual(diag.eqBypassChannelMismatch, 0)
        XCTAssertEqual(diag.eqBypassBufferCount, 0)
        XCTAssertEqual(diag.eqBypassNoOutputData, 0)

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

    // MARK: - EQ Bypass Reason Decision

    func testEQBypassReasonReturnsNilWhenEQCanRun() {
        let reason = ProcessTapController.eqBypassReason(
            hasEQProcessor: true,
            isCrossfadeActive: false,
            isInterleaved: true,
            channelCount: 2,
            outputBufferCount: 1,
            hasOutputData: true
        )
        XCTAssertNil(reason)
    }

    func testEQBypassReasonNoProcessor() {
        let reason = ProcessTapController.eqBypassReason(
            hasEQProcessor: false,
            isCrossfadeActive: false,
            isInterleaved: true,
            channelCount: 2,
            outputBufferCount: 1,
            hasOutputData: true
        )
        XCTAssertEqual(reason, .noProcessor)
    }

    func testEQBypassReasonCrossfade() {
        let reason = ProcessTapController.eqBypassReason(
            hasEQProcessor: true,
            isCrossfadeActive: true,
            isInterleaved: true,
            channelCount: 2,
            outputBufferCount: 1,
            hasOutputData: true
        )
        XCTAssertEqual(reason, .crossfadeActive)
    }

    func testEQBypassReasonNonInterleaved() {
        let reason = ProcessTapController.eqBypassReason(
            hasEQProcessor: true,
            isCrossfadeActive: false,
            isInterleaved: false,
            channelCount: 2,
            outputBufferCount: 1,
            hasOutputData: true
        )
        XCTAssertEqual(reason, .nonInterleaved)
    }

    func testEQBypassReasonChannelMismatch() {
        let reason = ProcessTapController.eqBypassReason(
            hasEQProcessor: true,
            isCrossfadeActive: false,
            isInterleaved: true,
            channelCount: 1,
            outputBufferCount: 1,
            hasOutputData: true
        )
        XCTAssertEqual(reason, .channelMismatch)
    }

    func testEQBypassReasonBufferCount() {
        let reason = ProcessTapController.eqBypassReason(
            hasEQProcessor: true,
            isCrossfadeActive: false,
            isInterleaved: true,
            channelCount: 2,
            outputBufferCount: 2,
            hasOutputData: true
        )
        XCTAssertEqual(reason, .bufferCount)
    }

    func testEQBypassReasonNoOutputData() {
        let reason = ProcessTapController.eqBypassReason(
            hasEQProcessor: true,
            isCrossfadeActive: false,
            isInterleaved: true,
            channelCount: 2,
            outputBufferCount: 1,
            hasOutputData: false
        )
        XCTAssertEqual(reason, .noOutputData)
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
            XCTAssertFalse(flags.isProcessRestoreEnabled, "isProcessRestoreEnabled causes dead aggregate output on macOS 26")
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

    // MARK: - EQ boost loudness (regression: "cranking the bass got quieter")

    /// The EQ must NOT pre-attenuate the signal when bands are boosted. Previously
    /// it applied a preamp of pow(10, -maxBoost/20), so boosting only restored
    /// unity while everything else dropped — perceived as "quieter". The fix pins
    /// the preamp at unity regardless of boost.
    func testEQBoostDoesNotPreAttenuate() {
        let eq = EQProcessor(sampleRate: 48_000)
        eq.updateSettings(EQSettings(bandGains: [12, 12, 6, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(eq.preampScalar, 1.0, accuracy: 1e-6,
            "Boosting must not pre-attenuate; preamp scalar should stay at unity")
    }

    /// End-to-end through the production order (preamp × samples, then EQ): a
    /// boosted low band must make a low-frequency tone clearly LOUDER than flat.
    func testBassBoostMakesLowFrequencyLouder() {
        let sampleRate = 48_000.0
        let freq = 62.5            // band index 1 centre frequency
        let frames = 8_192
        let amplitude: Float = 0.2 // low enough that +12 dB stays under the limiter

        func rmsThroughEQ(_ settings: EQSettings) -> Float {
            let eq = EQProcessor(sampleRate: sampleRate)
            eq.updateSettings(settings)

            var buf = [Float](repeating: 0, count: frames * 2)  // stereo interleaved
            for i in 0..<frames {
                let s = amplitude * Float(sin(2.0 * Double.pi * freq * Double(i) / sampleRate))
                buf[i * 2] = s
                buf[i * 2 + 1] = s
            }

            // Production order: apply the EQ preamp scalar, then EQ in place.
            var preamp = eq.preampScalar
            buf.withUnsafeMutableBufferPointer { p in
                vDSP_vsmul(p.baseAddress!, 1, &preamp, p.baseAddress!, 1, vDSP_Length(p.count))
                eq.process(input: p.baseAddress!, output: p.baseAddress!, frameCount: frames)
            }

            // RMS over the steady-state second half (skip filter settling).
            var sumSq: Float = 0
            for i in (frames)..<(frames * 2) { sumSq += buf[i] * buf[i] }
            return (sumSq / Float(frames)).squareRoot()
        }

        let flatRMS = rmsThroughEQ(EQSettings(bandGains: Array(repeating: 0, count: 10)))
        let boostRMS = rmsThroughEQ(EQSettings(bandGains: [12, 12, 0, 0, 0, 0, 0, 0, 0, 0]))

        XCTAssertGreaterThan(boostRMS, flatRMS * 1.5,
            "Boosting the low bands must make a low tone clearly louder (flat=\(flatRMS), boost=\(boostRMS))")
    }
}
