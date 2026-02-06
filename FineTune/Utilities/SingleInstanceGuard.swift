// FineTune/Utilities/SingleInstanceGuard.swift
import AppKit

struct RunningAppInfo: Sendable, Equatable {
    let bundleID: String?
    let pid: pid_t
}

enum SingleInstanceGuard {
    static func shouldTerminate(
        bundleID: String?,
        currentPID: pid_t,
        runningApps: [RunningAppInfo]
    ) -> Bool {
        guard let bundleID else { return false }
        return runningApps.contains { $0.bundleID == bundleID && $0.pid != currentPID }
    }

    static func shouldTerminateCurrentInstance(
        bundleIDProvider: () -> String? = { Bundle.main.bundleIdentifier },
        runningAppsProvider: () -> [RunningAppInfo] = Self.defaultRunningApps,
        currentPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        shouldSkip: () -> Bool = Self.isRunningTests
    ) -> Bool {
        guard !shouldSkip() else { return false }
        return shouldTerminate(
            bundleID: bundleIDProvider(),
            currentPID: currentPID,
            runningApps: runningAppsProvider()
        )
    }

    private static func defaultRunningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(bundleID: $0.bundleIdentifier, pid: $0.processIdentifier)
        }
    }

    private static func isRunningTests() -> Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
