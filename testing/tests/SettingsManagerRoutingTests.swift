import XCTest
@testable import FineTuneIntegration

/// Tests for SettingsManager device routing persistence.
///
/// These exercise the routing-specific APIs that underpin the entire device
/// routing system: set/get/clear/update/snapshot/restore. All are pure
/// logic + disk IO with no CoreAudio dependency.
@MainActor
final class SettingsManagerRoutingTests: XCTestCase {

    private var settings: SettingsManager!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        settings = SettingsManager(directory: tempDir)
    }

    override func tearDown() async throws {
        settings = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Basic CRUD

    func testSetAndGetDeviceRouting() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")

        XCTAssertEqual(settings.getDeviceRouting(for: "com.spotify"), "headphones")
    }

    func testGetReturnsNilWhenNotSet() {
        XCTAssertNil(settings.getDeviceRouting(for: "com.unknown"))
    }

    func testSetOverwritesPreviousValue() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "speakers")
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")

        XCTAssertEqual(settings.getDeviceRouting(for: "com.spotify"), "headphones")
    }

    func testClearDeviceRouting() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        settings.clearDeviceRouting(for: "com.spotify")

        XCTAssertNil(settings.getDeviceRouting(for: "com.spotify"),
                     "clearDeviceRouting should remove the entry entirely")
    }

    func testClearNonexistentIsNoOp() {
        // Should not crash or corrupt state
        settings.clearDeviceRouting(for: "com.nonexistent")
        XCTAssertNil(settings.getDeviceRouting(for: "com.nonexistent"))
    }

    // MARK: - Multiple Apps Independence

    func testMultipleAppsHaveIndependentRouting() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        settings.setDeviceRouting(for: "com.chrome", deviceUID: "speakers")
        settings.setDeviceRouting(for: "com.safari", deviceUID: "airpods")

        XCTAssertEqual(settings.getDeviceRouting(for: "com.spotify"), "headphones")
        XCTAssertEqual(settings.getDeviceRouting(for: "com.chrome"), "speakers")
        XCTAssertEqual(settings.getDeviceRouting(for: "com.safari"), "airpods")
    }

    func testClearOneDoesNotAffectOthers() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        settings.setDeviceRouting(for: "com.chrome", deviceUID: "speakers")

        settings.clearDeviceRouting(for: "com.spotify")

        XCTAssertNil(settings.getDeviceRouting(for: "com.spotify"))
        XCTAssertEqual(settings.getDeviceRouting(for: "com.chrome"), "speakers",
                       "Clearing one app should not affect another")
    }

    // MARK: - updateAllDeviceRoutings

    func testUpdateAllDeviceRoutings() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "speakers")
        settings.setDeviceRouting(for: "com.chrome", deviceUID: "headphones")
        settings.setDeviceRouting(for: "com.safari", deviceUID: "airpods")

        settings.updateAllDeviceRoutings(to: "new-device")

        XCTAssertEqual(settings.getDeviceRouting(for: "com.spotify"), "new-device")
        XCTAssertEqual(settings.getDeviceRouting(for: "com.chrome"), "new-device")
        XCTAssertEqual(settings.getDeviceRouting(for: "com.safari"), "new-device")
    }

    func testUpdateAllIsNoOpWhenEmpty() {
        // Should not crash or create entries
        settings.updateAllDeviceRoutings(to: "speakers")
        XCTAssertTrue(settings.snapshotDeviceRoutings().isEmpty,
                      "updateAllDeviceRoutings should not create entries when none exist")
    }

    func testUpdateAllSkipsAlreadyMatchingEntries() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        settings.setDeviceRouting(for: "com.chrome", deviceUID: "headphones")

        // All already match — this should be effectively a no-op
        settings.updateAllDeviceRoutings(to: "headphones")

        XCTAssertEqual(settings.getDeviceRouting(for: "com.spotify"), "headphones")
        XCTAssertEqual(settings.getDeviceRouting(for: "com.chrome"), "headphones")
    }

    // MARK: - Snapshot / Restore

    func testSnapshotCapturesCurrentState() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        settings.setDeviceRouting(for: "com.chrome", deviceUID: "speakers")

        let snapshot = settings.snapshotDeviceRoutings()

        XCTAssertEqual(snapshot["com.spotify"], "headphones")
        XCTAssertEqual(snapshot["com.chrome"], "speakers")
        XCTAssertEqual(snapshot.count, 2)
    }

    func testRestoreOverwritesCurrentState() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        settings.setDeviceRouting(for: "com.chrome", deviceUID: "speakers")

        let snapshot = settings.snapshotDeviceRoutings()

        // Mutate current state
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "airpods")
        settings.setDeviceRouting(for: "com.new-app", deviceUID: "speakers")
        settings.clearDeviceRouting(for: "com.chrome")

        // Restore should bring back the original state
        settings.restoreDeviceRoutings(snapshot)

        XCTAssertEqual(settings.getDeviceRouting(for: "com.spotify"), "headphones",
                       "Restore should revert spotify to headphones")
        XCTAssertEqual(settings.getDeviceRouting(for: "com.chrome"), "speakers",
                       "Restore should bring back chrome's routing")
        XCTAssertNil(settings.getDeviceRouting(for: "com.new-app"),
                     "Restore should remove entries that didn't exist in the snapshot")
    }

    func testRestoreWithEmptySnapshotClearsAll() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        settings.setDeviceRouting(for: "com.chrome", deviceUID: "speakers")

        settings.restoreDeviceRoutings([:])

        XCTAssertTrue(settings.snapshotDeviceRoutings().isEmpty,
                      "Restoring an empty snapshot should clear all routing entries")
    }

    func testSnapshotIsACopy() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        let snapshot = settings.snapshotDeviceRoutings()

        // Mutate after snapshot
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "speakers")

        XCTAssertEqual(snapshot["com.spotify"], "headphones",
                       "Snapshot should be a value copy, not affected by later mutations")
    }

    // MARK: - hasCustomSettings

    func testHasCustomSettingsWithRouting() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        XCTAssertTrue(settings.hasCustomSettings(for: "com.spotify"))
    }

    func testHasCustomSettingsWithVolumeOnly() {
        settings.setVolume(for: "com.spotify", to: 0.5)
        XCTAssertTrue(settings.hasCustomSettings(for: "com.spotify"))
    }

    func testHasCustomSettingsWithMuteOnly() {
        settings.setMute(for: "com.spotify", to: true)
        XCTAssertTrue(settings.hasCustomSettings(for: "com.spotify"))
    }

    func testHasCustomSettingsReturnsFalseWhenEmpty() {
        XCTAssertFalse(settings.hasCustomSettings(for: "com.unknown"))
    }

    // MARK: - isFollowingDefault

    func testIsFollowingDefaultWhenNoRouting() {
        XCTAssertTrue(settings.isFollowingDefault(for: "com.spotify"),
                      "App with no routing is following default")
    }

    func testIsFollowingDefaultReturnsFalseWithRouting() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        XCTAssertFalse(settings.isFollowingDefault(for: "com.spotify"),
                       "App with explicit routing is NOT following default")
    }

    func testIsFollowingDefaultAfterClear() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        settings.clearDeviceRouting(for: "com.spotify")
        XCTAssertTrue(settings.isFollowingDefault(for: "com.spotify"),
                      "App should be following default after routing is cleared")
    }

    // MARK: - Persistence Round-Trip (save to disk + reload)

    func testRoutingSurvivesSaveAndReload() {
        settings.setDeviceRouting(for: "com.spotify", deviceUID: "headphones")
        settings.setDeviceRouting(for: "com.chrome", deviceUID: "airpods")

        // Force synchronous save to disk (cancels debounce timer)
        settings.flushSync()

        // Create a new SettingsManager that loads from the same directory
        let reloaded = SettingsManager(directory: tempDir)

        XCTAssertEqual(reloaded.getDeviceRouting(for: "com.spotify"), "headphones",
                       "Routing should survive save + reload from disk")
        XCTAssertEqual(reloaded.getDeviceRouting(for: "com.chrome"), "airpods",
                       "Multiple app routings should survive save + reload")
    }
}
