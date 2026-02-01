// FineTune/Audio/Extensions/AudioDeviceID+Streams.swift
import AudioToolbox
import Foundation

// MARK: - Stream Queries

extension AudioDeviceID {
    func hasOutputStreams() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else { return false }
        return size > 0
    }

    func hasInputStreams() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else { return false }
        return size > 0
    }

    func readOutputStreamIDs() throws -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }

        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streamIDs = [AudioStreamID](repeating: AudioStreamID(kAudioObjectUnknown), count: count)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &streamIDs)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
        return streamIDs
    }

    func setNominalSampleRate(_ sampleRate: Double) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(sampleRate)
        let size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &rate)
        return err == noErr
    }

    func readBufferFrameSize() throws -> UInt32 {
        try read(kAudioDevicePropertyBufferFrameSize, defaultValue: UInt32(0))
    }
}

// MARK: - Stream Formats

extension AudioObjectID {
    func readVirtualFormat() throws -> AudioStreamBasicDescription {
        try read(kAudioStreamPropertyVirtualFormat, defaultValue: AudioStreamBasicDescription())
    }
}
