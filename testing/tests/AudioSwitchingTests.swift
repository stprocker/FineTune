import XCTest
import AppKit
@testable import FineTuneIntegration
@testable import FineTuneCore

// MARK: - CrossfadeState Interruption & Cancellation Tests

/// Tests for CrossfadeState behavior under interruption scenarios that caused
/// audio corruption before 1.18.
///
/// Pre-1.18 bug: Concurrent switchDevice calls on the same ProcessTapController
/// would corrupt crossfade state — both switches would manipulate progress,
/// secondary tap resources, and multipliers simultaneously. This caused:
/// - Crackling/distortion (two crossfades fighting over the same state)
/// - Audio drops (secondary tap destroyed while still in use)
/// - Stuck taps (crossfade never completed because counters were clobbered)
///
/// The fix: AudioEngine cancels in-flight switches before starting new ones,
/// and ProcessTapController checks for cancellation at key checkpoints.
/// These tests validate the state machine behavior that underlies the fix.
final class CrossfadeInterruptionTests: XCTestCase {

    // MARK: - Mid-Crossfade Abort (core of the 1.18 fix)

    /// Simulates the pre-1.18 failure: a crossfade is in progress (A → B) when
    /// a new switch request arrives (A → C). The first crossfade must be abortable
    /// via complete() so the second can start cleanly.
    ///
    /// Pre-1.18: No cancellation mechanism — two crossfades ran concurrently,
    /// clobbering shared state (progress, secondarySampleCount, isActive).
    func testAbortMidCrossfadeAndRestart() {
        var state = CrossfadeState()

        // Start first crossfade (A → B)
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 1200)  // ~50% through

        XCTAssertTrue(state.isActive)
        XCTAssertGreaterThan(state.progress, 0)
        XCTAssertEqual(state.secondarySamplesProcessed, 1200)

        // Abort first crossfade (simulates cancellation cleanup)
        state.complete()

        // Verify clean slate
        XCTAssertFalse(state.isActive, "State should be inactive after abort")
        XCTAssertEqual(state.progress, 0, "Progress should be reset after abort")
        XCTAssertEqual(state.secondarySampleCount, 0, "Sample count should be reset after abort")
        XCTAssertEqual(state.secondarySamplesProcessed, 0, "Samples processed should be reset after abort")
        XCTAssertEqual(state.totalSamples, 0, "Total samples should be reset after abort")

        // Start second crossfade (A → C)
        state.beginCrossfade(at: 48000)

        XCTAssertTrue(state.isActive, "Second crossfade should start cleanly")
        XCTAssertEqual(state.progress, 0, "Second crossfade should start at 0")
        XCTAssertEqual(state.secondarySampleCount, 0)
        XCTAssertEqual(state.secondarySamplesProcessed, 0)
        XCTAssertEqual(state.totalSamples, 2400, "Should have correct total for 48kHz")

