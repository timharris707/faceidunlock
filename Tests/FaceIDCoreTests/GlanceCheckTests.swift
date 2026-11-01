import XCTest
@testable import FaceIDCore

final class GlanceCheckTests: XCTestCase {
    /// SplitMix64: the same seed always gives the same directions.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    /// The camera sees the person from a little to one side, so their resting angle is not zero.
    private let rest = 0.12

    private func glance(_ direction: GlanceCheck.Direction, restingYaw: Double? = 0.12,
                        restingPoints: FacePoints? = nil) -> GlanceCheck {
        GlanceCheck(direction: direction, restingYaw: restingYaw, restingPoints: restingPoints, gallery: Synthetic.owner,
                    startedAt: 10)
    }

    /// A one-face frame turned `turn` radians toward `direction` (negative: the other way) from the resting angle.
    private func turned(_ time: TimeInterval, _ turn: Double, toward direction: GlanceCheck.Direction,
                        score: Float = 0.8, real: Float? = nil, points: FacePoints? = nil) -> FaceObservation {
        let sign = direction == .left ? MatchSettings.leftYawSign : -MatchSettings.leftYawSign
        return Synthetic.face(time, score: score, yaw: rest + sign * turn, photoScreen: real.map(Synthetic.photoScreen),
                              points: points)
    }

    func testTurningTheAskedWayPasses() {
        for direction in GlanceCheck.Direction.allCases {
            var check = glance(direction)
            XCTAssertNil(check.observe(turned(10.2, 0.05, toward: direction)))
            XCTAssertNil(check.observe(turned(10.4, 0.15, toward: direction)))
            XCTAssertEqual(check.observe(turned(10.6, 0.25, toward: direction)), .passed, "\(direction)")
            let record = check.record
            XCTAssertEqual(record.direction, direction)
            XCTAssertEqual(record.outcome, .passed)
            XCTAssertEqual(record.timeToPass ?? 0, 0.6, accuracy: 0.0001)
            XCTAssertEqual(record.timeToEnd ?? 0, 0.6, accuracy: 0.0001)
            XCTAssertEqual(record.turnedScore ?? 0, 0.8, accuracy: 0.001, "The passing frame was the only one turned enough")
            let sign = direction == .left ? MatchSettings.leftYawSign : -MatchSettings.leftYawSign
            XCTAssertEqual(record.yawChange ?? 0, sign * 0.25, accuracy: 0.0001, "Signed as Vision reports yaw")
        }
    }

    func testTheTurnIsMeasuredFromTheRestingAngleAndExactlyGlanceYawIsEnough() {
        let sign = MatchSettings.leftYawSign
        var exact = glance(.left, restingYaw: 0)
        XCTAssertEqual(exact.observe(Synthetic.face(10.5, score: 0.8, yaw: sign * MatchSettings.glanceYaw)), .passed)

        // A camera off to one side: resting at 0.4, a frame at 0.45 has turned only 0.05, though it is far from zero.
        var offAxis = glance(.left, restingYaw: sign * 0.4)
        XCTAssertNil(offAxis.observe(Synthetic.face(10.2, score: 0.8, yaw: sign * 0.45)))
        XCTAssertEqual(offAxis.observe(Synthetic.face(10.3, score: 0.8, yaw: sign * 0.65)), .passed)
    }

    func testTurningTheOtherWayFirstFails() {
        var check = glance(.right)
        XCTAssertNil(check.observe(turned(10.2, -0.1, toward: .right)))
        XCTAssertEqual(check.observe(turned(10.4, -0.22, toward: .right)), .wrongWay)
        XCTAssertEqual(check.observe(turned(10.6, 0.3, toward: .right)), .wrongWay, "A finished glance stays finished")
        let sign = -MatchSettings.leftYawSign
        XCTAssertEqual(check.record.yawChange ?? 0, sign * -0.22, accuracy: 0.0001)
        XCTAssertNil(check.record.timeToPass)
        XCTAssertEqual(check.record.timeToEnd ?? 0, 0.4, accuracy: 0.0001, "A failure says how soon it came")
    }

    func testTheWrongWayFailsEvenWhenThatFrameDoesNotMatch() {
        var check = glance(.left)
        XCTAssertEqual(check.observe(turned(10.3, -0.3, toward: .left, score: 0.1)), .wrongWay)
    }

