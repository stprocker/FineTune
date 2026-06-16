# Bug Sweep Remaining Risks - 2026-06-16

Source: follow-up verification and partial remediation of `docs/agents/18_comprehensive_bug_sweep/REPORT.md`.

Fixed in this pass:
- Onboarding red-X bypass of the startup path.
- Main-thread CoreAudio process-list reads in `AudioProcessMonitor`.
- Off-main SwiftUI binding mutation in popover/global click dismissal.
- Main-actor synchronous AppleScript activation and bundle-ID interpolation risk.
- Multi-device routing mode and selected UID startup restoration, including startup tap creation with the restored target UID set.
- Legacy/corrupt EQ band arrays crashing the EQ panel.
- Inert `maxVolumeBoost` setting on volume writes.
- Popup visibility false positives from unfiltered process-wide window notifications.
- App-row volume feedback loop on external volume updates.
- Empty single-mode device UID during mode-change tap creation.
- Tap-recreation re-entry and routing-suppression lifetime during coreaudiod restart recovery.
- Signal-handler HAL destruction risk, resolved by removing the signal-handler aggregate cleanup path and relying on normal teardown plus startup orphan cleanup.

Still open:
- EQ preamp headroom still accounts only for the largest positive band, not constructive overlap across the filter cascade.
- `DeviceVolumeMonitor.setDefaultDevice()` self-change suppression still relies partly on elapsed time rather than a target UID/token acknowledgement.
- `EQProcessor` still publishes setup/enabled/preamp state to the realtime thread without explicit release/acquire ordering.
- `ProcessTapController` secondary-converter promotion still has a narrow non-atomic optional-struct race while an IOProc may be in flight.
- Low-severity CoreAudio API/error-handling issues from the bug sweep remain open unless covered by the fixes above.