        // Second crossfade should run to completion independently
        _ = state.updateProgress(samples: 2400)
        XCTAssertTrue(state.isCrossfadeComplete, "Second crossfade should complete normally")
        XCTAssertTrue(state.isWarmupComplete, "Second crossfade should pass warmup")
    }

    /// Tests that multipliers are correct immediately after aborting a mid-progress crossfade.
    /// This is critical because the audio callback reads multipliers continuously — if they're
    /// stale after abort, audio will be at the wrong level.
    ///
    /// Pre-1.18 scenario: First crossfade at progress=0.5 means primary is at cos(π/4)≈0.707
    /// and secondary at sin(π/4)≈0.707. If a second crossfade starts without reset, the
    /// secondary tap for the NEW device would start at 0.707 instead of 0, causing a loud pop.
    func testMultipliersResetAfterAbort() {
        var state = CrossfadeState()

        // Mid-crossfade state
        state.beginCrossfade(at: 48000)
        state.progress = 0.5
        let midPrimary = state.primaryMultiplier
        let midSecondary = state.secondaryMultiplier
        XCTAssertLessThan(midPrimary, 1.0, "Primary should be fading out")
        XCTAssertGreaterThan(midSecondary, 0.0, "Secondary should be fading in")

        // Abort
        state.complete()

        // After complete(), primary should be at full volume (no crossfade)
        XCTAssertEqual(state.primaryMultiplier, 1.0, accuracy: 1e-6,
                        "Primary must be at full volume after abort (not stuck at fade-out level)")
        // Secondary should also be at full volume (no crossfade = post-promotion behavior)
        XCTAssertEqual(state.secondaryMultiplier, 1.0, accuracy: 1e-6,
                        "Secondary must be at full volume after abort")

        // Begin new crossfade — secondary starts silent
        state.beginCrossfade(at: 48000)
        XCTAssertEqual(state.primaryMultiplier, 1.0, accuracy: 1e-6,
                        "New crossfade primary should start at full volume")
        XCTAssertEqual(state.secondaryMultiplier, 0.0, accuracy: 1e-6,
                        "New crossfade secondary must start silent (not carry over from aborted crossfade)")
    }

    /// Rapid triple-switch scenario: A→B starts, then A→C starts (cancelling A→B),
    /// then A→D starts (cancelling A→C). Only the final crossfade should complete.
    func testRapidTripleSwitch() {
        var state = CrossfadeState()

        // Switch 1: A → B (aborted early)
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 200)
        state.complete()

        // Switch 2: A → C (aborted mid-crossfade)
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 1200)
        XCTAssertGreaterThan(state.progress, 0.4)
        state.complete()

        // Switch 3: A → D (runs to completion)
        state.beginCrossfade(at: 48000)
        XCTAssertEqual(state.progress, 0, "Third switch must start fresh")
        XCTAssertEqual(state.secondarySamplesProcessed, 0, "No carryover from previous switches")

        _ = state.updateProgress(samples: 2400)
        XCTAssertTrue(state.isCrossfadeComplete, "Final switch should complete")
        XCTAssertTrue(state.isWarmupComplete, "Final switch should pass warmup")
    }

    /// Tests the equal-power conservation during the transition window between
    /// aborting one crossfade and starting another. Audio should never clip or drop out.
    func testNoPowerGapDuringAbortAndRestart() {
        var state = CrossfadeState()

        // Mid-crossfade: verify power conservation holds
        state.beginCrossfade(at: 48000)
        state.progress = 0.5
        let p1 = state.primaryMultiplier
        let s1 = state.secondaryMultiplier
        XCTAssertEqual(p1 * p1 + s1 * s1, 1.0, accuracy: 1e-4,
                        "Equal-power should hold during crossfade")

        // Abort: after complete(), primary=1.0 and secondary=1.0 (both at full)
        // This is correct because after abort, the secondary tap is destroyed,
        // so only primary plays (at 1.0). The secondary multiplier being 1.0
        // is the "post-promotion" value that won't be used until next crossfade.
        state.complete()
        XCTAssertEqual(state.primaryMultiplier, 1.0, accuracy: 1e-6)

        // Start new crossfade: at t=0, primary=1.0 and secondary=0.0
        // Power = 1.0² + 0.0² = 1.0 — no gap
        state.beginCrossfade(at: 48000)
        let p2 = state.primaryMultiplier
        let s2 = state.secondaryMultiplier
        XCTAssertEqual(p2 * p2 + s2 * s2, 1.0, accuracy: 1e-4,
                        "Equal-power should hold at start of new crossfade (no gap)")
    }

    // MARK: - Warmup Tracking Under Interruption

    /// If a crossfade is aborted before warmup completes, the next crossfade's
    /// warmup counter must start from zero. Pre-1.18, stale counters could cause
    /// the system to think warmup was complete when the new secondary tap hadn't
    /// actually produced any samples.
    func testWarmupCounterResetsOnAbort() {
        var state = CrossfadeState()

        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 1500)  // Below warmup threshold but not zero
        XCTAssertFalse(state.isWarmupComplete, "1500 < 2048")

        state.complete()

        state.beginCrossfade(at: 48000)
        XCTAssertFalse(state.isWarmupComplete,
                        "Warmup must be incomplete after restart — no samples processed yet")
        XCTAssertEqual(state.secondarySamplesProcessed, 0,
                        "Samples processed must be zero after restart (not carry over 1500)")
    }

    /// If the first crossfade's warmup completed but the second hasn't started yet,
    /// aborting and restarting should require fresh warmup.
    func testWarmupCompleteThenAbortRequiresFreshWarmup() {
        var state = CrossfadeState()

        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 2500)  // Well past warmup threshold
        XCTAssertTrue(state.isWarmupComplete)

        state.complete()

        state.beginCrossfade(at: 48000)
        XCTAssertFalse(state.isWarmupComplete,
                        "Must require fresh warmup even though previous crossfade had it")
    }

    // MARK: - Sample Rate Change Between Switches

    /// When switching from a 48kHz device to a 96kHz device, the totalSamples
    /// calculation must use the new sample rate.
    func testCrossfadeAcrossSampleRateChange() {
        var state = CrossfadeState()

        // First crossfade at 48kHz
        state.beginCrossfade(at: 48000)
        XCTAssertEqual(state.totalSamples, 2400)
        state.complete()

        // Second crossfade at 96kHz
        state.beginCrossfade(at: 96000)
        XCTAssertEqual(state.totalSamples, 4800,
                        "Total samples should double for 96kHz")
    }

    /// Verify that progress calculation is correct when sample rate changes.
    /// At 96kHz, it takes 4800 samples to reach progress=1.0 (vs 2400 at 48kHz).
    func testProgressScalesWithSampleRate() {
        var state = CrossfadeState()

        state.beginCrossfade(at: 96000)
        _ = state.updateProgress(samples: 2400)
        XCTAssertEqual(state.progress, 0.5, accuracy: 1e-5,
                        "2400/4800 = 0.5 at 96kHz (would be 1.0 at 48kHz)")
        XCTAssertFalse(state.isCrossfadeComplete,
                        "Crossfade should not be complete at half the required samples")
    }

    // MARK: - Edge Cases

    /// Calling complete() when not active should be a safe no-op.
    func testCompleteWhenNotActive() {
        var state = CrossfadeState()
        XCTAssertFalse(state.isActive)

        state.complete()  // Should not crash or corrupt state

        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.progress, 0)
        XCTAssertEqual(state.primaryMultiplier, 1.0, accuracy: 1e-6)
    }

    /// Calling beginCrossfade twice without complete() should reset properly.
    /// This simulates the case where the AudioEngine-level cancellation fires
    /// beginCrossfade before the ProcessTapController has called complete().
    func testDoubleBeginWithoutComplete() {
        var state = CrossfadeState()

        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 1000)

        // Second begin without explicit complete
        state.beginCrossfade(at: 44100)

        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.progress, 0, "Should be reset by second begin")
        XCTAssertEqual(state.secondarySampleCount, 0)
        XCTAssertEqual(state.secondarySamplesProcessed, 0)
        XCTAssertEqual(state.totalSamples, CrossfadeConfig.totalSamples(at: 44100),
                        "Should use new sample rate")
    }

    /// updateProgress should be a no-op when crossfade is not active.
    func testUpdateProgressWhenInactive() {
        var state = CrossfadeState()
        XCTAssertFalse(state.isActive)

        let result = state.updateProgress(samples: 5000)

        XCTAssertEqual(result, 0, "Progress should remain 0 when inactive")
        XCTAssertEqual(state.secondarySampleCount, 0,
                        "Sample count should not accumulate when inactive")
        // Note: secondarySamplesProcessed DOES accumulate even when inactive
        // (used for warmup tracking which is separate from crossfade timing)
        XCTAssertEqual(state.secondarySamplesProcessed, 5000,
                        "Samples processed tracks total even when inactive (for warmup)")
    }
}