    func testASmallWobbleDecidesNothingAndThenTimesOut() {
        var check = glance(.left)
        for (index, wobble) in [0.1, -0.1, 0.19, -0.15, 0.0].enumerated() {
            XCTAssertNil(check.observe(turned(10.1 + Double(index) / 10, wobble, toward: .left)))
        }
        XCTAssertNil(check.tick(now: 10 + MatchSettings.glanceTimeout - 0.001))
        XCTAssertEqual(check.tick(now: 10 + MatchSettings.glanceTimeout), .timeout)
        XCTAssertEqual(check.record.outcome, .timeout)
        XCTAssertEqual(check.record.yawChange ?? 0, MatchSettings.leftYawSign * 0.19, accuracy: 0.0001,
                       "The furthest turn seen, so a too-small turn shows in the log")
        XCTAssertEqual(check.record.timeToEnd ?? 0, MatchSettings.glanceTimeout, accuracy: 0.0001)
        XCTAssertNil(check.record.turnedScore, "No frame turned far enough to be scored")

        // A bigger wobble the other way doesn't hide a turn the asked way that fell just short.
        var short = glance(.left)
        XCTAssertNil(short.observe(turned(10.2, 0.18, toward: .left)))
        XCTAssertNil(short.observe(turned(10.4, -0.19, toward: .left)))
        XCTAssertEqual(short.tick(now: 13), .timeout)
        XCTAssertEqual(short.record.yawChange ?? 0, MatchSettings.leftYawSign * 0.18, accuracy: 0.0001)
    }

    func testATurnCapturedAtTheDeadlineIsTooLate() {
        var check = glance(.left)
        XCTAssertEqual(check.observe(turned(10 + MatchSettings.glanceTimeout, 0.3, toward: .left)), .timeout)
        var inTime = glance(.left)
        XCTAssertEqual(inTime.observe(turned(10 + MatchSettings.glanceTimeout - 0.01, 0.3, toward: .left)), .passed)
    }

    func testNoFramesAtAllTimeOut() {
        var check = glance(.right)
        XCTAssertNil(check.tick(now: 11))
        XCTAssertEqual(check.tick(now: 13.5), .timeout)
        XCTAssertNil(check.record.yawChange, "No face, no angle")
    }

    func testASecondFaceFailsAtOnce() {
        var check = glance(.left)
        XCTAssertNil(check.observe(turned(10.2, 0.1, toward: .left)))
        XCTAssertEqual(check.observe(Synthetic.frame(.multipleFaces, 10.3)), .lostFace)
        XCTAssertEqual(check.observe(turned(10.4, 0.3, toward: .left)), .lostFace)
        XCTAssertEqual(check.record.timeToEnd ?? 0, 0.3, accuracy: 0.0001, "Before the timeout, so a second face")
    }

    func testNoFaceDarkOrUnusableFramesAreSkipped() {
        var check = glance(.left)
        for (index, kind) in [FaceObservation.Kind.noFace, .tooDark, .unusable].enumerated() {
            XCTAssertNil(check.observe(Synthetic.frame(kind, 10.1 + Double(index) / 10)))
        }
        XCTAssertEqual(check.observe(turned(10.5, 0.3, toward: .left)), .passed)
    }

    func testATurnedFaceBelowTheGlanceLineDoesNotPass() {
        // Turned faces score lower, so the glance has its own, lower line.
        var check = glance(.left)
        XCTAssertNil(check.observe(turned(10.2, 0.3, toward: .left, score: MatchSettings.glanceThreshold - 0.01)))
        XCTAssertEqual(check.tick(now: 13), .lostFace, "Times out saying the turned face didn't match")
        XCTAssertEqual(check.record.timeToEnd ?? 0, MatchSettings.glanceTimeout, accuracy: 0.0001)
        XCTAssertEqual(check.record.turnedScore ?? 0, MatchSettings.glanceThreshold - 0.01, accuracy: 0.001)

        var lower = glance(.left)
        XCTAssertLessThan(MatchSettings.glanceThreshold, MatchSettings.threshold)
        XCTAssertEqual(lower.observe(turned(10.2, 0.3, toward: .left, score: MatchSettings.glanceThreshold)), .passed)

        // One bad frame mid-turn is skipped, not fatal.
        var recovers = glance(.left)
        XCTAssertNil(recovers.observe(turned(10.2, 0.22, toward: .left, score: 0.2)))
        XCTAssertEqual(recovers.observe(turned(10.3, 0.28, toward: .left)), .passed)
    }

