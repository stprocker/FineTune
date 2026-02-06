// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FineTuneCore",
    platforms: [.macOS(.v14)],
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
        .testTarget(
            name: "FineTuneCoreTests",
            dependencies: ["FineTuneCore"],
            path: "testing/tests",
            sources: [
                "AudioBufferProcessorTests.swift",
                "BiquadMathTests.swift",
                "CrossfadeStateTests.swift",
                "EQPresetTests.swift",
                "EQSettingsTests.swift",
                "GainProcessorTests.swift",
                "SoftLimiterTests.swift",
                "VolumeMappingTests.swift",
                "VolumeRamperTests.swift",
            ]
        ),
    ]
)
