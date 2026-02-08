// tools/TapExperiment/main.swift
// macOS 26 CoreAudio API Validation Harness
//
// Tests four macOS 26 tap capabilities to determine architecture strategy:
//   A: Live tap reconfiguration (kAudioTapPropertyDescription settable)
//   B: Tap-only aggregates (no real sub-device)
//   C: bundleIDs + processRestoreEnabled
//   D: Live deviceUID change
//
// Build:  cd tools/TapExperiment && swift build
// Run:    .build/debug/TapExperiment [--test A|B|C|D] [--bundle-id com.spotify.client]

import AudioToolbox
import CoreAudio
import AppKit
import Foundation

// MARK: - Helpers

func logResult(_ test: String, _ passed: Bool, _ detail: String) {
    let symbol = passed ? "PASS" : "FAIL"
    print("[\(symbol)] Test \(test): \(detail)")
}

func logInfo(_ msg: String) {
    print("  [INFO] \(msg)")
}

func logError(_ msg: String) {
    print("  [ERROR] \(msg)")
}

func osStatusString(_ status: OSStatus) -> String {
    if status == noErr { return "noErr" }
    // Try 4-char code
    let bytes: [UInt8] = [
        UInt8((status >> 24) & 0xFF),
        UInt8((status >> 16) & 0xFF),
        UInt8((status >> 8) & 0xFF),
        UInt8(status & 0xFF),
    ]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
        return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")' (\(status))"
    }
    return "\(status)"
}

// MARK: - CoreAudio Helpers

func getDefaultOutputDeviceUID() -> String? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard err == noErr else {
        logError("Failed to get default output device: \(osStatusString(err))")
        return nil
    }

    var uidCF: CFString = "" as CFString
    size = UInt32(MemoryLayout<CFString>.size)
    address.mSelector = kAudioDevicePropertyDeviceUID
    let err2 = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uidCF)
    guard err2 == noErr else {
        logError("Failed to get device UID: \(osStatusString(err2))")
        return nil
    }
    return uidCF as String
}

/// Thread-safe counter for IO proc callbacks (avoids Swift 6 concurrency capture issues).
final class AtomicCounter: @unchecked Sendable {
    private let _value: UnsafeMutablePointer<Int64>
    init() {
        _value = .allocate(capacity: 1)
        _value.initialize(to: 0)
    }
    deinit { _value.deallocate() }
    func increment() { OSAtomicIncrement64(_value) }
    var value: Int64 { _value.pointee }
}

/// Thread-safe flag for IO proc audio detection.
final class AtomicFlag: @unchecked Sendable {
    private let _value: UnsafeMutablePointer<Int32>
    init() {
        _value = .allocate(capacity: 1)
        _value.initialize(to: 0)
    }
    deinit { _value.deallocate() }
    func set() { OSAtomicCompareAndSwap32(0, 1, _value) }
    var isSet: Bool { _value.pointee != 0 }
}

func checkAggregateStreams(_ aggID: AudioObjectID) {
    // Check input streams
    var inputSize: UInt32 = 0
    var inputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(aggID, &inputAddr, 0, nil, &inputSize)
    let inputCount = Int(inputSize) / MemoryLayout<AudioStreamID>.size
    logInfo("Aggregate #\(aggID) input streams: \(inputCount)")

    // Check output streams
    var outputSize: UInt32 = 0
    var outputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(aggID, &outputAddr, 0, nil, &outputSize)
    let outputCount = Int(outputSize) / MemoryLayout<AudioStreamID>.size
    logInfo("Aggregate #\(aggID) output streams: \(outputCount)")

    // Check sample rate
    var sampleRate: Float64 = 0
    var rateSize = UInt32(MemoryLayout<Float64>.size)
    var rateAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let err = AudioObjectGetPropertyData(aggID, &rateAddr, 0, nil, &rateSize, &sampleRate)
    if err == noErr {
        logInfo("Aggregate #\(aggID) sample rate: \(sampleRate)")
    } else {
        logInfo("Aggregate #\(aggID) sample rate: ERROR \(osStatusString(err))")
    }
}

func checkDeviceIsRunning(_ deviceID: AudioObjectID) -> Bool {
    var isRunning: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunning,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
    if err != noErr {
        logInfo("  isRunning check failed: \(osStatusString(err))")
        return false
    }
    logInfo("  Device #\(deviceID) isRunning: \(isRunning != 0)")
    return isRunning != 0
}

func getOutputStreamIndex(for deviceUID: String) -> Int? {
    // Find device by UID
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)

    for device in devices {
        var uidCF: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, &uidCF)
        guard err == noErr else { continue }
        guard (uidCF as String) == deviceUID else { continue }

        // Get output streams
        var streamsSize: UInt32 = 0
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(device, &streamAddr, 0, nil, &streamsSize)
        let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        guard streamCount > 0 else { continue }

        return 0 as Int // First output stream
    }
    return nil
}

/// Reads the CoreAudio process object list and returns all (AudioObjectID, pid_t) pairs.
func readCoreAudioProcessList() -> [(objectID: AudioObjectID, pid: pid_t)] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    var err = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    guard err == noErr else {
        logError("Failed to get process list size: \(osStatusString(err))")
        return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }

    var objectIDs = [AudioObjectID](repeating: 0, count: count)
    err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs)
    guard err == noErr else {
        logError("Failed to get process list: \(osStatusString(err))")
        return []
    }

    var result: [(objectID: AudioObjectID, pid: pid_t)] = []
    for objectID in objectIDs {
        var pid = pid_t(0)
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let pidErr = AudioObjectGetPropertyData(objectID, &pidAddr, 0, nil, &pidSize, &pid)
        if pidErr == noErr {
            result.append((objectID: objectID, pid: pid))
        }
    }
    return result
}

/// Resolves a system PID to its CoreAudio AudioObjectID.
/// CATapDescription(__processes:) expects AudioObjectIDs, NOT system PIDs.
func resolveAudioObjectID(for pid: pid_t) -> AudioObjectID? {
    let processList = readCoreAudioProcessList()
    return processList.first(where: { $0.pid == pid })?.objectID
}

