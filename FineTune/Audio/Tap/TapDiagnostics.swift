// FineTune/Audio/Tap/TapDiagnostics.swift

/// Snapshot of diagnostic counters from a ProcessTapController's audio callback.
/// All fields are atomically-read copies of RT-safe counters, safe to read from any thread.
struct TapDiagnostics {
    let callbackCount: UInt64
    let inputHasData: UInt64
    let outputWritten: UInt64
    let silencedForce: UInt64
    let silencedMute: UInt64
    let converterUsed: UInt64
    let converterFailed: UInt64
    let directFloat: UInt64
    let nonFloatPassthrough: UInt64
    let emptyInput: UInt64
    let eqApplied: UInt64
    let eqBypassed: UInt64
    let eqBypassNoProcessor: UInt64
    let eqBypassCrossfade: UInt64
    let eqBypassNonInterleaved: UInt64
    let eqBypassChannelMismatch: UInt64
    let eqBypassBufferCount: UInt64
    let eqBypassNoOutputData: UInt64
    let lastInputPeak: Float
    let lastOutputPeak: Float
    let outputBufCount: UInt32
    let outputBuf0ByteSize: UInt32
    let formatChannels: UInt32
    let formatIsFloat: Bool
    let formatIsInterleaved: Bool
    let formatSampleRate: Float
    let volume: Float
    let crossfadeActive: Bool
    let primaryCurrentVolume: Float

    init(
        callbackCount: UInt64,
        inputHasData: UInt64,
        outputWritten: UInt64,
        silencedForce: UInt64,
        silencedMute: UInt64,
        converterUsed: UInt64,
        converterFailed: UInt64,
        directFloat: UInt64,
        nonFloatPassthrough: UInt64,
        emptyInput: UInt64,
        eqApplied: UInt64 = 0,
        eqBypassed: UInt64 = 0,
        eqBypassNoProcessor: UInt64 = 0,
        eqBypassCrossfade: UInt64 = 0,
        eqBypassNonInterleaved: UInt64 = 0,
        eqBypassChannelMismatch: UInt64 = 0,
        eqBypassBufferCount: UInt64 = 0,
        eqBypassNoOutputData: UInt64 = 0,
        lastInputPeak: Float,
        lastOutputPeak: Float,
        outputBufCount: UInt32,
        outputBuf0ByteSize: UInt32,
        formatChannels: UInt32,
        formatIsFloat: Bool,
        formatIsInterleaved: Bool,
        formatSampleRate: Float,
        volume: Float,
        crossfadeActive: Bool,
        primaryCurrentVolume: Float
    ) {
        self.callbackCount = callbackCount
        self.inputHasData = inputHasData
        self.outputWritten = outputWritten
        self.silencedForce = silencedForce
        self.silencedMute = silencedMute
        self.converterUsed = converterUsed
        self.converterFailed = converterFailed
        self.directFloat = directFloat
        self.nonFloatPassthrough = nonFloatPassthrough
        self.emptyInput = emptyInput
        self.eqApplied = eqApplied
        self.eqBypassed = eqBypassed
        self.eqBypassNoProcessor = eqBypassNoProcessor
        self.eqBypassCrossfade = eqBypassCrossfade
        self.eqBypassNonInterleaved = eqBypassNonInterleaved
        self.eqBypassChannelMismatch = eqBypassChannelMismatch
        self.eqBypassBufferCount = eqBypassBufferCount
        self.eqBypassNoOutputData = eqBypassNoOutputData
        self.lastInputPeak = lastInputPeak
        self.lastOutputPeak = lastOutputPeak
        self.outputBufCount = outputBufCount
        self.outputBuf0ByteSize = outputBuf0ByteSize
        self.formatChannels = formatChannels
        self.formatIsFloat = formatIsFloat
        self.formatIsInterleaved = formatIsInterleaved
        self.formatSampleRate = formatSampleRate
        self.volume = volume
        self.crossfadeActive = crossfadeActive
        self.primaryCurrentVolume = primaryCurrentVolume
    }

    /// Output path is non-functional: callbacks run, buffers written, but no audio reaches hardware.
    /// Only meaningful when volume > 0 (zero volume legitimately produces zero peak).
    var hasDeadOutput: Bool {
        callbackCount > 10 && outputWritten > 0 && lastOutputPeak < 0.0001 && volume > 0.01
    }

    /// Input path is non-functional: callbacks run but no captured audio data.
    var hasDeadInput: Bool {
        callbackCount > 10 && inputHasData == 0 && lastInputPeak < 0.0001
    }
}
