import XCTest
import AudioToolbox
@testable import FineTuneCore

final class GainProcessorTests: XCTestCase {

    // MARK: - Interleaved Stereo

    func testInterleavedStereoUnityGain() {
        // Input: L0, R0, L1, R1 (interleaved stereo)
        let inputData: [Float] = [0.5, -0.3, 0.7, -0.1]
        let outputData: [Float] = [0, 0, 0, 0]

        let inputABL = makeBufferList(data: [inputData], interleaved: true)
        let outputABL = makeBufferList(data: [outputData], interleaved: true)
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        var currentVolume: Float = 1.0
        GainProcessor.processFloatBuffers(
            channelCount: 2,
            isInterleaved: true,
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL),
            targetVolume: 1.0,
            currentVolume: &currentVolume,
            rampCoefficient: 1.0,
            crossfadeMultiplier: 1.0,
            compensation: 1.0
        )

        let output = readBuffer(outputABL)
        for (i, (inp, out)) in zip(inputData, output).enumerated() {
            XCTAssertEqual(out, inp, accuracy: 0.01, "Sample \(i): expected \(inp), got \(out)")
        }
    }

    func testInterleavedStereoHalfVolume() {
        let inputData: [Float] = [1.0, 1.0, 1.0, 1.0]
        let outputData: [Float] = [0, 0, 0, 0]

        let inputABL = makeBufferList(data: [inputData], interleaved: true)
        let outputABL = makeBufferList(data: [outputData], interleaved: true)
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        var currentVolume: Float = 0.5
        GainProcessor.processFloatBuffers(
            channelCount: 2,
            isInterleaved: true,
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL),
            targetVolume: 0.5,
            currentVolume: &currentVolume,
            rampCoefficient: 1.0,
            crossfadeMultiplier: 1.0,
            compensation: 1.0
        )

        let output = readBuffer(outputABL)
        for sample in output {
            XCTAssertEqual(sample, 0.5, accuracy: 0.01)
        }
    }

    // MARK: - Volume Ramping

    func testVolumeRampingConverges() {
        let frameCount = 256
        let inputData: [Float] = Array(repeating: 1.0, count: frameCount * 2) // stereo interleaved
        let outputData: [Float] = Array(repeating: 0, count: frameCount * 2)

        let inputABL = makeBufferList(data: [inputData], interleaved: true)
        let outputABL = makeBufferList(data: [outputData], interleaved: true)
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        var currentVolume: Float = 0.0
        let rampCoeff = VolumeRamper.computeCoefficient(sampleRate: 44100, rampTime: 0.030)

        GainProcessor.processFloatBuffers(
            channelCount: 2,
            isInterleaved: true,
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL),
            targetVolume: 1.0,
            currentVolume: &currentVolume,
            rampCoefficient: rampCoeff,
            crossfadeMultiplier: 1.0,
            compensation: 1.0
        )

        let output = readBuffer(outputABL)
        // First sample should be near zero (starting from 0)
        XCTAssertLessThan(output[0], 0.1, "First sample should be near zero during ramp")
        // Last samples should be greater than first (ramping up)
        XCTAssertGreaterThan(output.last!, output[0], "Last sample should be greater than first (ramping)")
        // currentVolume should have moved toward target
        XCTAssertGreaterThan(currentVolume, 0.0, "Current volume should have ramped up from zero")
    }

    // MARK: - Crossfade Multiplier

    func testCrossfadeMultiplierScalesOutput() {
        let inputData: [Float] = [1.0, 1.0, 1.0, 1.0]
        let outputData: [Float] = [0, 0, 0, 0]

        let inputABL = makeBufferList(data: [inputData], interleaved: true)
        let outputABL = makeBufferList(data: [outputData], interleaved: true)
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        var currentVolume: Float = 1.0
        GainProcessor.processFloatBuffers(
            channelCount: 2,
            isInterleaved: true,
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL),
            targetVolume: 1.0,
            currentVolume: &currentVolume,
            rampCoefficient: 1.0,
            crossfadeMultiplier: 0.5,
            compensation: 1.0
        )

        let output = readBuffer(outputABL)
        for sample in output {
            XCTAssertEqual(sample, 0.5, accuracy: 0.01, "Crossfade 0.5 should halve output")
        }
    }

    // MARK: - Compensation

    func testCompensationScalesOutput() {
        let inputData: [Float] = [1.0, 1.0, 1.0, 1.0]
        let outputData: [Float] = [0, 0, 0, 0]

        let inputABL = makeBufferList(data: [inputData], interleaved: true)
        let outputABL = makeBufferList(data: [outputData], interleaved: true)
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        var currentVolume: Float = 1.0
        GainProcessor.processFloatBuffers(
            channelCount: 2,
            isInterleaved: true,
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL),
            targetVolume: 1.0,
            currentVolume: &currentVolume,
            rampCoefficient: 1.0,
            crossfadeMultiplier: 1.0,
            compensation: 0.75
        )

        let output = readBuffer(outputABL)
        for sample in output {
            XCTAssertEqual(sample, 0.75, accuracy: 0.01)
        }
    }

    // MARK: - Soft Limiting

    func testSoftLimitingEngagesAboveUnity() {
        let inputData: [Float] = [1.0, 1.0, 1.0, 1.0]
        let outputData: [Float] = [0, 0, 0, 0]

        let inputABL = makeBufferList(data: [inputData], interleaved: true)
        let outputABL = makeBufferList(data: [outputData], interleaved: true)
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        var currentVolume: Float = 1.5
        GainProcessor.processFloatBuffers(
            channelCount: 2,
            isInterleaved: true,
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL),
            targetVolume: 1.5,
            currentVolume: &currentVolume,
            rampCoefficient: 1.0,
            crossfadeMultiplier: 1.0,
            compensation: 1.0
        )

        let output = readBuffer(outputABL)
        for sample in output {
            // With 1.5x gain on 1.0 input, raw output would be 1.5.
            // SoftLimiter should compress this below ceiling (1.0)
            XCTAssertLessThanOrEqual(sample, SoftLimiter.ceiling, "Should be limited to ceiling")
            XCTAssertGreaterThan(sample, SoftLimiter.threshold, "Should be above threshold")
        }
    }

    func testNoLimitingBelowUnity() {
        let inputData: [Float] = [0.5, 0.5, 0.5, 0.5]
        let outputData: [Float] = [0, 0, 0, 0]

        let inputABL = makeBufferList(data: [inputData], interleaved: true)
        let outputABL = makeBufferList(data: [outputData], interleaved: true)
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        var currentVolume: Float = 0.8
        GainProcessor.processFloatBuffers(
            channelCount: 2,
            isInterleaved: true,
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL),
            targetVolume: 0.8,
            currentVolume: &currentVolume,
            rampCoefficient: 1.0,
            crossfadeMultiplier: 1.0,
            compensation: 1.0
        )

        let output = readBuffer(outputABL)
        for sample in output {
            // 0.5 * 0.8 = 0.4 (no limiting needed since targetVolume <= 1.0)
            XCTAssertEqual(sample, 0.4, accuracy: 0.01)
        }
    }

    // MARK: - Non-interleaved stereo

    func testNonInterleavedStereoUnityGain() {
        let leftData: [Float] = [0.5, 0.7, 0.3, 0.9]
        let rightData: [Float] = [-0.3, -0.1, 0.4, -0.8]
        let outLeft: [Float] = [0, 0, 0, 0]
        let outRight: [Float] = [0, 0, 0, 0]

        let inputABL = makeBufferList(data: [leftData, rightData], interleaved: false)
        let outputABL = makeBufferList(data: [outLeft, outRight], interleaved: false)
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        // Fix channel count on non-interleaved buffers
        let inputBuf = UnsafeMutableAudioBufferListPointer(inputABL)
        let outputBuf = UnsafeMutableAudioBufferListPointer(outputABL)
        for i in 0..<inputBuf.count { inputBuf[i].mNumberChannels = 1 }
        for i in 0..<outputBuf.count { outputBuf[i].mNumberChannels = 1 }

        var currentVolume: Float = 1.0
        GainProcessor.processFloatBuffers(
            channelCount: 2,
            isInterleaved: false,
            inputBuffers: inputBuf,
            outputBuffers: outputBuf,
            targetVolume: 1.0,
            currentVolume: &currentVolume,
            rampCoefficient: 1.0,
            crossfadeMultiplier: 1.0,
            compensation: 1.0
        )

        let outputL = readBuffer(outputABL, bufferIndex: 0)
        let outputR = readBuffer(outputABL, bufferIndex: 1)

        for (i, (inp, out)) in zip(leftData, outputL).enumerated() {
            XCTAssertEqual(out, inp, accuracy: 0.01, "Left sample \(i)")
        }
        for (i, (inp, out)) in zip(rightData, outputR).enumerated() {
            XCTAssertEqual(out, inp, accuracy: 0.01, "Right sample \(i)")
        }
    }

    // MARK: - Mute (zero volume)

    func testZeroVolumeProducesSilence() {
        let inputData: [Float] = [1.0, 1.0, 1.0, 1.0]
        let outputData: [Float] = [0, 0, 0, 0]

        let inputABL = makeBufferList(data: [inputData], interleaved: true)
        let outputABL = makeBufferList(data: [outputData], interleaved: true)
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        var currentVolume: Float = 0.0
        GainProcessor.processFloatBuffers(
            channelCount: 2,
            isInterleaved: true,
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL),
            targetVolume: 0.0,
            currentVolume: &currentVolume,
            rampCoefficient: 1.0,
            crossfadeMultiplier: 1.0,
            compensation: 1.0
        )

        let output = readBuffer(outputABL)
        for sample in output {
            XCTAssertEqual(sample, 0, accuracy: 1e-7, "Zero volume should produce silence")
        }
    }

    // MARK: - Edge cases

    func testZeroCrossfadeProducesSilence() {
        let inputData: [Float] = [1.0, 1.0]
        let outputData: [Float] = [0, 0]

        let inputABL = makeBufferList(data: [inputData], interleaved: true)
        let outputABL = makeBufferList(data: [outputData], interleaved: true)
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        var currentVolume: Float = 1.0
        GainProcessor.processFloatBuffers(
            channelCount: 2,
            isInterleaved: true,
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL),
            targetVolume: 1.0,
            currentVolume: &currentVolume,
            rampCoefficient: 1.0,
            crossfadeMultiplier: 0.0,
            compensation: 1.0
        )

        let output = readBuffer(outputABL)
        for sample in output {
            XCTAssertEqual(sample, 0, accuracy: 1e-7, "Zero crossfade should produce silence")
        }
    }
}
