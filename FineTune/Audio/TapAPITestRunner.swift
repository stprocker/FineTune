// FineTune/Audio/TapAPITestRunner.swift
import AudioToolbox
import AppKit
import Foundation

/// Runs macOS 26 CoreAudio tap API validation tests inside the running FineTune process.
/// This avoids TCC permission issues that block standalone CLI tools from using process taps.
///
/// Tests:
///   A — Live tap reconfiguration (kAudioTapPropertyDescription settable + write)
///   B — Tap-only aggregate (no real sub-device) vs standard aggregate
///   C — bundleIDs + processRestoreEnabled (macOS 26)
/// Not MainActor — runs entirely on a background thread to avoid freezing the UI.
final class TapAPITestRunner: @unchecked Sendable {
    private static var isRunning = false
    static let logFile = URL(fileURLWithPath: "/tmp/TapAPITest.log")

    private func log(_ msg: String) {
        let line = msg + "\n"
        NSLog("[TapAPITest] %@", msg)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.logFile.path) {
                if let handle = try? FileHandle(forWritingTo: Self.logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.logFile)
            }
        }
    }

    // Thread-safe counter for IO proc callbacks
    private final class Counter: @unchecked Sendable {
        private let ptr: UnsafeMutablePointer<Int64>
        init() { ptr = .allocate(capacity: 1); ptr.initialize(to: 0) }
        deinit { ptr.deallocate() }
        func increment() { OSAtomicIncrement64(ptr) }
        var value: Int64 { ptr.pointee }
    }

    private final class Flag: @unchecked Sendable {
        private let ptr: UnsafeMutablePointer<Int32>
        init() { ptr = .allocate(capacity: 1); ptr.initialize(to: 0) }
        deinit { ptr.deallocate() }
        func set() { OSAtomicCompareAndSwap32(0, 1, ptr) }
        var isSet: Bool { ptr.pointee != 0 }
    }

    func run() {
        guard !Self.isRunning else {
            log("Already running")
            return
        }
        Self.isRunning = true
        defer { Self.isRunning = false }

        // Clear previous log
        try? FileManager.default.removeItem(at: Self.logFile)

        log("========================================")
        log("  macOS 26 Validation — STARTING")
        log("========================================")
        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        runTestA()
        runTestB()
        runTestC()

        log("========================================")
        log("  COMPLETE")
        log("========================================")
    }

    // MARK: - Helpers

    private nonisolated func findProcess() -> (objectID: AudioObjectID, pid: pid_t, name: String)? {
        let processList: [AudioObjectID]
        do {
            processList = try AudioObjectID.readProcessList()
        } catch {
            log("[ERROR] Failed to read process list: \(error.localizedDescription)")
            return nil
        }
        let myPID = ProcessInfo.processInfo.processIdentifier

        let knownBundleIDs = [
            "com.spotify.client",
            "com.apple.Music",
            "com.apple.Safari",
            "com.brave.Browser",
            "com.google.Chrome",
        ]

        for bundleID in knownBundleIDs {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard let app = apps.first else { continue }
            let pid = app.processIdentifier
            for objectID in processList {
                guard let objPID = try? objectID.readProcessPID(), objPID == pid else { continue }
                let name = app.localizedName ?? bundleID
                log("  Target: \(name) (PID \(pid), AudioObjectID \(objectID))")
                return (objectID: objectID, pid: pid, name: name)
            }
        }

        // Fallback to any process that isn't us
        for objectID in processList {
            guard objectID.readProcessIsRunning(),
                  let pid = try? objectID.readProcessPID(),
                  pid != myPID else { continue }
            let name = objectID.readProcessBundleID() ?? "PID \(pid)"
            log("  Target (fallback): \(name) (PID \(pid), AudioObjectID \(objectID))")
            return (objectID: objectID, pid: pid, name: name)
        }
        return nil
    }

    private func getDefaultDeviceUID() -> String? {
        try? AudioDeviceID.readDefaultOutputDeviceUID()
    }

    private func getStreamIndex(for deviceUID: String) -> Int? {
        // resolveOutputStreamInfo requires a deviceMonitor; resolve device ID manually
        guard let devices = try? AudioObjectID.readDeviceList() else { return nil }
        for deviceID in devices {
            guard let uid = try? deviceID.readDeviceUID(), uid == deviceUID else { continue }
            guard let streamIDs = try? deviceID.readOutputStreamIDs(), !streamIDs.isEmpty else { return nil }
            let activeIndex = streamIDs.firstIndex { streamID in
                (try? streamID.readBool(kAudioStreamPropertyIsActive)) ?? true
            } ?? 0
            log("  Device \(deviceID) stream index \(activeIndex) (of \(streamIDs.count) output streams)")
            return activeIndex
        }
        return nil
    }

    private func pass(_ test: String, _ detail: String) {
        log("[PASS] \(test): \(detail)")
    }

    private func fail(_ test: String, _ detail: String) {
        log("[FAIL] \(test): \(detail)")
    }

    private func info(_ msg: String) {
        log("  \(msg)")
    }

    private func osStr(_ status: OSStatus) -> String {
        if status == noErr { return "noErr" }
        let bytes: [UInt8] = [
            UInt8((status >> 24) & 0xFF), UInt8((status >> 16) & 0xFF),
            UInt8((status >> 8) & 0xFF), UInt8(status & 0xFF),
        ]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")' (\(status))"
        }
        return "\(status)"
    }

    // MARK: - Test A: Live Tap Reconfiguration

    private func runTestA() {
        log("=== Test A: Live Tap Reconfiguration ===")

        guard let deviceUID = getDefaultDeviceUID() else { fail("A", "No default device"); return }
        guard let process = findProcess() else { fail("A", "No target process"); return }
        guard let streamIndex = getStreamIndex(for: deviceUID) else { fail("A", "No output stream"); return }

        let tapDesc = CATapDescription(
            __processes: [NSNumber(value: process.objectID)],
            andDeviceUID: deviceUID,
            withStream: streamIndex
        )
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else { fail("A", "CreateProcessTap: \(osStr(err))"); return }
        defer { AudioHardwareDestroyProcessTap(tapID); info("Destroyed tap #\(tapID)") }
        info("Created tap #\(tapID)")

        // Check settable
        var descAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable: DarwinBoolean = false
        err = AudioObjectIsPropertySettable(tapID, &descAddr, &isSettable)
        if err == noErr {
            pass("A.1", "isSettable = \(isSettable.boolValue)")
        } else {
            fail("A.1", "IsPropertySettable: \(osStr(err))")
        }

        // Read current description
        var readRef: Unmanaged<CATapDescription>?
        var readSize = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        err = AudioObjectGetPropertyData(tapID, &descAddr, 0, nil, &readSize, &readRef)
        if err == noErr {
            let desc = readRef?.takeUnretainedValue()
            pass("A.2", "Read muteBehavior = \(desc?.muteBehavior.rawValue ?? -1)")
        } else {
            fail("A.2", "GetPropertyData: \(osStr(err))")
        }

        // Try writing (before aggregate)
        tapDesc.muteBehavior = .mutedWhenTapped
        var writeRef: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(tapDesc)
        let writeSize = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        err = AudioObjectSetPropertyData(tapID, &descAddr, 0, nil, writeSize, &writeRef)
        if err == noErr {
            pass("A.3", "SetPropertyData succeeded (live muteBehavior change works!)")
        } else {
            fail("A.3", "SetPropertyData: \(osStr(err))")
        }

        // Create aggregate + IO proc to verify callbacks
        let aggUID = UUID().uuidString
        tapDesc.muteBehavior = .unmuted // Reset for aggregate test
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FT-APITest-A",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            ]],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard err == noErr else { fail("A.4", "CreateAggregate: \(osStr(err))"); return }
        defer { AudioHardwareDestroyAggregateDevice(aggID) }

        let counter = Counter()
        let queue = DispatchQueue(label: "ft.apitest.a")
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, _, _, _, _ in
            counter.increment()
        }
        guard err == noErr, let procID else { fail("A.4", "CreateIOProc: \(osStr(err))"); return }
        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(aggID, procID)
            fail("A.4", "DeviceStart: \(osStr(err))")
            return
        }
        Thread.sleep(forTimeInterval: 2.0)
        AudioDeviceStop(aggID, procID)
        AudioDeviceDestroyIOProcID(aggID, procID)

        if counter.value > 50 {
            pass("A.4", "Callbacks: \(counter.value)")
        } else {
            fail("A.4", "Callbacks: \(counter.value) (expected >50)")
        }
    }

    // MARK: - Test B: Tap-Only Aggregate

    private func runTestB() {
        log("=== Test B: Tap-Only Aggregate ===")

        guard let deviceUID = getDefaultDeviceUID() else { fail("B", "No default device"); return }
        guard let process = findProcess() else { fail("B", "No target process"); return }
        guard let streamIndex = getStreamIndex(for: deviceUID) else { fail("B", "No output stream"); return }

        let processNum = NSNumber(value: process.objectID)

        // --- Tap-only aggregate (no sub-device) ---
        let tapDesc = CATapDescription(__processes: [processNum], andDeviceUID: deviceUID, withStream: streamIndex)
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else { fail("B", "CreateProcessTap: \(osStr(err))"); return }
        defer { AudioHardwareDestroyProcessTap(tapID) }
        info("Created tap #\(tapID)")

        let tapOnlyAggUID = UUID().uuidString
        let tapOnlyAggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FT-APITest-B-TapOnly",
            kAudioAggregateDeviceUIDKey: tapOnlyAggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            ]],
        ]

        var tapOnlyAggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(tapOnlyAggDesc as CFDictionary, &tapOnlyAggID)
        if err != noErr {
            fail("B.1", "CreateTapOnlyAggregate: \(osStr(err))")
        } else {
            pass("B.1", "Created tap-only aggregate #\(tapOnlyAggID)")
            let (tapOnlyCallbacks, tapOnlyAudio) = measureAggregate(tapOnlyAggID, label: "B-TapOnly", seconds: 3.0)
            AudioHardwareDestroyAggregateDevice(tapOnlyAggID)

            if tapOnlyCallbacks > 50 { pass("B.2", "TapOnly callbacks: \(tapOnlyCallbacks)") }
            else { fail("B.2", "TapOnly callbacks: \(tapOnlyCallbacks)") }
            if tapOnlyAudio { pass("B.3", "TapOnly has audio data") }
            else { fail("B.3", "TapOnly no audio data") }
        }

        // --- Control: standard aggregate with sub-device ---
        let ctrlTapDesc = CATapDescription(__processes: [processNum], andDeviceUID: deviceUID, withStream: streamIndex)
        ctrlTapDesc.uuid = UUID()
        ctrlTapDesc.isPrivate = true
        ctrlTapDesc.muteBehavior = .mutedWhenTapped

        var ctrlTapID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateProcessTap(ctrlTapDesc, &ctrlTapID)
        guard err == noErr else { fail("B.ctrl", "CreateControlTap: \(osStr(err))"); return }
        defer { AudioHardwareDestroyProcessTap(ctrlTapID) }

        let ctrlAggUID = UUID().uuidString
        let ctrlAggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FT-APITest-B-Ctrl",
            kAudioAggregateDeviceUIDKey: ctrlAggUID,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: ctrlTapDesc.uuid.uuidString,
            ]],
        ]

        var ctrlAggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(ctrlAggDesc as CFDictionary, &ctrlAggID)
        guard err == noErr else { fail("B.ctrl", "CreateControlAggregate: \(osStr(err))"); return }
        let (ctrlCallbacks, ctrlAudio) = measureAggregate(ctrlAggID, label: "B-Ctrl", seconds: 3.0)
        AudioHardwareDestroyAggregateDevice(ctrlAggID)

        if ctrlCallbacks > 50 { pass("B.ctrl.1", "Control callbacks: \(ctrlCallbacks)") }
        else { fail("B.ctrl.1", "Control callbacks: \(ctrlCallbacks)") }
        if ctrlAudio { pass("B.ctrl.2", "Control has audio data") }
        else { fail("B.ctrl.2", "Control no audio data") }

        info("Summary — TapOnly: callbacks=\(tapOnlyAggID != AudioObjectID(kAudioObjectUnknown) ? "see above" : "skipped"), Control: callbacks=\(ctrlCallbacks)")
    }

    // MARK: - Test C: bundleIDs + processRestoreEnabled

    private func runTestC() {
        log("=== Test C: bundleIDs + processRestoreEnabled ===")

        guard let deviceUID = getDefaultDeviceUID() else { fail("C", "No default device"); return }
        guard let process = findProcess() else { fail("C", "No target process"); return }
        guard let streamIndex = getStreamIndex(for: deviceUID) else { fail("C", "No output stream"); return }

        let tapDesc = CATapDescription(
            __processes: [NSNumber(value: process.objectID)],
            andDeviceUID: deviceUID,
            withStream: streamIndex
        )
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped

        // Set bundleIDs (macOS 26)
        let bundleID = "com.spotify.client"
        if #available(macOS 26.0, *) {
            tapDesc.bundleIDs = [bundleID]
            pass("C.1a", "Set bundleIDs = [\(bundleID)]")
        } else {
            fail("C.1a", "bundleIDs requires macOS 26")
            return
        }

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        if err == noErr {
            pass("C.1b", "Created bundle-ID tap #\(tapID)")
        } else {
            fail("C.1b", "CreateProcessTap with bundleIDs: \(osStr(err))")
            return
        }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        // Test audio flow
        let aggUID = UUID().uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FT-APITest-C",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            ]],
        ]

        var aggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard err == noErr else { fail("C.2", "CreateAggregate: \(osStr(err))"); return }
        let (callbacks, hasAudio) = measureAggregate(aggID, label: "C", seconds: 3.0)
        AudioHardwareDestroyAggregateDevice(aggID)

        if callbacks > 50 { pass("C.2", "Bundle-ID tap callbacks: \(callbacks)") }
        else { fail("C.2", "Bundle-ID tap callbacks: \(callbacks)") }
        if hasAudio { pass("C.3", "Bundle-ID tap captured audio") }
        else { fail("C.3", "Bundle-ID tap no audio (is Spotify playing?)") }

        // processRestoreEnabled
        if #available(macOS 26.0, *) {
            tapDesc.isProcessRestoreEnabled = true
            pass("C.4", "isProcessRestoreEnabled = true accepted")
        } else {
            fail("C.4", "processRestoreEnabled requires macOS 26")
        }
    }

    // MARK: - Shared IO Proc Measurement

    private func measureAggregate(_ aggID: AudioObjectID, label: String, seconds: TimeInterval) -> (callbacks: Int64, hasAudio: Bool) {
        let counter = Counter()
        let audioFlag = Flag()
        let queue = DispatchQueue(label: "ft.apitest.\(label)")
        var procID: AudioDeviceIOProcID?

        var err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, inInputData, _, outOutputData, _ in
            counter.increment()
            let inBufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            for i in 0..<inBufs.count {
                guard let data = inBufs[i].mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let count = Int(inBufs[i].mDataByteSize) / MemoryLayout<Float>.size
                for j in 0..<count {
                    if abs(samples[j]) > 0.0001 { audioFlag.set(); break }
                }
                if audioFlag.isSet { break }
            }
            // Passthrough
            let outBufs = UnsafeMutableAudioBufferListPointer(outOutputData)
            for i in 0..<min(inBufs.count, outBufs.count) {
                guard let inData = inBufs[i].mData, let outData = outBufs[i].mData else { continue }
                let bytes = min(inBufs[i].mDataByteSize, outBufs[i].mDataByteSize)
                memcpy(outData, inData, Int(bytes))
            }
        }
        guard err == noErr, let procID else {
            info("\(label) CreateIOProc failed: \(osStr(err))")
            return (0, false)
        }

        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(aggID, procID)
            info("\(label) DeviceStart failed: \(osStr(err))")
            return (0, false)
        }

        Thread.sleep(forTimeInterval: seconds)

        AudioDeviceStop(aggID, procID)
        AudioDeviceDestroyIOProcID(aggID, procID)

        return (counter.value, audioFlag.isSet)
    }
}
