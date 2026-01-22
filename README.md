<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="FineTune Icon">
</p>

# FineTune

**Per-application audio control for macOS.**

FineTune gives you granular control over your Mac's audio. Set individual volume levels for running apps, route specific apps to different output devices (e.g., Spotify to speakers, Zoom to headphones), and apply professional-grade EQ settings—all from a beautiful, native menu bar interface.

## Features

### 🎛️ Advanced Audio Control
- **Per-App Volume**: independent volume sliders for every running application.
- **Volume Boost**: Boost quiet apps up to 200%.
- **Mute Control**: Instantly mute individual apps or devices.
- **Device Management**: Control volume and mute state for all your output devices.

### 🔀 Smart Routing
- **Per-App Routing**: Send different apps to different audio devices effortlessly.
- **Quick Switching**: toggle your default system output directly from the menu.

### 🎨 10-Band Equalizer
Customize your sound with a powerful 10-band EQ and 20+ tailored presets across 5 categories:
- **Music**: Rock, Pop, Electronic, Jazz, Classical, Hip-Hop, R&B, Deep, Acoustic.
- **Speech**: Vocal Clarity, Podcast, Spoken Word.
- **Listening**: Loudness, Late Night, Small Speakers.
- **Media**: Movie mode for cinematic experiences.
- **Utility**: Flat, Bass Boost, Bass Cut, Treble Boost.

### ✨ Modern Design System
- **Glassmorphic UI**: A stunning, dark-mode-first interface that feels at home on macOS.
- **Fluid Animations**: Smooth transitions for expanding EQ panels and device lists.
- **Real-time Visuals**: Live VU meters for every active audio source.

### ⚡️ Power User Tools
- **Smart Activation**: Click an app's icon in the list to bring it to the front and restore minimized windows.
- **Robust Persistence**: Settings are saved automatically and safely, with corruption recovery to ensure your preferences are never lost.

## Requirements

- **macOS 14.0 (Sonoma)** or later.
- **Audio Permission**: Requires audio capture (microphone) permission to monitor and route application audio. You will be prompted on first launch.

## Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/yourusername/FineTune.git
   ```
2. **Open in Xcode**:
   Double-click `FineTune.xcodeproj`.
3. **Build and Run**:
   Select the "FineTune" scheme and press Cmd+R.

## Credits

Built with 100% Swift and SwiftUI.
- **FluidMenuBarExtra**: For the window-based menu bar experience.
- **CoreAudio**: For low-level audio routing and volume control.
