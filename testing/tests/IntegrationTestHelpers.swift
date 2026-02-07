// testing/tests/IntegrationTestHelpers.swift
import AppKit
@testable import FineTuneIntegration

/// Creates a fake AudioApp for testing. Used across integration test files.
func makeFakeApp(
    pid: pid_t = 99999,
    name: String = "TestApp",
    bundleID: String = "com.test.app"
) -> AudioApp {
    AudioApp(
        id: pid,
        objectID: .unknown,
        name: name,
        icon: NSImage(),
        bundleID: bundleID
    )
}
