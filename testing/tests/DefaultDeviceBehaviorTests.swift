import XCTest
import AppKit
import AudioToolbox
@testable import FineTuneIntegration

@MainActor
final class DefaultDeviceBehaviorTests: XCTestCase {

    private var tempDir: URL?

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    func testVirtualDefaultDoesNotOverrideExplicitRouting() {
        let deviceMonitor = AudioDeviceMonitor()
        let volumeMonitor = DeviceVolumeMonitor(deviceMonitor: deviceMonitor)

        var routedUIDs: [String] = []
        volumeMonitor.onDefaultDeviceChangedExternally = { uid in
            routedUIDs.append(uid)
        }

        let physicalID = AudioDeviceID(100)
        volumeMonitor.applyDefaultDeviceChangeForTests(
            deviceID: physicalID,
            deviceUID: "physical-uid",
            isVirtual: false
        )

        routedUIDs.removeAll()

        let virtualID = AudioDeviceID(200)
        volumeMonitor.applyDefaultDeviceChangeForTests(
            deviceID: virtualID,
            deviceUID: "virtual-uid",
            isVirtual: true
        )

        XCTAssertEqual(volumeMonitor.defaultDeviceID, physicalID,
                       "Virtual default should not replace stored default device")
        XCTAssertEqual(volumeMonitor.defaultDeviceUID, "physical-uid",
                       "Virtual default should not replace stored default UID")
        XCTAssertEqual(routedUIDs.count, 0,
                       "Virtual default should not trigger routing callbacks")
    }

    func testDefaultFlipBackDoesNotRouteVirtual() {
        let deviceMonitor = AudioDeviceMonitor()
        let volumeMonitor = DeviceVolumeMonitor(deviceMonitor: deviceMonitor)

        var routedUIDs: [String] = []
        volumeMonitor.onDefaultDeviceChangedExternally = { uid in
            routedUIDs.append(uid)
        }

        let physicalID = AudioDeviceID(101)
        volumeMonitor.applyDefaultDeviceChangeForTests(
            deviceID: physicalID,
            deviceUID: "physical-a",
            isVirtual: false
        )

        routedUIDs.removeAll()

        let virtualID = AudioDeviceID(202)
        volumeMonitor.applyDefaultDeviceChangeForTests(
            deviceID: virtualID,
            deviceUID: "virtual-uid",
            isVirtual: true
        )

        XCTAssertEqual(volumeMonitor.defaultDeviceID, physicalID,
                       "Virtual default should not replace stored default device during flip")
        XCTAssertEqual(volumeMonitor.defaultDeviceUID, "physical-a",
                       "Virtual default should not replace stored default UID during flip")
        XCTAssertEqual(routedUIDs.count, 0,
                       "Virtual default should not trigger routing callbacks during flip")

        let physicalIDB = AudioDeviceID(303)
        volumeMonitor.applyDefaultDeviceChangeForTests(
            deviceID: physicalIDB,
            deviceUID: "physical-b",
            isVirtual: false
        )

        XCTAssertEqual(volumeMonitor.defaultDeviceID, physicalIDB)
        XCTAssertEqual(volumeMonitor.defaultDeviceUID, "physical-b")
        XCTAssertEqual(routedUIDs, ["physical-b"],
                       "Only non-virtual default should trigger routing after flip")
    }

    func testApplyPersistedSettingsSkipsVirtualDefault() {
        guard let tempDir else {
            XCTFail("Missing temp directory")
            return
        }

        let settings = SettingsManager(directory: tempDir)
        let engine = AudioEngine(
            settingsManager: settings,
            defaultOutputDeviceUIDProvider: { "virtual-uid" }
        )

        let realDevice = AudioDevice(
            id: AudioDeviceID(404),
            uid: "real-uid",
            name: "Real Speakers",
            icon: nil
        )
        engine.deviceMonitor.setOutputDevicesForTests([realDevice])

        let app = makeFakeApp()
        // App needs custom settings to pass the hasCustomSettings guard
        // (apps with no saved state are intentionally skipped on startup)
        settings.setVolume(for: app.persistenceIdentifier, to: 0.8)
        engine.applyPersistedSettingsForTests(apps: [app])

        let persistedUID = settings.getDeviceRouting(for: app.persistenceIdentifier)
        XCTAssertEqual(persistedUID, "real-uid",
                       "Persisted routing should skip virtual default and use real device")
    }
}
