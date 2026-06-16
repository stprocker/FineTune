import AudioToolbox
import XCTest
@testable import FineTuneIntegration

final class OrphanedTapCleanupTests: XCTestCase {
    func testDestroyOrphanedDevicesOnlyDestroysFineTuneAggregateDevices() {
        let fineTuneAggregate = AudioDeviceID(101)
        let unrelatedAggregate = AudioDeviceID(102)
        let fineTuneBuiltIn = AudioDeviceID(103)
        let secondFineTuneAggregate = AudioDeviceID(104)
        var destroyedDevices: [AudioDeviceID] = []

        OrphanedTapCleanup.destroyOrphanedDevices(
            readDevices: {
                [
                    fineTuneAggregate,
                    unrelatedAggregate,
                    fineTuneBuiltIn,
                    secondFineTuneAggregate,
                ]
            },
            readTransportType: { device in
                device == fineTuneBuiltIn ? .builtIn : .aggregate
            },
            readDeviceName: { device in
                switch device {
                case fineTuneAggregate:
                    "FineTune-123"
                case unrelatedAggregate:
                    "User Aggregate"
                case fineTuneBuiltIn:
                    "FineTune-456"
                case secondFineTuneAggregate:
                    "FineTune-789-secondary"
                default:
                    nil
                }
            },
            destroyAggregateDevice: { device in
                destroyedDevices.append(device)
                return noErr
            }
        )

        XCTAssertEqual(destroyedDevices, [fineTuneAggregate, secondFineTuneAggregate])
    }
}
