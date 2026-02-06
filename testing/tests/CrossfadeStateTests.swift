import XCTest
@testable import FineTuneCore

final class CrossfadeStateTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let state = CrossfadeState()
        XCTAssertEqual(state.progress, 0)
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.secondarySampleCount, 0)
        XCTAssertEqual(state.totalSamples, 0)
        XCTAssertEqual(state.secondarySamplesProcessed, 0)
    }

    // MARK: - Warmup Detection (Bug 2 foundation)
    //
    // Bug 2: performCrossfadeSwitch previously promoted the secondary tap
    // after timeout even if the secondary callback never fired (e.g., BT device
    // not ready). The fix checks isWarmupComplete before promoting.
    // These tests validate the detection mechanism.

    func testWarmupIncompleteWhenNoSamplesProcessed() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        XCTAssertFalse(state.isWarmupComplete,
                        "Warmup should be incomplete with zero samples processed")
    }

    func testWarmupIncompleteJustBelowThreshold() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: CrossfadeState.minimumWarmupSamples - 1)
        XCTAssertFalse(state.isWarmupComplete,
                        "Warmup should be incomplete at \(CrossfadeState.minimumWarmupSamples - 1) samples")
    }

    func testWarmupCompleteAtExactThreshold() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: CrossfadeState.minimumWarmupSamples)
        XCTAssertTrue(state.isWarmupComplete,
                       "Warmup should be complete at exactly \(CrossfadeState.minimumWarmupSamples) samples")
    }

    func testWarmupCompleteAboveThreshold() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: CrossfadeState.minimumWarmupSamples + 1000)
        XCTAssertTrue(state.isWarmupComplete)
    }

    func testMinimumWarmupSamplesIsReasonable() {
        XCTAssertEqual(CrossfadeState.minimumWarmupSamples, 2048)
        let durationMs = Double(CrossfadeState.minimumWarmupSamples) / 48000.0 * 1000.0
        XCTAssertGreaterThan(durationMs, 40, "Warmup should be at least 40ms at 48kHz")
        XCTAssertLessThan(durationMs, 50, "Warmup should be less than 50ms at 48kHz")
    }

    // MARK: - Bug 2 Scenario: Non-Functioning Secondary Tap

    /// Simulates the exact Bug 2 scenario: secondary tap created but IO callback
    /// never fired (BT device not ready). After timeout we must detect warmup
    /// is incomplete so the caller can fall back to destructive switch.
    func testBug2ScenarioSecondaryNeverFires() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        // Simulate: time passes but secondary callback never runs
        XCTAssertFalse(state.isWarmupComplete,
                        "Bug 2: Should detect that secondary never processed any samples")
        XCTAssertFalse(state.isCrossfadeComplete,
                        "Crossfade should not be complete without any progress")
        XCTAssertEqual(state.secondarySamplesProcessed, 0)
    }

    /// Partial warmup: secondary produced some samples but below threshold.
    func testBug2ScenarioPartialWarmup() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 512)
        XCTAssertFalse(state.isWarmupComplete,
                        "512 samples < 2048 minimum — warmup should be incomplete")
    }

    /// Successful warmup: secondary produced enough samples.
    func testBug2ScenarioSuccessfulWarmup() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 1024)
        _ = state.updateProgress(samples: 1024)
        XCTAssertTrue(state.isWarmupComplete,
                       "2048 samples >= minimum — warmup should be complete")
    }

    // MARK: - Primary Multiplier (equal-power fade-out)

    func testPrimaryMultiplierIdleIsUnity() {
        let state = CrossfadeState()
        XCTAssertEqual(state.primaryMultiplier, 1.0, accuracy: 1e-6)
    }

    func testPrimaryMultiplierAtCrossfadeStart() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        // Active, progress = 0 → cos(0) = 1.0
        XCTAssertEqual(state.primaryMultiplier, 1.0, accuracy: 1e-6)
    }

    func testPrimaryMultiplierAtMidpoint() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        state.progress = 0.5
        let expected = cos(0.5 * Float.pi / 2.0)
        XCTAssertEqual(state.primaryMultiplier, expected, accuracy: 1e-5)
    }

    func testPrimaryMultiplierAtEnd() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        state.progress = 1.0
        XCTAssertEqual(state.primaryMultiplier, 0.0, accuracy: 1e-5,
                        "Primary should be silent at end of crossfade")
    }

    /// The "dead zone": crossfade deactivated but progress still >= 1.0.
    /// Primary must stay silent until state is fully reset by complete().
    func testPrimaryMultiplierDeadZone() {
        var state = CrossfadeState()
        state.isActive = false
        state.progress = 1.0
        XCTAssertEqual(state.primaryMultiplier, 0.0,
                        "Primary should be silent in dead zone (isActive=false, progress>=1.0)")
    }

    func testPrimaryMultiplierAfterComplete() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        state.progress = 1.0
        state.complete()
        // complete() resets: isActive=false, progress=0 → returns 1.0
        XCTAssertEqual(state.primaryMultiplier, 1.0, accuracy: 1e-6,
                        "After complete(), primary should be at full volume")
    }

    // MARK: - Secondary Multiplier (equal-power fade-in)

    func testSecondaryMultiplierAtCrossfadeStart() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        // Active, progress = 0 → sin(0) = 0.0
        XCTAssertEqual(state.secondaryMultiplier, 0.0, accuracy: 1e-6)
    }

    func testSecondaryMultiplierAtMidpoint() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        state.progress = 0.5
        let expected = sin(0.5 * Float.pi / 2.0)
        XCTAssertEqual(state.secondaryMultiplier, expected, accuracy: 1e-5)
    }

    func testSecondaryMultiplierAtEnd() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        state.progress = 1.0
        XCTAssertEqual(state.secondaryMultiplier, 1.0, accuracy: 1e-5,
                        "Secondary should be at full volume at end of crossfade")
    }

    func testSecondaryMultiplierWhenNotActive() {
        let state = CrossfadeState()
        // After promotion, secondary (now primary) should be full volume
        XCTAssertEqual(state.secondaryMultiplier, 1.0, accuracy: 1e-6)
    }

    // MARK: - Equal-Power Conservation

    func testEqualPowerConservation() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        // At any point: primary² + secondary² ≈ 1.0 (equal-power property)
        for i in 0...10 {
            state.progress = Float(i) / 10.0
            let p = state.primaryMultiplier
            let s = state.secondaryMultiplier
            let powerSum = p * p + s * s
            XCTAssertEqual(powerSum, 1.0, accuracy: 1e-4,
                            "Equal-power conservation violated at progress=\(state.progress)")
        }
    }

    // MARK: - Progress Tracking

    func testUpdateProgressAccumulatesSamples() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        // At 48kHz with 50ms duration: totalSamples = 2400
        XCTAssertEqual(state.totalSamples, 2400)

        _ = state.updateProgress(samples: 480)
        XCTAssertEqual(state.secondarySamplesProcessed, 480)
        XCTAssertEqual(state.secondarySampleCount, 480)
        XCTAssertEqual(state.progress, Float(480) / Float(2400), accuracy: 1e-6)
    }

    func testUpdateProgressIncrementalAccumulation() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 1000)
        _ = state.updateProgress(samples: 1000)
        XCTAssertEqual(state.secondarySamplesProcessed, 2000)
        XCTAssertEqual(state.secondarySampleCount, 2000)
    }

    func testProgressClampedToOne() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 10000)
        XCTAssertEqual(state.progress, 1.0, "Progress should be clamped to 1.0")
    }

    func testIsCrossfadeCompleteAtFullProgress() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 10000)
        XCTAssertTrue(state.isCrossfadeComplete)
    }

    func testIsCrossfadeCompleteBeforeFullProgress() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 100)
        XCTAssertFalse(state.isCrossfadeComplete)
    }

    // MARK: - beginCrossfade / complete Lifecycle

    func testBeginCrossfadeResetsState() {
        var state = CrossfadeState()
        // Dirty the state
        state.progress = 0.5
        state.secondarySampleCount = 999
        state.secondarySamplesProcessed = 999
        state.isActive = false

        state.beginCrossfade(at: 48000)

        XCTAssertEqual(state.progress, 0)
        XCTAssertEqual(state.secondarySampleCount, 0)
        XCTAssertEqual(state.secondarySamplesProcessed, 0)
        XCTAssertTrue(state.isActive)
        XCTAssertGreaterThan(state.totalSamples, 0)
    }

    func testCompleteResetsAllState() {
        var state = CrossfadeState()
        state.beginCrossfade(at: 48000)
        _ = state.updateProgress(samples: 5000)

        state.complete()

        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.progress, 0)
        XCTAssertEqual(state.secondarySampleCount, 0)
        XCTAssertEqual(state.secondarySamplesProcessed, 0)
        XCTAssertEqual(state.totalSamples, 0)
    }

    // MARK: - CrossfadeConfig

    func testDefaultDuration() {
        XCTAssertEqual(CrossfadeConfig.defaultDuration, 0.050, accuracy: 1e-6,
                        "Default crossfade should be 50ms")
    }

    func testTotalSamplesAt48kHz() {
        XCTAssertEqual(CrossfadeConfig.totalSamples(at: 48000), 2400)
    }

    func testTotalSamplesAt44100Hz() {
        XCTAssertEqual(CrossfadeConfig.totalSamples(at: 44100), 2205)
    }

    func testTotalSamplesAt96kHz() {
        XCTAssertEqual(CrossfadeConfig.totalSamples(at: 96000), 4800)
    }
}
