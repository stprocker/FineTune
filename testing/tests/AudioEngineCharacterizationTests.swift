// testing/tests/AudioEngineCharacterizationTests.swift
import XCTest
import AppKit
import AudioToolbox
@testable import FineTuneIntegration
@testable import FineTuneCore

/// Characterization tests for AudioEngine state management and display logic.
/// Validates current behavior before structural refactoring.
/// Note: Heavy routing/switching/startup tests exist in separate test files.
@MainActor
final class AudioEngineCharacterizationTests: XCTestCase {

    // MARK: - Permission Confirmation Logic

    func testShouldConfirmPermissionRequiresMinCallbacks() {
        let diagnostics = TapDiagnostics(
            callbackCount: 5, // too few
            inputHasData: 5,
            outputWritten: 5,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.5, lastOutputPeak: 0.5,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics))
    }

    func testShouldConfirmPermissionRequiresOutput() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 25,
            outputWritten: 0, // no output
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.5, lastOutputPeak: 0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics))
    }

    func testShouldConfirmPermissionRequiresAudibleOutputPeak() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 25,
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 25, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.5, lastOutputPeak: 0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics))
    }

    func testShouldConfirmPermissionRequiresInputData() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 0, // no input data
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0, lastOutputPeak: 0.5,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics))
    }

    func testShouldConfirmPermissionSucceedsWithInputData() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 10,
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.5, lastOutputPeak: 0.5,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertTrue(AudioEngine.shouldConfirmPermission(from: diagnostics))
    }

    func testShouldConfirmPermissionSucceedsWithInputPeak() {
        // Even if inputHasData is 0, non-zero lastInputPeak confirms permission
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 0,
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.001, lastOutputPeak: 0.5,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertTrue(AudioEngine.shouldConfirmPermission(from: diagnostics))
    }

    // MARK: - Dead Output Detection

    /// Bundle-ID tap failure signature: callbacks run, input captured, output written,
    /// but output peak is zero (audio never reaches hardware).
    func testShouldConfirmPermissionRejectsDeadOutput() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 10,
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.5, lastOutputPeak: 0.0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics),
                       "Dead output (outPeak=0) should not confirm permission")
    }

    /// Noise-floor output peak should not confirm permission.
    func testShouldConfirmPermissionRejectsTinyOutputPeak() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 10,
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.5, lastOutputPeak: 0.00005,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics),
                       "Noise-floor output peak should not confirm permission")
    }

    /// Real output peak above threshold should confirm permission.
    func testShouldConfirmPermissionAcceptsRealOutputPeak() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 10,
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.5, lastOutputPeak: 0.001,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertTrue(AudioEngine.shouldConfirmPermission(from: diagnostics),
                      "Real output peak should confirm permission")
    }

    /// Many output writes but zero peak = buffers not connected to hardware.
    func testShouldConfirmPermissionRejectsOutputWrittenWithZeroPeak() {
        let diagnostics = TapDiagnostics(
            callbackCount: 100,
            inputHasData: 50,
            outputWritten: 100,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.3, lastOutputPeak: 0.0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics),
                       "Output writes with zero peak = disconnected buffers")
    }

    /// Volume=0 legitimately produces zero output peak — don't block permission.
    func testShouldConfirmPermissionAllowsZeroOutputPeakWhenMuted() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 10,
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.5, lastOutputPeak: 0.0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 0.0, crossfadeActive: false, primaryCurrentVolume: 0.0
        )
        XCTAssertTrue(AudioEngine.shouldConfirmPermission(from: diagnostics),
                      "Zero output peak is expected when volume=0")
    }

    /// Volume=1.0 but dead output should reject permission.
    func testShouldConfirmPermissionRequiresOutputPeakWhenAudible() {
        let diagnostics = TapDiagnostics(
            callbackCount: 25,
            inputHasData: 10,
            outputWritten: 25,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.5, lastOutputPeak: 0.0,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics),
                       "Audible volume with zero output peak = dead output path")
    }

    // MARK: - Injectable Timing

    func testDefaultTimingValues() {
        let engine = AudioEngine(
            defaultOutputDeviceUIDProvider: { "test-uid" },
            isProcessRunningProvider: { _ in false }
        )
        XCTAssertEqual(engine.diagnosticPollInterval, .seconds(3))
        XCTAssertEqual(engine.startupTapDelay, .seconds(2))
        XCTAssertEqual(engine.staleTapGracePeriod, .seconds(1))
        XCTAssertEqual(engine.serviceRestartDelay, .milliseconds(1500))
        XCTAssertEqual(engine.fastHealthCheckIntervals.count, 3)
    }

    func testTimingSeamsAreInjectable() {
        let engine = AudioEngine(
            defaultOutputDeviceUIDProvider: { "test-uid" },
            isProcessRunningProvider: { _ in false }
        )
        engine.diagnosticPollInterval = .milliseconds(10)
        engine.startupTapDelay = .zero
        engine.staleTapGracePeriod = .zero
        engine.serviceRestartDelay = .zero
        engine.fastHealthCheckIntervals = []

        XCTAssertEqual(engine.diagnosticPollInterval, .milliseconds(10))
        XCTAssertEqual(engine.startupTapDelay, .zero)
        XCTAssertTrue(engine.fastHealthCheckIntervals.isEmpty)
    }

    // MARK: - Recreation Snapshot

    func testTransactionSnapshotRestoreRoundTripsRoutingAndSelectionState() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settings = SettingsManager(directory: tempDir)
        let engine = AudioEngine(
            settingsManager: settings,
            defaultOutputDeviceUIDProvider: { "speakers" },
            isProcessRunningProvider: { _ in false }
        )
        defer { engine.stop() }

        let spotify = makeFakeApp(pid: 18001, name: "Spotify", bundleID: "com.spotify")
        let chrome = makeFakeApp(pid: 18002, name: "Chrome", bundleID: "com.chrome")
        engine.updateDisplayedAppsStateForTests(activeApps: [spotify, chrome])

        engine.appDeviceRouting[spotify.id] = "headphones"
        settings.setDeviceRouting(for: spotify.persistenceIdentifier, deviceUID: "headphones")
        settings.setDeviceRouting(for: chrome.persistenceIdentifier, deviceUID: "speakers")
        engine.volumeState.setDeviceSelectionMode(for: spotify.id, to: .multi, identifier: spotify.persistenceIdentifier)
        engine.volumeState.setSelectedDeviceUIDs(for: spotify.id, to: ["headphones", "speakers"], identifier: spotify.persistenceIdentifier)
        engine.markFollowsDefaultForTests([chrome.id])

        engine.captureTransactionSnapshotForTests()

        engine.appDeviceRouting[spotify.id] = "display"
        settings.setDeviceRouting(for: spotify.persistenceIdentifier, deviceUID: "display")
        settings.clearDeviceRouting(for: chrome.persistenceIdentifier)
        engine.volumeState.setDeviceSelectionMode(for: spotify.id, to: .single, identifier: spotify.persistenceIdentifier)
        engine.volumeState.setSelectedDeviceUIDs(for: spotify.id, to: ["display"], identifier: spotify.persistenceIdentifier)
        engine.markFollowsDefaultForTests([])

        engine.restoreTransactionSnapshotForTests()

        XCTAssertEqual(engine.appDeviceRoutingSnapshotForTests(), [spotify.id: "headphones"])
        XCTAssertEqual(engine.followsDefaultSnapshotForTests(), [chrome.id])
        XCTAssertEqual(settings.getDeviceRouting(for: spotify.persistenceIdentifier), "headphones")
        XCTAssertEqual(settings.getDeviceRouting(for: chrome.persistenceIdentifier), "speakers")
        XCTAssertEqual(engine.volumeState.getDeviceSelectionMode(for: spotify.id), .multi)
        XCTAssertEqual(engine.volumeState.getSelectedDeviceUIDs(for: spotify.id), Set(["headphones", "speakers"]))
        XCTAssertEqual(settings.getDeviceSelectionMode(for: spotify.persistenceIdentifier), .multi)
        XCTAssertEqual(settings.getSelectedDeviceUIDs(for: spotify.persistenceIdentifier), Set(["headphones", "speakers"]))
    }

    func testTapConstructionUsesPermissionConfirmedForMuteOriginal() {
        func observedMuteOriginal(permissionConfirmed: Bool, pid: pid_t) -> Bool? {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let settings = SettingsManager(directory: tempDir)
            let engine = AudioEngine(
                settingsManager: settings,
                defaultOutputDeviceUIDProvider: { "speakers" },
                isProcessRunningProvider: { _ in false }
            )
            defer { engine.stop() }
            engine.deviceMonitor.setOutputDevicesForTests([
                AudioDevice(id: AudioDeviceID(1), uid: "speakers", name: "Speakers", icon: nil),
            ])
            engine.setPermissionConfirmedForTests(permissionConfirmed)

            let app = makeFakeApp(pid: pid, name: "Spotify", bundleID: "com.spotify.\(pid)")
            settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: "speakers")

            var observed: Bool?
            engine.onTapConstructedForTests = { constructedApp, muteOriginal in
                if constructedApp.id == app.id {
                    observed = muteOriginal
                }
            }

            engine.applyPersistedSettingsForTests(apps: [app])
            return observed
        }

        XCTAssertEqual(observedMuteOriginal(permissionConfirmed: false, pid: 20001), false)
        XCTAssertEqual(observedMuteOriginal(permissionConfirmed: true, pid: 20002), true)
    }
}
