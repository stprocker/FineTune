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