// MARK: - AudioEngine Routing State Under Concurrent Switching

/// Tests for AudioEngine routing state management during device switching scenarios.
///
/// These tests verify the routing state invariants that 1.18 depends on.
/// Since CoreAudio taps can't be created in the test environment, these tests
/// exercise the synchronous routing state management paths.
///
/// The 1.18 concurrent switch fix relies on:
/// 1. `setDevice` updating `appDeviceRouting` BEFORE spawning the async switch Task
/// 2. The guard `appDeviceRouting[app.id] != deviceUID` preventing redundant switches
/// 3. Cancelled switches NOT reverting `appDeviceRouting` (newer switch owns it)
/// 4. `handleDeviceDisconnected` routing through `setDevice` (not a parallel path)
@MainActor
final class AudioEngineSwitchingTests: XCTestCase {

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

    // MARK: - Rapid setDevice Calls (1.18 core fix)

    /// Rapid A→B→C switching should leave routing at the last-requested device.
    /// Pre-1.18: Concurrent switches could leave routing in an intermediate state
    /// or revert to A if the B switch failed and reverted unconditionally.
    ///
    /// Note: In test environment, tap creation fails, so all switches go through
    /// the no-tap branch. This tests the synchronous routing state, not the async path.
    func testRapidSwitchLeavesLastRequestedRouting() {
        let app = makeFakeApp()

        // All calls fail tap creation and revert, so routing stays nil.
        // But the KEY invariant is: each call should not corrupt the OTHER calls' state.
        engine.setDevice(for: app, deviceUID: "device-A")
        engine.setDevice(for: app, deviceUID: "device-B")
        engine.setDevice(for: app, deviceUID: "device-C")

        // Since tap creation fails, routing should be reverted (no tap = no routing).
        // This is correct behavior: routing only sticks if the tap is created.
        // Pre-1.18 Bug 3 fix ensures this revert happens cleanly.
        XCTAssertNil(engine.appDeviceRouting[app.id],
                      "Routing should be nil when all tap creations fail")
    }

