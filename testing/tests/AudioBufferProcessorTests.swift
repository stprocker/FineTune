import XCTest
import AudioToolbox
import Accelerate
@testable import FineTuneCore

final class AudioBufferProcessorTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeBufferList(data: [[Float]]) -> UnsafeMutablePointer<AudioBufferList> {
        let bufferCount = data.count
        let listSize = MemoryLayout<AudioBufferList>.size + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let listPtr = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        let abl = listPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        abl.pointee.mNumberBuffers = UInt32(bufferCount)

        let bufferPtr = UnsafeMutableAudioBufferListPointer(abl)

        for i in 0..<bufferCount {
            let byteSize = data[i].count * MemoryLayout<Float>.size
            let dataPtr = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: MemoryLayout<Float>.alignment)
            data[i].withUnsafeBufferPointer { src in
                dataPtr.copyMemory(from: UnsafeRawPointer(src.baseAddress!), byteCount: byteSize)
            }
            bufferPtr[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(byteSize),
                mData: dataPtr
            )
        }

        return abl
    }

    private func readBuffer(_ abl: UnsafeMutablePointer<AudioBufferList>, index: Int = 0) -> [Float] {
        let bufferPtr = UnsafeMutableAudioBufferListPointer(abl)
        guard index < bufferPtr.count,
              let data = bufferPtr[index].mData else { return [] }
        let sampleCount = Int(bufferPtr[index].mDataByteSize) / MemoryLayout<Float>.size
        let floats = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: floats, count: sampleCount))
    }

    private func freeBufferList(_ abl: UnsafeMutablePointer<AudioBufferList>) {
        let bufferPtr = UnsafeMutableAudioBufferListPointer(abl)
        for i in 0..<bufferPtr.count {
            if let data = bufferPtr[i].mData {
                data.deallocate()
            }
        }
        UnsafeMutableRawPointer(abl).deallocate()
    }

    // MARK: - zeroOutputBuffers

    func testZeroOutputBuffersSingleBuffer() {
        let abl = makeBufferList(data: [[1.0, 2.0, 3.0, 4.0]])
        defer { freeBufferList(abl) }

        AudioBufferProcessor.zeroOutputBuffers(UnsafeMutableAudioBufferListPointer(abl))

        let output = readBuffer(abl)
        XCTAssertEqual(output.count, 4)
        for sample in output {
            XCTAssertEqual(sample, 0, "All samples should be zeroed")
        }
    }

    func testZeroOutputBuffersMultipleBuffers() {
        let abl = makeBufferList(data: [[1.0, 2.0], [3.0, 4.0]])
        defer { freeBufferList(abl) }

        AudioBufferProcessor.zeroOutputBuffers(UnsafeMutableAudioBufferListPointer(abl))

        let buf0 = readBuffer(abl, index: 0)
        let buf1 = readBuffer(abl, index: 1)
        XCTAssertTrue(buf0.allSatisfy { $0 == 0 })
        XCTAssertTrue(buf1.allSatisfy { $0 == 0 })
    }

    // MARK: - copyInputToOutput

    func testCopyInputToOutputExactCopy() {
        let inputData: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let outputData: [Float] = [0, 0, 0, 0, 0]

        let inputABL = makeBufferList(data: [inputData])
        let outputABL = makeBufferList(data: [outputData])
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        AudioBufferProcessor.copyInputToOutput(
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL)
        )

        let output = readBuffer(outputABL)
        XCTAssertEqual(output, inputData)
    }

    func testCopyInputToOutputMultipleBuffers() {
        let inputABL = makeBufferList(data: [[0.1, 0.2], [0.3, 0.4]])
        let outputABL = makeBufferList(data: [[0, 0], [0, 0]])
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        AudioBufferProcessor.copyInputToOutput(
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL)
        )

        XCTAssertEqual(readBuffer(outputABL, index: 0), [0.1, 0.2])
        XCTAssertEqual(readBuffer(outputABL, index: 1), [0.3, 0.4])
    }

    func testCopyInputToOutputMinSizeWhenOutputSmaller() {
        let inputABL = makeBufferList(data: [[0.1, 0.2, 0.3, 0.4]])
        let outputABL = makeBufferList(data: [[0, 0]]) // smaller
        defer { freeBufferList(inputABL); freeBufferList(outputABL) }

        AudioBufferProcessor.copyInputToOutput(
            inputBuffers: UnsafeMutableAudioBufferListPointer(inputABL),
            outputBuffers: UnsafeMutableAudioBufferListPointer(outputABL)
        )

        let output = readBuffer(outputABL)
        // Should only copy min(4,2) bytes worth = 2 samples
        XCTAssertEqual(output, [0.1, 0.2])
    }

    // MARK: - computePeak

    func testComputePeakSilence() {
        let abl = makeBufferList(data: [[0, 0, 0, 0]])
        defer { freeBufferList(abl) }

        let peak = AudioBufferProcessor.computePeak(inputBuffers: UnsafeMutableAudioBufferListPointer(abl))
        XCTAssertEqual(peak, 0.0)
    }

    func testComputePeakPositive() {
        let abl = makeBufferList(data: [[0.1, 0.5, 0.3, 0.2]])
        defer { freeBufferList(abl) }

        let peak = AudioBufferProcessor.computePeak(inputBuffers: UnsafeMutableAudioBufferListPointer(abl))
        XCTAssertEqual(peak, 0.5, accuracy: 1e-6)
    }

    func testComputePeakNegative() {
        let abl = makeBufferList(data: [[0.1, -0.9, 0.3, -0.2]])
        defer { freeBufferList(abl) }

        let peak = AudioBufferProcessor.computePeak(inputBuffers: UnsafeMutableAudioBufferListPointer(abl))
        XCTAssertEqual(peak, 0.9, accuracy: 1e-6, "Should use absolute value for negative samples")
    }

    func testComputePeakAcrossMultipleBuffers() {
        let abl = makeBufferList(data: [[0.1, 0.2], [0.5, 0.3]])
        defer { freeBufferList(abl) }

        let peak = AudioBufferProcessor.computePeak(inputBuffers: UnsafeMutableAudioBufferListPointer(abl))
        XCTAssertEqual(peak, 0.5, accuracy: 1e-6, "Should find max across all buffers")
    }

    func testComputePeakAboveUnity() {
        let abl = makeBufferList(data: [[0.5, 1.5, 0.3]])
        defer { freeBufferList(abl) }

        let peak = AudioBufferProcessor.computePeak(inputBuffers: UnsafeMutableAudioBufferListPointer(abl))
        XCTAssertEqual(peak, 1.5, accuracy: 1e-6, "Peak can exceed 1.0 for boosted audio")
    }

    func testComputePeakSingleSample() {
        let abl = makeBufferList(data: [[0.42]])
        defer { freeBufferList(abl) }

        let peak = AudioBufferProcessor.computePeak(inputBuffers: UnsafeMutableAudioBufferListPointer(abl))
        XCTAssertEqual(peak, 0.42, accuracy: 1e-6)
    }

    // MARK: - frameCount

    func testFrameCountBasic() {
        let abl = makeBufferList(data: [[0, 0, 0, 0]]) // 4 floats = 16 bytes
        defer { freeBufferList(abl) }

        let count = AudioBufferProcessor.frameCount(
            bufferList: UnsafeMutableAudioBufferListPointer(abl),
            bytesPerFrame: MemoryLayout<Float>.size // 4 bytes per frame (mono)
        )
        XCTAssertEqual(count, 4)
    }

    func testFrameCountStereo() {
        let abl = makeBufferList(data: [[0, 0, 0, 0]]) // 4 floats = 16 bytes
        defer { freeBufferList(abl) }

        let count = AudioBufferProcessor.frameCount(
            bufferList: UnsafeMutableAudioBufferListPointer(abl),
            bytesPerFrame: MemoryLayout<Float>.size * 2 // 8 bytes per frame (interleaved stereo)
        )
        XCTAssertEqual(count, 2, "4 floats with 8 bytes/frame = 2 frames")
    }

    func testFrameCountZeroBytesPerFrame() {
        let abl = makeBufferList(data: [[1, 2, 3]])
        defer { freeBufferList(abl) }

        let count = AudioBufferProcessor.frameCount(
            bufferList: UnsafeMutableAudioBufferListPointer(abl),
            bytesPerFrame: 0
        )
        XCTAssertEqual(count, 0, "Zero bytesPerFrame should return 0")
    }

    func testFrameCountLargeBuffer() {
        let data = Array(repeating: Float(0), count: 4096)
        let abl = makeBufferList(data: [data])
        defer { freeBufferList(abl) }

        let count = AudioBufferProcessor.frameCount(
            bufferList: UnsafeMutableAudioBufferListPointer(abl),
            bytesPerFrame: MemoryLayout<Float>.size
        )
        XCTAssertEqual(count, 4096)
    }
}
