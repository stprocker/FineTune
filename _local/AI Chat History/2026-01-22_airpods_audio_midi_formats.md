# Audio MIDI Setup Snapshot (AirPods Connected)

**Date:** 2026-01-22

This file captures the device formats shown in Audio MIDI Setup while AirPods were connected. The user reported **robot noise + System Settings freeze** only when AirPods were out of the case and connected. When AirPods were put away (disconnected), System Settings Output selection works normally.

## Devices & Formats (from screenshots)

- **MacBook Pro Speakers**: 48,000 Hz, **2 ch**, **32‑bit Float** (Output)
- **MacBook Pro Microphone**: 48,000 Hz, **1 ch**, **32‑bit Float** (Input)
- **Alex’s AirPods Pro 4.0 1**: 24,000 Hz, **1 ch**, **32‑bit Float** (Input only; 1 in / 0 out)
- **Alex’s AirPods Pro 4.0 2**: 24,000 Hz, **1 ch**, **32‑bit Float** (Output; 0 in / 1 out)
- **CalDigit Thunderbolt 3 Audio 1**: 48,000 Hz, **2 ch**, **16‑bit Integer** (Output; 0 in / 2 out)
- **CalDigit Thunderbolt 3 Audio 2**: 48,000 Hz, **2 ch**, **16‑bit Integer** (Input; 2 in / 0 out)
- **Scarlett 2i2 USB**: 48,000 Hz, **2 ch**, **24‑bit Integer** (Output; 2 in / 2 out)
- **Logitech Webcam C925e**: 16,000 Hz, **2 ch**, **16‑bit Integer** (Output; 2 in / 0 out)
- **Microsoft Teams Audio**: 48,000 Hz, **1 ch**, **32‑bit Float** (Output)
- **Background Music**: 44,100 Hz, **2 ch**, **32‑bit Float** (Output)
- **Background Music (UI Sounds)**: 44,100 Hz, **2 ch**, **32‑bit Float** (Output)
- **SRAudioDriver 2ch**: 48,000 Hz, **2 ch**, **32‑bit Float** (Output)
- **Splashtop Remote Sound**: 44,100 Hz, **2 ch**, **32‑bit Float** (Output)

## Aggregate / Multi‑Output Devices

- **Screen Recorder Go Aggregate**: 48.0 kHz sample rate (Aggregate; clock source SRAudioDriver 2ch)
- **Screen Recorder Go Stacked**: 48.0 kHz sample rate (Multi‑Output group)
- **AudioSwitcher MultiOutput**: *No devices in aggregate* (empty)

## FineTune UI (AirPods Connected)

- Output device list shows **Alex’s AirPods Pro 4.0** selected, plus CalDigit TB3 Audio, M32UC, MacBook Pro Speakers.
- Dropdown includes AirPods Pro, CalDigit TB3 Audio, M32UC, MacBook Pro Speakers, Scarlett 2i2 USB.

## Symptom Correlation

- **AirPods connected (24 kHz, 1‑ch Float)** → robot noise + System Settings Output freezes.
- **AirPods disconnected (in case)** → issue disappears; Output selection works normally.
