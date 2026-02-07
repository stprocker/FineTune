// testing/tests/AudioEngineCharacterizationTests.swift
import XCTest
import AppKit
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
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertTrue(AudioEngine.shouldConfirmPermission(from: diagnostics))
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
}