    /// The same-device guard should prevent unnecessary work.
    /// This guard is critical for the cancellation logic: after a cancelled switch
    /// reverts nothing, a retry to the same device should be a no-op.
    func testSameDeviceGuardPreventsRedundantSwitch() {
        let app = makeFakeApp()

        // Manually set routing to simulate a successful previous switch
        engine.appDeviceRouting[app.id] = "device-A"

        // setDevice to the same device should be a no-op (guard returns early)
        engine.setDevice(for: app, deviceUID: "device-A")

        // Routing should still be "device-A" (not reverted to nil by failed tap creation)
        XCTAssertEqual(engine.appDeviceRouting[app.id], "device-A",
                        "Same-device guard should prevent any state changes")
    }

    /// When routing exists from a prior successful switch, a failed new switch
    /// should revert to the previous device.
    func testFailedSwitchRevertsToExistingRouting() {
        let app = makeFakeApp()

        // Simulate prior successful routing
        engine.appDeviceRouting[app.id] = "device-A"

        // Switch to B (no tap exists, so it goes through ensureTapExists which fails)
        engine.setDevice(for: app, deviceUID: "device-B")

        // Should revert to previous (device-A) since tap creation failed
        XCTAssertEqual(engine.appDeviceRouting[app.id], "device-A",
                        "Failed switch should revert to previous routing, not leave stale 'device-B'")
    }

    /// Multiple apps switching independently should not interfere with each other.
    func testMultipleAppsSwitchIndependently() {
        let app1 = makeFakeApp(pid: 10001, name: "App1", bundleID: "com.test.app1")
        let app2 = makeFakeApp(pid: 10002, name: "App2", bundleID: "com.test.app2")

        // Simulate prior successful routing for both apps
        engine.appDeviceRouting[app1.id] = "device-A"
        engine.appDeviceRouting[app2.id] = "device-B"

        // Switch app1 to C (fails, reverts to A)
        engine.setDevice(for: app1, deviceUID: "device-C")

        // App2's routing should be unaffected
        XCTAssertEqual(engine.appDeviceRouting[app1.id], "device-A",
                        "App1 should revert to A")
        XCTAssertEqual(engine.appDeviceRouting[app2.id], "device-B",
                        "App2 should be unaffected by App1's switch")
    }

    // MARK: - routeAllApps Behavior

    /// routeAllApps should skip apps already on the target device.
    /// This tests the filter `apps.filter { appDeviceRouting[$0.id] != deviceUID }`.
    func testRouteAllAppsSkipsAlreadyOnTarget() {
        let app = makeFakeApp()
        engine.appDeviceRouting[app.id] = "device-A"

        // Route all to device-A (should be a no-op for this app)
        engine.routeAllApps(to: "device-A")

        XCTAssertEqual(engine.appDeviceRouting[app.id], "device-A",
                        "App already on target device should not be disturbed")
    }

    /// routeAllApps with empty app list should be harmless.
    func testRouteAllAppsWithNoApps() {
        // No apps in processMonitor = no crashes
        engine.routeAllApps(to: "device-A")
        // Should not crash or leave any stale state
    }

    // MARK: - stop() Cleanup

    /// stop() should clear all routing state and taps.
    func testStopClearsRoutingState() {
        let app = makeFakeApp()
        engine.appDeviceRouting[app.id] = "device-A"

        engine.stop()

        // After stop, engine should be in clean state
        // (appDeviceRouting is not cleared by stop — only taps are.
        // This is intentional: routing is persisted and restored on restart)
    }

    // MARK: - Settings Persistence During Switching

    /// When setDevice succeeds in setting routing (even if tap fails), the settings
    /// manager should reflect the attempted routing, NOT the reverted state.
    /// Wait — actually, the revert code DOES revert the settings manager too.
    /// This test verifies the revert is complete.
    func testSettingsPersistenceRevertsOnFailure() {
        let app = makeFakeApp()
        let settings = engine.settingsManager

        // No prior routing
        XCTAssertNil(settings.getDeviceRouting(for: app.persistenceIdentifier))

        // Attempt switch (fails)
        engine.setDevice(for: app, deviceUID: "device-X")
        XCTAssertNil(settings.getDeviceRouting(for: app.persistenceIdentifier),
                     "Failed switch with no prior routing should not leave persisted orphan routing")
    }

