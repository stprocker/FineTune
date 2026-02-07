// FineTune/Audio/ProcessTapController.swift
import AudioToolbox
import os
#if canImport(FineTuneCore)
import FineTuneCore
#endif

final class ProcessTapController {
    // CrossfadeConfig is now defined in Crossfade/CrossfadeState.swift

    let app: AudioApp
    private let logger: Logger
    // Note: This queue is passed to AudioDeviceCreateIOProcIDWithBlock but the actual
    // audio callback runs on CoreAudio's real-time HAL I/O thread, not this queue.
    private let queue: DispatchQueue

    /// Weak reference to device monitor for O(1) device lookups during crossfade
    private weak var deviceMonitor: AudioDeviceMonitor?

#if DEBUG
    /// Test-only hook for forcing performDeviceSwitch outcomes.
    var testPerformDeviceSwitchHook: ((String) throws -> Void)?
    /// Test-only hook for controlling async sleeps in switch paths.
    var testSleepHook: ((UInt64) async throws -> Void)?
#endif

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

    // --- Diagnostic counters (RT-safe: atomic increments on 64-bit ARM) ---
    private nonisolated(unsafe) var _diagCallbackCount: UInt64 = 0
    private nonisolated(unsafe) var _diagInputHasData: UInt64 = 0
    private nonisolated(unsafe) var _diagOutputWritten: UInt64 = 0
    private nonisolated(unsafe) var _diagSilencedForce: UInt64 = 0
    private nonisolated(unsafe) var _diagSilencedMute: UInt64 = 0
    private nonisolated(unsafe) var _diagConverterUsed: UInt64 = 0
    private nonisolated(unsafe) var _diagConverterFailed: UInt64 = 0
    private nonisolated(unsafe) var _diagDirectFloat: UInt64 = 0
    private nonisolated(unsafe) var _diagNonFloatPassthrough: UInt64 = 0
    private nonisolated(unsafe) var _diagEmptyInput: UInt64 = 0  // Callbacks with zero-length or nil input buffers
    private nonisolated(unsafe) var _diagLastInputPeak: Float = 0
    private nonisolated(unsafe) var _diagLastOutputPeak: Float = 0
    private nonisolated(unsafe) var _diagFormatChannels: UInt32 = 0
    private nonisolated(unsafe) var _diagFormatIsFloat: Bool = false
    private nonisolated(unsafe) var _diagFormatIsInterleaved: Bool = false
    private nonisolated(unsafe) var _diagFormatSampleRate: Float = 0

    // Current device volume scalar (0-1) for VU meter calculation
    // Updated from main thread when device volume changes
    private nonisolated(unsafe) var _currentDeviceVolume: Float = 1.0

    // Current device mute state for VU meter calculation
    private nonisolated(unsafe) var _isDeviceMuted: Bool = false

    /// Current peak audio level (0-1) for VU meter visualization
    /// Read from main thread, written from audio callback (atomic Float)
    var audioLevel: Float { _peakLevel }

    // MARK: - Diagnostics

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

    var diagnostics: TapDiagnostics {
        TapDiagnostics(
            callbackCount: _diagCallbackCount,
            inputHasData: _diagInputHasData,
            outputWritten: _diagOutputWritten,
            silencedForce: _diagSilencedForce,
            silencedMute: _diagSilencedMute,
            converterUsed: _diagConverterUsed,
            converterFailed: _diagConverterFailed,
            directFloat: _diagDirectFloat,
            nonFloatPassthrough: _diagNonFloatPassthrough,
            emptyInput: _diagEmptyInput,
            lastInputPeak: _diagLastInputPeak,
            lastOutputPeak: _diagLastOutputPeak,
            formatChannels: _diagFormatChannels,
            formatIsFloat: _diagFormatIsFloat,
            formatIsInterleaved: _diagFormatIsInterleaved,
            formatSampleRate: _diagFormatSampleRate,
            volume: _volume,
            crossfadeActive: crossfadeState.isActive,
            primaryCurrentVolume: _primaryCurrentVolume
        )
    }

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

    // Tap format info (TapFormat is defined in Types/TapFormat.swift)
    private nonisolated(unsafe) var primaryFormat: TapFormat?
    private nonisolated(unsafe) var secondaryFormat: TapFormat?

    // Converter state (ConverterState is defined in Processing/AudioFormatConverter.swift)
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

    // Core Audio resources (encapsulated for safe cleanup)
    private var primaryResources = TapResources()
    private var secondaryResources = TapResources()
    private var activated = false

    // Crossfade state machine (RT-safe, lock-free access from audio callbacks)
    private nonisolated(unsafe) var crossfadeState = CrossfadeState()

