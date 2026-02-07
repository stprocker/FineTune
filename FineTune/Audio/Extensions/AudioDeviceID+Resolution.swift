// FineTune/Audio/Extensions/AudioDeviceID+Resolution.swift
import AudioToolbox

/// Output stream resolution result
struct OutputStreamInfo {
    let deviceID: AudioDeviceID
    let streamID: AudioStreamID
    let streamIndex: Int
    let streamFormat: AudioStreamBasicDescription
}

extension AudioObjectID {

    /// Resolves output stream information for a device UID.
    ///
    /// - Parameters:
    ///   - deviceUID: The device UID to look up
    ///   - deviceMonitor: Optional device monitor for cached O(1) lookups
    /// - Returns: Output stream info if found, nil otherwise
    static func resolveOutputStreamInfo(
        for deviceUID: String,
        using deviceMonitor: AudioDeviceMonitor? = nil
    ) -> OutputStreamInfo? {
        // Fast path: use cached device lookup, fallback to fresh CoreAudio read
        guard let deviceID = deviceMonitor?.resolveDeviceID(for: deviceUID) else {
            return nil
        }

        guard let streamIDs = try? deviceID.readOutputStreamIDs(), !streamIDs.isEmpty else {
            return nil
        }

        // Prefer first active stream, fallback to index 0
        let activeIndex = streamIDs.firstIndex { streamID in
            (try? streamID.readBool(kAudioStreamPropertyIsActive)) ?? true
        } ?? 0

        let streamID = streamIDs[activeIndex]
        let streamFormat = (try? streamID.readVirtualFormat()) ?? AudioStreamBasicDescription()

        return OutputStreamInfo(
            deviceID: deviceID,
            streamID: streamID,
            streamIndex: activeIndex,
            streamFormat: streamFormat
        )
    }
}