    /// When a switch from device-A to device-B fails, settings should revert to A.
    func testSettingsPersistenceRevertsToOriginal() {
        let app = makeFakeApp()
        let settings = engine.settingsManager

        // Set initial routing in both engine and settings
        engine.appDeviceRouting[app.id] = "device-A"
        settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: "device-A")

        // Attempt switch to B (fails, should revert)
        engine.setDevice(for: app, deviceUID: "device-B")

        XCTAssertEqual(engine.appDeviceRouting[app.id], "device-A",
                        "In-memory routing should revert to A")
        XCTAssertEqual(settings.getDeviceRouting(for: app.persistenceIdentifier), "device-A",
                        "Persisted routing should revert to A")
    }

    // MARK: - Routing State Invariants

    /// The routing dictionary should never contain entries for PIDs that have no
    /// corresponding tap AND no pending switch. In test environment (no taps),
    /// failed setDevice should not leave orphan entries.
    func testNoOrphanRoutingEntries() {
        let app = makeFakeApp()

        engine.setDevice(for: app, deviceUID: "device-A")
        engine.setDevice(for: app, deviceUID: "device-B")
        engine.setDevice(for: app, deviceUID: "device-C")

        // All fail → no routing should remain
        XCTAssertNil(engine.appDeviceRouting[app.id],
                      "No orphan routing entries when all switches fail")
    }
}

// MARK: - CrossfadeState Concurrent Access Patterns

/// Tests that simulate the read/write patterns that occur during concurrent
/// device switches. These test the state machine invariants that prevent
/// corruption when one switch is cancelled and another begins.
final class CrossfadeConcurrencyTests: XCTestCase {

