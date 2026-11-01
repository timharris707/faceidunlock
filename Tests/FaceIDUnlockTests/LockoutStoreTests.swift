import XCTest
@testable import FaceIDUnlock

/// Preferences in memory, so tests never write to disk. Values come back as UserDefaults returns them.
final class MemoryPreferences: PreferenceStore {
    private(set) var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class LockoutStoreTests: XCTestCase {
    private let builtIn = CameraDevice(id: "built-in", displayName: "MacBook Pro Camera", isBuiltIn: true)
    private let studio = CameraDevice(id: "0x2014000015bc0000", displayName: "Studio Display Camera")
    private let phone = CameraDevice(id: "phone", displayName: "Tim's iPhone Camera")

    private func newCamera(_ devices: [CameraDevice], trusted: Set<String>) -> String? {
        LockoutStore.newCamera(in: devices, trusted: trusted)?.displayName
    }

    func testCameraNeverTrustedIsNew() {
        XCTAssertEqual(newCamera([builtIn, studio], trusted: ["built-in"]), "Studio Display Camera")
        XCTAssertNil(newCamera([builtIn, studio], trusted: ["built-in", studio.id]))
    }

    func testTrustedCameraThatIsUnpluggedIsFine() {
        XCTAssertNil(newCamera([builtIn], trusted: ["built-in", "phone"]))
        XCTAssertNil(newCamera([], trusted: ["built-in"]))
    }

    func testTwoCamerasSharingOneIDAreNewEvenWhenTheIDIsTrusted() {
        // A camera extension chooses its own ID, so it can copy a real camera's.
        let copy = CameraDevice(id: "built-in", displayName: "Copy Camera")
        XCTAssertEqual(newCamera([builtIn, copy], trusted: ["built-in"]), "Copy Camera")
        XCTAssertEqual(LockoutStore.sharedID(in: [builtIn, studio, copy])?.displayName, "Copy Camera")
        XCTAssertNil(LockoutStore.sharedID(in: [builtIn, studio]))
        XCTAssertEqual(newCamera([builtIn, copy, phone], trusted: ["built-in"]), "Tim's iPhone Camera",
                       "A camera never trusted is named first")
    }

    func testTrustAddsToTheCamerasTrustedBefore() {
        let store = LockoutStore(defaults: MemoryPreferences())
        XCTAssertNil(store.trustedCameras, "Nothing trusted yet")
        store.trust([builtIn.id, phone.id])
        store.trust([builtIn.id, studio.id])
        XCTAssertEqual(store.trustedCameras, ["built-in", "phone", studio.id], "The phone stays trusted while away")
        store.trust([])
        XCTAssertEqual(store.trustedCameras?.count, 3)
    }

    func testMissesAndTheLockoutAreKeptInPreferences() {
        let preferences = MemoryPreferences()
        let store = LockoutStore(defaults: preferences)
        XCTAssertEqual(store.misses, 0)
        XCTAssertNil(store.lockout)
        store.misses = 2
        store.lockout = .newCamera(name: "USB Camera")
        store.pausedCamera = "usb"
        let reopened = LockoutStore(defaults: preferences)
        XCTAssertEqual(reopened.misses, 2)
        XCTAssertEqual(reopened.lockout, .newCamera(name: "USB Camera"))
        XCTAssertEqual(reopened.pausedCamera, "usb")
        reopened.lockout = .misses
        XCTAssertEqual(store.lockout, .misses)
        XCTAssertNil(preferences.values["pausedForCamera"], "No camera name kept for a pause after misses")
        XCTAssertNil(store.pausedCamera, "Nor its ID")
        store.lockout = nil
        XCTAssertNil(reopened.lockout)
    }
}
