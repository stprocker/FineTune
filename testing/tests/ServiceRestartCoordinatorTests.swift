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
}