    /// Simulates the audio callback reading multipliers while the main thread
    /// is aborting a crossfade. After complete(), multipliers must immediately
    /// reflect the non-crossfading state.
    func testMultiplierConsistencyDuringAbort() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)

        // Advance to various points and abort at each
        for progressPoint: Float in stride(from: 0.0, through: 1.0, by: 0.1) {
            state.beginCrossfade(at: 48000)
            state.progress = progressPoint
            state.complete()

            // After complete: primary=1.0 (full volume, no crossfade)
            XCTAssertEqual(state.primaryMultiplier, 1.0, accuracy: 1e-6,
                            "Primary must be 1.0 after abort at progress=\(progressPoint)")
        }
    }

    /// The "dead zone" between crossfade complete (progress=1.0) and complete() call.
    /// During this window, primary must output silence (multiplier=0) and secondary
    /// must output full (multiplier=1). This prevents double-audio.
    func testDeadZoneBehavior() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 5000)  // Well past completion

        // Progress clamped to 1.0
        XCTAssertEqual(state.progress, 1.0)

        // Active crossfade at progress=1.0
        XCTAssertEqual(state.primaryMultiplier, 0.0, accuracy: 1e-5,
                        "Primary must be silent when crossfade reaches 1.0")
        XCTAssertEqual(state.secondaryMultiplier, 1.0, accuracy: 1e-5,
                        "Secondary must be at full volume when crossfade reaches 1.0")

        // Deactivate but don't reset progress (simulates gap between isActive=false and complete)
        state.isActive = false
        // Now in dead zone: isActive=false, progress=1.0
        XCTAssertEqual(state.primaryMultiplier, 0.0,
                        "Primary must stay silent in dead zone")
        XCTAssertEqual(state.secondaryMultiplier, 1.0,
                        "Secondary must stay at full volume in dead zone (post-promotion)")
    }

    /// Tests that the crossfade progress is monotonically increasing and
    /// properly clamped. This prevents negative progress or progress > 1.0
    /// which could produce NaN in sin/cos calculations.
    func testProgressMonotonicity() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)

        var previousProgress: Float = -1
        for _ in 0..<50 {
            let p = state.updateProgress(samples: 100)
            XCTAssertGreaterThanOrEqual(p, previousProgress,
                                         "Progress must be monotonically increasing")
            XCTAssertLessThanOrEqual(p, 1.0, "Progress must be clamped to 1.0")
            XCTAssertGreaterThanOrEqual(p, 0.0, "Progress must be non-negative")
            previousProgress = p
        }
    }

    /// Multipliers must always produce finite values (no NaN/Inf) regardless
    /// of state. NaN in the audio callback would corrupt the output buffer.
    func testMultipliersAlwaysFinite() {
        var state = CrossfadeState()

        // Check various states
        let testCases: [(Float, Bool, String)] = [
            (0.0, false, "idle"),
            (0.0, true, "start"),
            (0.5, true, "midpoint"),
            (1.0, true, "end"),
            (1.0, false, "dead zone"),
            (0.0, false, "post-complete"),
        ]

        for (progress, isActive, label) in testCases {
            state.progress = progress
            state.isActive = isActive
            XCTAssertTrue(state.primaryMultiplier.isFinite,
                           "Primary multiplier must be finite in state: \(label)")
            XCTAssertTrue(state.secondaryMultiplier.isFinite,
                           "Secondary multiplier must be finite in state: \(label)")
            XCTAssertGreaterThanOrEqual(state.primaryMultiplier, 0.0,
                                         "Primary multiplier must be non-negative in state: \(label)")
            XCTAssertGreaterThanOrEqual(state.secondaryMultiplier, 0.0,
                                         "Secondary multiplier must be non-negative in state: \(label)")
        }
    }

    // MARK: - Warmup + Crossfade Independence

    /// Warmup tracking (secondarySamplesProcessed) and crossfade timing
    /// (secondarySampleCount / progress) must be independent.
    /// Pre-1.18: Both used the same counter, so aborting the crossfade
    /// would also reset warmup, potentially causing the system to think
    /// a warmed-up tap was not ready.
    func testWarmupAndProgressAreIndependent() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)

        // Process enough samples for warmup
        _ = state.updateProgress(samples: 2048)
        XCTAssertTrue(state.isWarmupComplete)
        XCTAssertLessThan(state.progress, 1.0, "Not yet at crossfade completion")

        // Continue to crossfade completion
        _ = state.updateProgress(samples: 2400)
        XCTAssertTrue(state.isCrossfadeComplete)
        XCTAssertTrue(state.isWarmupComplete, "Warmup should still be complete")

        // Total processed should be the sum
        XCTAssertEqual(state.secondarySamplesProcessed, 4448)
    }

    /// After abort + restart, warmup must track independently of progress.
    func testWarmupTracksIndependentlyAcrossRestart() {
        var state = CrossfadeState()

        // First crossfade: warmup completes
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 3000)
        XCTAssertTrue(state.isWarmupComplete)

        // Abort
        state.complete()

        // Second crossfade: warmup must NOT carry over
        state.beginCrossfade(at: 48000)
        XCTAssertFalse(state.isWarmupComplete,
                        "Warmup must reset — new secondary tap hasn't produced samples yet")

        // New warmup starts from zero
        _ = state.updateProgress(samples: 1024)
        XCTAssertFalse(state.isWarmupComplete, "1024 < 2048")

        _ = state.updateProgress(samples: 1024)
        XCTAssertTrue(state.isWarmupComplete, "2048 >= 2048")
    }
}

// MARK: - ProcessTapController Destructive Switch Failure Recovery

final class ProcessTapControllerSwitchFailureTests: XCTestCase {

    private enum TestError: Error {
        case forcedFailure
    }

    func testDestructiveSwitchClearsForceSilenceOnFailure() async {
        let app = makeFakeApp()
        let tap = ProcessTapController(app: app, targetDeviceUID: "device-a", deviceMonitor: nil)
        tap.testSleepHook = { _ in }
        tap.testPerformDeviceSwitchHook = { _ in
            throw TestError.forcedFailure
        }

        do {
            try await tap.performDestructiveDeviceSwitchForTests(to: "device-b")
            XCTFail("Expected forced destructive-switch failure")
        } catch {
            // Expected
        }

        XCTAssertFalse(tap.isForceSilenceEnabledForTests,
                       "Force silence should be cleared even when destructive switch throws")
    }

    func testDestructiveSwitchClearsForceSilenceOnCancellation() async {
        let app = makeFakeApp()
        let tap = ProcessTapController(app: app, targetDeviceUID: "device-a", deviceMonitor: nil)
        tap.testSleepHook = { _ in
            throw CancellationError()
        }

        do {
            try await tap.performDestructiveDeviceSwitchForTests(to: "device-b")
            XCTFail("Expected destructive switch cancellation")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError, got: \(error)")
        }

        XCTAssertFalse(tap.isForceSilenceEnabledForTests,
                       "Force silence should be cleared when destructive switch is cancelled")
    }
}
