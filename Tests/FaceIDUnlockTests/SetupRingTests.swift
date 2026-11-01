import FaceIDCore
import XCTest
@testable import FaceIDUnlock

/// Tripwire for the setup ring's ticks: a turn lights the half of the mirrored picture it turns toward, and
/// looking at the screen tints every tick together, never a route around the ring (which made the owner
/// circle his head in September 2026).
@MainActor
final class SetupRingTests: XCTestCase {
    /// The lit ticks' angles, in degrees clockwise from 12 o'clock.
    private func litAngles(_ progress: [FaceGallery.Pose: Double]) -> [Double] {
        (0..<72).filter { SetupView.tick($0, progress: progress).lit }.map { 2.5 + 5 * Double($0) }
    }

    func testOneLeftSampleLightsTheTwelveTicksAroundNineOClock() {
        XCTAssertEqual(litAngles([.center: 1, .left: 1.0 / 3, .right: 0]), Array(stride(from: 242.5, through: 297.5, by: 5)))
    }

    func testOneRightSampleMirrorsItAroundThreeOClock() {
        XCTAssertEqual(litAngles([.center: 1, .left: 0, .right: 1.0 / 3]), Array(stride(from: 62.5, through: 117.5, by: 5)))
    }

    func testEachSampleSpreadsTheSideFurther() {
        XCTAssertEqual(litAngles([.left: 2.0 / 3]), Array(stride(from: 212.5, through: 327.5, by: 5)))
        XCTAssertEqual(litAngles([.left: 1]), Array(stride(from: 182.5, through: 357.5, by: 5)))
    }

    func testLookingAtTheScreenTintsEveryTickTogether() {
        for center in [1.0 / 3, 2.0 / 3, 1] {
            for index in 0..<72 {
                let tick = SetupView.tick(index, progress: [.center: center, .left: 0, .right: 0])
                XCTAssertFalse(tick.lit, "tick \(index)")
                XCTAssertEqual(tick.green, 0.4 * center, accuracy: 0.0001, "tick \(index)")
            }
        }
    }

    func testDoneLightsEveryTick() {
        XCTAssertEqual(litAngles([.center: 1, .left: 1, .right: 1]).count, 72)
        XCTAssertTrue(litAngles([:]).isEmpty)
    }
}