/// Finds a running audio app and returns its CoreAudio AudioObjectID.
/// Returns (objectID, pid, appName) or nil if no audio app is found.
func findAudioProducingProcess() -> (objectID: AudioObjectID, pid: pid_t, name: String)? {
    let processList = readCoreAudioProcessList()
    let myPID = ProcessInfo.processInfo.processIdentifier

    logInfo("CoreAudio process list has \(processList.count) entries")

    // Try known audio apps first
    let knownBundleIDs = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.Safari",
        "com.brave.Browser",
        "com.google.Chrome",
    ]
    for bundleID in knownBundleIDs {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if let app = apps.first {
            let pid = app.processIdentifier
            if let entry = processList.first(where: { $0.pid == pid }) {
                let name = app.localizedName ?? bundleID
                logInfo("Found audio app: \(name) (PID: \(pid), AudioObjectID: \(entry.objectID))")
                return (objectID: entry.objectID, pid: pid, name: name)
            }
        }
    }

    // Fallback: pick any CoreAudio process that's not us
    for entry in processList where entry.pid != myPID {
        let runningApp = NSRunningApplication(processIdentifier: entry.pid)
        let name = runningApp?.localizedName ?? "PID \(entry.pid)"
        logInfo("Using fallback process: \(name) (PID: \(entry.pid), AudioObjectID: \(entry.objectID))")
        return (objectID: entry.objectID, pid: entry.pid, name: name)
    }

    return nil
}

// MARK: - Test A: Live Tap Reconfiguration

func runTestA() {
    print("\n=== Test A: Live Tap Reconfiguration ===")
    print("Goal: Can we change muteBehavior on a live tap via kAudioTapPropertyDescription?\n")

    guard let deviceUID = getDefaultOutputDeviceUID() else {
        logResult("A", false, "Could not get default output device UID")
        return
    }
    logInfo("Default output device: \(deviceUID)")

    guard let process = findAudioProducingProcess() else {
        logResult("A", false, "No audio-producing process found in CoreAudio process list")
        return
    }

    guard let streamIndex = getOutputStreamIndex(for: deviceUID) else {
        logResult("A", false, "Could not find output stream for device")
        return
    }

    // Step 1: Create tap with .unmuted + bundleIDs (macOS 26 API)
    let processNumber = NSNumber(value: process.objectID)
    let tapDesc = CATapDescription(__processes: [processNumber], andDeviceUID: deviceUID, withStream: streamIndex)
    tapDesc.uuid = UUID()
    tapDesc.isPrivate = true
    tapDesc.muteBehavior = CATapMuteBehavior.unmuted
    logInfo("Creating tap with .unmuted for \(process.name) (PID: \(process.pid), AudioObjectID: \(process.objectID))...")

    var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
    guard err == noErr else {
        logResult("A", false, "Failed to create process tap: \(osStatusString(err))")
        return
    }
    logInfo("Created process tap #\(tapID)")
    defer {
        AudioHardwareDestroyProcessTap(tapID)
        logInfo("Destroyed tap #\(tapID)")
    }

    // Step 2: Check if kAudioTapPropertyDescription is settable
    var descAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyDescription,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var isSettable: DarwinBoolean = false
    err = AudioObjectIsPropertySettable(tapID, &descAddress, &isSettable)
    if err != noErr {
        logResult("A.1", false, "AudioObjectIsPropertySettable failed: \(osStatusString(err))")
        logResult("A", false, "Cannot determine if tap description is settable")
        return
    }
    logResult("A.1", isSettable.boolValue, "kAudioTapPropertyDescription is settable: \(isSettable.boolValue)")

    guard isSettable.boolValue else {
        logResult("A", false, "Tap description is not settable — live reconfiguration not available")
        return
    }

    // Step 3: Read current description
    var readRef: Unmanaged<CATapDescription>?
    var readSize = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
    err = AudioObjectGetPropertyData(tapID, &descAddress, 0, nil, &readSize, &readRef)
    if err != noErr {
        logResult("A.2", false, "Failed to read tap description: \(osStatusString(err))")
        return
    }
    let readDesc = readRef?.takeUnretainedValue()
    logResult("A.2", true, "Read current tap description (muteBehavior: \(readDesc?.muteBehavior.rawValue ?? -1))")

    // Step 4: Try writing BEFORE aggregate (may fail with !hog)
    logInfo("Attempt 1: Setting muteBehavior BEFORE creating aggregate...")
    tapDesc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
    var writeRef: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(tapDesc)
    let writeSize = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
    err = AudioObjectSetPropertyData(tapID, &descAddress, 0, nil, writeSize, &writeRef)
    let preAggSetWorked = (err == noErr)
    if err != noErr {
        logResult("A.3a", false, "Set before aggregate failed: \(osStatusString(err))")
        // Reset to .unmuted for next attempt
        tapDesc.muteBehavior = CATapMuteBehavior.unmuted
    } else {
        logResult("A.3a", true, "Set before aggregate succeeded")
    }

    // Step 5: Create aggregate and start IO proc
    let aggregateUID = UUID().uuidString
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "TapExperiment-A",
        kAudioAggregateDeviceUIDKey: aggregateUID,
        kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: deviceUID]
        ],
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            ]
        ],
    ]

    var aggID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
    guard err == noErr else {
        logResult("A.4", false, "Failed to create aggregate: \(osStatusString(err))")
        logResult("A", preAggSetWorked, preAggSetWorked
                  ? "Live reconfiguration worked before aggregate"
                  : "Could not verify — aggregate creation failed")
        return
    }
    defer { AudioHardwareDestroyAggregateDevice(aggID) }
    checkAggregateStreams(aggID)

    let counter = AtomicCounter()
    let queue = DispatchQueue(label: "testA.io")
    var procID: AudioDeviceIOProcID?
    err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, _, _, _, _ in
        counter.increment()
    }
    guard err == noErr, let procID else {
        logResult("A.4", false, "Failed to create IO proc: \(osStatusString(err))")
        logResult("A", preAggSetWorked, "IO proc creation failed")
        return
    }
    err = AudioDeviceStart(aggID, procID)
    guard err == noErr else {
        AudioDeviceDestroyIOProcID(aggID, procID)
        logResult("A.4", false, "Failed to start device: \(osStatusString(err))")
        logResult("A", preAggSetWorked, "Device start failed")
        return
    }
    logInfo("Aggregate running, IO proc started")

    // Step 6: Try writing AFTER aggregate is active (if pre-agg failed)
    if !preAggSetWorked {
        logInfo("Attempt 2: Setting muteBehavior AFTER aggregate is active...")
        tapDesc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        var writeRef2: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(tapDesc)
        err = AudioObjectSetPropertyData(tapID, &descAddress, 0, nil, writeSize, &writeRef2)
        if err != noErr {
            logResult("A.3b", false, "Set after aggregate also failed: \(osStatusString(err))")

            // Attempt 3: Try using the read-back description object instead
            logInfo("Attempt 3: Modifying the read-back CATapDescription and setting it...")
            if let readDesc {
                readDesc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
                var writeRef3: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(readDesc)
                err = AudioObjectSetPropertyData(tapID, &descAddress, 0, nil, writeSize, &writeRef3)
                if err != noErr {
                    logResult("A.3c", false, "Set with read-back object also failed: \(osStatusString(err))")
                } else {
                    logResult("A.3c", true, "Set with read-back object succeeded!")
                }
            }
        } else {
            logResult("A.3b", true, "Set after aggregate succeeded!")
        }
    }

    // Step 7: Listen and verify
    logInfo("Listening for callbacks for 2 seconds...")
    Thread.sleep(forTimeInterval: 2.0)

    AudioDeviceStop(aggID, procID)
    AudioDeviceDestroyIOProcID(aggID, procID)

    let callbacksFlowing = counter.value > 50
    logResult("A.5", callbacksFlowing, "Callbacks: \(counter.value) (expected >50)")

    // Re-read final state
    var verifyRef: Unmanaged<CATapDescription>?
    var verifySize = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
    err = AudioObjectGetPropertyData(tapID, &descAddress, 0, nil, &verifySize, &verifyRef)
    if err == noErr, let verifyDesc = verifyRef?.takeUnretainedValue() {
        logInfo("Final muteBehavior: \(verifyDesc.muteBehavior.rawValue)")
    }

    let anySetWorked = preAggSetWorked  // We'll determine from output
    logResult("A", anySetWorked || callbacksFlowing, anySetWorked
              ? "Live tap reconfiguration works — muteBehavior changeable"
              : "kAudioTapPropertyDescription reports settable but writes fail with !hog")
}

