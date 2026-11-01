import XCTest
@testable import FaceIDUnlock

/// Decision L2: no filling while the Mac is being watched or controlled remotely.
final class RemoteControlTests: XCTestCase {
    /// Running on Tim's Mac: Tailscale, a Zoom audio driver and the usual daemons.
    private let everyday = ["launchd", "WindowServer", "coreaudiod", "tailscaled", "Tailscale", "IPNExtension",
                            "zoom.us", "ZoomAudioDevice", "ScreenSharingSub", "loginwindow"]

    private func remote(onConsole: Bool? = true, _ processes: [String]?) -> Bool {
        LiveDialogSystem.isRemoteControlled(onConsole: onConsole, processes: processes)
    }

    func testOtherAppsThatCanShareTheScreenDoNotCount() {
        XCTAssertFalse(remote(everyday))
    }

    func testAConnectedScreenSharingClientCounts() {
        XCTAssertTrue(remote(everyday + ["screensharingd"]))
    }

    func testASessionThatIsNotOnTheMacsOwnScreenCounts() {
        XCTAssertTrue(remote(onConsole: false, everyday))
        XCTAssertFalse(remote(onConsole: nil, everyday), "A missing console flag alone doesn't block")
    }

    func testAnUnreadableProcessListCounts() {
        XCTAssertTrue(remote(nil))
    }

    func testTheProcessListIncludesDaemonsRunAsRoot() throws {
        // screensharingd runs as root; proc_name returns nothing for root processes, so it would never be seen.
        let names = try XCTUnwrap(LiveDialogSystem.processNames())
        XCTAssertTrue(names.contains("launchd"))
        XCTAssertTrue(names.contains("WindowServer"))
    }
}
