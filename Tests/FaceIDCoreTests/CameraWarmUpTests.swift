import XCTest
@testable import FaceIDCore

final class CameraWarmUpTests: XCTestCase {
    func testSettledExposureEndsWarmUpOnlyAfterTheMinimum() {
        var warmUp = CameraWarmUp()
        XCTAssertFalse(warmUp.observeFrame(at: 10, exposureSettled: true))
        XCTAssertFalse(warmUp.observeFrame(at: 10.25, exposureSettled: true), "Settled before the minimum is still warming up.")
        XCTAssertTrue(warmUp.observeFrame(at: 10.375, exposureSettled: true))
        XCTAssertEqual(warmUp.firstFrameAt, 10)
        XCTAssertEqual(warmUp.readyAt, 10.375)
        XCTAssertTrue(warmUp.observeFrame(at: 10.5, exposureSettled: false), "Once ready, it stays ready.")
    }

    func testUnsettledExposureEndsWarmUpAtTheMaximum() {
        var warmUp = CameraWarmUp()
        for time in [0, 0.5, 0.875] { XCTAssertFalse(warmUp.observeFrame(at: time, exposureSettled: false)) }
        XCTAssertTrue(warmUp.observeFrame(at: 1.0, exposureSettled: false), "A frame exactly at the maximum is usable.")
        XCTAssertEqual(warmUp.readyAt, 1.0)
    }

    func testLateFrameAfterTheMaximumMarksReadyAtThatFrame() {
        var warmUp = CameraWarmUp()
        warmUp.observeFrame(at: 0, exposureSettled: false)
        XCTAssertTrue(warmUp.observeFrame(at: 1.5, exposureSettled: false))
        XCTAssertEqual(warmUp.readyAt, 1.0)
    }

    func testClockEndsWarmUpWhenFramesStallButNotBeforeAnyFrame() {
        var warmUp = CameraWarmUp()
        warmUp.tick(now: 5)
        XCTAssertFalse(warmUp.isReady, "With no frame at all, the camera has not started.")
        warmUp.observeFrame(at: 6, exposureSettled: false)
        warmUp.tick(now: 6.5)
        XCTAssertFalse(warmUp.isReady)
        warmUp.tick(now: 7.25)
        XCTAssertEqual(warmUp.readyAt, 7)
        XCTAssertFalse(warmUp.observeFrame(at: 6.75, exposureSettled: true),
                       "A frame captured during warm-up but delivered late is still ignored.")
        XCTAssertTrue(warmUp.observeFrame(at: 7.5, exposureSettled: true))
    }

    func testEndIsTheLatestPossibleUntilReady() {
        var warmUp = CameraWarmUp()
        XCTAssertEqual(warmUp.end(startedAt: 3), 4)
        warmUp.observeFrame(at: 5, exposureSettled: false)
        XCTAssertEqual(warmUp.end(startedAt: 3), 6)
        warmUp.observeFrame(at: 5.5, exposureSettled: true)
        XCTAssertEqual(warmUp.end(startedAt: 3), 5.5)
    }

    func testNonFiniteTimesAreIgnored() {
        var warmUp = CameraWarmUp()
        XCTAssertFalse(warmUp.observeFrame(at: .nan, exposureSettled: true))
        XCTAssertNil(warmUp.firstFrameAt)
    }
}
