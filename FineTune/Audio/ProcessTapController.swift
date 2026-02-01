// FineTune/Audio/ProcessTapController.swift
import AudioToolbox
import os

final class ProcessTapController {
    /// Configuration for crossfade behavior
    private enum CrossfadeConfig {
        static let defaultDuration: TimeInterval = 0.050  // 50ms

        static var duration: TimeInterval {
            let custom = UserDefaults.standard.double(forKey: "FineTuneCrossfadeDuration")
            return custom > 0 ? custom : defaultDuration
        }

        static func totalSamples(at sampleRate: Double) -> Int64 {
            Int64(sampleRate * duration)
        }
    }

    let app: AudioApp
    private let logger: Logger
    // Note: This queue is passed to AudioDeviceCreateIOProcIDWithBlock but the actual
    // audio callback runs on CoreAudio's real-time HAL I/O thread, not this queue.
    private let queue = DispatchQueue(label: "ProcessTapController", qos: .userInitiated)

    /// Weak reference to device monitor for O(1) device lookups during crossfade
    private weak var deviceMonitor: AudioDeviceMonitor?

    // Lock-free volume access for real-time audio safety
    // Aligned Float32 reads/writes are atomic on Apple platforms.
    // Audio thread may read slightly stale volume values, which is acceptable
    // for volume control where exact synchronization isn't critical.
    private nonisolated(unsafe) var _volume: Float = 1.0

    // Separate volume states for primary and secondary taps (fixes race condition)
    // Each callback ramps independently toward _volume
    private nonisolated(unsafe) var _primaryCurrentVolume: Float = 1.0
    private nonisolated(unsafe) var _secondaryCurrentVolume: Float = 1.0

    // Force silence flag - when true, output zeros regardless of input
    // Used during device switching to prevent clicks/pops
    private nonisolated(unsafe) var _forceSilence: Bool = false

    // Mute flag - when true, output zeros (user-initiated mute)
    // Separate from _forceSilence which is for device switching
    private nonisolated(unsafe) var _isMuted: Bool = false

    // Device volume compensation scalar (applied during/after crossfade)
    // Computed as: sourceDeviceVolume / destinationDeviceVolume
    private nonisolated(unsafe) var _deviceVolumeCompensation: Float = 1.0

    // Peak audio level for VU meter display (0-1 range)
    // Written by audio callback, read by UI for visualization
    // Uses exponential smoothing to reduce nervous jumping
    private nonisolated(unsafe) var _peakLevel: Float = 0.0

    // Smoothing factor for VU meter (0-1)
    // Lower = smoother/slower response, Higher = more responsive
    // 0.3 gives ~30ms effective integration at 30fps UI update rate
    private let levelSmoothingFactor: Float = 0.3

    // Current device volume scalar (0-1) for VU meter calculation
    // Updated from main thread when device volume changes
    private nonisolated(unsafe) var _currentDeviceVolume: Float = 1.0

    // Current device mute state for VU meter calculation
    private nonisolated(unsafe) var _isDeviceMuted: Bool = false

    /// Current peak audio level (0-1) for VU meter visualization
    /// Read from main thread, written from audio callback (atomic Float)
    var audioLevel: Float { _peakLevel }

    /// Current device volume for VU meter scaling (atomic write from main thread)
    var currentDeviceVolume: Float {
        get { _currentDeviceVolume }
        set { _currentDeviceVolume = newValue }
    }

    /// Current device mute state for VU meter (atomic write from main thread)
    var isDeviceMuted: Bool {
        get { _isDeviceMuted }
        set { _isDeviceMuted = newValue }
    }

    // Ramp coefficient for ~30ms smoothing, computed from device sample rate on activation
    // Formula: 1 - exp(-1 / (sampleRate * rampTimeSeconds))
    private var rampCoefficient: Float = 0.0007  // Default, updated on activation
    private var secondaryRampCoefficient: Float = 0.0007  // For secondary tap during crossfade

    // EQ processor (pre-allocated at activation)
    private var eqProcessor: EQProcessor?

    // Tap format info (drives audio processing assumptions)
    private struct TapFormat {
        let asbd: AudioStreamBasicDescription
        let channelCount: Int
        let isInterleaved: Bool
        let isFloat32: Bool
        let sampleRate: Double
    }

    private nonisolated(unsafe) var primaryFormat: TapFormat?
    private nonisolated(unsafe) var secondaryFormat: TapFormat?

    private struct ConverterState {
        var inputASBD: AudioStreamBasicDescription
        var outputASBD: AudioStreamBasicDescription
        var procASBD: AudioStreamBasicDescription
        var inputConverter: AudioConverterRef?
        var outputConverter: AudioConverterRef?
        var procBuffer: UnsafeMutablePointer<Float>
        var procBufferFrames: Int
    }

    private nonisolated(unsafe) var primaryConverter: ConverterState?
    private nonisolated(unsafe) var secondaryConverter: ConverterState?

    var volume: Float {
        get { _volume }
        set { _volume = newValue }
    }

    var isMuted: Bool {
        get { _isMuted }
        set { _isMuted = newValue }
    }

    /// Update EQ settings (thread-safe, called from main thread)
    func updateEQSettings(_ settings: EQSettings) {
        eqProcessor?.updateSettings(settings)
    }

    // Target device UID (always explicit)
    private var targetDeviceUID: String
    private(set) var currentDeviceUID: String?

    // Core Audio state (primary tap)
    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var activated = false

    // Secondary tap for crossfade (only exists during device switch)
    private var secondaryTapID: AudioObjectID = .unknown
    private var secondaryAggregateID: AudioObjectID = .unknown
    private var secondaryDeviceProcID: AudioDeviceIOProcID?
    private var secondaryTapDescription: CATapDescription?

    // Crossfade state: 0 = full primary, 1 = full secondary
    private nonisolated(unsafe) var _crossfadeProgress: Float = 0
    private nonisolated(unsafe) var _isCrossfading: Bool = false

    // Sample-accurate crossfade timing (secondary callback drives progress)
    private nonisolated(unsafe) var _secondarySampleCount: Int64 = 0
    private nonisolated(unsafe) var _crossfadeTotalSamples: Int64 = 0

    // Warmup tracking: don't destroy primary until secondary has processed enough samples
    // Ensures secondary HAL I/O thread is fully connected before app unmutes
    private nonisolated(unsafe) var _secondarySamplesProcessed: Int = 0
    private let minimumWarmupSamples: Int = 2048  // ~43ms at 48kHz