    func testTheDetectorGateAppliesToTheTurnedFace() {
        var screen = glance(.right)
        XCTAssertNil(screen.observe(turned(10.2, 0.3, toward: .right, real: MatchSettings.minimumReal - 0.01)))
        XCTAssertEqual(screen.tick(now: 13), .notReal)
        XCTAssertEqual(screen.record.turnedReal ?? 0, MatchSettings.minimumReal - 0.01, accuracy: 0.001)

        var real = glance(.right)
        XCTAssertEqual(real.observe(turned(10.2, 0.3, toward: .right, real: MatchSettings.minimumReal)), .passed)

        var noDetector = glance(.right)
        XCTAssertEqual(noDetector.observe(turned(10.2, 0.3, toward: .right)), .passed,
                       "With no detector score, the match alone decides")
    }

    func testAPrerecordedVideoTurningBothWaysFailsWhenTheWrongWayComesFirst() {
        // A clip of the owner turning right, back, then left: what someone could record and replay.
        let clip: [(TimeInterval, Double)] = [(10.1, 0), (10.3, 0.1), (10.5, 0.25), (10.7, 0.3), (10.9, 0.1),
                                              (11.1, 0), (11.3, -0.1), (11.5, -0.25), (11.7, -0.3)]
        func play(asked: GlanceCheck.Direction) -> GlanceCheck.Outcome? {
            var check = glance(asked)
            for (time, toRight) in clip {
                if let outcome = check.observe(turned(time, toRight, toward: .right)) { return outcome }
            }
            return check.tick(now: 13)
        }
        XCTAssertEqual(play(asked: .left), .wrongWay)
        // The known limit: asked the way the clip turns first, it passes. Half the tries, and each failed one is a miss.
        XCTAssertEqual(play(asked: .right), .passed)
    }

    func testFramesFromBeforeTheGlanceOrOutOfOrderAreIgnored() {
        var check = glance(.left)
        XCTAssertNil(check.observe(turned(9.9, 0.3, toward: .left)), "Captured before the bar asked")
        XCTAssertNil(check.observe(turned(10.5, 0.1, toward: .left)))
        XCTAssertNil(check.observe(turned(10.4, 0.3, toward: .left)), "Older than the last frame")
        XCTAssertNil(check.observe(turned(10.5, 0.3, toward: .left)), "The same frame again")
        XCTAssertEqual(check.observe(turned(10.6, 0.3, toward: .left)), .passed)
    }

    func testWithoutARestingAngleNothingPasses() {
        var check = glance(.left, restingYaw: nil)
        XCTAssertNil(check.observe(turned(10.2, 0.4, toward: .left)))
        XCTAssertEqual(check.tick(now: 13), .timeout)
    }

    func testStoppedGlanceHasNoOutcome() {
        var check = glance(.left)
        check.observe(turned(10.2, 0.1, toward: .left))
        XCTAssertNil(check.record.outcome)
        XCTAssertNil(check.record.timeToEnd)
        XCTAssertEqual(check.record.direction, .left)
    }

