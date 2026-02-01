// FineTune/Audio/Types/CoreAudioQueues.swift
import Foundation

/// Shared dispatch queues for CoreAudio operations.
/// Centralizes queue management to ensure consistent behavior across all audio components.
enum CoreAudioQueues {
    /// Shared background queue for all CoreAudio property listener callbacks.
    /// Using a dedicated queue avoids blocking the main thread during HAL operations,
    /// which can cause deadlocks with other apps (like System Settings) that also
    /// interact with CoreAudio on the main thread.
    static let listenerQueue = DispatchQueue(label: "com.finetune.coreaudio-listeners", qos: .userInitiated)
}