    /// When true, taps use `.mutedWhenTapped` to silence original audio (normal operation).
    /// When false, taps use `.unmuted` so original audio still plays (safe for first launch
    /// before system audio permission is confirmed — prevents silence if the app is killed).
    private let muteOriginal: Bool

    // MARK: - Injectable Timing (for deterministic tests)

    /// Warmup wait before crossfade begins (ms). Bluetooth uses extended warmup.
    var crossfadeWarmupMs: Int = 50
    var crossfadeWarmupBTMs: Int = 500

    /// Crossfade completion timeout extension beyond crossfade duration (ms).
    var crossfadeTimeoutPaddingMs: Int = 100
    var crossfadeTimeoutPaddingBTMs: Int = 600

    /// Poll interval during crossfade completion check (ms).
    var crossfadePollIntervalMs: UInt64 = 5

    /// Post-crossfade buffer for final samples (ms).
    var crossfadePostBufferMs: Int = 10

    /// Destructive switch silence/startup delays (ms).
    var destructiveSwitchPreSilenceMs: UInt64 = 100
    var destructiveSwitchPostSilenceMs: UInt64 = 150
    var destructiveSwitchFadeInMs: UInt64 = 100

    init(app: AudioApp, targetDeviceUID: String, deviceMonitor: AudioDeviceMonitor? = nil, muteOriginal: Bool = true, queue: DispatchQueue? = nil) {
        self.app = app
        self.targetDeviceUID = targetDeviceUID
        self.deviceMonitor = deviceMonitor
        self.muteOriginal = muteOriginal
        self.queue = queue ?? DispatchQueue(label: "ProcessTapController", qos: .userInitiated)
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "ProcessTapController(\(app.name))")
    }

    // MARK: - Tap/Device Format Helpers

    /// Resolves output stream info using the shared extension.
    /// Wrapper to add logging on failure.
    private func resolveOutputStreamInfo(for deviceUID: String) -> OutputStreamInfo? {
        guard let info = AudioObjectID.resolveOutputStreamInfo(for: deviceUID, using: deviceMonitor) else {
            logger.error("Failed to resolve output stream for device UID: \(deviceUID)")
            return nil
        }
        return info
    }

    /// Creates a TapFormat from an ASBD (delegated to TapFormat constructor)
    private func makeTapFormat(from asbd: AudioStreamBasicDescription, fallbackSampleRate: Double) -> TapFormat {
        TapFormat(asbd: asbd, fallbackSampleRate: fallbackSampleRate)
    }

    /// Human-readable format description (delegated to TapFormat.description)
    private func describeASBD(_ asbd: AudioStreamBasicDescription) -> String {
        TapFormat(asbd: asbd).description
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

    // MARK: - Converter Setup (delegated to AudioFormatConverter)

    private func configureConverter(
        for format: TapFormat,
        deviceID: AudioDeviceID
    ) -> ConverterState? {
        AudioFormatConverter.configure(for: format, deviceID: deviceID, logger: logger)
    }

    private func destroyConverter(_ state: inout ConverterState?) {
        AudioFormatConverter.destroy(&state)
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

        logger.debug("Target device stream format: \(self.describeASBD(streamInfo.streamFormat))")

        // Create process tap that matches the target device stream format.
        let processNumber = NSNumber(value: app.objectID)
        let tapDesc = CATapDescription(__processes: [processNumber], andDeviceUID: outputUID, withStream: streamInfo.streamIndex)
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = muteOriginal ? .mutedWhenTapped : .unmuted
        self.primaryResources.tapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(err)"])
        }

        primaryResources.tapID = tapID
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

        primaryResources.aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &primaryResources.aggregateDeviceID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(err)"])
        }

        logger.debug("Created aggregate device #\(self.primaryResources.aggregateDeviceID)")

        // Use OUTPUT DEVICE sample rate for the aggregate, not the tap's rate.
        // Process taps may report the app's internal rate (e.g., Chromium uses 24000 Hz)
        // which the output device may not support (e.g., AirPods require 48000 Hz).
        // CoreAudio's drift compensation on the tap sub-device handles resampling.
        let deviceSampleRate = fallbackSampleRate
        let tapSampleRate = primaryFormat?.sampleRate ?? fallbackSampleRate
        if tapSampleRate != deviceSampleRate {
            logger.info("Tap sample rate (\(tapSampleRate) Hz) differs from device (\(deviceSampleRate) Hz) — using device rate for aggregate")
        }
        if AudioDeviceID(primaryResources.aggregateDeviceID).setNominalSampleRate(deviceSampleRate) {
            logger.debug("Aggregate sample rate set to \(deviceSampleRate) Hz (tap: \(self.describeASBD(self.primaryFormat?.asbd ?? AudioStreamBasicDescription())))")
        } else {
            logger.warning("Failed to set aggregate sample rate to \(deviceSampleRate) Hz")
        }

        destroyConverter(&primaryConverter)
        if let format = primaryFormat {
            logger.debug("Primary tap format summary: \(self.describeASBD(format.asbd))")
            primaryConverter = configureConverter(for: format, deviceID: AudioDeviceID(primaryResources.aggregateDeviceID))
            if primaryConverter != nil {
                logger.debug("Primary converter enabled (input: \(self.describeASBD(format.asbd)) -> proc: 2ch float -> output: \(self.describeASBD(format.asbd)))")
            } else {
                logger.debug("Primary converter not required (format already safe)")
            }
        }

        if let format = primaryFormat, !format.isFloat32 {
            logger.warning("Non-float tap format detected, conversion required: \(self.describeASBD(format.asbd))")
        }

        // Compute ramp coefficient from device sample rate (aggregate callback rate)
        rampCoefficient = VolumeRamper.computeCoefficient(sampleRate: deviceSampleRate, rampTime: VolumeRamper.defaultRampTime)
        logger.debug("Configured for sample rate: \(deviceSampleRate) Hz, Ramp: \(self.rampCoefficient)")

        // Initialize EQ processor with device sample rate
        eqProcessor = EQProcessor(sampleRate: deviceSampleRate)

        // Create IO proc with gain processing
        err = AudioDeviceCreateIOProcIDWithBlock(&primaryResources.deviceProcID, primaryResources.aggregateDeviceID, queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self else { return }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        // Start the device
        err = AudioDeviceStart(primaryResources.aggregateDeviceID, primaryResources.deviceProcID)
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

        // Diagnostic: log full activation details for pipeline troubleshooting
        if let format = primaryFormat {
            logger.info("[DIAG] Activation complete: format=\(format.description), converter=\(self.primaryConverter != nil), aggDeviceID=\(self.primaryResources.aggregateDeviceID), rampCoeff=\(self.rampCoefficient)")
        }
    }

    /// Switches the output device using dual-tap crossfade for seamless transition.
    /// Creates a second tap+aggregate for the new device, crossfades, then destroys the old one.
    func switchDevice(to newDeviceUID: String) async throws {
        guard activated else {
            targetDeviceUID = newDeviceUID
            logger.debug("[SWITCH] Not activated, just updating target to \(newDeviceUID)")
            return
        }

        // Skip if already on the target device (can happen when a cancelled switch
        // leaves us on the original device and the new switch targets the same device)
        guard currentDeviceUID != newDeviceUID else {
            logger.debug("[SWITCH] Already on target device \(newDeviceUID), skipping")
            targetDeviceUID = newDeviceUID
            return
        }

        try Task.checkCancellation()

        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("[SWITCH] === START === \(self.app.name) -> \(newDeviceUID)")

        // Use device UID directly (always explicit)
        let newOutputUID = newDeviceUID

        do {
            // Try crossfade approach
            try await performCrossfadeSwitch(to: newOutputUID)
        } catch {
            // Always clean up secondary tap resources on crossfade failure
            cleanupSecondaryTap()

            // If cancelled by a newer switch, don't attempt destructive fallback —
            // the newer switch will handle routing to the correct device.
            if Task.isCancelled {
                logger.info("[SWITCH] Cancelled during crossfade for \(self.app.name), aborting")
                throw CancellationError()
            }

            // Fall back to destroy/recreate if crossfade fails
            logger.warning("[SWITCH] Crossfade failed: \(error.localizedDescription), using fallback")
            try await performDestructiveDeviceSwitch(to: newDeviceUID)
        }

        // Final cancellation check before committing state
        try Task.checkCancellation()

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

        // Enable crossfade BEFORE secondary tap starts, so it begins silent.
        // NOTE: Can't use crossfadeState.beginCrossfade(at:) here because we don't know
        // the sample rate until after tap creation. isActive must be true before the
        // secondary callback starts to ensure secondaryMultiplier returns 0 (silent).
        // totalSamples is set later in createSecondaryTap() once sample rate is known.
        crossfadeState.progress = 0
        crossfadeState.secondarySampleCount = 0
        crossfadeState.secondarySamplesProcessed = 0
        crossfadeState.isActive = true
        OSMemoryBarrier()  // Ensure audio callbacks see crossfade state before secondary tap starts

        // Create secondary tap (starts at sin(0) = 0 = silent because isActive=true)
        logger.info("[CROSSFADE] Step 3: Creating secondary tap for new device")
        try createSecondaryTap(for: newOutputUID)

        if isBluetoothDestination {
            logger.info("[CROSSFADE] Destination is Bluetooth - using extended warmup")
        }

        // Wait for secondary tap to warm up and start producing samples
        // Bluetooth devices need much longer warmup due to A2DP connection latency (can take 500ms+)
        let warmupMs = isBluetoothDestination ? crossfadeWarmupBTMs : crossfadeWarmupMs
        logger.info("[CROSSFADE] Step 4: Waiting for secondary tap warmup (\(warmupMs)ms)...")
        try await Task.sleep(for: .milliseconds(UInt64(warmupMs)))

        logger.info("[CROSSFADE] Step 5: Crossfade in progress (\(CrossfadeConfig.duration * 1000)ms)")

        // Poll for completion (don't control timing - secondary callback does)
        // Wait for BOTH: crossfade animation complete AND secondary tap warmup complete
        // Bluetooth gets extended timeout to account for A2DP connection latency
        let timeoutMs = Int(CrossfadeConfig.duration * 1000) + (isBluetoothDestination ? crossfadeTimeoutPaddingBTMs : crossfadeTimeoutPaddingMs)
        let pollIntervalMs: UInt64 = crossfadePollIntervalMs
        var elapsedMs: Int = 0

        while (!crossfadeState.isCrossfadeComplete || !crossfadeState.isWarmupComplete) && elapsedMs < timeoutMs {
            try await Task.sleep(for: .milliseconds(pollIntervalMs))
            elapsedMs += Int(pollIntervalMs)
        }

        // Verify secondary tap is actually producing audio before destroying primary.
        // If warmup never completed, the secondary tap isn't working — fall back to
        // destructive switch rather than promoting a non-functioning tap.
        if !crossfadeState.isWarmupComplete {
            let samplesProcessed = crossfadeState.secondarySamplesProcessed
            logger.error("[CROSSFADE] Secondary tap warmup incomplete after \(elapsedMs)ms (processed: \(samplesProcessed)/\(CrossfadeState.minimumWarmupSamples) samples)")
            throw NSError(domain: "ProcessTapController", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Secondary tap warmup incomplete after \(elapsedMs)ms"])
        }

        // Small buffer to ensure final samples processed
        try await Task.sleep(for: .milliseconds(Int64(crossfadePostBufferMs)))

        // Crossfade complete - destroy primary, promote secondary
        logger.info("[CROSSFADE] Crossfade complete (progress: \(self.crossfadeState.progress), elapsed: \(elapsedMs)ms), promoting secondary")

        destroyPrimaryTap()
        promoteSecondaryToPrimary()  // Also resets crossfade state after promotion

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
        tapDesc.muteBehavior = muteOriginal ? .mutedWhenTapped : .unmuted
        secondaryResources.tapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary tap: \(err)"])
        }
        secondaryResources.tapID = tapID
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

        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &secondaryResources.aggregateDeviceID)
        guard err == noErr else {
            // Clean up tap
            AudioHardwareDestroyProcessTap(secondaryResources.tapID)
            secondaryResources.tapID = .unknown
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary aggregate: \(err)"])
        }
        logger.debug("[CROSSFADE] Created secondary aggregate #\(self.secondaryResources.aggregateDeviceID)")

        // Use OUTPUT DEVICE sample rate for the aggregate (same fix as activate())
        let deviceSampleRate = fallbackSampleRate
        if AudioDeviceID(secondaryResources.aggregateDeviceID).setNominalSampleRate(deviceSampleRate) {
            logger.debug("[CROSSFADE] Secondary aggregate sample rate set to \(deviceSampleRate) Hz (tap: \(self.describeASBD(self.secondaryFormat?.asbd ?? AudioStreamBasicDescription())))")
        }

        destroyConverter(&secondaryConverter)
        if let format = secondaryFormat {
            logger.debug("[CROSSFADE] Secondary tap format summary: \(self.describeASBD(format.asbd))")
            secondaryConverter = configureConverter(for: format, deviceID: AudioDeviceID(secondaryResources.aggregateDeviceID))
            if secondaryConverter != nil {
                logger.debug("[CROSSFADE] Secondary converter enabled (input: \(self.describeASBD(format.asbd)) -> proc: 2ch float -> output: \(self.describeASBD(format.asbd)))")
            } else {
                logger.debug("[CROSSFADE] Secondary converter not required (format already safe)")
            }
        }

        crossfadeState.totalSamples = CrossfadeConfig.totalSamples(at: deviceSampleRate)

        // Compute ramp coefficient for secondary device's sample rate
        secondaryRampCoefficient = VolumeRamper.computeCoefficient(sampleRate: deviceSampleRate, rampTime: VolumeRamper.defaultRampTime)

        // Initialize secondary volume to match primary for smooth handoff
        _secondaryCurrentVolume = _primaryCurrentVolume

        // Create IO proc for secondary
        err = AudioDeviceCreateIOProcIDWithBlock(&secondaryResources.deviceProcID, secondaryResources.aggregateDeviceID, queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self else { return }
            self.processAudioSecondary(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            AudioHardwareDestroyAggregateDevice(secondaryResources.aggregateDeviceID)
            AudioHardwareDestroyProcessTap(secondaryResources.tapID)
            secondaryResources.aggregateDeviceID = .unknown
            secondaryResources.tapID = .unknown
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary IO proc: \(err)"])
        }

        // Start secondary device
        err = AudioDeviceStart(secondaryResources.aggregateDeviceID, secondaryResources.deviceProcID)
        guard err == noErr else {
            if let procID = secondaryResources.deviceProcID {
                AudioDeviceDestroyIOProcID(secondaryResources.aggregateDeviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(secondaryResources.aggregateDeviceID)
            AudioHardwareDestroyProcessTap(secondaryResources.tapID)
            secondaryResources.deviceProcID = nil
            secondaryResources.aggregateDeviceID = .unknown
            secondaryResources.tapID = .unknown
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start secondary device: \(err)"])
        }

        logger.debug("[CROSSFADE] Secondary tap started")
    }

    /// Destroys the primary tap + aggregate.
    private func destroyPrimaryTap() {
        primaryResources.destroy()
        primaryFormat = nil
        destroyConverter(&primaryConverter)
    }

    /// Cleans up secondary tap resources if crossfade fails.
    /// Must be called before falling back to destructive switch to prevent resource leaks.
    private func cleanupSecondaryTap() {
        // Reset crossfade state (includes memory barrier for audio callback visibility)
        crossfadeState.complete()

        // Clean up secondary CoreAudio resources
        secondaryResources.destroy()
        secondaryFormat = nil
        destroyConverter(&secondaryConverter)
    }

    /// Promotes secondary tap to primary after crossfade.
    private func promoteSecondaryToPrimary() {
        // Transfer resources from secondary to primary
        primaryResources = secondaryResources
        secondaryResources = TapResources()  // Clear secondary (no destruction - resources are now primary's)

        primaryFormat = secondaryFormat
        primaryConverter = secondaryConverter
        secondaryFormat = nil
        secondaryConverter = nil

        // Update ramp coefficient and EQ processor sample rate for new device
        let deviceSampleRate = (try? primaryResources.aggregateDeviceID.readNominalSampleRate()) ?? 48000
        rampCoefficient = VolumeRamper.computeCoefficient(sampleRate: deviceSampleRate, rampTime: VolumeRamper.defaultRampTime)
        eqProcessor?.updateSampleRate(deviceSampleRate)

        // Transfer volume state from secondary to primary (prevents volume jump)
        _primaryCurrentVolume = _secondaryCurrentVolume
        _secondaryCurrentVolume = 0

        // Reset crossfade state for next switch (includes isActive=false + OSMemoryBarrier)
        // CRITICAL: This must happen AFTER all state is transferred so audio callback
        // sees the promoted resources before it checks isActive for EQ processing
        crossfadeState.complete()
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
        defer {
            _forceSilence = false
            OSMemoryBarrier()
        }

        try await sleepForSwitch(milliseconds: destructiveSwitchPreSilenceMs)

        try performDeviceSwitchWithHook(to: newDeviceUID)

        // Start from silence; the per-sample volume ramper (~30ms exponential ramp)
        // will smoothly bring volume back to target without racing with user changes.
        _primaryCurrentVolume = 0
        _volume = originalVolume

        try await sleepForSwitch(milliseconds: destructiveSwitchPostSilenceMs)

        _forceSilence = false
        OSMemoryBarrier()  // Ensure audio thread sees this write before processing resumes

        // Allow the built-in volume ramper to complete the fade-in (~90ms to 95%)
        try await sleepForSwitch(milliseconds: destructiveSwitchFadeInMs)

        logger.info("[SWITCH-DESTROY] Complete")
    }

    private func performDeviceSwitchWithHook(to newDeviceUID: String) throws {
#if DEBUG
        if let testPerformDeviceSwitchHook {
            try testPerformDeviceSwitchHook(newDeviceUID)
            return
        }
#endif
        try performDeviceSwitch(to: newDeviceUID)
    }

    private func sleepForSwitch(milliseconds: UInt64) async throws {
#if DEBUG
        if let testSleepHook {
            try await testSleepHook(milliseconds)
            return
        }
#endif
        try await Task.sleep(for: .milliseconds(Int64(milliseconds)))
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
        newTapDesc.muteBehavior = muteOriginal ? .mutedWhenTapped : .unmuted

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
        if primaryResources.aggregateDeviceID.isValid {
            AudioDeviceStop(primaryResources.aggregateDeviceID, primaryResources.deviceProcID)
            if let procID = primaryResources.deviceProcID {
                AudioDeviceDestroyIOProcID(primaryResources.aggregateDeviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(primaryResources.aggregateDeviceID)
        }
        if primaryResources.tapID.isValid {
            AudioHardwareDestroyProcessTap(primaryResources.tapID)
        }

        // STEP 5: Promote new to primary
        primaryResources.tapID = newTapID
        primaryResources.tapDescription = newTapDesc
        primaryResources.aggregateDeviceID = newAggregateID
        primaryResources.deviceProcID = newDeviceProcID
        targetDeviceUID = newDeviceUID
        currentDeviceUID = outputUID

        updatePrimaryFormat(from: newTapID, fallbackSampleRate: fallbackSampleRate)
        destroyConverter(&primaryConverter)
        if let format = primaryFormat {
            logger.debug("[SWITCH-DESTROY] Primary tap format summary: \(self.describeASBD(format.asbd))")
            primaryConverter = configureConverter(for: format, deviceID: AudioDeviceID(primaryResources.aggregateDeviceID))
            if primaryConverter != nil {
                logger.debug("[SWITCH-DESTROY] Primary converter enabled (input: \(self.describeASBD(format.asbd)) -> proc: 2ch float -> output: \(self.describeASBD(format.asbd)))")
            } else {
                logger.debug("[SWITCH-DESTROY] Primary converter not required (format already safe)")
            }
        }

        // Update ramp coefficient and EQ coefficients for new device sample rate
        if let deviceSampleRate = try? primaryResources.aggregateDeviceID.readNominalSampleRate() {
            rampCoefficient = VolumeRamper.computeCoefficient(sampleRate: deviceSampleRate, rampTime: VolumeRamper.defaultRampTime)
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
        _diagCallbackCount += 1

        // Check silence flag first (atomic Bool read)
        // When silencing for device switch, output zeros to prevent clicks
        if _forceSilence {
            _diagSilencedForce += 1
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

        // Record format info (RT-safe atomic writes)
        _diagFormatChannels = UInt32(format.channelCount)
        _diagFormatIsFloat = format.isFloat32
        _diagFormatIsInterleaved = format.isInterleaved
        _diagFormatSampleRate = Float(format.sampleRate)

        // Track peak level for VU meter (RT-safe: simple max tracking + smoothing)
        // Always measure INPUT signal so VU shows source activity even when muted
        // This helps users see "app is playing" and supports future EQ visualization
        // Check if input buffers have any data at all
        var hasAnyInputData = false
        if inputBuffers.count > 0 && inputBuffers[0].mDataByteSize > 0 && inputBuffers[0].mData != nil {
            hasAnyInputData = true
        }
        if !hasAnyInputData {
            _diagEmptyInput += 1
        }

        if format.isFloat32 {
            let maxPeak = computePeak(inputBuffers: inputBuffers)
            let rawPeak = min(maxPeak, 1.0)
            _peakLevel = _peakLevel + levelSmoothingFactor * (rawPeak - _peakLevel)
            if rawPeak > 0 {
                _diagInputHasData += 1
                _diagLastInputPeak = rawPeak
            }
        } else {
            _peakLevel = 0.0
        }

        // Check user mute flag (atomic Bool read)
        // When muted, output zeros but VU meter still shows source activity (measured above)
        if _isMuted {
            _diagSilencedMute += 1
            zeroOutputBuffers(outputBuffers)
            return
        }

        // Read target once at start of buffer (atomic Float read)
        let targetVol = _volume
        var currentVol = _primaryCurrentVolume

        // During crossfade, primary tap fades OUT using equal-power curve (delegated to CrossfadeState)
        let crossfadeMultiplier = crossfadeState.primaryMultiplier

        if let converter = primaryConverter {
            _diagConverterUsed += 1
            let processed = processWithConverter(
                converter: converter,
                format: format,
                inputBufferList: inputBufferList,
                outputBufferList: outputBufferList,
                targetVol: targetVol,
                currentVol: &currentVol,
                rampCoefficient: rampCoefficient,
                crossfadeMultiplier: crossfadeMultiplier,
                compensation: crossfadeState.isActive ? 1.0 : _deviceVolumeCompensation,
                eqProcessor: eqProcessor,
                allowEQ: !crossfadeState.isActive
            )
            if processed {
                _diagOutputWritten += 1
                _diagLastOutputPeak = computeOutputPeak(outputBuffers)
                _primaryCurrentVolume = currentVol
                return
            }
            _diagConverterFailed += 1
        }

        // If format isn't Float32 PCM, pass through untouched (avoid corrupting non-float buffers)
        // During crossfade, silence non-float output to prevent doubled audio from both taps
        guard format.isFloat32 else {
            _diagNonFloatPassthrough += 1
            if crossfadeMultiplier < 1.0 {
                zeroOutputBuffers(outputBuffers)
            } else {
                copyInputToOutput(inputBuffers: inputBuffers, outputBuffers: outputBuffers)
            }
            _diagOutputWritten += 1
            return
        }

        _diagDirectFloat += 1

        // Copy input to output with ramped gain and soft limiting
        let effectiveCompensation: Float = crossfadeState.isActive ? 1.0 : _deviceVolumeCompensation
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
           !crossfadeState.isActive,
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

        _diagOutputWritten += 1
        _diagLastOutputPeak = computeOutputPeak(outputBuffers)

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
        _diagCallbackCount += 1

        // Check silence flag first (atomic Bool read)
        if _forceSilence {
            _diagSilencedForce += 1
            zeroOutputBuffers(outputBuffers)
            return
        }

        let format = secondaryFormat ?? TapFormat(
            asbd: AudioStreamBasicDescription(),
            channelCount: 2,
            isInterleaved: true,
            isFloat32: true,
            sampleRate: 48000
        )

        // Record format info (RT-safe atomic writes)
        _diagFormatChannels = UInt32(format.channelCount)
        _diagFormatIsFloat = format.isFloat32
        _diagFormatIsInterleaved = format.isInterleaved
        _diagFormatSampleRate = Float(format.sampleRate)

        // Track peak level for VU meter (RT-safe: simple max tracking + smoothing)
        // Always measure INPUT signal so VU shows source activity even when muted
        var totalSamplesThisBuffer: Int = 0
        if format.isFloat32 {
            let maxPeak = computePeak(inputBuffers: inputBuffers)
            let rawPeak = min(maxPeak, 1.0)
            _peakLevel = _peakLevel + levelSmoothingFactor * (rawPeak - _peakLevel)
            if rawPeak > 0 {
                _diagInputHasData += 1
                _diagLastInputPeak = rawPeak
            }
        } else {
            _peakLevel = 0.0
        }

        if inputBuffers.count > 0 {
            let firstBuffer = inputBuffers[0]
            // Use mBytesPerFrame for correct frame counting (handles padded formats like 24-bit in 32-bit containers)
            let bytesPerFrame = max(1, Int(format.asbd.mBytesPerFrame))
            if format.isInterleaved {
                // For interleaved: bytes / bytesPerFrame = frames
                totalSamplesThisBuffer = Int(firstBuffer.mDataByteSize) / bytesPerFrame
            } else {
                // For non-interleaved: mBytesPerFrame is per-channel, so it's bytes per sample
                // (e.g., 24-bit in 32-bit container: mBytesPerFrame=4, not mBitsPerChannel/8=3)
                totalSamplesThisBuffer = Int(firstBuffer.mDataByteSize) / bytesPerFrame
            }
        }

        // Update crossfade counters and progress (needed for timing even when muted)
        // updateProgress handles: secondarySamplesProcessed, secondarySampleCount, and progress calculation
        _ = crossfadeState.updateProgress(samples: totalSamplesThisBuffer)

        // Check user mute flag (atomic Bool read)
        // When muted, output zeros but VU meter still shows source activity (measured above)
        if _isMuted {
            _diagSilencedMute += 1
            zeroOutputBuffers(outputBuffers)
            return
        }

        // Read target volume
        let targetVol = _volume
        var currentVol = _secondaryCurrentVolume

        // Get crossfade multiplier (equal-power fade IN: sin(0) = 0, sin(π/2) = 1)
        let crossfadeMultiplier = crossfadeState.secondaryMultiplier

        // Copy input to output with ramped gain and crossfade
        // Use secondaryRampCoefficient during crossfade (we ARE the secondary),
        // but switch to rampCoefficient after promotion to primary.
        // This prevents coefficient corruption when a new secondary is created during the next switch.
        let activeRampCoef = crossfadeState.isActive ? secondaryRampCoefficient : rampCoefficient

        if let converter = secondaryConverter {
            _diagConverterUsed += 1
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
                allowEQ: !crossfadeState.isActive
            )
            if processed {
                _diagOutputWritten += 1
                _diagLastOutputPeak = computeOutputPeak(outputBuffers)
                _secondaryCurrentVolume = currentVol
                return
            }
            _diagConverterFailed += 1
        }

        // If format isn't Float32 PCM, pass through untouched (avoid corrupting non-float buffers)
        // During crossfade, silence non-float output to prevent doubled audio from both taps
        guard format.isFloat32 else {
            _diagNonFloatPassthrough += 1
            if crossfadeMultiplier < 1.0 {
                zeroOutputBuffers(outputBuffers)
            } else {
                copyInputToOutput(inputBuffers: inputBuffers, outputBuffers: outputBuffers)
            }
            _diagOutputWritten += 1
            return
        }

        _diagDirectFloat += 1

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
           !crossfadeState.isActive,
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

        _diagOutputWritten += 1
        _diagLastOutputPeak = computeOutputPeak(outputBuffers)

        // Store for next callback
        _secondaryCurrentVolume = currentVol
    }

    // MARK: - RT-Safe Buffer Helpers

    // MARK: - RT-Safe Buffer Helpers (delegated to extracted types)

    @inline(__always)
    private func zeroOutputBuffers(_ outputBuffers: UnsafeMutableAudioBufferListPointer) {
        AudioBufferProcessor.zeroOutputBuffers(outputBuffers)
    }

    @inline(__always)
    private func copyInputToOutput(
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer
    ) {
        AudioBufferProcessor.copyInputToOutput(inputBuffers: inputBuffers, outputBuffers: outputBuffers)
    }

    @inline(__always)
    private func computePeak(inputBuffers: UnsafeMutableAudioBufferListPointer) -> Float {
        AudioBufferProcessor.computePeak(inputBuffers: inputBuffers)
    }

    /// Compute peak of output buffers for diagnostics (RT-safe: simple float max)
    @inline(__always)
    private func computeOutputPeak(_ outputBuffers: UnsafeMutableAudioBufferListPointer) -> Float {
        var peak: Float = 0
        for i in 0..<outputBuffers.count {
            guard let data = outputBuffers[i].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(outputBuffers[i].mDataByteSize) / MemoryLayout<Float>.size
            for j in 0..<count {
                let abs = samples[j] < 0 ? -samples[j] : samples[j]
                if abs > peak { peak = abs }
            }
        }
        return min(peak, 1.0)
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
        GainProcessor.processFloatBuffers(
            channelCount: format.channelCount,
            isInterleaved: format.isInterleaved,
            inputBuffers: inputBuffers,
            outputBuffers: outputBuffers,
            targetVolume: targetVol,
            currentVolume: &currentVol,
            rampCoefficient: rampCoefficient,
            crossfadeMultiplier: crossfadeMultiplier,
            compensation: compensation
        )
    }

    @inline(__always)
    private func frameCount(
        bufferList: UnsafeMutableAudioBufferListPointer,
        bytesPerFrame: Int
    ) -> Int {
        AudioBufferProcessor.frameCount(bufferList: bufferList, bytesPerFrame: bytesPerFrame)
    }

    /// Processes audio through format converter (delegated to AudioFormatConverter)
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
        AudioFormatConverter.process(
            converter: converter,
            inputBufferList: inputBufferList,
            outputBufferList: outputBufferList,
            targetVolume: targetVol,
            currentVolume: &currentVol,
            rampCoefficient: rampCoefficient,
            crossfadeMultiplier: crossfadeMultiplier,
            compensation: compensation,
            eqProcessor: eqProcessor,
            allowEQ: allowEQ
        )
    }

    /// Soft-knee limiter using asymptotic compression (delegated to SoftLimiter).
    @inline(__always)
    private func softLimit(_ sample: Float) -> Float {
        SoftLimiter.apply(sample)
    }

    /// Cleans up partially created CoreAudio resources on activation failure.
    /// Called when any step in activate() fails after resources were created.
    private func cleanupPartialActivation() {
        primaryResources.destroy()
        primaryFormat = nil
        destroyConverter(&primaryConverter)
    }

    func invalidate() {
        guard activated else { return }
        activated = false

        logger.debug("Invalidating tap for \(self.app.name)")

        // Stop crossfade immediately if in progress (includes OSMemoryBarrier)
        crossfadeState.complete()

        // Async teardown: captures values, clears state immediately, dispatches destruction to background
        // This avoids blocking main thread (AudioDeviceDestroyIOProcID blocks until callback finishes)
        primaryResources.destroyAsync()
        secondaryResources.destroyAsync()

        primaryFormat = nil
        secondaryFormat = nil
        destroyConverter(&primaryConverter)
        destroyConverter(&secondaryConverter)

        logger.info("Tap invalidated for \(self.app.name)")
    }

#if DEBUG
    /// Test-only read of destructive-switch force-silence flag.
    var isForceSilenceEnabledForTests: Bool {
        _forceSilence
    }

    /// Test-only entry point for destructive switch path.
    func performDestructiveDeviceSwitchForTests(to newDeviceUID: String) async throws {
        try await performDestructiveDeviceSwitch(to: newDeviceUID)
    }
#endif

    deinit {
        invalidate()
    }
}