    init(app: AudioApp, targetDeviceUID: String, deviceMonitor: AudioDeviceMonitor? = nil) {
        self.app = app
        self.targetDeviceUID = targetDeviceUID
        self.deviceMonitor = deviceMonitor
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "ProcessTapController(\(app.name))")
    }

    // MARK: - Tap/Device Format Helpers

    private func resolveOutputStreamInfo(for deviceUID: String) -> (deviceID: AudioDeviceID, streamID: AudioStreamID, streamIndex: Int, streamFormat: AudioStreamBasicDescription)? {
        let deviceID: AudioDeviceID
        if let device = deviceMonitor?.device(for: deviceUID) {
            deviceID = device.id
        } else if let id = (try? AudioObjectID.readDeviceList())?.first(where: { (try? $0.readDeviceUID()) == deviceUID }) {
            deviceID = id
        } else {
            logger.error("Failed to resolve device ID for UID: \(deviceUID)")
            return nil
        }

        guard let streamIDs = try? deviceID.readOutputStreamIDs(), !streamIDs.isEmpty else {
            logger.error("No output streams for device UID: \(deviceUID)")
            return nil
        }

        // Prefer first active stream, fallback to index 0
        let activeIndex = streamIDs.firstIndex { streamID in
            (try? streamID.readBool(kAudioStreamPropertyIsActive)) ?? true
        } ?? 0

        let streamID = streamIDs[activeIndex]
        let streamFormat = (try? streamID.readVirtualFormat()) ?? AudioStreamBasicDescription()
        return (deviceID, streamID, activeIndex, streamFormat)
    }

    private func makeTapFormat(from asbd: AudioStreamBasicDescription, fallbackSampleRate: Double) -> TapFormat {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isLinearPCM = asbd.mFormatID == kAudioFormatLinearPCM
        let bits = Int(asbd.mBitsPerChannel)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : fallbackSampleRate
        return TapFormat(
            asbd: asbd,
            channelCount: channels,
            isInterleaved: !isNonInterleaved,
            isFloat32: isLinearPCM && isFloat && bits == 32,
            sampleRate: sampleRate
        )
    }

    private func describeASBD(_ asbd: AudioStreamBasicDescription) -> String {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let formatID = asbd.mFormatID == kAudioFormatLinearPCM ? "lpcm" : "\(asbd.mFormatID)"
        return "\(Int(asbd.mSampleRate)) Hz, \(Int(asbd.mChannelsPerFrame)) ch, \(Int(asbd.mBitsPerChannel))-bit, \(isFloat ? "float" : "int"), \(isNonInterleaved ? "non-interleaved" : "interleaved"), \(formatID)"
    }

    private func updatePrimaryFormat(from tapID: AudioObjectID, fallbackSampleRate: Double) {
        if let asbd = try? tapID.readAudioTapStreamBasicDescription() {
            let format = makeTapFormat(from: asbd, fallbackSampleRate: fallbackSampleRate)
            primaryFormat = format
            logger.debug("Primary tap format: \(self.describeASBD(format.asbd))")
        } else {
            primaryFormat = nil
            logger.error("Failed to read primary tap format")
        }
    }

    private func updateSecondaryFormat(from tapID: AudioObjectID, fallbackSampleRate: Double) {
        if let asbd = try? tapID.readAudioTapStreamBasicDescription() {
            let format = makeTapFormat(from: asbd, fallbackSampleRate: fallbackSampleRate)
            secondaryFormat = format
            logger.debug("Secondary tap format: \(self.describeASBD(format.asbd))")
        } else {
            secondaryFormat = nil
            logger.error("Failed to read secondary tap format")
        }
    }

    // MARK: - Converter Setup

    private struct ConverterInputContext {
        let bufferList: UnsafePointer<AudioBufferList>
        let frames: UInt32
    }

    private static let converterInputProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, _, inUserData in
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

    private func makeProcASBD(sampleRate: Double) -> AudioStreamBasicDescription {
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

    private func configureConverter(
        for format: TapFormat,
        deviceID: AudioDeviceID
    ) -> ConverterState? {
        if format.isFloat32, format.isInterleaved, format.channelCount == 2 {
            return nil
        }

        guard format.channelCount <= 2 else {
            logger.warning("Unsupported channel count for conversion: \(format.channelCount)")
            return nil
        }

        let procASBD = makeProcASBD(sampleRate: format.sampleRate)

        var inputConverter: AudioConverterRef?
        var outputConverter: AudioConverterRef?

        var inputASBD = format.asbd
        var outputASBD = format.asbd

        let inputStatus = AudioConverterNew(&inputASBD, &procASBD, &inputConverter)
        guard inputStatus == noErr, let inConverter = inputConverter else {
            logger.error("Failed to create input converter: \(inputStatus)")
            return nil
        }

        let outputStatus = AudioConverterNew(&procASBD, &outputASBD, &outputConverter)
        guard outputStatus == noErr, let outConverter = outputConverter else {
            AudioConverterDispose(inConverter)
            logger.error("Failed to create output converter: \(outputStatus)")
            return nil
        }

        if format.channelCount == 1 {
            var upmixMap: [Int32] = [0, 0]
            let mapSize = UInt32(MemoryLayout<Int32>.size * upmixMap.count)
            AudioConverterSetProperty(inConverter, kAudioConverterChannelMap, mapSize, &upmixMap)

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

    private func destroyConverter(_ state: inout ConverterState?) {
        guard let state = state else { return }
        if let converter = state.inputConverter {
            AudioConverterDispose(converter)
        }
        if let converter = state.outputConverter {
            AudioConverterDispose(converter)
        }
        state.procBuffer.deallocate()
        state = nil
    }

    func activate() throws {
        guard !activated else { return }

        logger.debug("Activating tap for \(self.app.name)")

        // Use target device UID directly (always explicit)
        let outputUID = targetDeviceUID
        currentDeviceUID = outputUID

        guard let streamInfo = resolveOutputStreamInfo(for: outputUID) else {
            throw NSError(domain: "ProcessTapController", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to resolve output stream for device \(outputUID)"])
        }

        logger.debug("Target device stream format: \(describeASBD(streamInfo.streamFormat))")

        // Create process tap that matches the target device stream format.
        let processNumber = NSNumber(value: app.objectID)
        let tapDesc = CATapDescription(__processes: [processNumber], andDeviceUID: outputUID, withStream: streamInfo.streamIndex)
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped  // Mute original, we provide the audio
        self.tapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(err)"])
        }

        processTapID = tapID
        logger.debug("Created process tap #\(tapID)")
        let fallbackSampleRate = streamInfo.streamFormat.mSampleRate > 0
        ? streamInfo.streamFormat.mSampleRate
        : (try? streamInfo.deviceID.readNominalSampleRate()) ?? 48000
        updatePrimaryFormat(from: tapID, fallbackSampleRate: fallbackSampleRate)

        // Create aggregate device
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-\(app.id)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString
                ]
            ]
        ]

        aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(err)"])
        }

        logger.debug("Created aggregate device #\(self.aggregateDeviceID)")

        // Ensure aggregate device matches the tap/device sample rate.
        let tapSampleRate = primaryFormat?.sampleRate ?? fallbackSampleRate
        if AudioDeviceID(aggregateDeviceID).setNominalSampleRate(tapSampleRate) {
            logger.debug("Aggregate sample rate set to \(tapSampleRate) Hz (tap: \(describeASBD(primaryFormat?.asbd ?? AudioStreamBasicDescription())))")
        } else {
            logger.warning("Failed to set aggregate sample rate to \(tapSampleRate) Hz")
        }

        destroyConverter(&primaryConverter)
        if let format = primaryFormat {
            logger.debug("Primary tap format summary: \(describeASBD(format.asbd))")
            primaryConverter = configureConverter(for: format, deviceID: AudioDeviceID(aggregateDeviceID))
            if primaryConverter != nil {
                logger.debug("Primary converter enabled (input: \(describeASBD(format.asbd)) -> proc: 2ch float -> output: \(describeASBD(format.asbd)))")
            } else {
                logger.debug("Primary converter not required (format already safe)")
            }
        }

        if let format = primaryFormat, !format.isFloat32 {
            logger.warning("Non-float tap format detected, conversion required: \(describeASBD(format.asbd))")
        }

        // Compute ramp coefficient from confirmed sample rate
        let rampTimeSeconds: Float = 0.030  // 30ms smoothing
        rampCoefficient = 1 - exp(-1 / (Float(tapSampleRate) * rampTimeSeconds))
        logger.debug("Configured for sample rate: \(tapSampleRate) Hz, Ramp: \(self.rampCoefficient)")

        // Initialize EQ processor with device sample rate
        eqProcessor = EQProcessor(sampleRate: tapSampleRate)

        // Create IO proc with gain processing
        err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self else { return }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        // Start the device
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(err)"])
        }

        // Initialize current to target to skip initial fade-in
        _primaryCurrentVolume = _volume
        _deviceVolumeCompensation = 1.0  // No compensation on first activation

        // Only set activated after complete success
        activated = true
        logger.info("Tap activated for \(self.app.name)")
    }

    /// Switches the output device using dual-tap crossfade for seamless transition.
    /// Creates a second tap+aggregate for the new device, crossfades, then destroys the old one.
    func switchDevice(to newDeviceUID: String) async throws {
        guard activated else {
            targetDeviceUID = newDeviceUID
            logger.debug("[SWITCH] Not activated, just updating target to \(newDeviceUID)")
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("[SWITCH] === START === \(self.app.name) -> \(newDeviceUID)")

        // Use device UID directly (always explicit)
        let newOutputUID = newDeviceUID

        do {
            // Try crossfade approach
            try await performCrossfadeSwitch(to: newOutputUID)
        } catch {
            // Fall back to destroy/recreate if crossfade fails
            logger.warning("[SWITCH] Crossfade failed: \(error.localizedDescription), using fallback")
            // Clean up any partially-created secondary tap resources before fallback
            cleanupSecondaryTap()
            try await performDestructiveDeviceSwitch(to: newDeviceUID)
        }

        targetDeviceUID = newDeviceUID
        currentDeviceUID = newOutputUID

        let endTime = CFAbsoluteTimeGetCurrent()
        logger.info("[SWITCH] === END === Total time: \((endTime - startTime) * 1000)ms")
    }

    /// Performs a crossfade switch using two simultaneous taps.
    /// Secondary callback drives timing via sample counting for sample-accurate transitions.
    private func performCrossfadeSwitch(to newOutputUID: String) async throws {
        logger.info("[CROSSFADE] Step 1: Reading device volumes for compensation")

        // Read source device volume and sample rate
        // Fast path: use cached device lookup (O(1)), fallback to readDeviceList if cache miss
        var sourceVolume: Float = 1.0
        var sourceSampleRate: Float64 = 0
        if let sourceUID = currentDeviceUID {
            if let sourceDevice = deviceMonitor?.device(for: sourceUID) {
                // Cache hit - use O(1) lookup
                sourceVolume = sourceDevice.id.readOutputVolumeScalar()
                sourceSampleRate = (try? sourceDevice.id.readNominalSampleRate()) ?? 0
                logger.debug("[CROSSFADE] Source device (cached): volume=\(sourceVolume), sampleRate=\(sourceSampleRate)Hz")
            } else {
                // Fallback: device may have disconnected, try fresh read
                if let devices = try? AudioObjectID.readDeviceList(),
                   let sourceDevice = devices.first(where: { (try? $0.readDeviceUID()) == sourceUID }) {
                    sourceVolume = sourceDevice.readOutputVolumeScalar()
                    sourceSampleRate = (try? sourceDevice.readNominalSampleRate()) ?? 0
                    logger.debug("[CROSSFADE] Source device (fallback): volume=\(sourceVolume), sampleRate=\(sourceSampleRate)Hz")
                }
                // Continue with defaults if device gone
            }
        }

        // Read destination device volume and sample rate
        var destVolume: Float = 1.0
        var destSampleRate: Float64 = 0
        var isBluetoothDestination = false

        if let destDevice = deviceMonitor?.device(for: newOutputUID) {
            // Cache hit - use O(1) lookup
            destVolume = destDevice.id.readOutputVolumeScalar()
            destSampleRate = (try? destDevice.id.readNominalSampleRate()) ?? 0
            let transport = destDevice.id.readTransportType()
            isBluetoothDestination = (transport == .bluetooth || transport == .bluetoothLE)
            logger.debug("[CROSSFADE] Destination device (cached): volume=\(destVolume), sampleRate=\(destSampleRate)Hz, BT=\(isBluetoothDestination)")
        } else {
            // Fallback: device may have disconnected, try fresh read
            if let devices = try? AudioObjectID.readDeviceList(),
               let destDevice = devices.first(where: { (try? $0.readDeviceUID()) == newOutputUID }) {
                destVolume = destDevice.readOutputVolumeScalar()
                destSampleRate = (try? destDevice.readNominalSampleRate()) ?? 0
                let transport = destDevice.readTransportType()
                isBluetoothDestination = (transport == .bluetooth || transport == .bluetoothLE)
                logger.debug("[CROSSFADE] Destination device (fallback): volume=\(destVolume), sampleRate=\(destSampleRate)Hz, BT=\(isBluetoothDestination)")
            }
        }

        // Log sample rate mismatch but proceed with crossfade anyway
        // Crossfade is better than destructive switch because:
        // - Secondary tap is created BEFORE primary is destroyed
        // - No gap where audio leaks to system default output
        if sourceSampleRate > 0 && destSampleRate > 0 && sourceSampleRate != destSampleRate {
            logger.info("[CROSSFADE] Sample rate mismatch: source=\(sourceSampleRate)Hz, dest=\(destSampleRate)Hz - proceeding anyway (avoids audio leak)")
        }

        // Device volume compensation disabled - causes cumulative attenuation on round-trip switches
        // Keep compensation at 1.0 so slider directly controls output volume
        logger.info("[CROSSFADE] Device volumes: source=\(sourceVolume), dest=\(destVolume) (no compensation applied)")

        logger.info("[CROSSFADE] Step 2: Preparing crossfade state")

        // Enable crossfade BEFORE secondary tap starts, so it begins silent
        _crossfadeProgress = 0
        _secondarySampleCount = 0
        _secondarySamplesProcessed = 0  // Reset warmup counter for new secondary tap
        _isCrossfading = true
        OSMemoryBarrier()  // Ensure audio callbacks see crossfade state before secondary tap starts

        // Create secondary tap (it will start at sin(0) = 0 = silent)
        logger.info("[CROSSFADE] Step 3: Creating secondary tap for new device")
        try createSecondaryTap(for: newOutputUID)

        if isBluetoothDestination {
            logger.info("[CROSSFADE] Destination is Bluetooth - using extended warmup")
        }

        // Wait for secondary tap to warm up and start producing samples
        // Bluetooth devices need much longer warmup due to A2DP connection latency (can take 500ms+)
        let warmupMs = isBluetoothDestination ? 500 : 50
        logger.info("[CROSSFADE] Step 4: Waiting for secondary tap warmup (\(warmupMs)ms)...")
        try await Task.sleep(for: .milliseconds(UInt64(warmupMs)))

        logger.info("[CROSSFADE] Step 5: Crossfade in progress (\(CrossfadeConfig.duration * 1000)ms)")

        // Poll for completion (don't control timing - secondary callback does)
        // Wait for BOTH: crossfade animation complete AND secondary tap warmup complete
        // Bluetooth gets extended timeout to account for A2DP connection latency
        let timeoutMs = Int(CrossfadeConfig.duration * 1000) + (isBluetoothDestination ? 600 : 100)
        let pollIntervalMs: UInt64 = 5
        var elapsedMs: Int = 0

        while (_crossfadeProgress < 1.0 || _secondarySamplesProcessed < minimumWarmupSamples) && elapsedMs < timeoutMs {
            try await Task.sleep(for: .milliseconds(pollIntervalMs))
            elapsedMs += Int(pollIntervalMs)
        }

        // Small buffer to ensure final samples processed
        try await Task.sleep(for: .milliseconds(10))

        // Crossfade complete - destroy primary, promote secondary
        logger.info("[CROSSFADE] Crossfade complete, promoting secondary")

        destroyPrimaryTap()
        promoteSecondaryToPrimary()

        // Set _isCrossfading = false AFTER promotion to avoid race condition:
        // Callback checks _isCrossfading, and if false, uses eqProcessor.
        // eqProcessor must already be the promoted one when this happens.
        _isCrossfading = false
        OSMemoryBarrier()  // Ensure audio callback sees this before starting EQ processing

        logger.info("[CROSSFADE] Complete")
    }

    /// Creates a secondary tap + aggregate for crossfade.
    private func createSecondaryTap(for outputUID: String) throws {
        guard let streamInfo = resolveOutputStreamInfo(for: outputUID) else {
            throw NSError(domain: "ProcessTapController", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to resolve output stream for device \(outputUID)"])
        }

        // Create new process tap for the same app, matching target device stream format
        let processNumber = NSNumber(value: app.objectID)
        let tapDesc = CATapDescription(__processes: [processNumber], andDeviceUID: outputUID, withStream: streamInfo.streamIndex)
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped  // Must mute to prevent audio on system default after primary destroyed
        secondaryTapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary tap: \(err)"])
        }
        secondaryTapID = tapID
        let fallbackSampleRate = streamInfo.streamFormat.mSampleRate > 0
        ? streamInfo.streamFormat.mSampleRate
        : (try? streamInfo.deviceID.readNominalSampleRate()) ?? 48000
        updateSecondaryFormat(from: tapID, fallbackSampleRate: fallbackSampleRate)
        logger.debug("[CROSSFADE] Created secondary tap #\(tapID)")

        // Create aggregate device for new output
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-\(app.id)-secondary",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString
                ]
            ]
        ]

        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &secondaryAggregateID)
        guard err == noErr else {
            // Clean up tap
            AudioHardwareDestroyProcessTap(secondaryTapID)
            secondaryTapID = .unknown
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary aggregate: \(err)"])
        }
        logger.debug("[CROSSFADE] Created secondary aggregate #\(self.secondaryAggregateID)")

        // Initialize sample-accurate crossfade timing from secondary tap format
        let sampleRate = secondaryFormat?.sampleRate ?? fallbackSampleRate
        if AudioDeviceID(secondaryAggregateID).setNominalSampleRate(sampleRate) {
            logger.debug("[CROSSFADE] Secondary aggregate sample rate set to \(sampleRate) Hz (tap: \(describeASBD(secondaryFormat?.asbd ?? AudioStreamBasicDescription())))")
        }

        destroyConverter(&secondaryConverter)
        if let format = secondaryFormat {
            logger.debug("[CROSSFADE] Secondary tap format summary: \(describeASBD(format.asbd))")
            secondaryConverter = configureConverter(for: format, deviceID: AudioDeviceID(secondaryAggregateID))
            if secondaryConverter != nil {
                logger.debug("[CROSSFADE] Secondary converter enabled (input: \(describeASBD(format.asbd)) -> proc: 2ch float -> output: \(describeASBD(format.asbd)))")
            } else {
                logger.debug("[CROSSFADE] Secondary converter not required (format already safe)")
            }
        }

        _crossfadeTotalSamples = CrossfadeConfig.totalSamples(at: sampleRate)

        // Compute ramp coefficient for secondary device's sample rate
        let rampTimeSeconds: Float = 0.030  // 30ms smoothing (same as primary)
        secondaryRampCoefficient = 1 - exp(-1 / (Float(sampleRate) * rampTimeSeconds))

        // Initialize secondary volume to match primary for smooth handoff
        _secondaryCurrentVolume = _primaryCurrentVolume

        // Create IO proc for secondary
        err = AudioDeviceCreateIOProcIDWithBlock(&secondaryDeviceProcID, secondaryAggregateID, queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self else { return }
            self.processAudioSecondary(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            AudioHardwareDestroyAggregateDevice(secondaryAggregateID)
            AudioHardwareDestroyProcessTap(secondaryTapID)
            secondaryAggregateID = .unknown
            secondaryTapID = .unknown
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary IO proc: \(err)"])
        }

        // Start secondary device
        err = AudioDeviceStart(secondaryAggregateID, secondaryDeviceProcID)
        guard err == noErr else {
            if let procID = secondaryDeviceProcID {
                AudioDeviceDestroyIOProcID(secondaryAggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(secondaryAggregateID)
            AudioHardwareDestroyProcessTap(secondaryTapID)
            secondaryDeviceProcID = nil
            secondaryAggregateID = .unknown
            secondaryTapID = .unknown
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start secondary device: \(err)"])
        }

        logger.debug("[CROSSFADE] Secondary tap started")
    }

    /// Destroys the primary tap + aggregate.
    private func destroyPrimaryTap() {
        if aggregateDeviceID.isValid {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let procID = deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
        }

        deviceProcID = nil
        aggregateDeviceID = .unknown
        processTapID = .unknown
        tapDescription = nil
        primaryFormat = nil
        destroyConverter(&primaryConverter)
    }

    /// Cleans up secondary tap resources if crossfade fails.
    /// Must be called before falling back to destructive switch to prevent resource leaks.
    private func cleanupSecondaryTap() {
        // Reset crossfade state first
        _isCrossfading = false
        _crossfadeProgress = 0
        _secondarySampleCount = 0
        _secondarySamplesProcessed = 0
        OSMemoryBarrier()  // Ensure audio callback sees reset state

        // Clean up secondary tap resources if they exist
        if secondaryAggregateID.isValid {
            AudioDeviceStop(secondaryAggregateID, secondaryDeviceProcID)
            if let procID = secondaryDeviceProcID {
                AudioDeviceDestroyIOProcID(secondaryAggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(secondaryAggregateID)
        }
        if secondaryTapID.isValid {
            AudioHardwareDestroyProcessTap(secondaryTapID)
        }

        // Clear secondary references
        secondaryDeviceProcID = nil
        secondaryAggregateID = .unknown
        secondaryTapID = .unknown
        secondaryTapDescription = nil
        secondaryFormat = nil
        destroyConverter(&secondaryConverter)
    }

    /// Promotes secondary tap to primary after crossfade.
    private func promoteSecondaryToPrimary() {
        processTapID = secondaryTapID
        aggregateDeviceID = secondaryAggregateID
        deviceProcID = secondaryDeviceProcID
        tapDescription = secondaryTapDescription
        primaryFormat = secondaryFormat
        primaryConverter = secondaryConverter
        secondaryFormat = nil
        secondaryConverter = nil

        // Update ramp coefficient and EQ processor sample rate for new device
        // Read sample rate once to avoid redundant CoreAudio calls and potential inconsistency
        let deviceSampleRate = (try? aggregateDeviceID.readNominalSampleRate()) ?? 48000
        let rampTimeSeconds: Float = 0.030
        rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * rampTimeSeconds))
        eqProcessor?.updateSampleRate(deviceSampleRate)

        // Transfer volume state from secondary to primary (prevents volume jump)
        _primaryCurrentVolume = _secondaryCurrentVolume
        _secondaryCurrentVolume = 0

        // Reset crossfade state for next switch
        _crossfadeProgress = 0  // CRITICAL: Reset so new primary doesn't stay silent
        _secondarySampleCount = 0
        _crossfadeTotalSamples = 0

        // Clear secondary references
        secondaryTapID = .unknown
        secondaryAggregateID = .unknown
        secondaryDeviceProcID = nil
        secondaryTapDescription = nil
    }

    /// Fallback: Switches using destroy/recreate approach.
    private func performDestructiveDeviceSwitch(to newDeviceUID: String) async throws {
        let originalVolume = _volume

        // Use device UID directly (always explicit)
        let newOutputUID = newDeviceUID

        var sourceVolume: Float = 1.0
        var destVolume: Float = 1.0

        // Fast path: use cached device lookup (O(1))
        var cachedSource: AudioDevice?
        var cachedDest: AudioDevice?

        if let sourceUID = currentDeviceUID {
            if let monitor = deviceMonitor {
                cachedSource = monitor.device(for: sourceUID)
                cachedDest = monitor.device(for: newOutputUID)
            }

            // Use cached values if available
            if let source = cachedSource {
                sourceVolume = source.id.readOutputVolumeScalar()
            }
            if let dest = cachedDest {
                destVolume = dest.id.readOutputVolumeScalar()
            }

            // Fallback for any missing device
            if cachedSource == nil || cachedDest == nil {
                if let devices = try? AudioObjectID.readDeviceList() {
                    if cachedSource == nil,
                       let source = devices.first(where: { (try? $0.readDeviceUID()) == sourceUID }) {
                        sourceVolume = source.readOutputVolumeScalar()
                    }
                    if cachedDest == nil,
                       let dest = devices.first(where: { (try? $0.readDeviceUID()) == newOutputUID }) {
                        destVolume = dest.readOutputVolumeScalar()
                    }
                }
            }
        }

        // Device volume compensation disabled - causes cumulative attenuation on round-trip switches
        logger.info("[SWITCH-DESTROY] Device volumes: source=\(sourceVolume), dest=\(destVolume) (no compensation applied)")

        _forceSilence = true
        OSMemoryBarrier()  // Ensure audio thread sees this write immediately
        logger.info("[SWITCH-DESTROY] Enabled _forceSilence=true")

        try await Task.sleep(for: .milliseconds(100))

        try performDeviceSwitch(to: newDeviceUID)

        _primaryCurrentVolume = 0
        _volume = 0

        try await Task.sleep(for: .milliseconds(150))

        _forceSilence = false
        OSMemoryBarrier()  // Ensure audio thread sees this write before fade-in starts

        // Gradual fade-in
        for i in 1...10 {
            _volume = originalVolume * Float(i) / 10.0
            try await Task.sleep(for: .milliseconds(20))
        }

        logger.info("[SWITCH-DESTROY] Complete")
    }

    /// Internal destroy/recreate switch (used as fallback).
    /// Creates new tap+aggregate BEFORE destroying old to prevent audio leak to system default.
    private func performDeviceSwitch(to newDeviceUID: String) throws {
        // Use device UID directly (always explicit)
        let outputUID = newDeviceUID

        guard let streamInfo = resolveOutputStreamInfo(for: outputUID) else {
            throw NSError(domain: "ProcessTapController", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to resolve output stream for device \(outputUID)"])
        }

        // STEP 1: Create NEW tap (process will be muted by BOTH old and new taps)
        let processNumber = NSNumber(value: app.objectID)
        let newTapDesc = CATapDescription(__processes: [processNumber], andDeviceUID: outputUID, withStream: streamInfo.streamIndex)
        newTapDesc.uuid = UUID()
        newTapDesc.isPrivate = true
        newTapDesc.muteBehavior = .mutedWhenTapped

        var newTapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(newTapDesc, &newTapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create new tap: \(err)"])
        }

        // STEP 2: Create new aggregate with the new tap
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-\(app.id)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: newTapDesc.uuid.uuidString
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr else {
            // Cleanup tap on failure
            AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate: \(err)"])
        }

        let fallbackSampleRate = streamInfo.streamFormat.mSampleRate > 0
        ? streamInfo.streamFormat.mSampleRate
        : (try? streamInfo.deviceID.readNominalSampleRate()) ?? 48000
        _ = AudioDeviceID(newAggregateID).setNominalSampleRate(fallbackSampleRate)

        // STEP 3: Create and start IO proc for new aggregate
        var newDeviceProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newDeviceProcID, newAggregateID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        err = AudioDeviceStart(newAggregateID, newDeviceProcID)
        guard err == noErr else {
            if let procID = newDeviceProcID {
                AudioDeviceDestroyIOProcID(newAggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(err)"])
        }

        // STEP 4: NOW destroy old tap + aggregate (process still muted by new tap)
        if aggregateDeviceID.isValid {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let procID = deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
        }

        // STEP 5: Promote new to primary
        processTapID = newTapID
        tapDescription = newTapDesc
        aggregateDeviceID = newAggregateID
        deviceProcID = newDeviceProcID
        targetDeviceUID = newDeviceUID
        currentDeviceUID = outputUID

        updatePrimaryFormat(from: newTapID, fallbackSampleRate: fallbackSampleRate)
        destroyConverter(&primaryConverter)
        if let format = primaryFormat {
            logger.debug("[SWITCH-DESTROY] Primary tap format summary: \(describeASBD(format.asbd))")
            primaryConverter = configureConverter(for: format, deviceID: AudioDeviceID(aggregateDeviceID))
            if primaryConverter != nil {
                logger.debug("[SWITCH-DESTROY] Primary converter enabled (input: \(describeASBD(format.asbd)) -> proc: 2ch float -> output: \(describeASBD(format.asbd)))")
            } else {
                logger.debug("[SWITCH-DESTROY] Primary converter not required (format already safe)")
            }
        }

        // Update ramp coefficient and EQ coefficients for new device sample rate
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * 0.030))
            eqProcessor?.updateSampleRate(deviceSampleRate)
        }
    }

    /// Audio processing callback for PRIMARY tap - runs on CoreAudio's real-time HAL I/O thread.
    ///
    /// **RT SAFETY CONSTRAINTS - DO NOT:**
    /// - Allocate memory (malloc, Array append, String operations)
    /// - Acquire locks/mutexes
    /// - Use Objective-C messaging
    /// - Call print/logging functions
    /// - Perform file/network I/O
    ///
    /// Current implementation is RT-safe: only atomic Float reads and simple math.
    /// See: https://developer.apple.com/library/archive/qa/qa1467/_index.html
    private func processAudio(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)

        // Check silence flag first (atomic Bool read)
        // When silencing for device switch, output zeros to prevent clicks
        if _forceSilence {
            zeroOutputBuffers(outputBuffers)
            return
        }

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))
        let format = primaryFormat ?? TapFormat(
            asbd: AudioStreamBasicDescription(),
            channelCount: 2,
            isInterleaved: true,
            isFloat32: true,
            sampleRate: 48000
        )

        // Track peak level for VU meter (RT-safe: simple max tracking + smoothing)
        // Always measure INPUT signal so VU shows source activity even when muted
        // This helps users see "app is playing" and supports future EQ visualization
        if format.isFloat32 {
            let maxPeak = computePeak(inputBuffers: inputBuffers)
            let rawPeak = min(maxPeak, 1.0)
            _peakLevel = _peakLevel + levelSmoothingFactor * (rawPeak - _peakLevel)
        } else {
            _peakLevel = 0.0
        }

        // Check user mute flag (atomic Bool read)
        // When muted, output zeros but VU meter still shows source activity (measured above)
        if _isMuted {
            zeroOutputBuffers(outputBuffers)
            return
        }

        // Read target once at start of buffer (atomic Float read)
        let targetVol = _volume
        var currentVol = _primaryCurrentVolume

        // During crossfade, primary tap fades OUT using equal-power curve
        // cos(0) = 1.0, cos(π/2) = 0.0
        // CRITICAL: Also stay silent when progress >= 1.0 even if _isCrossfading is false,
        // to prevent race condition pop between setting flag and destroying tap
        let crossfadeMultiplier: Float
        if _isCrossfading {
            crossfadeMultiplier = cos(_crossfadeProgress * .pi / 2.0)
        } else if _crossfadeProgress >= 1.0 {
            // Crossfade completed but tap not yet destroyed - stay silent
            crossfadeMultiplier = 0.0
        } else {
            crossfadeMultiplier = 1.0
        }

        if let converter = primaryConverter {
            let processed = processWithConverter(
                converter: converter,
                format: format,
                inputBufferList: inputBufferList,
                outputBufferList: outputBufferList,
                targetVol: targetVol,
                currentVol: &currentVol,
                rampCoefficient: rampCoefficient,
                crossfadeMultiplier: crossfadeMultiplier,
                compensation: _isCrossfading ? 1.0 : _deviceVolumeCompensation,
                eqProcessor: eqProcessor,
                allowEQ: !_isCrossfading
            )
            if processed {
                _primaryCurrentVolume = currentVol
                return
            }
        }

        // If format isn't Float32 PCM, pass through untouched (avoid corrupting non-float buffers)
        guard format.isFloat32 else {
            copyInputToOutput(inputBuffers: inputBuffers, outputBuffers: outputBuffers)
            return
        }

        // Copy input to output with ramped gain and soft limiting
        let effectiveCompensation: Float = _isCrossfading ? 1.0 : _deviceVolumeCompensation
        processFloatBuffers(
            format: format,
            inputBuffers: inputBuffers,
            outputBuffers: outputBuffers,
            targetVol: targetVol,
            currentVol: &currentVol,
            rampCoefficient: rampCoefficient,
            crossfadeMultiplier: crossfadeMultiplier,
            compensation: effectiveCompensation
        )

        // Apply EQ processing (after volume, before output)
        // Only safe for interleaved stereo Float32
        if let eqProcessor = eqProcessor,
           !_isCrossfading,
           format.isInterleaved,
           format.channelCount == 2,
           outputBuffers.count == 1,
           let outputData = outputBuffers[0].mData {
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(outputBuffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let frameCount = sampleCount / 2  // Stereo frames
            eqProcessor.process(
                input: outputSamples,
                output: outputSamples,
                frameCount: frameCount
            )
        }

        // Store for next callback
        _primaryCurrentVolume = currentVol
    }

    /// Audio processing callback for SECONDARY tap.
    /// During crossfade: fades IN (0 → 1) while primary fades out.
    /// After promotion to primary: behaves identically to processAudio.
    /// OWNS crossfade timing via sample counting for sample-accurate transitions.
    private func processAudioSecondary(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))
        let format = secondaryFormat ?? TapFormat(
            asbd: AudioStreamBasicDescription(),
            channelCount: 2,
            isInterleaved: true,
            isFloat32: true,
            sampleRate: 48000
        )

        // Track peak level for VU meter (RT-safe: simple max tracking + smoothing)
        // Always measure INPUT signal so VU shows source activity even when muted
        var totalSamplesThisBuffer: Int = 0
        if format.isFloat32 {
            let maxPeak = computePeak(inputBuffers: inputBuffers)
            let rawPeak = min(maxPeak, 1.0)
            _peakLevel = _peakLevel + levelSmoothingFactor * (rawPeak - _peakLevel)
        } else {
            _peakLevel = 0.0
        }

        if inputBuffers.count > 0 {
            let firstBuffer = inputBuffers[0]
            totalSamplesThisBuffer = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
            if format.isInterleaved {
                let channels = max(1, format.channelCount)
                totalSamplesThisBuffer = totalSamplesThisBuffer / channels
            }
        }

        // Always update counters (needed for crossfade timing even when muted)
        _secondarySamplesProcessed += totalSamplesThisBuffer
        if _isCrossfading {
            _secondarySampleCount += Int64(totalSamplesThisBuffer)
        }

        // Check user mute flag (atomic Bool read)
        // When muted, output zeros but VU meter still shows source activity (measured above)
        if _isMuted {
            zeroOutputBuffers(outputBuffers)
            return
        }

        // Read target volume
        let targetVol = _volume
        var currentVol = _secondaryCurrentVolume

        // Compute crossfade multiplier and update progress (sample-accurate)
        var crossfadeMultiplier: Float = 1.0
        if _isCrossfading {
            // Update progress based on samples processed
            let progress = min(1.0, Float(_secondarySampleCount) / Float(max(1, _crossfadeTotalSamples)))
            _crossfadeProgress = progress
            // Equal-power fade IN: sin(0) = 0.0, sin(π/2) = 1.0
            crossfadeMultiplier = sin(progress * .pi / 2.0)
        }

        // Copy input to output with ramped gain and crossfade
        // Use secondaryRampCoefficient during crossfade (we ARE the secondary),
        // but switch to rampCoefficient after promotion to primary.
        // This prevents coefficient corruption when a new secondary is created during the next switch.
        let activeRampCoef = _isCrossfading ? secondaryRampCoefficient : rampCoefficient

        if let converter = secondaryConverter {
            let processed = processWithConverter(
                converter: converter,
                format: format,
                inputBufferList: inputBufferList,
                outputBufferList: outputBufferList,
                targetVol: targetVol,
                currentVol: &currentVol,
                rampCoefficient: activeRampCoef,
                crossfadeMultiplier: crossfadeMultiplier,
                compensation: _deviceVolumeCompensation,
                eqProcessor: eqProcessor,
                allowEQ: !_isCrossfading
            )
            if processed {
                _secondaryCurrentVolume = currentVol
                return
            }
        }

        // If format isn't Float32 PCM, pass through untouched (avoid corrupting non-float buffers)
        guard format.isFloat32 else {
            copyInputToOutput(inputBuffers: inputBuffers, outputBuffers: outputBuffers)
            return
        }

        processFloatBuffers(
            format: format,
            inputBuffers: inputBuffers,
            outputBuffers: outputBuffers,
            targetVol: targetVol,
            currentVol: &currentVol,
            rampCoefficient: activeRampCoef,
            crossfadeMultiplier: crossfadeMultiplier,
            compensation: _deviceVolumeCompensation
        )

        // Apply EQ after crossfade completes (when this tap becomes the primary)
        // Skip during crossfade to prevent glitches from mixing EQ states
        if let eqProcessor = eqProcessor,
           !_isCrossfading,
           format.isInterleaved,
           format.channelCount == 2,
           outputBuffers.count == 1,
           let outputData = outputBuffers[0].mData {
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(outputBuffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let frameCount = sampleCount / 2  // Stereo frames
            eqProcessor.process(
                input: outputSamples,
                output: outputSamples,
                frameCount: frameCount
            )
        }

        // Store for next callback
        _secondaryCurrentVolume = currentVol
    }

    // MARK: - RT-Safe Buffer Helpers

    @inline(__always)
    private func zeroOutputBuffers(_ outputBuffers: UnsafeMutableAudioBufferListPointer) {
        for outputBuffer in outputBuffers {
            guard let outputData = outputBuffer.mData else { continue }
            memset(outputData, 0, Int(outputBuffer.mDataByteSize))
        }
    }

    @inline(__always)
    private func copyInputToOutput(
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer
    ) {
        let bufferCount = min(inputBuffers.count, outputBuffers.count)
        guard bufferCount > 0 else { return }
        for index in 0..<bufferCount {
            let inputBuffer = inputBuffers[index]
            let outputBuffer = outputBuffers[index]
            guard let inputData = inputBuffer.mData,
                  let outputData = outputBuffer.mData else { continue }
            let byteCount = min(Int(inputBuffer.mDataByteSize), Int(outputBuffer.mDataByteSize))
            memcpy(outputData, inputData, byteCount)
        }
    }

    @inline(__always)
    private func computePeak(inputBuffers: UnsafeMutableAudioBufferListPointer) -> Float {
        var maxPeak: Float = 0.0
        for inputBuffer in inputBuffers {
            guard let inputData = inputBuffer.mData else { continue }
            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<sampleCount {
                let absSample = abs(inputSamples[i])
                if absSample > maxPeak {
                    maxPeak = absSample
                }
            }
        }
        return maxPeak
    }

    @inline(__always)
    private func processFloatBuffers(
        format: TapFormat,
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        targetVol: Float,
        currentVol: inout Float,
        rampCoefficient: Float,
        crossfadeMultiplier: Float,
        compensation: Float
    ) {
        let bufferCount = min(inputBuffers.count, outputBuffers.count)
        guard bufferCount > 0 else { return }

        let channels = max(1, format.channelCount)
        let shouldLimit = targetVol > 1.0

        if format.isInterleaved {
            for index in 0..<bufferCount {
                let inputBuffer = inputBuffers[index]
                let outputBuffer = outputBuffers[index]
                guard let inputData = inputBuffer.mData,
                      let outputData = outputBuffer.mData else { continue }

                let inputSamples = inputData.assumingMemoryBound(to: Float.self)
                let outputSamples = outputData.assumingMemoryBound(to: Float.self)
                let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

                var channelIndex = 0
                var frameGain: Float = currentVol * crossfadeMultiplier * compensation
                for i in 0..<sampleCount {
                    if channelIndex == 0 {
                        currentVol += (targetVol - currentVol) * rampCoefficient
                        frameGain = currentVol * crossfadeMultiplier * compensation
                    }

                    var sample = inputSamples[i] * frameGain
                    if shouldLimit {
                        sample = softLimit(sample)
                    }
                    outputSamples[i] = sample

                    channelIndex += 1
                    if channelIndex >= channels {
                        channelIndex = 0
                    }
                }
            }
        } else {
            let channelCount = min(channels, bufferCount)
            var frameCount = Int.max
            for channel in 0..<channelCount {
                let inputBuffer = inputBuffers[channel]
                let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
                frameCount = min(frameCount, sampleCount)
            }
            guard frameCount != Int.max else { return }

            for frame in 0..<frameCount {
                currentVol += (targetVol - currentVol) * rampCoefficient
                let frameGain = currentVol * crossfadeMultiplier * compensation

                for channel in 0..<channelCount {
                    let inputBuffer = inputBuffers[channel]
                    let outputBuffer = outputBuffers[channel]
                    guard let inputData = inputBuffer.mData,
                          let outputData = outputBuffer.mData else { continue }

                    let inputSamples = inputData.assumingMemoryBound(to: Float.self)
                    let outputSamples = outputData.assumingMemoryBound(to: Float.self)

                    var sample = inputSamples[frame] * frameGain
                    if shouldLimit {
                        sample = softLimit(sample)
                    }
                    outputSamples[frame] = sample
                }
            }
        }
    }

    @inline(__always)
    private func frameCount(
        bufferList: UnsafeMutableAudioBufferListPointer,
        bytesPerFrame: Int
    ) -> Int {
        guard bufferList.count > 0, bytesPerFrame > 0 else { return 0 }
        let buffer = bufferList[0]
        return Int(buffer.mDataByteSize) / bytesPerFrame
    }

    private func processWithConverter(
        converter: ConverterState,
        format: TapFormat,
        inputBufferList: UnsafePointer<AudioBufferList>,
        outputBufferList: UnsafeMutablePointer<AudioBufferList>,
        targetVol: Float,
        currentVol: inout Float,
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

        let inputFrames = frameCount(bufferList: inputBuffers, bytesPerFrame: inputBytesPerFrame)
        let outputFrames = frameCount(bufferList: outputBuffers, bytesPerFrame: outputBytesPerFrame)
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
            Self.converterInputProc,
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
        let procFormat = TapFormat(
            asbd: converter.procASBD,
            channelCount: 2,
            isInterleaved: true,
            isFloat32: true,
            sampleRate: converter.procASBD.mSampleRate
        )

        var outputSuccess = false
        withUnsafeMutablePointer(to: &procABL) { procPtr in
            let procBuffers = UnsafeMutableAudioBufferListPointer(procPtr)
            processFloatBuffers(
                format: procFormat,
                inputBuffers: procBuffers,
                outputBuffers: procBuffers,
                targetVol: targetVol,
                currentVol: &currentVol,
                rampCoefficient: rampCoefficient,
                crossfadeMultiplier: crossfadeMultiplier,
                compensation: compensation
            )

            if let eqProcessor = eqProcessor, allowEQ {
                let outputSamples = converter.procBuffer
                let frameCount = actualFrames
                eqProcessor.process(
                    input: outputSamples,
                    output: outputSamples,
                    frameCount: frameCount
                )
            }

            var outputContext = ConverterInputContext(
                bufferList: UnsafePointer(procPtr),
                frames: UInt32(actualFrames)
            )

            var outFrames: UInt32 = UInt32(min(actualFrames, outputFrames))
            let outputStatus = AudioConverterFillComplexBuffer(
                outputConverter,
                Self.converterInputProc,
                &outputContext,
                &outFrames,
                outputBufferList,
                nil
            )

            outputSuccess = (outputStatus == noErr)
        }

        return outputSuccess
    }

    /// Soft-knee limiter using asymptotic compression.
    /// Threshold at 0.8, smooth transition to ±1.0 ceiling.
    /// Output is guaranteed <= 1.0 for any finite input. Transparent for musical material.
    /// - Parameter sample: Input sample (may exceed ±1.0 when boosted)
    /// - Returns: Limited sample in range approximately ±1.0
    @inline(__always)
    private func softLimit(_ sample: Float) -> Float {
        let threshold: Float = 0.8
        let ceiling: Float = 1.0

        let absSample = abs(sample)
        if absSample <= threshold {
            return sample  // Below threshold: pass through
        }

        // Soft knee: smoothly compress above threshold
        let overshoot = absSample - threshold
        let headroom = ceiling - threshold  // 0.2
        // Asymptotic approach to ceiling
        let compressed = threshold + headroom * (overshoot / (overshoot + headroom))

        return sample >= 0 ? compressed : -compressed
    }

    /// Cleans up partially created CoreAudio resources on activation failure.
    /// Called when any step in activate() fails after resources were created.
    private func cleanupPartialActivation() {
        if let procID = deviceProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceProcID = nil
        }
        if aggregateDeviceID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = .unknown
        }
        primaryFormat = nil
        destroyConverter(&primaryConverter)
    }

    func invalidate() {
        guard activated else { return }
        activated = false

        logger.debug("Invalidating tap for \(self.app.name)")

        // Stop crossfade immediately if in progress
        _isCrossfading = false
        OSMemoryBarrier()  // Ensure audio callback sees this before teardown begins

        // Capture all IDs before clearing - teardown happens on background queue
        // to avoid blocking main thread (AudioDeviceDestroyIOProcID blocks until callback finishes)
        let primaryAggregate = aggregateDeviceID
        let primaryProcID = deviceProcID
        let primaryTap = processTapID
        let secAggregate = secondaryAggregateID
        let secProcID = secondaryDeviceProcID
        let secTap = secondaryTapID

        // Clear instance state immediately
        aggregateDeviceID = .unknown
        deviceProcID = nil
        processTapID = .unknown
        secondaryAggregateID = .unknown
        secondaryDeviceProcID = nil
        secondaryTapID = .unknown
        secondaryTapDescription = nil
        primaryFormat = nil
        secondaryFormat = nil
        destroyConverter(&primaryConverter)
        destroyConverter(&secondaryConverter)

        // Dispatch blocking teardown to background queue
        DispatchQueue.global(qos: .utility).async {
            // Clean up secondary resources if they exist
            // Check both aggregate ID and procID are valid before calling stop/destroy
            if secAggregate.isValid, let procID = secProcID {
                AudioDeviceStop(secAggregate, procID)
                AudioDeviceDestroyIOProcID(secAggregate, procID)
                AudioHardwareDestroyAggregateDevice(secAggregate)
            } else if secAggregate.isValid {
                // Aggregate exists but no procID - just destroy the aggregate
                AudioHardwareDestroyAggregateDevice(secAggregate)
            }
            if secTap.isValid {
                AudioHardwareDestroyProcessTap(secTap)
            }

            // Clean up primary resources
            // Check both aggregate ID and procID are valid before calling stop/destroy
            if primaryAggregate.isValid, let procID = primaryProcID {
                AudioDeviceStop(primaryAggregate, procID)
                AudioDeviceDestroyIOProcID(primaryAggregate, procID)
                AudioHardwareDestroyAggregateDevice(primaryAggregate)
            } else if primaryAggregate.isValid {
                // Aggregate exists but no procID - just destroy the aggregate
                AudioHardwareDestroyAggregateDevice(primaryAggregate)
            }
            if primaryTap.isValid {
                AudioHardwareDestroyProcessTap(primaryTap)
            }
        }

        logger.info("Tap invalidated for \(self.app.name)")
    }

    deinit {
        invalidate()
    }
}