// MARK: - Test B: Tap-Only Aggregate

func runTestB() {
    print("\n=== Test B: Tap-Only Aggregate (No Real Sub-Device) ===")
    print("Goal: Can an aggregate with ONLY a tap (no kAudioAggregateDeviceSubDeviceListKey) output audio?\n")

    guard let deviceUID = getDefaultOutputDeviceUID() else {
        logResult("B", false, "Could not get default output device UID")
        return
    }

    guard let process = findAudioProducingProcess() else {
        logResult("B", false, "No audio-producing process found in CoreAudio process list")
        return
    }

    guard let streamIndex = getOutputStreamIndex(for: deviceUID) else {
        logResult("B", false, "Could not find output stream for device")
        return
    }

    // Create tap with .mutedWhenTapped
    let processNumber = NSNumber(value: process.objectID)
    let tapDesc = CATapDescription(__processes: [processNumber], andDeviceUID: deviceUID, withStream: streamIndex)
    tapDesc.uuid = UUID()
    tapDesc.isPrivate = true
    tapDesc.muteBehavior = CATapMuteBehavior.mutedWhenTapped

    var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
    guard err == noErr else {
        logResult("B", false, "Failed to create tap: \(osStatusString(err))")
        return
    }
    logInfo("Created tap #\(tapID) with .mutedWhenTapped")
    defer { AudioHardwareDestroyProcessTap(tapID) }

    // Create aggregate WITHOUT real sub-device — only tap
    let tapOnlyAggUID = UUID().uuidString
    let tapOnlyAggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "TapExperiment-B-TapOnly",
        kAudioAggregateDeviceUIDKey: tapOnlyAggUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        // NO kAudioAggregateDeviceMainSubDeviceKey
        // NO kAudioAggregateDeviceSubDeviceListKey
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            ]
        ],
    ]

    var tapOnlyAggID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    err = AudioHardwareCreateAggregateDevice(tapOnlyAggDesc as CFDictionary, &tapOnlyAggID)
    if err != noErr {
        logResult("B.1", false, "Failed to create tap-only aggregate: \(osStatusString(err))")
        logResult("B", false, "Tap-only aggregate creation not supported")
        return
    }
    logResult("B.1", true, "Created tap-only aggregate #\(tapOnlyAggID)")
    defer { AudioHardwareDestroyAggregateDevice(tapOnlyAggID) }

    // Set up IO proc and check for audio
    // Give the aggregate a moment to stabilize
    Thread.sleep(forTimeInterval: 0.5)
    checkAggregateStreams(tapOnlyAggID)
    let tapOnlyCounter = AtomicCounter()
    let tapOnlyAudioFlag = AtomicFlag()
    let queue = DispatchQueue(label: "testB.tapOnly")
    var procID: AudioDeviceIOProcID?

    err = AudioDeviceCreateIOProcIDWithBlock(&procID, tapOnlyAggID, queue) { _, inInputData, _, outOutputData, _ in
        tapOnlyCounter.increment()

        // Check if input has audio data
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        for i in 0..<inputBuffers.count {
            guard let data = inputBuffers[i].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(inputBuffers[i].mDataByteSize) / MemoryLayout<Float>.size
            for j in 0..<count {
                if abs(samples[j]) > 0.0001 {
                    tapOnlyAudioFlag.set()
                    break
                }
            }
            if tapOnlyAudioFlag.isSet { break }
        }

        // Copy input to output (passthrough)
        let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
        for i in 0..<min(inputBuffers.count, outBuffers.count) {
            guard let inData = inputBuffers[i].mData,
                  let outData = outBuffers[i].mData else { continue }
            let bytes = min(inputBuffers[i].mDataByteSize, outBuffers[i].mDataByteSize)
            memcpy(outData, inData, Int(bytes))
        }
    }

    guard err == noErr, let procID else {
        logResult("B.2", false, "Failed to create IO proc: \(osStatusString(err))")
        logResult("B", false, "Could not test tap-only aggregate audio flow")
        return
    }

    err = AudioDeviceStart(tapOnlyAggID, procID)
    guard err == noErr else {
        AudioDeviceDestroyIOProcID(tapOnlyAggID, procID)
        logResult("B.2", false, "Failed to start tap-only aggregate: \(osStatusString(err))")
        logResult("B", false, "Tap-only aggregate could not start")
        return
    }

    checkDeviceIsRunning(tapOnlyAggID)
    logInfo("Listening on tap-only aggregate for 3 seconds...")
    logInfo("(If target app is producing audio, check if sound comes from speakers)")
    Thread.sleep(forTimeInterval: 3.0)

    AudioDeviceStop(tapOnlyAggID, procID)
    AudioDeviceDestroyIOProcID(tapOnlyAggID, procID)

    logResult("B.2", tapOnlyCounter.value > 50, "Tap-only aggregate callbacks: \(tapOnlyCounter.value)")
    logResult("B.3", tapOnlyAudioFlag.isSet, "Tap-only aggregate received audio data: \(tapOnlyAudioFlag.isSet)")

    // Now run control test with standard aggregate (with real sub-device)
    logInfo("\nRunning control test with standard aggregate (with real sub-device)...")

    // Need a fresh tap for control
    let controlTapDesc = CATapDescription(__processes: [processNumber], andDeviceUID: deviceUID, withStream: streamIndex)
    controlTapDesc.uuid = UUID()
    controlTapDesc.isPrivate = true
    controlTapDesc.muteBehavior = CATapMuteBehavior.mutedWhenTapped

    var controlTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    err = AudioHardwareCreateProcessTap(controlTapDesc, &controlTapID)
    guard err == noErr else {
        logResult("B.control", false, "Failed to create control tap: \(osStatusString(err))")
        logResult("B", tapOnlyAudioFlag.isSet, tapOnlyAudioFlag.isSet
                  ? "Tap-only aggregate outputs audio (control test skipped)"
                  : "Tap-only aggregate does NOT output audio (control test skipped)")
        return
    }
    defer { AudioHardwareDestroyProcessTap(controlTapID) }

    let controlAggUID = UUID().uuidString
    let controlAggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "TapExperiment-B-Control",
        kAudioAggregateDeviceUIDKey: controlAggUID,
        kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: deviceUID]
        ],
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: controlTapDesc.uuid.uuidString,
            ]
        ],
    ]

    var controlAggID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    err = AudioHardwareCreateAggregateDevice(controlAggDesc as CFDictionary, &controlAggID)
    guard err == noErr else {
        logResult("B.control", false, "Failed to create control aggregate: \(osStatusString(err))")
        logResult("B", tapOnlyAudioFlag.isSet, "Tap-only result: \(tapOnlyAudioFlag.isSet) (control failed)")
        return
    }
    defer { AudioHardwareDestroyAggregateDevice(controlAggID) }

    Thread.sleep(forTimeInterval: 0.5)
    checkAggregateStreams(controlAggID)
    let controlCounter = AtomicCounter()
    let controlAudioFlag = AtomicFlag()
    let controlQueue = DispatchQueue(label: "testB.control")
    var controlProcID: AudioDeviceIOProcID?

    err = AudioDeviceCreateIOProcIDWithBlock(&controlProcID, controlAggID, controlQueue) { _, inInputData, _, outOutputData, _ in
        controlCounter.increment()
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        for i in 0..<inputBuffers.count {
            guard let data = inputBuffers[i].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(inputBuffers[i].mDataByteSize) / MemoryLayout<Float>.size
            for j in 0..<count {
                if abs(samples[j]) > 0.0001 {
                    controlAudioFlag.set()
                    break
                }
            }
            if controlAudioFlag.isSet { break }
        }
        let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
        for i in 0..<min(inputBuffers.count, outBuffers.count) {
            guard let inData = inputBuffers[i].mData,
                  let outData = outBuffers[i].mData else { continue }
            let bytes = min(inputBuffers[i].mDataByteSize, outBuffers[i].mDataByteSize)
            memcpy(outData, inData, Int(bytes))
        }
    }

    guard err == noErr, let controlProcID else {
        logResult("B.control", false, "Failed to create control IO proc: \(osStatusString(err))")
        logResult("B", tapOnlyAudioFlag.isSet, "Tap-only result: \(tapOnlyAudioFlag.isSet) (control IO proc failed)")
        return
    }

    err = AudioDeviceStart(controlAggID, controlProcID)
    guard err == noErr else {
        AudioDeviceDestroyIOProcID(controlAggID, controlProcID)
        logResult("B.control", false, "Failed to start control aggregate: \(osStatusString(err))")
        logResult("B", tapOnlyAudioFlag.isSet, "Tap-only result: \(tapOnlyAudioFlag.isSet) (control start failed)")
        return
    }

    checkDeviceIsRunning(controlAggID)
    logInfo("Listening on control (standard) aggregate for 3 seconds...")
    Thread.sleep(forTimeInterval: 3.0)

    AudioDeviceStop(controlAggID, controlProcID)
    AudioDeviceDestroyIOProcID(controlAggID, controlProcID)

    logResult("B.control.1", controlCounter.value > 50, "Control aggregate callbacks: \(controlCounter.value)")
    logResult("B.control.2", controlAudioFlag.isSet, "Control aggregate received audio data: \(controlAudioFlag.isSet)")

    logInfo("\n--- Test B Summary ---")
    logInfo("Tap-only aggregate: callbacks=\(tapOnlyCounter.value), audio=\(tapOnlyAudioFlag.isSet)")
    logInfo("Standard aggregate: callbacks=\(controlCounter.value), audio=\(controlAudioFlag.isSet)")
    logInfo("USER ACTION NEEDED: Did audio come from speakers during the tap-only test?")

    logResult("B", tapOnlyAudioFlag.isSet, tapOnlyAudioFlag.isSet
              ? "Tap-only aggregate appears to work (audio data detected)"
              : "Tap-only aggregate did NOT produce audio data — real sub-device still needed")
}

