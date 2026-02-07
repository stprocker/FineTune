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
    let formatChannels: UInt32
    let formatIsFloat: Bool
    let formatIsInterleaved: Bool
    let formatSampleRate: Float
    let volume: Float
    let crossfadeActive: Bool
    let primaryCurrentVolume: Float
}
