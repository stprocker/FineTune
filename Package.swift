// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FineTuneCore",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "FineTuneCore", targets: ["FineTuneCore"]),
    ],
    targets: [
        .target(
            name: "FineTuneCore",
            path: "FineTune",
            sources: [
                "Audio/BiquadMath.swift",
                "Audio/Crossfade/CrossfadeState.swift",
                "Audio/Processing/AudioBufferProcessor.swift",
                "Audio/Processing/GainProcessor.swift",
                "Audio/Processing/SoftLimiter.swift",
                "Audio/Processing/VolumeRamper.swift",
                "Models/EQPreset.swift",
                "Models/EQSettings.swift",
                "Models/VolumeMapping.swift",
            ]
        ),
        .target(
            name: "FineTuneIntegration",
            dependencies: ["FineTuneCore"],
            path: "FineTune",
            exclude: [
                "FineTuneApp.swift",
                "Views",
                "Audio/BiquadMath.swift",
                "Audio/Crossfade/CrossfadeState.swift",
                "Audio/Processing/AudioBufferProcessor.swift",
                "Audio/Processing/GainProcessor.swift",
                "Audio/Processing/SoftLimiter.swift",
                "Audio/Processing/VolumeRamper.swift",
                "Models/EQPreset.swift",
                "Models/EQSettings.swift",
                "Models/VolumeMapping.swift",
                "Info.plist",
                "Info-Debug.plist",
                "FineTune.entitlements",
                "Settings/UpdateManager.swift",
                "Utilities/URLHandler.swift",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "FineTuneCoreTests",
            dependencies: ["FineTuneCore"],
            path: "testing/tests",
            sources: [
                "AppRowInteractionTests.swift",
                "AudioBufferProcessorTests.swift",
                "AudioBufferTestHelpers.swift",
                "BiquadMathTests.swift",
                "CrossfadeStateTests.swift",
                "EQPresetTests.swift",
                "EQSettingsTests.swift",
                "GainProcessorTests.swift",
                "SoftLimiterTests.swift",
                "PostEQLimiterTests.swift",
                "VolumeMappingTests.swift",
                "VolumeRamperTests.swift",
            ]
        ),
        .testTarget(
            name: "FineTuneIntegrationTests",
            dependencies: ["FineTuneIntegration", "FineTuneCore"],
            path: "testing/tests",
            sources: [
                "AudioEngineCharacterizationTests.swift",
                "AudioEngineRoutingTests.swift",
                "AudioSwitchingTests.swift",
                "DefaultDeviceBehaviorTests.swift",
                "IntegrationTestHelpers.swift",
                "ProcessTapControllerTests.swift",
                "StartupAudioInterruptionTests.swift",
                "SingleInstanceGuardTests.swift",
                "TapDiagnosticPatternTests.swift",
            ]
        ),
    ]
)