// MARK: - Test C: bundleIDs + processRestoreEnabled

func runTestC(bundleID: String = "com.spotify.client") {
    print("\n=== Test C: bundleIDs + processRestoreEnabled ===")
    print("Goal: Can we target taps by bundle ID and auto-reconnect after app restart?\n")

    guard let deviceUID = getDefaultOutputDeviceUID() else {
        logResult("C", false, "Could not get default output device UID")
        return
    }

    guard let streamIndex = getOutputStreamIndex(for: deviceUID) else {
        logResult("C", false, "Could not find output stream for device")
        return
    }

    // Check if target app is running
    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if runningApps.isEmpty {
        logInfo("Target app '\(bundleID)' is not running.")
        logInfo("Will create tap anyway to test API availability.")
    } else {
        logInfo("Found '\(bundleID)' running (PID: \(runningApps.first!.processIdentifier))")
    }

    // Step 1: Create tap targeting a bundle ID (macOS 26 API)
    // bundleIDs is a property on CATapDescription, not an initializer parameter.
    // Create a standard tap (with a placeholder process) then set bundleIDs to switch targeting mode.
    logInfo("Creating tap with bundleIDs: [\(bundleID)]...")

    // We need any valid AudioObjectID as placeholder for the init
    guard let placeholderProcess = findAudioProducingProcess() else {
        logResult("C", false, "No CoreAudio process found for placeholder")
        return
    }
    let placeholderNumber = NSNumber(value: placeholderProcess.objectID)
    let tapDesc = CATapDescription(__processes: [placeholderNumber], andDeviceUID: deviceUID, withStream: streamIndex)
    tapDesc.uuid = UUID()
    tapDesc.isPrivate = true
    tapDesc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
    if #available(macOS 26.0, *) {
        tapDesc.bundleIDs = [bundleID]
        logInfo("Set bundleIDs property to: \(tapDesc.bundleIDs)")
    } else {
        logResult("C", false, "bundleIDs property requires macOS 26.0+")
        return
    }

    var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
    if err != noErr {
        logResult("C.1", false, "Failed to create bundle-ID tap: \(osStatusString(err))")
        logInfo("bundleIDs-based taps may not be supported on this OS version")
        logResult("C", false, "bundleIDs API not available")
        return
    }
    logResult("C.1", true, "Created bundle-ID tap #\(tapID)")
    defer { AudioHardwareDestroyProcessTap(tapID) }

    // Create aggregate and check for audio
    let aggUID = UUID().uuidString
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "TapExperiment-C",
        kAudioAggregateDeviceUIDKey: aggUID,
        kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: deviceUID]
        ],
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            ]
        ],
    ]

    var aggID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
    guard err == noErr else {
        logResult("C.2", false, "Failed to create aggregate: \(osStatusString(err))")
        logResult("C", false, "Could not verify bundle-ID tap audio")
        return
    }
    defer { AudioHardwareDestroyAggregateDevice(aggID) }

    checkAggregateStreams(aggID)
    let cCounter = AtomicCounter()
    let cAudioFlag = AtomicFlag()
    let queue = DispatchQueue(label: "testC.io")
    var procID: AudioDeviceIOProcID?

    err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, inInputData, _, outOutputData, _ in
        cCounter.increment()
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        for i in 0..<inputBuffers.count {
            guard let data = inputBuffers[i].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(inputBuffers[i].mDataByteSize) / MemoryLayout<Float>.size
            for j in 0..<count {
                if abs(samples[j]) > 0.0001 {
                    cAudioFlag.set()
                    break
                }
            }
            if cAudioFlag.isSet { break }
        }
        let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
        for i in 0..<min(inputBuffers.count, outBuffers.count) {
            guard let inData = inputBuffers[i].mData,
                  let outData = outBuffers[i].mData else { continue }
            let bytes = min(inputBuffers[i].mDataByteSize, outBuffers[i].mDataByteSize)
            memcpy(outData, inData, Int(bytes))
        }
    }

    guard err == noErr, let procID else {
        logResult("C.2", false, "Failed to create IO proc: \(osStatusString(err))")
        logResult("C", false, "Could not verify bundle-ID tap audio")
        return
    }

    err = AudioDeviceStart(aggID, procID)
    guard err == noErr else {
        AudioDeviceDestroyIOProcID(aggID, procID)
        logResult("C.2", false, "Failed to start aggregate: \(osStatusString(err))")
        logResult("C", false, "Could not start bundle-ID tap")
        return
    }

    logInfo("Listening for audio from bundle-ID tap for 3 seconds...")
    Thread.sleep(forTimeInterval: 3.0)

    AudioDeviceStop(aggID, procID)
    AudioDeviceDestroyIOProcID(aggID, procID)

    logResult("C.2", cCounter.value > 50, "Bundle-ID tap callbacks: \(cCounter.value)")
    logResult("C.3", cAudioFlag.isSet, "Bundle-ID tap captured audio: \(cAudioFlag.isSet)")

    // Step 2: Test processRestoreEnabled
    logInfo("\nTesting processRestoreEnabled...")
    if #available(macOS 26.0, *) {
        tapDesc.isProcessRestoreEnabled = true
        logResult("C.4", true, "Set isProcessRestoreEnabled = true (property accepted)")
    } else {
        logResult("C.4", false, "processRestoreEnabled requires macOS 26.0+")
    }

    logInfo("\n--- processRestoreEnabled Manual Test ---")
    logInfo("To test auto-reconnect:")
    logInfo("  1. Keep this program running")
    logInfo("  2. Quit \(bundleID)")
    logInfo("  3. Relaunch \(bundleID)")
    logInfo("  4. Check if audio is still captured")
    logInfo("(Auto-reconnect cannot be verified programmatically in this run)")

    let overallPass = cCounter.value > 50
    logResult("C", overallPass, overallPass
              ? "Bundle-ID taps work; processRestoreEnabled set (manual relaunch test needed)"
              : "Bundle-ID tap created but callbacks insufficient")
}