    func testTheRecordKeepsTheBestScoresOfTheTurnedFrames() {
        // For tuning: how close the turned face came to the glance line and the detector line.
        var check = glance(.right)
        XCTAssertNil(check.observe(turned(10.2, 0.1, toward: .right, score: 0.9, real: 0.99)), "Not turned enough to count")
        XCTAssertNil(check.observe(turned(10.4, 0.25, toward: .right, score: 0.3, real: 0.9)))
        XCTAssertNil(check.observe(turned(10.6, 0.3, toward: .right, score: 0.4, real: 0.5)))
        XCTAssertEqual(check.tick(now: 13), .lostFace)
        XCTAssertEqual(check.record.turnedScore ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(check.record.turnedReal ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(check.record.yawChange ?? 0, -MatchSettings.leftYawSign * 0.3, accuracy: 0.0001)
    }

    // MARK: The flatness score (watch-only)

    func testThePassingFramesFlatnessIsLoggedAndDecidesNothing() {
        // Watch-only (owner's decision 2026-10-30): a flat turn passes exactly as a real one, and both log the score.
        func passed(nose: Double) -> GlanceRecord {
            var check = glance(.left, restingPoints: Synthetic.points())
            XCTAssertNil(check.observe(turned(10.2, 0.1, toward: .left, points: Synthetic.points(shift: 5, nose: nose / 2))))
            XCTAssertEqual(check.observe(turned(10.4, 0.25, toward: .left, points: Synthetic.points(shift: 12, nose: nose))),
                           .passed)
            return check.record
        }
        XCTAssertEqual(passed(nose: 0).flatness ?? 1, 0, accuracy: 1e-9, "Every point moved together")
        XCTAssertEqual(passed(nose: 8).flatness ?? 0, 0.1, accuracy: 1e-9, "The passing frame's: 8 px of the 80 between the eyes")
    }

    func testAGlanceThatFailsLogsTheFlatnessOfTheFrameItsTurnCameFrom() {
        var wrongWay = glance(.right, restingPoints: Synthetic.points())
        XCTAssertNil(wrongWay.observe(turned(10.2, 0.1, toward: .right, points: Synthetic.points(nose: 2))))
        XCTAssertEqual(wrongWay.observe(turned(10.4, -0.25, toward: .right, points: Synthetic.points(nose: -12))), .wrongWay)
        XCTAssertEqual(wrongWay.record.flatness ?? 0, 0.15, accuracy: 1e-9)

        // A timeout: the frame turned furthest the asked way, the one its yaw change comes from.
        var short = glance(.left, restingPoints: Synthetic.points())
        XCTAssertNil(short.observe(turned(10.2, 0.1, toward: .left, points: Synthetic.points(nose: 4))))
        XCTAssertNil(short.observe(turned(10.4, 0.15, toward: .left, points: Synthetic.points(nose: 8))))
        XCTAssertNil(short.observe(turned(10.6, 0.05, toward: .left, points: Synthetic.points(nose: 16))))
        XCTAssertEqual(short.tick(now: 13), .timeout)
        XCTAssertEqual(short.record.flatness ?? 0, 0.1, accuracy: 1e-9)

        // A turned face that didn't match: still measured, for tuning on photos.
        var stranger = glance(.left, restingPoints: Synthetic.points())
        XCTAssertNil(stranger.observe(turned(10.2, 0.3, toward: .left, score: 0.1, points: Synthetic.points(shift: 9))))
        XCTAssertEqual(stranger.tick(now: 13), .lostFace)
        XCTAssertEqual(stranger.record.flatness ?? 1, 0, accuracy: 1e-9)
    }

    func testNoFlatnessWithoutRestingPointsOrATurnedFaceWithPoints() {
        var noRest = glance(.left)
        XCTAssertEqual(noRest.observe(turned(10.4, 0.25, toward: .left, points: Synthetic.points(nose: 8))), .passed)
        XCTAssertNil(noRest.record.flatness)
        var noPoints = glance(.left, restingPoints: Synthetic.points())
        XCTAssertEqual(noPoints.observe(turned(10.4, 0.25, toward: .left)), .passed)
        XCTAssertNil(noPoints.record.flatness)
        var noFace = glance(.left, restingPoints: Synthetic.points())
        XCTAssertEqual(noFace.tick(now: 13), .timeout)
        XCTAssertNil(noFace.record.flatness)
    }

    func testDirectionComesFromTheRandomSourceWithEvenOdds() {
        var first = SeededGenerator(state: 7), second = SeededGenerator(state: 7)
        let picks = (0..<200).map { _ in GlanceCheck.Direction.random(using: &first) }
        XCTAssertEqual(picks, (0..<200).map { _ in GlanceCheck.Direction.random(using: &second) }, "Same seed, same ways")
        let lefts = picks.filter { $0 == .left }.count
        XCTAssertTrue((70...130).contains(lefts), "\(lefts) of 200 were left")
        XCTAssertEqual(GlanceCheck.Direction.allCases.map(\.rawValue), ["left", "right"], "Fixed codes in the score log")
        XCTAssertEqual(abs(MatchSettings.leftYawSign), 1)
    }
}
