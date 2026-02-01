// FineTune/Audio/Types/TapFormat.swift
import AudioToolbox

/// Audio format information for a process tap.
/// Drives audio processing assumptions (interleaving, sample format, etc.)
struct TapFormat {
    /// The underlying Audio Stream Basic Description
    let asbd: AudioStreamBasicDescription

    /// Number of audio channels (1 = mono, 2 = stereo)
    let channelCount: Int

    /// Whether samples are interleaved (LRLRLR) vs planar (LLL...RRR...)
    let isInterleaved: Bool

    /// Whether samples are 32-bit floating point (required for processing)
    let isFloat32: Bool

    /// Sample rate in Hz
    let sampleRate: Double

    /// Creates a TapFormat by parsing an AudioStreamBasicDescription.
    ///
    /// - Parameters:
    ///   - asbd: The audio stream description to parse
    ///   - fallbackSampleRate: Sample rate to use if ASBD has 0
    init(asbd: AudioStreamBasicDescription, fallbackSampleRate: Double = 48000) {
        self.asbd = asbd

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isLinearPCM = asbd.mFormatID == kAudioFormatLinearPCM
        let bits = Int(asbd.mBitsPerChannel)

        self.channelCount = max(1, Int(asbd.mChannelsPerFrame))
        self.isInterleaved = !isNonInterleaved
        self.isFloat32 = isLinearPCM && isFloat && bits == 32
        self.sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : fallbackSampleRate
    }

    /// Creates a default stereo Float32 format.
    static var defaultStereo: TapFormat {
        TapFormat(
            asbd: AudioStreamBasicDescription(),
            channelCount: 2,
            isInterleaved: true,
            isFloat32: true,
            sampleRate: 48000
        )
    }

    /// Direct initializer for all fields.
    init(asbd: AudioStreamBasicDescription, channelCount: Int, isInterleaved: Bool, isFloat32: Bool, sampleRate: Double) {
        self.asbd = asbd
        self.channelCount = channelCount
        self.isInterleaved = isInterleaved
        self.isFloat32 = isFloat32
        self.sampleRate = sampleRate
    }

    /// Human-readable description of the format.
    var description: String {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let formatID = asbd.mFormatID == kAudioFormatLinearPCM ? "lpcm" : "\(asbd.mFormatID)"
        return "\(Int(asbd.mSampleRate)) Hz, \(Int(asbd.mChannelsPerFrame)) ch, \(Int(asbd.mBitsPerChannel))-bit, \(isFloat ? "float" : "int"), \(isNonInterleaved ? "non-interleaved" : "interleaved"), \(formatID)"
    }
}