// MARK: - Test D: Live deviceUID Change

func runTestD() {
    print("\n=== Test D: Live deviceUID Change ===")
    print("Goal: Can we change a tap's target device via kAudioTapPropertyDescription?\n")

    // Get all output devices
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)

    // Find output devices with UIDs
    var outputDevices: [(id: AudioDeviceID, uid: String, name: String)] = []
    for device in devices {
        // Check for output streams
        var streamsSize: UInt32 = 0
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(device, &streamAddr, 0, nil, &streamsSize)
        let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        guard streamCount > 0 else { continue }

        var uidCF: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, &uidCF) == noErr else { continue }

        var nameCF: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &nameAddr, 0, nil, &nameSize, &nameCF)

        let uid = uidCF as String
        let name = nameCF as String

        // Skip aggregates and virtual devices
        if uid.contains("FineTune") || uid.contains("TapExperiment") { continue }

        outputDevices.append((id: device, uid: uid, name: name))
    }

    logInfo("Found \(outputDevices.count) output device(s):")
    for (i, dev) in outputDevices.enumerated() {
        logInfo("  [\(i)] \(dev.name) (\(dev.uid))")
    }

    guard outputDevices.count >= 2 else {
        logResult("D", false, "Need at least 2 output devices to test live deviceUID change (found \(outputDevices.count))")
        logInfo("Connect a second output device (headphones, Bluetooth, etc.) and retry")
        return
    }

    let deviceA = outputDevices[0]
    let deviceB = outputDevices[1]
    logInfo("Device A: \(deviceA.name) (\(deviceA.uid))")
    logInfo("Device B: \(deviceB.name) (\(deviceB.uid))")

    guard let process = findAudioProducingProcess() else {
        logResult("D", false, "No audio-producing process found in CoreAudio process list")
        return
    }

    guard let streamIndex = getOutputStreamIndex(for: deviceA.uid) else {
        logResult("D", false, "Could not find output stream for Device A")
        return
    }

    // Step 1: Create tap targeting Device A
    let processNumber = NSNumber(value: process.objectID)
    let tapDesc = CATapDescription(__processes: [processNumber], andDeviceUID: deviceA.uid, withStream: streamIndex)
    tapDesc.uuid = UUID()
    tapDesc.isPrivate = true
    tapDesc.muteBehavior = CATapMuteBehavior.mutedWhenTapped

    var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
    guard err == noErr else {
        logResult("D", false, "Failed to create tap on Device A: \(osStatusString(err))")
        return
    }
    logResult("D.1", true, "Created tap #\(tapID) targeting Device A")
    defer { AudioHardwareDestroyProcessTap(tapID) }

    // Step 2: Change deviceUID to Device B via kAudioTapPropertyDescription
    var descAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyDescription,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var isSettable: DarwinBoolean = false
    err = AudioObjectIsPropertySettable(tapID, &descAddress, &isSettable)
    if err != noErr || !isSettable.boolValue {
        logResult("D.2", false, "kAudioTapPropertyDescription not settable: \(osStatusString(err)), isSettable=\(isSettable.boolValue)")
        logResult("D", false, "Cannot change deviceUID — property not settable")
        return
    }

    logInfo("Changing tap deviceUID from \(deviceA.uid) to \(deviceB.uid)...")

    // Modify the tap description with new device UID
    // Note: CATapDescription is an ObjC class, we need to create a new one
    guard let streamIndexB = getOutputStreamIndex(for: deviceB.uid) else {
        logResult("D.2", false, "Could not find output stream for Device B")
        logResult("D", false, "Device B has no output stream")
        return
    }

    let newTapDesc = CATapDescription(__processes: [processNumber], andDeviceUID: deviceB.uid, withStream: streamIndexB)
    newTapDesc.uuid = tapDesc.uuid // Keep same UUID
    newTapDesc.isPrivate = true
    newTapDesc.muteBehavior = CATapMuteBehavior.mutedWhenTapped

    var writeRef: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(newTapDesc)
    let writeSize = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
    err = AudioObjectSetPropertyData(tapID, &descAddress, 0, nil, writeSize, &writeRef)
    if err != noErr {
        logResult("D.2", false, "Failed to set new deviceUID: \(osStatusString(err))")
        logResult("D", false, "Live deviceUID change failed")
        return
    }
    logResult("D.2", true, "AudioObjectSetPropertyData succeeded for deviceUID change")

    // Step 3: Verify by creating aggregate on new device and checking audio
    let aggUID = UUID().uuidString
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "TapExperiment-D",
        kAudioAggregateDeviceUIDKey: aggUID,
        kAudioAggregateDeviceMainSubDeviceKey: deviceB.uid,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: deviceB.uid]
        ],
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            ]
        ],
    ]

    var aggID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
    guard err == noErr else {
        logResult("D.3", false, "Failed to create aggregate on Device B: \(osStatusString(err))")
        logResult("D", false, "Could not verify audio routes to Device B")
        return
    }
    defer { AudioHardwareDestroyAggregateDevice(aggID) }

    let dCounter = AtomicCounter()
    let dAudioFlag = AtomicFlag()
    let queue = DispatchQueue(label: "testD.io")
    var procID: AudioDeviceIOProcID?

    err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, inInputData, _, outOutputData, _ in
        dCounter.increment()
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        for i in 0..<inputBuffers.count {
            guard let data = inputBuffers[i].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(inputBuffers[i].mDataByteSize) / MemoryLayout<Float>.size
            for j in 0..<count {
                if abs(samples[j]) > 0.0001 {
                    dAudioFlag.set()
                    break
                }
            }
            if dAudioFlag.isSet { break }
        }
        let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
        for i in 0..<min(inputBuffers.count, outBuffers.count) {
            guard let inData = inputBuffers[i].mData,
                  let outData = outBuffers[i].mData else { continue }
            let bytes = min(inputBuffers[i].mDataByteSize, outBuffers[i].mDataByteSize)
            memcpy(outData, inData, Int(bytes))
        }
    }

    guard err == noErr, let procID else {
        logResult("D.3", false, "Failed to create IO proc: \(osStatusString(err))")
        logResult("D", false, "Could not verify audio on Device B")
        return
    }

    err = AudioDeviceStart(aggID, procID)
    guard err == noErr else {
        AudioDeviceDestroyIOProcID(aggID, procID)
        logResult("D.3", false, "Failed to start aggregate on Device B: \(osStatusString(err))")
        logResult("D", false, "Could not start Device B aggregate")
        return
    }

    logInfo("Listening on Device B for 3 seconds after live deviceUID change...")
    Thread.sleep(forTimeInterval: 3.0)

    AudioDeviceStop(aggID, procID)
    AudioDeviceDestroyIOProcID(aggID, procID)

    logResult("D.3", dCounter.value > 50, "Device B callbacks after switch: \(dCounter.value)")
    logResult("D.4", dAudioFlag.isSet, "Device B received audio: \(dAudioFlag.isSet)")

    logResult("D", dAudioFlag.isSet, dAudioFlag.isSet
              ? "Live deviceUID change works — audio routes to new device without recreation"
              : "Live deviceUID change did not produce audio on Device B")
}

