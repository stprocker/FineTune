import XCTest
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
}
