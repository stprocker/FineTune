// FineTune/Audio/Processing/AudioFormatConverter.swift
import AudioToolbox
import os
import FineTuneCore

/// State for audio format conversion between tap format and processing format.
/// Handles non-standard formats (non-Float32, non-interleaved, mono) by converting
/// to/from a canonical processing format (interleaved stereo Float32).
struct ConverterState {
    var inputASBD: AudioStreamBasicDescription
    var outputASBD: AudioStreamBasicDescription
    var procASBD: AudioStreamBasicDescription
    var inputConverter: AudioConverterRef?
    var outputConverter: AudioConverterRef?
    var procBuffer: UnsafeMutablePointer<Float>
    var procBufferFrames: Int
}

/// Factory and utilities for audio format conversion.
enum AudioFormatConverter {

    /// Input context for the converter callback
    struct ConverterInputContext {
        let bufferList: UnsafePointer<AudioBufferList>
        let frames: UInt32
    }

    /// Converter input callback (C-compatible)
    static let converterInputProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, _, inUserData in
        guard let inUserData else { return -1 }
        let context = inUserData.assumingMemoryBound(to: ConverterInputContext.self)
        let availableFrames = context.pointee.frames
        if availableFrames == 0 {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        ioNumberDataPackets.pointee = min(ioNumberDataPackets.pointee, availableFrames)
        ioData.pointee = context.pointee.bufferList.pointee
        return noErr
    }

    /// Creates a processing format ASBD (interleaved stereo Float32).
    static func makeProcASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// Configures a converter for the given tap format.
    /// Returns nil if no conversion is needed (format is already stereo interleaved Float32).
    ///
    /// - Parameters:
    ///   - format: The tap format to convert from/to
    ///   - deviceID: Device ID for buffer size query
    ///   - logger: Optional logger for diagnostics
    /// - Returns: ConverterState if conversion needed, nil otherwise
    static func configure(
        for format: TapFormat,
        deviceID: AudioDeviceID,
        logger: Logger? = nil
    ) -> ConverterState? {
        // No conversion needed for stereo interleaved Float32
        if format.isFloat32, format.isInterleaved, format.channelCount == 2 {
            return nil
        }

        // Only support mono and stereo
        guard format.channelCount <= 2 else {
            logger?.warning("Unsupported channel count for conversion: \(format.channelCount)")
            return nil
        }

        var procASBD = makeProcASBD(sampleRate: format.sampleRate)

        var inputConverter: AudioConverterRef?
        var outputConverter: AudioConverterRef?

        var inputASBD = format.asbd
        var outputASBD = format.asbd

        let inputStatus = AudioConverterNew(&inputASBD, &procASBD, &inputConverter)
        guard inputStatus == noErr, let inConverter = inputConverter else {
            logger?.error("Failed to create input converter: \(inputStatus)")
            return nil
        }

        let outputStatus = AudioConverterNew(&procASBD, &outputASBD, &outputConverter)
        guard outputStatus == noErr, let outConverter = outputConverter else {
            AudioConverterDispose(inConverter)
            logger?.error("Failed to create output converter: \(outputStatus)")
            return nil
        }

        // Configure channel mapping for mono
        if format.channelCount == 1 {
            // Upmix: duplicate mono to both channels
            var upmixMap: [Int32] = [0, 0]
            let mapSize = UInt32(MemoryLayout<Int32>.size * upmixMap.count)
            AudioConverterSetProperty(inConverter, kAudioConverterChannelMap, mapSize, &upmixMap)

            // Downmix: take first channel
            var downmixMap: [Int32] = [0]
            let downmixSize = UInt32(MemoryLayout<Int32>.size * downmixMap.count)
            AudioConverterSetProperty(outConverter, kAudioConverterChannelMap, downmixSize, &downmixMap)
        }

        let bufferFrames = Int((try? deviceID.readBufferFrameSize()) ?? 4096)
        let procBuffer = UnsafeMutablePointer<Float>.allocate(capacity: bufferFrames * 2)
        procBuffer.initialize(repeating: 0, count: bufferFrames * 2)

        return ConverterState(
            inputASBD: inputASBD,
            outputASBD: outputASBD,
            procASBD: procASBD,
            inputConverter: inConverter,
            outputConverter: outConverter,
            procBuffer: procBuffer,
            procBufferFrames: bufferFrames
        )
    }