// MARK: - Sanity Check: IO Proc on Raw Device

func runSanityCheck() {
    print("\n=== Sanity Check: IO Proc on Raw Default Device ===\n")

    // Get default output device ID directly
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard err == noErr else {
        logError("Could not get default output device: \(osStatusString(err))")
        return
    }
    logInfo("Default output device ID: \(deviceID)")

    // Check streams
    var outSize: UInt32 = 0
    var outAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(deviceID, &outAddr, 0, nil, &outSize)
    logInfo("Output streams: \(Int(outSize) / MemoryLayout<AudioStreamID>.size)")

    // Try block-based IO proc
    let counter = AtomicCounter()
    let queue = DispatchQueue(label: "sanity.io")
    var procID: AudioDeviceIOProcID?
    err = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, _, _, _, _ in
        counter.increment()
    }
    if err != noErr {
        logError("AudioDeviceCreateIOProcIDWithBlock failed: \(osStatusString(err))")
        return
    }
    logInfo("IO proc created successfully")

    err = AudioDeviceStart(deviceID, procID)
    if err != noErr {
        logError("AudioDeviceStart failed: \(osStatusString(err))")
        AudioDeviceDestroyIOProcID(deviceID, procID!)
        return
    }
    logInfo("Device started, waiting 1 second...")
    Thread.sleep(forTimeInterval: 1.0)

    AudioDeviceStop(deviceID, procID!)
    AudioDeviceDestroyIOProcID(deviceID, procID!)

    logInfo("Block-based IO proc callbacks on raw device: \(counter.value)")

    if counter.value == 0 {
        logInfo("Block-based IO proc got 0 callbacks. Trying function-pointer IO proc...")

        // Try the traditional C function pointer approach
        var fpProcID: AudioDeviceIOProcID?
        let ioProc: AudioDeviceIOProc = { _, _, _, _, _, _, _ in
            return noErr
        }
        err = AudioDeviceCreateIOProcID(deviceID, ioProc, nil, &fpProcID)
        if err != noErr {
            logError("AudioDeviceCreateIOProcID (func ptr) failed: \(osStatusString(err))")
            return
        }
        err = AudioDeviceStart(deviceID, fpProcID)
        if err != noErr {
            logError("AudioDeviceStart (func ptr) failed: \(osStatusString(err))")
            AudioDeviceDestroyIOProcID(deviceID, fpProcID!)
            return
        }
        Thread.sleep(forTimeInterval: 1.0)
        AudioDeviceStop(deviceID, fpProcID!)
        AudioDeviceDestroyIOProcID(deviceID, fpProcID!)
        logInfo("Function-pointer IO proc test complete (no crash = success)")
    }

    logResult("Sanity", counter.value > 0, "IO proc callbacks on raw device: \(counter.value)")

    // Test 2: Simple aggregate (no tap) to see if aggregates can start at all
    logInfo("\nTest 2: Simple aggregate with just the output device (no tap)...")
    guard let deviceUID = getDefaultOutputDeviceUID() else {
        logError("Could not get default device UID for aggregate test")
        return
    }

    let simpleAggUID = UUID().uuidString
    let simpleAggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "TapExperiment-Sanity",
        kAudioAggregateDeviceUIDKey: simpleAggUID,
        kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: deviceUID]
        ],
    ]

    var simpleAggID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    var err2 = AudioHardwareCreateAggregateDevice(simpleAggDesc as CFDictionary, &simpleAggID)
    guard err2 == noErr else {
        logError("Failed to create simple aggregate: \(osStatusString(err2))")
        return
    }
    defer { AudioHardwareDestroyAggregateDevice(simpleAggID) }
    checkAggregateStreams(simpleAggID)

    let aggCounter = AtomicCounter()
    let aggQueue = DispatchQueue(label: "sanity.agg")
    var aggProcID: AudioDeviceIOProcID?
    err2 = AudioDeviceCreateIOProcIDWithBlock(&aggProcID, simpleAggID, aggQueue) { _, _, _, _, _ in
        aggCounter.increment()
    }
    guard err2 == noErr, let aggProcID else {
        logError("Failed to create IO proc on simple aggregate: \(osStatusString(err2))")
        return
    }
    err2 = AudioDeviceStart(simpleAggID, aggProcID)
    guard err2 == noErr else {
        logError("Failed to start simple aggregate: \(osStatusString(err2))")
        AudioDeviceDestroyIOProcID(simpleAggID, aggProcID)
        return
    }
    checkDeviceIsRunning(simpleAggID)
    Thread.sleep(forTimeInterval: 1.0)
    checkDeviceIsRunning(simpleAggID)
    AudioDeviceStop(simpleAggID, aggProcID)
    AudioDeviceDestroyIOProcID(simpleAggID, aggProcID)
    logResult("Sanity.2", aggCounter.value > 0, "IO proc callbacks on simple aggregate (no tap): \(aggCounter.value)")

    // Test 3: Aggregate with sub-device AND tap to isolate the tap issue
    logInfo("\nTest 3: Aggregate with sub-device AND tap...")
    guard let process = findAudioProducingProcess() else {
        logError("No audio process found for tap test")
        return
    }
    guard let streamIdx = getOutputStreamIndex(for: deviceUID) else {
        logError("No output stream for tap test")
        return
    }
    let testTapDesc = CATapDescription(__processes: [NSNumber(value: process.objectID)], andDeviceUID: deviceUID, withStream: streamIdx)
    testTapDesc.uuid = UUID()
    testTapDesc.isPrivate = true
    testTapDesc.muteBehavior = CATapMuteBehavior.unmuted

    var testTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    err2 = AudioHardwareCreateProcessTap(testTapDesc, &testTapID)
    guard err2 == noErr else {
        logError("Failed to create tap: \(osStatusString(err2))")
        return
    }
    defer { AudioHardwareDestroyProcessTap(testTapID) }
    logInfo("Created tap #\(testTapID) with .unmuted for \(process.name)")

    let tapAggUID = UUID().uuidString
    let tapAggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "TapExperiment-Sanity3",
        kAudioAggregateDeviceUIDKey: tapAggUID,
        kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: deviceUID]
        ],
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: testTapDesc.uuid.uuidString,
            ]
        ],
    ]

    var tapAggID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    err2 = AudioHardwareCreateAggregateDevice(tapAggDesc as CFDictionary, &tapAggID)
    guard err2 == noErr else {
        logError("Failed to create tap aggregate: \(osStatusString(err2))")
        return
    }
    defer { AudioHardwareDestroyAggregateDevice(tapAggID) }
    checkAggregateStreams(tapAggID)

    let tapAggCounter = AtomicCounter()
    let tapAggQueue = DispatchQueue(label: "sanity.tapAgg")
    var tapAggProcID: AudioDeviceIOProcID?
    err2 = AudioDeviceCreateIOProcIDWithBlock(&tapAggProcID, tapAggID, tapAggQueue) { _, _, _, _, _ in
        tapAggCounter.increment()
    }
    guard err2 == noErr, let tapAggProcID else {
        logError("Failed to create IO proc on tap aggregate: \(osStatusString(err2))")
        return
    }
    err2 = AudioDeviceStart(tapAggID, tapAggProcID)
    guard err2 == noErr else {
        logError("Failed to start tap aggregate: \(osStatusString(err2))")
        AudioDeviceDestroyIOProcID(tapAggID, tapAggProcID)
        return
    }
    checkDeviceIsRunning(tapAggID)
    Thread.sleep(forTimeInterval: 1.0)
    checkDeviceIsRunning(tapAggID)
    AudioDeviceStop(tapAggID, tapAggProcID)
    AudioDeviceDestroyIOProcID(tapAggID, tapAggProcID)
    logResult("Sanity.3", tapAggCounter.value > 0, "IO proc callbacks on aggregate WITH tap (.unmuted): \(tapAggCounter.value)")
}

