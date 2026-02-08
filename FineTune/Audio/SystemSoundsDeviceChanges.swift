// FineTune/Audio/SystemSoundsDeviceChanges.swift
//
// =============================================================================
// INTEGRATION GUIDE: System Sounds Support for DeviceVolumeMonitor
// =============================================================================
//
// This file documents the changes needed in DeviceVolumeMonitor.swift to support
// system sound effects device selection. Another agent is modifying DeviceVolumeMonitor
// for input devices, so these changes should be integrated after that work completes.
//
// The UI components (SoundEffectsDeviceRow, SettingsView) are already built and
// pass system sound state through parameters rather than directly referencing
// DeviceVolumeMonitor properties, so they will compile without these changes.
//
// =============================================================================
// 1. NEW STATE PROPERTIES
// =============================================================================
//
// Add these alongside the existing defaultDeviceID/defaultDeviceUID properties:
//
//     /// The current system output device ID (for alerts, notifications, Siri)
//     private(set) var systemDeviceID: AudioDeviceID = .unknown
//
//     /// The current system output device UID (cached)
//     private(set) var systemDeviceUID: String?
//
//     /// Whether system sounds follow the default output device
//     private(set) var isSystemFollowingDefault: Bool = true
//
// =============================================================================
// 2. CORE AUDIO LISTENER
// =============================================================================
//
// Add a property listener for kAudioHardwarePropertyDefaultSystemOutputDevice,
// similar to the existing defaultDeviceListenerBlock:
//
//     private var systemDeviceListenerBlock: AudioObjectPropertyListenerBlock?
//     private var systemDeviceDebounceTask: Task<Void, Never>?
//
//     private var systemDeviceAddress = AudioObjectPropertyAddress(
//         mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
//         mScope: kAudioObjectPropertyScopeGlobal,
//         mElement: kAudioObjectPropertyElementMain
//     )
//
// In start(), register the listener:
//
//     let systemBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
//         Task { @MainActor [weak self] in
//             self?.systemDeviceDebounceTask?.cancel()
//             self?.systemDeviceDebounceTask = Task { @MainActor [weak self] in
//                 try? await Task.sleep(for: .milliseconds(self?.defaultDeviceDebounceMs ?? 300))
//                 guard !Task.isCancelled else { return }
//                 self?.handleSystemDeviceChanged()
//             }
//         }
//     }
//     systemDeviceListenerBlock = AudioObjectID.system.addPropertyListener(
//         address: &systemDeviceAddress, queue: coreAudioListenerQueue, block: systemBlock
//     )
//
// In stop(), remove the listener:
//
//     if let block = systemDeviceListenerBlock {
//         AudioObjectID.system.removePropertyListener(
//             address: &systemDeviceAddress, queue: coreAudioListenerQueue, block: block
//         )
//         systemDeviceListenerBlock = nil
//     }
//     systemDeviceDebounceTask?.cancel()
//     systemDeviceDebounceTask = nil
//
// =============================================================================
// 3. REFRESH & VALIDATION METHODS
// =============================================================================
//
//     /// Re-reads the system output device from CoreAudio.
//     func refreshSystemDevice() {
//         do {
//             let newDeviceID = try AudioDeviceID.readDefaultSystemOutputDevice()
//             if newDeviceID.isValid {
//                 systemDeviceID = newDeviceID
//                 systemDeviceUID = try? newDeviceID.readDeviceUID()
//             } else {
//                 systemDeviceID = .unknown
//                 systemDeviceUID = nil
//             }
//         } catch {
//             logger.error("Failed to read system output device: \(error.localizedDescription)")
//         }
//     }
//
//     /// Validates system sound state after device list changes.
//     /// If the system device was disconnected, falls back to default.
//     func validateSystemSoundState() {
//         guard !isSystemFollowingDefault else { return }
//         let currentDeviceIDs = Set(deviceMonitor.outputDevices.map(\.id))
//         if !currentDeviceIDs.contains(systemDeviceID) {
//             logger.info("System sound device disconnected, reverting to follow default")
//             setSystemFollowDefault()
//         }
//     }
//
// =============================================================================
// 4. CHANGE HANDLER
// =============================================================================
//
//     /// Handles system output device change notification
//     private func handleSystemDeviceChanged() {
//         logger.debug("System output device changed")
//         refreshSystemDevice()
//     }
//
// =============================================================================
// 5. PUBLIC CONTROL METHODS
// =============================================================================
//
//     /// Sets system sounds to follow the default output device
//     func setSystemFollowDefault() {
//         isSystemFollowingDefault = true
//         // Sync system device to current default
//         do {
//             try AudioDeviceID.setSystemOutputDevice(defaultDeviceID)
//             refreshSystemDevice()
//         } catch {
//             logger.error("Failed to sync system device to default: \(error.localizedDescription)")
//         }
//     }
//
//     /// Sets system sounds to an explicit device
//     func setSystemDeviceExplicit(_ deviceID: AudioDeviceID) {
//         isSystemFollowingDefault = false
//         do {
//             try AudioDeviceID.setSystemOutputDevice(deviceID)
//             refreshSystemDevice()
//         } catch {
//             logger.error("Failed to set system output device: \(error.localizedDescription)")
//         }
//     }
//
// =============================================================================
// 6. MODIFY handleDefaultDeviceChanged() FOR FOLLOW-DEFAULT SYNC
// =============================================================================
//
// At the end of applyDefaultDeviceChange(deviceID:deviceUID:isVirtual:), add:
//
//     // Sync system sounds if following default
//     if isSystemFollowingDefault {
//         do {
//             try AudioDeviceID.setSystemOutputDevice(deviceID)
//             refreshSystemDevice()
//         } catch {
//             logger.error("Failed to sync system device after default change: \(error.localizedDescription)")
//         }
//     }
//
// =============================================================================
// 7. INIT & START UPDATES
// =============================================================================
//
// In init(), after refreshDefaultDevice(), add:
//     refreshSystemDevice()
//
// In start(), after refreshDefaultDevice(), add:
//     refreshSystemDevice()
//
// In handleServiceRestarted(), add refreshSystemDevice() in the recovery block.
//
// =============================================================================
// 8. WIRING TO SETTINGS VIEW
// =============================================================================
//
// When creating SettingsView, pass DeviceVolumeMonitor properties:
//
//     SettingsView(
//         settings: $appSettings,
//         onResetAll: { settingsManager.resetAllSettings() },
//         outputDevices: deviceMonitor.outputDevices,
//         systemDeviceUID: deviceVolumeMonitor.systemDeviceUID,
//         defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
//         isSystemFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
//         onSystemDeviceSelected: { deviceID in
//             deviceVolumeMonitor.setSystemDeviceExplicit(deviceID)
//         },
//         onSystemFollowDefault: {
//             deviceVolumeMonitor.setSystemFollowDefault()
//         },
//         currentIconStyle: currentMenuBarIconStyle,
//         onIconChanged: { style in
//             menuBarStatusController.updateIcon(to: style)
//         }
//     )
//
// =============================================================================

import Foundation

// This file is intentionally empty of executable code.
// It serves as documentation for the DeviceVolumeMonitor integration.
