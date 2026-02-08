// FineTune/Views/Onboarding/OnboardingView.swift
import SwiftUI

struct OnboardingView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 8)

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("Welcome to FineTune")
                .font(.system(size: 24, weight: .bold))

            Text("FineTune needs the **Screen & System Audio Recording** permission to capture and control per-app audio.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

            Text("Grant the permission in System Settings, then come back here and click Continue.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

            Spacer().frame(height: 4)

            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open System Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .frame(width: 240)

            Button {
                onContinue()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .frame(width: 240)

            Spacer().frame(height: 8)
        }
        .padding(32)
        .frame(width: 440)
    }
}