    /// Destroys a converter state, releasing all resources.
    static func destroy(_ state: inout ConverterState?) {
        guard let converterState = state else { return }
        if let converter = converterState.inputConverter {
            AudioConverterDispose(converter)
        }
        if let converter = converterState.outputConverter {
            AudioConverterDispose(converter)
        }
        converterState.procBuffer.deallocate()
        state = nil
    }

    /// Processes audio through the converter with gain and EQ.
    ///
    /// - Parameters:
    ///   - converter: The converter state
    ///   - inputBufferList: Source audio buffers
    ///   - outputBufferList: Destination audio buffers
    ///   - targetVolume: Target volume level
    ///   - currentVolume: Current ramped volume (modified)
    ///   - rampCoefficient: Volume ramp coefficient
    ///   - crossfadeMultiplier: Crossfade gain multiplier
    ///   - compensation: Device volume compensation
    ///   - eqProcessor: Optional EQ processor
    ///   - allowEQ: Whether to apply EQ
    /// - Returns: True if processing succeeded
    @inline(__always)
    static func process(
        converter: ConverterState,
        inputBufferList: UnsafePointer<AudioBufferList>,
        outputBufferList: UnsafeMutablePointer<AudioBufferList>,
        targetVolume: Float,
        currentVolume: inout Float,
        rampCoefficient: Float,
        crossfadeMultiplier: Float,
        compensation: Float,
        eqProcessor: EQProcessor?,
        allowEQ: Bool
    ) -> Bool {
        guard let inputConverter = converter.inputConverter,
              let outputConverter = converter.outputConverter else {
            return false
        }

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)

        let inputBytesPerFrame = max(1, Int(converter.inputASBD.mBytesPerFrame))
        let outputBytesPerFrame = max(1, Int(converter.outputASBD.mBytesPerFrame))

        let inputFrames = AudioBufferProcessor.frameCount(bufferList: inputBuffers, bytesPerFrame: inputBytesPerFrame)
        let outputFrames = AudioBufferProcessor.frameCount(bufferList: outputBuffers, bytesPerFrame: outputBytesPerFrame)
        let maxFrames = min(converter.procBufferFrames, min(inputFrames, outputFrames))
        guard maxFrames > 0 else { return false }

        var procABL = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(maxFrames * 2 * MemoryLayout<Float>.size),
                mData: converter.procBuffer
            )
        )

        var inputContext = ConverterInputContext(
            bufferList: inputBufferList,
            frames: UInt32(inputFrames)
        )

        var procFrames: UInt32 = UInt32(maxFrames)
        let inputStatus = AudioConverterFillComplexBuffer(
            inputConverter,
            converterInputProc,
            &inputContext,
            &procFrames,
            &procABL,
            nil
        )

        guard inputStatus == noErr, procFrames > 0 else {
            return false
        }

        let actualFrames = Int(procFrames)
        procABL.mBuffers.mDataByteSize = UInt32(actualFrames * 2 * MemoryLayout<Float>.size)

        // Process on normalized interleaved stereo Float32 buffer
        var outputSuccess = false
        withUnsafeMutablePointer(to: &procABL) { procPtr in
            let procBuffers = UnsafeMutableAudioBufferListPointer(procPtr)
            GainProcessor.processFloatBuffers(
                channelCount: 2,
                isInterleaved: true,
                inputBuffers: procBuffers,
                outputBuffers: procBuffers,
                targetVolume: targetVolume,
                currentVolume: &currentVolume,
                rampCoefficient: rampCoefficient,
                crossfadeMultiplier: crossfadeMultiplier,
                compensation: compensation
            )

            if let eqProcessor = eqProcessor, allowEQ {
                let outputSamples = converter.procBuffer
                eqProcessor.process(
                    input: outputSamples,
                    output: outputSamples,
                    frameCount: actualFrames
                )
            }

            var outputContext = ConverterInputContext(
                bufferList: UnsafePointer(procPtr),
                frames: UInt32(actualFrames)
            )

            var outFrames: UInt32 = UInt32(min(actualFrames, outputFrames))
            let outputStatus = AudioConverterFillComplexBuffer(
                outputConverter,
                converterInputProc,
                &outputContext,
                &outFrames,
                outputBufferList,
                nil
            )

            outputSuccess = (outputStatus == noErr)
        }

        return outputSuccess
    }
}
