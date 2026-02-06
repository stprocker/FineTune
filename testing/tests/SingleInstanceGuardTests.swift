import XCTest
@testable import FineTuneIntegration

final class SingleInstanceGuardTests: XCTestCase {

    // MARK: - Pure logic tests

    func testDuplicateInstanceDetectedAndWouldTerminate() {
        let apps = [
            RunningAppInfo(bundleID: "com.finetuneapp.FineTune", pid: 100),
            RunningAppInfo(bundleID: "com.finetuneapp.FineTune", pid: 200)
        ]

        let shouldTerminate = SingleInstanceGuard.shouldTerminate(
            bundleID: "com.finetuneapp.FineTune",
            currentPID: 100,
            runningApps: apps
        )

        XCTAssertTrue(shouldTerminate)
    }

    func testNoDuplicateInstanceDoesNotTerminate() {
        let apps = [
            RunningAppInfo(bundleID: "com.finetuneapp.FineTune", pid: 100)
        ]

        let shouldTerminate = SingleInstanceGuard.shouldTerminate(
            bundleID: "com.finetuneapp.FineTune",
            currentPID: 100,
            runningApps: apps
        )

        XCTAssertFalse(shouldTerminate)
    }

    func testDifferentBundleIDsAreIgnored() {
        let apps = [
            RunningAppInfo(bundleID: "com.other.app", pid: 999)
        ]

        let shouldTerminate = SingleInstanceGuard.shouldTerminate(
            bundleID: "com.finetuneapp.FineTune",
            currentPID: 100,
            runningApps: apps
        )

        XCTAssertFalse(shouldTerminate)
    }

    // MARK: - Termination wiring tests (shouldTerminateCurrentInstance)

    func testWiringDetectsDuplicateWhenSkipIsFalse() {
        // Simulates the exact Xcode scenario: two debug instances with same bundle ID
        let result = SingleInstanceGuard.shouldTerminateCurrentInstance(
            bundleIDProvider: { "com.finetuneapp.FineTune" },
            runningAppsProvider: {
                [
                    RunningAppInfo(bundleID: "com.finetuneapp.FineTune", pid: 100),
                    RunningAppInfo(bundleID: "com.finetuneapp.FineTune", pid: 200)
                ]
            },
            currentPID: 200,
            shouldSkip: { false }
        )

        XCTAssertTrue(result, "Second instance should be told to terminate when skip is disabled")
    }

    func testWiringSkipsDetectionDuringTests() {
        // When shouldSkip returns true (test environment), guard must not fire
        let result = SingleInstanceGuard.shouldTerminateCurrentInstance(
            bundleIDProvider: { "com.finetuneapp.FineTune" },
            runningAppsProvider: {
                [
                    RunningAppInfo(bundleID: "com.finetuneapp.FineTune", pid: 100),
                    RunningAppInfo(bundleID: "com.finetuneapp.FineTune", pid: 200)
                ]
            },
            currentPID: 200,
            shouldSkip: { true }
        )

        XCTAssertFalse(result, "Guard should be inactive when running in test environment")
    }

    func testWiringWithNilBundleIDNeverTerminates() {
        // If bundle ID is nil (e.g. command-line tool context), guard should be inert
        let result = SingleInstanceGuard.shouldTerminateCurrentInstance(
            bundleIDProvider: { nil },
            runningAppsProvider: {
                [RunningAppInfo(bundleID: nil, pid: 100)]
            },
            currentPID: 200,
            shouldSkip: { false }
        )

        XCTAssertFalse(result, "Nil bundle ID should never trigger termination")
    }

    func testWiringSoloInstanceDoesNotTerminate() {
        // Normal launch — only one instance running
        let result = SingleInstanceGuard.shouldTerminateCurrentInstance(
            bundleIDProvider: { "com.finetuneapp.FineTune" },
            runningAppsProvider: {
                [RunningAppInfo(bundleID: "com.finetuneapp.FineTune", pid: 100)]
            },
            currentPID: 100,
            shouldSkip: { false }
        )

        XCTAssertFalse(result, "Solo instance should not terminate")
    }

    func testWiringXcodeRelaunchScenario() {
        // Xcode "Run" while previous debug instance is still alive:
        // old instance (pid 83500) + new instance (pid 86842) + unrelated apps
        let result = SingleInstanceGuard.shouldTerminateCurrentInstance(
            bundleIDProvider: { "com.finetuneapp.FineTune" },
            runningAppsProvider: {
                [
                    RunningAppInfo(bundleID: "com.apple.finder", pid: 400),
                    RunningAppInfo(bundleID: "com.finetuneapp.FineTune", pid: 83500),
                    RunningAppInfo(bundleID: "com.apple.Safari", pid: 500),
                    RunningAppInfo(bundleID: "com.finetuneapp.FineTune", pid: 86842)
                ]
            },
            currentPID: 86842,
            shouldSkip: { false }
        )

        XCTAssertTrue(result, "Newer instance should detect stale older instance and terminate")
    }
}
