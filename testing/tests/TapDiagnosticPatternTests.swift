// testing/tests/TapDiagnosticPatternTests.swift
import XCTest
@testable import FineTuneIntegration
@testable import FineTuneCore

/// Tests for characteristic diagnostic signatures of each tap failure mode.
/// Documents the known failure patterns as regression tests.
final class TapDiagnosticPatternTests: XCTestCase {

    func testEQCountersRoundTripThroughTapDiagnostics() {
        let diagnostics = TapDiagnostics(
            callbackCount: 50,
            inputHasData: 40,
            outputWritten: 50,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 50, nonFloatPassthrough: 0,
            emptyInput: 0,
            eqApplied: 123,
            eqBypassed: 7,
            eqBypassNoProcessor: 1,
            eqBypassCrossfade: 2,
            eqBypassNonInterleaved: 3,
            eqBypassChannelMismatch: 4,
            eqBypassBufferCount: 5,
            eqBypassNoOutputData: 6,
            lastInputPeak: 0.3, lastOutputPeak: 0.3,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )

        XCTAssertEqual(diagnostics.eqApplied, 123)
        XCTAssertEqual(diagnostics.eqBypassed, 7)
        XCTAssertEqual(diagnostics.eqBypassNoProcessor, 1)
        XCTAssertEqual(diagnostics.eqBypassCrossfade, 2)
        XCTAssertEqual(diagnostics.eqBypassNonInterleaved, 3)
        XCTAssertEqual(diagnostics.eqBypassChannelMismatch, 4)
        XCTAssertEqual(diagnostics.eqBypassBufferCount, 5)
        XCTAssertEqual(diagnostics.eqBypassNoOutputData, 6)
    }

    // MARK: - Bundle-ID Tap Dead Output Pattern

    /// Bundle-ID tap failure: capture works (input has data) but aggregate output is dead (outPeak=0).
    func testBundleIDTapDeadOutputPattern() {
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
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics),
                       "Bundle-ID dead output pattern must not confirm permission")
        XCTAssertTrue(diagnostics.hasDeadOutput,
                      "Should detect dead output path")
        XCTAssertFalse(diagnostics.hasDeadInput,
                       "Input path is functional in this pattern")
    }

    // MARK: - PID-Only Dead Input Pattern

    /// PID-only tap failure: output works but can't capture audio (input=0).
    func testPIDOnlyDeadInputPattern() {
        let diagnostics = TapDiagnostics(
            callbackCount: 50,
            inputHasData: 0,
            outputWritten: 50,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 50, nonFloatPassthrough: 0,
            emptyInput: 50, lastInputPeak: 0.0, lastOutputPeak: 0.3,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics),
                       "PID-only dead input pattern must not confirm permission")
        XCTAssertTrue(diagnostics.hasDeadInput,
                      "Should detect dead input path")
        XCTAssertFalse(diagnostics.hasDeadOutput,
                       "Output path is functional in this pattern")
    }

    // MARK: - Healthy Tap Pattern

    /// Both input and output working normally.
    func testHealthyTapPattern() {
        let diagnostics = TapDiagnostics(
            callbackCount: 50,
            inputHasData: 40,
            outputWritten: 50,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 50, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.3, lastOutputPeak: 0.3,
            outputBufCount: 1, outputBuf0ByteSize: 4096,
            formatChannels: 2, formatIsFloat: true,
            formatIsInterleaved: true, formatSampleRate: 48000,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 1.0
        )
        XCTAssertTrue(AudioEngine.shouldConfirmPermission(from: diagnostics),
                      "Healthy tap should confirm permission")
        XCTAssertFalse(diagnostics.hasDeadOutput,
                       "Healthy tap should not report dead output")
        XCTAssertFalse(diagnostics.hasDeadInput,
                       "Healthy tap should not report dead input")
    }

    // MARK: - Completely Dead Tap Pattern

    /// Everything zero: tap never started or completely broken.
    func testCompletelyDeadTapPattern() {
        let diagnostics = TapDiagnostics(
            callbackCount: 0,
            inputHasData: 0,
            outputWritten: 0,
            silencedForce: 0, silencedMute: 0,
            converterUsed: 0, converterFailed: 0,
            directFloat: 0, nonFloatPassthrough: 0,
            emptyInput: 0, lastInputPeak: 0.0, lastOutputPeak: 0.0,
            outputBufCount: 0, outputBuf0ByteSize: 0,
            formatChannels: 0, formatIsFloat: false,
            formatIsInterleaved: false, formatSampleRate: 0,
            volume: 1.0, crossfadeActive: false, primaryCurrentVolume: 0.0
        )
        XCTAssertFalse(AudioEngine.shouldConfirmPermission(from: diagnostics),
                       "Completely dead tap must not confirm permission")
        // hasDeadOutput/hasDeadInput require callbackCount > 10, so both false here
        XCTAssertFalse(diagnostics.hasDeadOutput)
        XCTAssertFalse(diagnostics.hasDeadInput)
    }
}
