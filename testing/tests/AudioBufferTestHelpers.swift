// testing/tests/AudioBufferTestHelpers.swift
import AudioToolbox

/// Shared audio buffer test utilities used by GainProcessorTests and AudioBufferProcessorTests.

/// Creates an AudioBufferList from Float arrays.
/// - Parameters:
///   - data: Array of Float arrays, one per buffer.
///   - interleaved: If true, sets mNumberChannels to 2 for non-empty buffers; otherwise 1.
/// - Returns: The allocated AudioBufferList pointer.
func makeBufferList(
    data: [[Float]],
    interleaved: Bool = false
) -> UnsafeMutablePointer<AudioBufferList> {
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
            mNumberChannels: interleaved ? UInt32(data[i].count > 0 ? 2 : 0) : 1,
            mDataByteSize: UInt32(byteSize),
            mData: dataPtr
        )
    }

    return abl
}

/// Reads Float samples from a buffer in an AudioBufferList.
func readBuffer(_ abl: UnsafeMutablePointer<AudioBufferList>, bufferIndex: Int = 0) -> [Float] {
    let bufferPtr = UnsafeMutableAudioBufferListPointer(abl)
    guard bufferIndex < bufferPtr.count,
          let data = bufferPtr[bufferIndex].mData else { return [] }
    let sampleCount = Int(bufferPtr[bufferIndex].mDataByteSize) / MemoryLayout<Float>.size
    let floats = data.assumingMemoryBound(to: Float.self)
    return Array(UnsafeBufferPointer(start: floats, count: sampleCount))
}

/// Frees all memory associated with an AudioBufferList.
func freeBufferList(_ abl: UnsafeMutablePointer<AudioBufferList>) {
    let bufferPtr = UnsafeMutableAudioBufferListPointer(abl)
    for i in 0..<bufferPtr.count {
        if let data = bufferPtr[i].mData {
            data.deallocate()
        }
    }
    UnsafeMutableRawPointer(abl).deallocate()
}