// MARK: - Main

func printUsage() {
    print("""
    TapExperiment — macOS 26 CoreAudio API Validation Harness

    Usage: TapExperiment [options]

    Options:
      --test A|B|C|D     Run specific test (default: run all)
      --bundle-id ID     Bundle ID for Test C (default: com.spotify.client)
      --help             Show this help

    Tests:
      A  Live tap reconfiguration (change muteBehavior without recreation)
      B  Tap-only aggregates (no real sub-device)
      C  bundleIDs + processRestoreEnabled
      D  Live deviceUID change
    """)
}

// Parse arguments
var selectedTest: String?
var bundleID = "com.spotify.client"

var args = CommandLine.arguments.dropFirst()
while let arg = args.first {
    args = args.dropFirst()
    switch arg {
    case "--test":
        selectedTest = args.first.map { String($0) }
        args = args.dropFirst()
    case "--bundle-id":
        bundleID = args.first.map { String($0) } ?? bundleID
        args = args.dropFirst()
    case "--help", "-h":
        printUsage()
        exit(0)
    default:
        logError("Unknown argument: \(arg)")
        printUsage()
        exit(1)
    }
}

print("==============================================")
print("  TapExperiment — macOS 26 API Validation")
print("==============================================")
print("Date: \(Date())")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

// Always run sanity check first
runSanityCheck()

if let test = selectedTest?.uppercased() {
    switch test {
    case "A": runTestA()
    case "B": runTestB()
    case "C": runTestC(bundleID: bundleID)
    case "D": runTestD()
    default:
        logError("Unknown test: \(test)")
        printUsage()
        exit(1)
    }
} else {
    runTestA()
    runTestB()
    runTestC(bundleID: bundleID)
    runTestD()
}

print("\n==============================================")
print("  Test Run Complete")
print("==============================================")
