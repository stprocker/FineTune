// FineTune/Audio/Extensions/AudioObjectID+Listener.swift
import AudioToolbox
import os

private let listenerLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioListener")

extension AudioObjectID {
    /// Adds a property listener block and returns the block on success, or nil on failure.
    /// Centralizes the repeated add-listener + error-check pattern used across monitors.
    @discardableResult
    func addPropertyListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> AudioObjectPropertyListenerBlock? {
        let selector = address.mSelector
        let status = AudioObjectAddPropertyListenerBlock(self, &address, queue, block)
        if status != noErr {
            listenerLogger.warning("Failed to add listener (selector \(selector)) on object \(self): \(status)")
            return nil
        }
        return block
    }

    /// Removes a previously added property listener block.
    func removePropertyListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        AudioObjectRemovePropertyListenerBlock(self, &address, queue, block)
    }
}
