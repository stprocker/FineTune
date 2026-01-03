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

    // Device volume compensation scalar (applied during/after crossfade)
    // Computed as: sourceDeviceVolume / destinationDeviceVolume
    private nonisolated(unsafe) var _deviceVolumeCompensation: Float = 1.0

    // Ramp coefficient for ~30ms smoothing, computed from device sample rate on activation
    // Formula: 1 - exp(-1 / (sampleRate * rampTimeSeconds))
    private var rampCoefficient: Float = 0.0007  // Default, updated on activation
    private var secondaryRampCoefficient: Float = 0.0007  // For secondary tap during crossfade

    var volume: Float {
        get { _volume }
        set { _volume = newValue }
    }

    // Target device UID (nil = system default)
    private var targetDeviceUID: String?
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

    init(app: AudioApp, targetDeviceUID: String? = nil) {
        self.app = app
        self.targetDeviceUID = targetDeviceUID
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "ProcessTapController(\(app.name))")
    }

    func activate() throws {
        guard !activated else { return }

        logger.debug("Activating tap for \(self.app.name)")

        // NOTE: CATapDescription stereoMixdownOfProcesses produces stereo Float32 interleaved.
        // The processAudio callback assumes this format.
        // Create process tap
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .mutedWhenTapped  // Mute original, we provide the audio
        self.tapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(err)"])
        }

        processTapID = tapID
        logger.debug("Created process tap #\(tapID)")

        // Get output device UID (target device or system default)
        let outputUID: String
        do {
            if let targetUID = targetDeviceUID {
                outputUID = targetUID
            } else {
                let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
                outputUID = try systemOutputID.readDeviceUID()
            }
            currentDeviceUID = outputUID
        } catch {
            cleanupPartialActivation()
            throw error
        }

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

        // Compute ramp coefficient from actual device sample rate
        let sampleRate: Float64
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            sampleRate = deviceSampleRate
            logger.info("Device sample rate: \(sampleRate) Hz")
        } else {
            sampleRate = 48000
            logger.warning("Failed to read sample rate, using default: \(sampleRate) Hz")
        }
        let rampTimeSeconds: Float = 0.030  // 30ms smoothing
        rampCoefficient = 1 - exp(-1 / (Float(sampleRate) * rampTimeSeconds))
        logger.debug("Ramp coefficient: \(self.rampCoefficient)")

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
    func switchDevice(to newDeviceUID: String?) async throws {
        guard activated else {
            targetDeviceUID = newDeviceUID
            logger.debug("[SWITCH] Not activated, just updating target to \(newDeviceUID ?? "nil")")
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("[SWITCH] === START === \(self.app.name) -> \(newDeviceUID ?? "system default")")

        // Resolve the actual device UID
        let newOutputUID: String
        if let targetUID = newDeviceUID {
            newOutputUID = targetUID
        } else {
            let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
            newOutputUID = try systemOutputID.readDeviceUID()
        }

        do {
            // Try crossfade approach
            try await performCrossfadeSwitch(to: newOutputUID)
        } catch {
            // Fall back to destroy/recreate if crossfade fails
            logger.warning("[SWITCH] Crossfade failed: \(error.localizedDescription), using fallback")
            guard let tapDesc = tapDescription else {
                throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No tap description available"])
            }
            try await performDestructiveDeviceSwitch(to: newDeviceUID, tapDesc: tapDesc)
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

        // Read source device volume (need to find the physical device behind our aggregate)
        var sourceVolume: Float = 1.0
        if let sourceUID = currentDeviceUID {
            do {
                let devices = try AudioObjectID.readDeviceList()
                if let sourceDevice = devices.first(where: { (try? $0.readDeviceUID()) == sourceUID }) {
                    sourceVolume = sourceDevice.readOutputVolumeScalar()
                    logger.debug("[CROSSFADE] Source device volume: \(sourceVolume)")
                }
            } catch {
                logger.warning("[CROSSFADE] Failed to read source volume: \(error.localizedDescription)")
            }
        }

        // Read destination device volume
        var destVolume: Float = 1.0
        do {
            let devices = try AudioObjectID.readDeviceList()
            if let destDevice = devices.first(where: { (try? $0.readDeviceUID()) == newOutputUID }) {
                destVolume = destDevice.readOutputVolumeScalar()
                logger.debug("[CROSSFADE] Destination device volume: \(destVolume)")
            }
        } catch {
            logger.warning("[CROSSFADE] Failed to read destination volume: \(error.localizedDescription)")
        }

        // Calculate compensation: source/dest to maintain perceived loudness
        let compensation = destVolume > 0.001 ? sourceVolume / destVolume : 1.0
        _deviceVolumeCompensation = compensation
        logger.info("[CROSSFADE] Volume compensation: \(compensation) (source=\(sourceVolume), dest=\(destVolume))")

        logger.info("[CROSSFADE] Step 2: Preparing crossfade state")

        // Enable crossfade BEFORE secondary tap starts, so it begins silent
        _crossfadeProgress = 0
        _secondarySampleCount = 0
        _isCrossfading = true

        // Create secondary tap (it will start at sin(0) = 0 = silent)
        logger.info("[CROSSFADE] Step 3: Creating secondary tap for new device")
        try createSecondaryTap(for: newOutputUID)

        // Wait for secondary tap to warm up and start producing samples
        logger.info("[CROSSFADE] Step 4: Waiting for secondary tap warmup...")
        try await Task.sleep(for: .milliseconds(20))

        logger.info("[CROSSFADE] Step 5: Crossfade in progress (\(CrossfadeConfig.duration * 1000)ms)")

        // Poll for completion (don't control timing - secondary callback does)
        let timeoutMs = Int(CrossfadeConfig.duration * 1000) + 100  // Add 100ms safety margin
        let pollIntervalMs: UInt64 = 5
        var elapsedMs: Int = 0

        while _crossfadeProgress < 1.0 && elapsedMs < timeoutMs {
            try await Task.sleep(for: .milliseconds(pollIntervalMs))
            elapsedMs += Int(pollIntervalMs)
        }

        // Small buffer to ensure final samples processed
        try await Task.sleep(for: .milliseconds(10))

        // Crossfade complete - destroy primary, promote secondary
        logger.info("[CROSSFADE] Step 6: Crossfade complete (progress=\(self._crossfadeProgress)), promoting secondary")
        _isCrossfading = false

        destroyPrimaryTap()
        promoteSecondaryToPrimary()

        logger.info("[CROSSFADE] Complete")
    }

    /// Creates a secondary tap + aggregate for crossfade.
    private func createSecondaryTap(for outputUID: String) throws {
        // Create new process tap for the same app
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [app.objectID])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .mutedWhenTapped  // Must mute to prevent audio on system default after primary destroyed
        secondaryTapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create secondary tap: \(err)"])
        }
        secondaryTapID = tapID
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

        // Initialize sample-accurate crossfade timing from secondary device sample rate
        // Note: _secondarySampleCount is already set to 0 in performCrossfadeSwitch() before this is called
        let sampleRate: Double
        if let deviceSampleRate = try? secondaryAggregateID.readNominalSampleRate() {
            sampleRate = deviceSampleRate
        } else {
            sampleRate = 48000
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
    }

    /// Promotes secondary tap to primary after crossfade.
    private func promoteSecondaryToPrimary() {
        processTapID = secondaryTapID
        aggregateDeviceID = secondaryAggregateID
        deviceProcID = secondaryDeviceProcID
        tapDescription = secondaryTapDescription

        // Update ramp coefficient for new device sample rate
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            let rampTimeSeconds: Float = 0.030
            rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * rampTimeSeconds))
        }

        // Transfer volume state from secondary to primary (prevents volume jump)
        _primaryCurrentVolume = _secondaryCurrentVolume
        _secondaryCurrentVolume = 0

        // Reset crossfade state for next switch
        _secondarySampleCount = 0
        _crossfadeTotalSamples = 0

        // Clear secondary references
        secondaryTapID = .unknown
        secondaryAggregateID = .unknown
        secondaryDeviceProcID = nil
        secondaryTapDescription = nil
    }

    /// Fallback: Switches using destroy/recreate approach.
    private func performDestructiveDeviceSwitch(to newDeviceUID: String?, tapDesc: CATapDescription) async throws {
        let originalVolume = _volume

        _forceSilence = true
        logger.info("[SWITCH-DESTROY] Enabled _forceSilence=true")

        try await Task.sleep(for: .milliseconds(100))

        try performDeviceSwitch(to: newDeviceUID, tapDesc: tapDesc)

        _primaryCurrentVolume = 0
        _volume = 0

        try await Task.sleep(for: .milliseconds(150))

        _forceSilence = false

        // Gradual fade-in
        for i in 1...10 {
            _volume = originalVolume * Float(i) / 10.0
            try await Task.sleep(for: .milliseconds(20))
        }

        logger.info("[SWITCH-DESTROY] Complete")
    }

    /// Internal destroy/recreate switch (used as fallback).
    private func performDeviceSwitch(to newDeviceUID: String?, tapDesc: CATapDescription) throws {
        // Stop and destroy current
        if aggregateDeviceID.isValid {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let procID = deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                deviceProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }

        // Resolve output UID
        let outputUID: String
        if let targetUID = newDeviceUID {
            outputUID = targetUID
        } else {
            let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
            outputUID = try systemOutputID.readDeviceUID()
        }

        targetDeviceUID = newDeviceUID
        currentDeviceUID = outputUID

        // Create new aggregate with same tap
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

        var err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate: \(err)"])
        }

        // Update ramp coefficient
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            rampCoefficient = 1 - exp(-1 / (Float(deviceSampleRate) * 0.030))
        }

        // Create IO proc
        err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        // Start device
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(err)"])
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
            for outputBuffer in outputBuffers {
                guard let outputData = outputBuffer.mData else { continue }
                // Zero the entire output buffer
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
            }
            return
        }

        // Read target once at start of buffer (atomic Float read)
        let targetVol = _volume
        var currentVol = _primaryCurrentVolume

        // During crossfade, primary tap fades OUT using equal-power curve
        // cos(0) = 1.0, cos(π/2) = 0.0
        let crossfadeMultiplier: Float = _isCrossfading
            ? cos(_crossfadeProgress * .pi / 2.0)
            : 1.0

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        // Copy input to output with ramped gain and soft limiting
        for (inputBuffer, outputBuffer) in zip(inputBuffers, outputBuffers) {
            guard let inputData = inputBuffer.mData,
                  let outputData = outputBuffer.mData else { continue }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

            for i in 0..<sampleCount {
                // Per-sample volume ramping (one-pole lowpass)
                currentVol += (targetVol - currentVol) * rampCoefficient

                // Apply gain with crossfade multiplier and device volume compensation
                var sample = inputSamples[i] * currentVol * crossfadeMultiplier * _deviceVolumeCompensation

                // Soft-knee limiter (prevents harsh clipping when boosting)
                sample = softLimit(sample)

                outputSamples[i] = sample
            }
        }

        // Store for next callback
        _primaryCurrentVolume = currentVol
    }

    /// Audio processing callback for SECONDARY tap.
    /// During crossfade: fades IN (0 → 1) while primary fades out.
    /// OWNS crossfade timing via sample counting for sample-accurate transitions.
    private func processAudioSecondary(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)

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

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBufferList))

        var totalSamplesThisBuffer: Int = 0

        // Copy input to output with ramped gain and crossfade
        for (inputBuffer, outputBuffer) in zip(inputBuffers, outputBuffers) {
            guard let inputData = inputBuffer.mData,
                  let outputData = outputBuffer.mData else { continue }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

            // Track samples for counter (only count once, not per channel)
            if totalSamplesThisBuffer == 0 {
                totalSamplesThisBuffer = sampleCount / 2  // Stereo interleaved: frames = samples / 2
            }

            for i in 0..<sampleCount {
                // Per-sample volume ramping
                currentVol += (targetVol - currentVol) * secondaryRampCoefficient

                // Apply ramped gain with crossfade multiplier and device volume compensation
                var sample = inputSamples[i] * currentVol * crossfadeMultiplier * _deviceVolumeCompensation

                // Soft-knee limiter
                sample = softLimit(sample)

                outputSamples[i] = sample
            }
        }

        // Increment sample counter (once per callback, after processing)
        if _isCrossfading {
            _secondarySampleCount += Int64(totalSamplesThisBuffer)
        }

        // Store for next callback
        _secondaryCurrentVolume = currentVol
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
    }

    func invalidate() {
        guard activated else { return }
        defer { activated = false }

        logger.debug("Invalidating tap for \(self.app.name)")

        // Stop crossfade immediately if in progress
        _isCrossfading = false

        // Clean up secondary resources if they exist (mid-crossfade termination)
        if secondaryAggregateID.isValid {
            AudioDeviceStop(secondaryAggregateID, secondaryDeviceProcID)
            if let procID = secondaryDeviceProcID {
                AudioDeviceDestroyIOProcID(secondaryAggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(secondaryAggregateID)
            secondaryAggregateID = .unknown
        }
        if secondaryTapID.isValid {
            AudioHardwareDestroyProcessTap(secondaryTapID)
            secondaryTapID = .unknown
        }
        secondaryDeviceProcID = nil
        secondaryTapDescription = nil

        // Clean up primary resources
        if aggregateDeviceID.isValid {
            var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if err != noErr { logger.warning("Failed to stop device: \(err)") }

            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                if err != noErr { logger.warning("Failed to destroy IO proc: \(err)") }
                self.deviceProcID = nil
            }

            err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr { logger.warning("Failed to destroy aggregate device: \(err)") }
            aggregateDeviceID = .unknown
        }

        if processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr { logger.warning("Failed to destroy process tap: \(err)") }
            processTapID = .unknown
        }

        logger.info("Tap invalidated for \(self.app.name)")
    }

    deinit {
        invalidate()
    }
}
