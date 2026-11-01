import XCTest
@testable import FaceIDUnlock

final class CameraPreferenceTests: XCTestCase {
    private let builtIn = CameraDevice(id: "built-in", displayName: "MacBook Pro Camera", isBuiltIn: true)
    private let studio = CameraDevice(id: "studio", displayName: "Studio Display Camera")
    private let usb = CameraDevice(id: "usb", displayName: "USB Webcam")
    private let phone = CameraDevice(id: "phone", displayName: "iPhone Camera")

    private func choice(_ devices: [CameraDevice], saved: String? = nil) -> String? {
        CameraPreference.choose(from: devices, saved: saved)?.id
    }

    func testSavedCameraWinsWhenConnected() {
        XCTAssertEqual(choice([builtIn, studio, usb], saved: "usb"), "usb")
    }

    func testBuiltInCameraComesFirstWithoutASavedChoice() {
        XCTAssertEqual(choice([usb, studio, phone, builtIn]), "built-in")
    }

    func testStudioDisplayComesNextWhenThereIsNoBuiltInCamera() {
        XCTAssertEqual(choice([usb, phone, studio]), "studio")
    }

    func testFirstCameraIsTheLastResort() {
        XCTAssertEqual(choice([phone, usb]), "phone")
        XCTAssertNil(choice([]))
    }

    func testSavedCameraThatIsUnpluggedFallsBackToTheOrder() {
        XCTAssertEqual(choice([usb, studio], saved: "built-in"), "studio")
    }

    func testIdleServiceSwitchesBackToASavedCameraThatReconnects() {
        XCTAssertEqual(CameraPreference.next(current: "built-in", devices: [builtIn, studio], saved: "studio", capturing: false), "studio")
        XCTAssertNil(CameraPreference.next(current: "studio", devices: [builtIn, studio], saved: "studio", capturing: false))
    }

    func testCapturingKeepsTheCurrentCameraUnlessItWentAway() {
        XCTAssertNil(CameraPreference.next(current: "built-in", devices: [builtIn, studio], saved: "studio", capturing: true))
        XCTAssertEqual(CameraPreference.next(current: "usb", devices: [builtIn, studio], saved: nil, capturing: true), "built-in")
        XCTAssertEqual(CameraPreference.next(current: "usb", devices: [], saved: nil, capturing: true), "")
    }
}
