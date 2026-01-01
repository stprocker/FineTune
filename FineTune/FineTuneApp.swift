// FineTune/FineTuneApp.swift
import SwiftUI

@main
struct FineTuneApp: App {
    @State private var audioEngine: AudioEngine

    var body: some Scene {
        MenuBarExtra("FineTune", systemImage: "slider.horizontal.3") {
            MenuBarPopupView(audioEngine: audioEngine)
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        let settings = SettingsManager()
        _audioEngine = State(initialValue: AudioEngine(settingsManager: settings))
    }
}
