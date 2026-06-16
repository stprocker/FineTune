import XCTest
import AudioToolbox
@testable import FineTuneIntegration

@MainActor
final class ServiceRestartCoordinatorTests: XCTestCase {

    func testEmitRestartEventsFiresWillBeginBeforeChurnAndRestarted() {
        let monitor = AudioDeviceMonitor()
        var events: [String] = []

        monitor.onServiceRestartWillBegin = {
            events.append("willBegin")
        }
        monitor.onDeviceDisconnected = { uid, _ in
            events.append("outputDisconnected:\(uid)")
        }
        monitor.onDeviceConnected = { uid, _ in
            events.append("outputConnected:\(uid)")
        }
        monitor.onInputDeviceDisconnected = { uid, _ in
            events.append("inputDisconnected:\(uid)")
        }
        monitor.onInputDeviceConnected = { uid, _ in
            events.append("inputConnected:\(uid)")
        }
        monitor.onServiceRestarted = {
            events.append("restarted")
        }

        monitor.emitRestartEvents(
            previousOutput: ["old-output"],
            currentOutput: ["new-output"],
            previousInput: ["old-input"],
            currentInput: ["new-input"]
        )

        XCTAssertEqual(events, [
            "willBegin",
            "outputDisconnected:old-output",
            "outputConnected:new-output",
            "inputDisconnected:old-input",
            "inputConnected:new-input",
            "restarted",
        ])
    }

    func testRestartAndPermissionTriggersCoalesceIntoOneTransaction() async {
        let engine = AudioEngine(
            defaultOutputDeviceUIDProvider: { "speakers" },
            isProcessRunningProvider: { _ in false }
        )
        defer { engine.stop() }
        engine.serviceRestartDelay = .milliseconds(50)
        engine.fastHealthCheckIntervals = []

        engine.serviceRestartWillBeginForTests()
        engine.serviceRestartDidCompleteForTests()
        engine.serviceRestartDidCompleteForTests()
        engine.permissionRecoveryRecreationForTests()

        XCTAssertTrue(engine.isInRecreationTransactionForTests)
        XCTAssertTrue(engine.suppressesDeviceNotificationsForTests)
        XCTAssertEqual(engine.recreationTransactionCountForTests, 1)

        await engine.waitForRecreationTransactionForTests()

        XCTAssertFalse(engine.isInRecreationTransactionForTests)
        XCTAssertEqual(engine.recreationTransactionCountForTests, 1)
    }

    func testProbeDrivenPermissionDowngradeCoalescesWithinActiveTransaction() async {
        let engine = AudioEngine(
            defaultOutputDeviceUIDProvider: { "speakers" },
            isProcessRunningProvider: { _ in false }
        )
        defer { engine.stop() }
        engine.serviceRestartDelay = .zero
        engine.fastHealthCheckIntervals = []
        engine.setPermissionConfirmedForTests(true)

        engine.serviceRestartWillBeginForTests()
        engine.serviceRestartDidCompleteForTests()
        await engine.waitForRecreationTransactionForTests()

        XCTAssertFalse(engine.permissionConfirmedForTests)
        XCTAssertEqual(engine.recreationTransactionCountForTests, 1)
    }

    func testCoalescedRestartDoesNotClearSuppressionBeforeActiveTransactionCompletes() async {
        let engine = AudioEngine(
            defaultOutputDeviceUIDProvider: { "speakers" },
            isProcessRunningProvider: { _ in false }
        )
        defer { engine.stop() }
        engine.serviceRestartDelay = .milliseconds(50)
        engine.fastHealthCheckIntervals = []

        engine.serviceRestartWillBeginForTests()
        engine.serviceRestartDidCompleteForTests()
        engine.serviceRestartDidCompleteForTests()

        XCTAssertEqual(engine.recreationTransactionCountForTests, 1)
        XCTAssertTrue(engine.suppressesDeviceNotificationsForTests)

        await engine.waitForRecreationTransactionForTests()

        XCTAssertFalse(engine.isInRecreationTransactionForTests)
        XCTAssertEqual(engine.recreationTransactionCountForTests, 1)
    }

    func testDisconnectDuringActiveTransactionDoesNotMutateRoutingOrSelection() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settings = SettingsManager(directory: tempDir)
        let engine = AudioEngine(
            settingsManager: settings,
            defaultOutputDeviceUIDProvider: { "speakers" },
            isProcessRunningProvider: { _ in false }
        )
        defer { engine.stop() }
        let app = makeFakeApp(pid: 19001, name: "Spotify", bundleID: "com.spotify")
        engine.updateDisplayedAppsStateForTests(activeApps: [app])
        engine.deviceMonitor.setOutputDevicesForTests([
            AudioDevice(id: AudioDeviceID(1), uid: "speakers", name: "Speakers", icon: nil),
        ])

        engine.appDeviceRouting[app.id] = "headphones"
        settings.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: "headphones")
        engine.volumeState.setDeviceSelectionMode(for: app.id, to: .multi, identifier: app.persistenceIdentifier)
        engine.volumeState.setSelectedDeviceUIDs(for: app.id, to: ["headphones", "speakers"], identifier: app.persistenceIdentifier)
        engine.markFollowsDefaultForTests([])

        engine.serviceRestartWillBeginForTests()
        engine.deviceDisconnectedForTests(uid: "headphones", name: "Headphones")

        XCTAssertEqual(engine.appDeviceRoutingSnapshotForTests(), [app.id: "headphones"])
        XCTAssertTrue(engine.followsDefaultSnapshotForTests().isEmpty)
        XCTAssertEqual(engine.volumeState.getSelectedDeviceUIDs(for: app.id), Set(["headphones", "speakers"]))
        XCTAssertEqual(settings.getSelectedDeviceUIDs(for: app.persistenceIdentifier), Set(["headphones", "speakers"]))
        XCTAssertEqual(engine.activeSwitchTaskCountForTests, 0)
    }

    func testCancelledInFlightSwitchTaskDrainsAndSkipsGuardedCommit() async {
        let engine = AudioEngine(
            defaultOutputDeviceUIDProvider: { "speakers" },
            isProcessRunningProvider: { _ in false }
        )
        defer { engine.stop() }
        engine.serviceRestartDelay = .zero
        engine.fastHealthCheckIntervals = []

        let started = expectation(description: "switch task started")
        var releaseOperation: CheckedContinuation<Void, Never>?
        var commitRan = false

        engine.installInFlightSwitchTaskForTests(
            pid: 19002,
            operation: {
                await withCheckedContinuation { continuation in
                    releaseOperation = continuation
                    started.fulfill()
                }
            },
            commit: {
                commitRan = true
            }
        )
        await fulfillment(of: [started], timeout: 1.0)
        XCTAssertEqual(engine.activeSwitchTaskCountForTests, 1)

        engine.serviceRestartWillBeginForTests()
        releaseOperation?.resume()
        engine.serviceRestartDidCompleteForTests()
        await engine.waitForRecreationTransactionForTests()

        XCTAssertFalse(commitRan)
        XCTAssertEqual(engine.activeSwitchTaskCountForTests, 0)
    }
}
