// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapExperiment",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TapExperiment",
            path: ".",
            sources: ["main.swift"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
