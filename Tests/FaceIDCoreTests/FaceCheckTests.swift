import XCTest
@testable import FaceIDCore

final class FaceCheckTests: XCTestCase {
    private let match: Float = 0.9
    private let miss: Float = 0.2

    /// A check whose warm-up ended at exactly 1.0 s: frames from 0 with exposure never settled.
    private func lookingCheck(gallery: FaceGallery = Synthetic.owner, threshold: Float = MatchSettings.threshold) -> FaceCheck {
        var check = FaceCheck(gallery: gallery, startedAt: 0, threshold: threshold)
        check.observe(Synthetic.frame(.noFace, 0), exposureSettled: false)
        XCTAssertEqual(check.observe(Synthetic.frame(.noFace, 1.0), exposureSettled: false), .looking)
        return check
    }

    // MARK: Regression tripwires

    func testColdCameraWithNoUsableFramesUntilTwoSecondsStillRecognizes() {
        // Tripwire: the old check needed a first match within 1.5 s of the camera starting.
        var check = FaceCheck(gallery: Synthetic.owner, startedAt: 0)
        for time in Synthetic.times(from: 0.05, to: 2.0) {
            let kind: FaceObservation.Kind = Int(time * 30) % 2 == 0 ? .tooDark : .noFace
            XCTAssertNotEqual(check.observe(Synthetic.frame(kind, time), exposureSettled: time > 0.8), .notRecognized)
        }
        var state = check.state
        for time in Synthetic.times(from: 2.0, to: 2.2) {
            state = check.observe(Synthetic.face(time, score: match), exposureSettled: true)
        }
        XCTAssertEqual(state, .recognized)
        XCTAssertEqual(check.record.timeToFirstMatch ?? 0, 2.0, accuracy: 0.001)
    }

    func testColdCameraWhoseFirstFrameArrivesAtTwoSecondsStillRecognizes() {
        var check = FaceCheck(gallery: Synthetic.owner, startedAt: 0)
        for now in [0.5, 1.0, 1.5, 1.9] { XCTAssertEqual(check.tick(now: now), .warmingUp) }
        for time in Synthetic.times(from: 2.0, to: 2.3) {
            XCTAssertEqual(check.observe(Synthetic.face(time, score: match), exposureSettled: true), .warmingUp)
        }
        var state = check.state
        for time in Synthetic.times(from: 2.3, to: 2.5) {
            state = check.observe(Synthetic.face(time, score: match), exposureSettled: true)
        }
        XCTAssertEqual(state, .recognized)
        XCTAssertEqual(check.record.timeToFirstFrame ?? 0, 2.0, accuracy: 0.001)
    }

    func testBelowThresholdFrameBetweenMatchesIsSkipped() {
        var check = lookingCheck()
        check.observe(Synthetic.face(1.1, score: match), exposureSettled: true)
        XCTAssertEqual(check.observe(Synthetic.face(1.2, score: miss), exposureSettled: true), .looking)
        check.observe(Synthetic.face(1.3, score: match), exposureSettled: true)
        XCTAssertEqual(check.observe(Synthetic.face(1.4, score: match), exposureSettled: true), .recognized)
        XCTAssertEqual(check.record.scores.count, 4)
    }

    func testDarkMissingOrUnusableFramesBetweenMatchesAreSkipped() {
        var check = lookingCheck()
        check.observe(Synthetic.face(1.1, score: match), exposureSettled: true)
        for (index, kind) in [FaceObservation.Kind.tooDark, .noFace, .unusable].enumerated() {
            XCTAssertEqual(check.observe(Synthetic.frame(kind, 1.15 + Double(index) * 0.05), exposureSettled: true), .looking)
        }
        check.observe(Synthetic.face(1.4, score: match), exposureSettled: true)
        XCTAssertEqual(check.observe(Synthetic.face(1.5, score: match), exposureSettled: true), .recognized)
        // The first noFace at 1.0 ended warm-up, so it is counted too.
        XCTAssertEqual(check.record.skipped, SkippedFrames(noFace: 2, multipleFaces: 0, tooDark: 1, unusable: 1))
    }

    func testSecondFaceInViewRefusesUntilThreeMatchesFollowIt() {
        // The plan: a second face in view still refuses. It is skipped, not fatal, but clears the matches so far.
        var check = lookingCheck()
        check.observe(Synthetic.face(1.1, score: match), exposureSettled: true)
        check.observe(Synthetic.face(1.2, score: match), exposureSettled: true)
        XCTAssertEqual(check.observe(Synthetic.frame(.multipleFaces, 1.25), exposureSettled: true), .looking)
        XCTAssertEqual(check.observe(Synthetic.face(1.3, score: match), exposureSettled: true), .looking)
        XCTAssertEqual(check.observe(Synthetic.face(1.4, score: match), exposureSettled: true), .looking)
        XCTAssertEqual(check.observe(Synthetic.face(1.5, score: match), exposureSettled: true), .recognized)
        XCTAssertEqual(check.record.skipped.multipleFaces, 1)
    }

    func testFacesTurnedFurtherThanSetupEverSavesAreSkipped() {
        // Tripwire: looking at another screen scored low, so a whole check of it counted as a miss.
        func turned(_ time: TimeInterval, yaw: Double, score: Float) -> FaceObservation {
            FaceObservation(kind: .face, timestamp: time, embedding: Synthetic.vector(score: score), yaw: yaw, roll: 0,
                            quality: 0.5)
        }
        var away = lookingCheck()
        for time in Synthetic.times(from: 1.1, to: 7) { away.observe(turned(time, yaw: 1.2, score: 0.25), exposureSettled: true) }
        XCTAssertEqual(away.state, .notRecognized)
        XCTAssertEqual(away.record.scores, [], "Nothing scored, so nothing to count as a miss")
        XCTAssertGreaterThan(away.record.skipped.unusable, 0)

        var matching = lookingCheck()
        for time in [1.1, 1.2, 1.3] { matching.observe(turned(time, yaw: -1.0, score: match), exposureSettled: true) }
        XCTAssertEqual(matching.state, .looking, "A face turned that far can't match either")
        for time in [1.4, 1.5, 1.6] {
            matching.observe(turned(time, yaw: MatchSettings.maximumYaw, score: match), exposureSettled: true)
        }
        XCTAssertEqual(matching.state, .recognized, "Up to the limit, frames are scored as before")
    }

    func testMatchingFramesDuringWarmUpAreIgnored() {
        var check = FaceCheck(gallery: Synthetic.owner, startedAt: 0)
        for time in [0.0, 0.1, 0.2, 0.5, 0.75, 0.875] {
            XCTAssertEqual(check.observe(Synthetic.face(time, score: match), exposureSettled: false), .warmingUp)
        }
        XCTAssertEqual(check.record.scores, [])
        XCTAssertNil(check.record.timeToFirstMatch)
        XCTAssertEqual(check.observe(Synthetic.face(1.0, score: match), exposureSettled: false), .looking)
        XCTAssertEqual(check.observe(Synthetic.face(1.1, score: match), exposureSettled: false), .looking)
        XCTAssertEqual(check.observe(Synthetic.face(1.2, score: match), exposureSettled: false), .recognized)
        XCTAssertEqual(check.record.timeToFirstMatch, 1.0)
    }

    func testOnlyNonMatchingFramesTimeOutAfterTheCheckTimeout() {
        var check = FaceCheck(gallery: Synthetic.owner, startedAt: 0)
        var state = check.state
        for time in Synthetic.times(from: 0, to: 7) {
            state = check.observe(Synthetic.face(time, score: miss), exposureSettled: true)
            if state == .notRecognized { break }
        }
        XCTAssertEqual(state, .notRecognized)
        // Warm-up ended at the frame at 0.3 s; the check gives up 5 s later.
        XCTAssertEqual(check.record.totalTime, 0.3 + MatchSettings.checkTimeout, accuracy: 0.0001)
    }

    func testTimeoutBoundaryIsExactlyCheckTimeoutAfterWarmUp() {
        var check = lookingCheck()
        XCTAssertEqual(check.tick(now: 5.999), .looking)
        XCTAssertEqual(check.tick(now: 6.0), .notRecognized)
        XCTAssertEqual(check.record.totalTime, 6.0)
    }

    func testMatchCapturedExactlyAtTheDeadlineIsTooLate() {
        var check = lookingCheck()
        check.observe(Synthetic.face(5.5, score: match), exposureSettled: true)
        check.observe(Synthetic.face(5.75, score: match), exposureSettled: true)
        XCTAssertEqual(check.observe(Synthetic.face(6.0, score: match), exposureSettled: true), .notRecognized)
    }

    func testMatchCapturedJustBeforeTheDeadlineCounts() {
        var check = lookingCheck()
        check.observe(Synthetic.face(5.5, score: match), exposureSettled: true)
        check.observe(Synthetic.face(5.75, score: match), exposureSettled: true)
        XCTAssertEqual(check.observe(Synthetic.face(5.9375, score: match), exposureSettled: true), .recognized)
    }

    func testNoFramesAtAllTimeOutFromTheStart() {
        var check = FaceCheck(gallery: Synthetic.owner, startedAt: 0)
        XCTAssertEqual(check.tick(now: 5.875), .warmingUp)
        XCTAssertEqual(check.tick(now: MatchSettings.warmUpMaximum + MatchSettings.checkTimeout), .notRecognized)
        XCTAssertNil(check.record.timeToFirstFrame)
    }

    func testThreeMatchesSpreadBeyondTheWindowDoNotPass() {
        var check = lookingCheck()
        check.observe(Synthetic.face(2.0, score: match), exposureSettled: true)
        check.observe(Synthetic.face(2.75, score: match), exposureSettled: true)
        XCTAssertEqual(check.observe(Synthetic.face(3.0625, score: match), exposureSettled: true), .looking)
        XCTAssertEqual(check.observe(Synthetic.face(3.5, score: match), exposureSettled: true), .recognized,
                       "The last three matches fall within the window.")
    }

    func testThreeMatchesWithinTheWindowPassIncludingTheEdge() {
        var check = lookingCheck()
        check.observe(Synthetic.face(2.0, score: match), exposureSettled: true)
        check.observe(Synthetic.face(2.5, score: match), exposureSettled: true)
        XCTAssertEqual(check.observe(Synthetic.face(3.0, score: match), exposureSettled: true), .recognized)
    }

    func testRepeatedTimestampsCountAsOneFrame() {
        var check = lookingCheck()
        for _ in 0..<3 { check.observe(Synthetic.face(2.0, score: match), exposureSettled: true) }
        check.observe(Synthetic.face(1.5, score: match), exposureSettled: true)
        XCTAssertEqual(check.state, .looking)
        XCTAssertEqual(check.record.scores.count, 1)
    }

    func testFramesFromBeforeTheStartAreIgnored() {
        var check = FaceCheck(gallery: Synthetic.owner, startedAt: 10)
        check.observe(Synthetic.face(9.5, score: match), exposureSettled: true)
        XCTAssertNil(check.record.timeToFirstFrame)
    }

    func testEmptyGalleryNeverRecognizes() {
        var check = lookingCheck(gallery: FaceGallery(samples: []))
        for time in Synthetic.times(from: 1.1, to: 7) { check.observe(Synthetic.face(time, score: 1), exposureSettled: true) }
        XCTAssertEqual(check.state, .notRecognized)
        XCTAssertEqual(check.record.scores, [])
        XCTAssertGreaterThan(check.record.skipped.unusable, 0)
    }

    func testScoresAgainstTheClosestSavedSample() {
        let gallery = FaceGallery(samples: [FaceGallery.Sample(pose: .center, embedding: Synthetic.axis(5)),
                                            FaceGallery.Sample(pose: .left, embedding: Synthetic.axis(0))])
        var check = lookingCheck(gallery: gallery)
        for time in [1.1, 1.2, 1.3] { check.observe(Synthetic.face(time, score: match), exposureSettled: true) }
        XCTAssertEqual(check.state, .recognized)
    }

    func testThresholdOverrideNeverGoesBelowTheMinimum() {
        XCTAssertEqual(FaceCheck(gallery: Synthetic.owner, startedAt: 0, threshold: 0.3).threshold, MatchSettings.minimumThreshold)
        XCTAssertEqual(FaceCheck(gallery: Synthetic.owner, startedAt: 0, threshold: .nan).threshold, MatchSettings.threshold)
        XCTAssertEqual(FaceCheck(gallery: Synthetic.owner, startedAt: 0, threshold: 0.6).threshold, 0.6)
        XCTAssertEqual(FaceCheck(gallery: Synthetic.owner, startedAt: 0).threshold, 0.70)

        var low = lookingCheck(threshold: 0.3)
        for time in [1.1, 1.2, 1.3] { low.observe(Synthetic.face(time, score: 0.38), exposureSettled: true) }
        XCTAssertEqual(low.state, .looking, "0.38 is below the 0.40 floor even when tuning asks for 0.30.")

        var high = lookingCheck(threshold: 0.6)
        for time in [1.1, 1.2, 1.3] { high.observe(Synthetic.face(time, score: 0.5), exposureSettled: true) }
        XCTAssertEqual(high.state, .looking)
    }

    func testHintFollowsTheMostRecentFrames() {
        var check = FaceCheck(gallery: Synthetic.owner, startedAt: 0)
        check.observe(Synthetic.frame(.noFace, 0.1), exposureSettled: false)
        XCTAssertNil(check.hint, "No hint while warming up.")
        var check2 = lookingCheck()
        XCTAssertEqual(check2.hint, .noFace)
        check2.observe(Synthetic.frame(.tooDark, 1.1), exposureSettled: true)
        XCTAssertNil(check2.hint, "No problem is in more than half of the last frames.")
        check2.observe(Synthetic.frame(.tooDark, 1.2), exposureSettled: true)
        XCTAssertEqual(check2.hint, .tooDark)
        for time in [1.3, 1.4, 1.5] { check2.observe(Synthetic.frame(.multipleFaces, time), exposureSettled: true) }
        XCTAssertEqual(check2.hint, .multipleFaces)
        for time in [1.6, 1.7, 1.8] { check2.observe(Synthetic.face(time, score: miss), exposureSettled: true) }
        XCTAssertNil(check2.hint, "Faces that don't match give no hint.")
    }

    func testRecordHoldsTimingsScoresAndCounts() {
        var check = FaceCheck(gallery: Synthetic.owner, startedAt: 100)
        check.observe(Synthetic.frame(.noFace, 100.25), exposureSettled: false)
        check.observe(Synthetic.frame(.tooDark, 100.5), exposureSettled: false)
        check.observe(Synthetic.face(100.625, score: miss), exposureSettled: true)
        check.observe(Synthetic.face(100.75, score: match), exposureSettled: true)
        check.observe(Synthetic.frame(.noFace, 100.875), exposureSettled: true)
        check.observe(Synthetic.face(101.0, score: match), exposureSettled: true)
        check.observe(Synthetic.face(101.25, score: match), exposureSettled: true)
        let record = check.record
        XCTAssertEqual(record.outcome, .recognized)
        XCTAssertEqual(record.scores.map { ($0 * 1000).rounded() }, [200, 900, 900, 900])
        XCTAssertEqual(record.skipped, SkippedFrames(noFace: 1))
        XCTAssertEqual(record.timeToFirstFrame, 0.25)
        XCTAssertEqual(record.timeToFirstMatch, 0.75)
        XCTAssertEqual(record.totalTime, 1.25)

        check.observe(Synthetic.face(101.5, score: miss), exposureSettled: true)
        check.tick(now: 120)
        XCTAssertEqual(check.record, record, "A finished check ignores later frames and ticks.")
    }

    func testPhotoScreenScoresRideAlongWithScoredFrames() {
        // The detector's value is kept for exactly the frames that got a match score.
        func run(withReal: Bool) -> (states: [FaceCheck.State], record: CheckRecord) {
            func real(_ value: Float) -> PhotoScreenScore? { withReal ? Synthetic.photoScreen(value) : nil }
            let frames: [(FaceObservation, Bool)] = [
                (Synthetic.face(0.0, score: match, photoScreen: real(0.11)), false),  // warm-up
                (Synthetic.face(0.5, score: match, photoScreen: real(0.12)), false),  // warm-up
                (Synthetic.face(1.0, score: miss, photoScreen: real(0.3)), false),
                (FaceObservation(kind: .noFace, timestamp: 1.05, photoScreen: real(0.13)), true),
                (Synthetic.face(1.1, score: match, yaw: 1.2, photoScreen: real(0.22)), true),  // turned away
                (Synthetic.face(1.15, score: match), true),  // the detector gave nothing
                (Synthetic.face(1.2, score: match, photoScreen: real(0.9)), true),
                (Synthetic.face(1.3, score: match, photoScreen: real(0.8)), true),
                (Synthetic.face(1.4, score: match, photoScreen: real(0.5)), true)  // after the check ended
            ]
            var check = FaceCheck(gallery: Synthetic.owner, startedAt: 0)
            let states = frames.map { check.observe($0.0, exposureSettled: $0.1) }
            return (states, check.record)
        }
        let watched = run(withReal: true), plain = run(withReal: false)
        XCTAssertEqual(watched.record.photoScreen, [0.3, 0.9, 0.8].map(Synthetic.photoScreen))
        XCTAssertEqual(watched.record.scores.count, 4)
        XCTAssertEqual(watched.states, plain.states, "Every matching frame here passes the detector")
        XCTAssertEqual(watched.states.last, .recognized)
        XCTAssertEqual(plain.record.photoScreen, [])
        XCTAssertEqual(watched.record.matchOnly, 1)
        XCTAssertEqual(plain.record.matchOnly, 3)
    }

    func testMatchingFramesThatLookLikeAPhotoOrScreenDoNotCount() {
        // Owner's decision 2026-10-30: the photo/screen detector is a gate at 0.60, no longer watch-only.
        var check = lookingCheck()
        for (index, real) in [Float(0.55), 0.3, 0.59].enumerated() {
            let time = 1.1 + Double(index) / 10
            XCTAssertEqual(check.observe(Synthetic.face(time, score: match, photoScreen: Synthetic.photoScreen(real)),
                                         exposureSettled: true), .looking)
        }
        XCTAssertNil(check.record.timeToFirstMatch, "Turned away, so not a match")
        check.observe(Synthetic.face(1.5, score: match, photoScreen: Synthetic.photoScreen(MatchSettings.minimumReal)),
                      exposureSettled: true)
        check.observe(Synthetic.face(1.6, score: match, photoScreen: Synthetic.photoScreen(0.97)), exposureSettled: true)
        XCTAssertEqual(check.observe(Synthetic.face(1.7, score: match, photoScreen: Synthetic.photoScreen(0.61)),
                                     exposureSettled: true), .recognized, "At the gate counts; the others are skipped, not fatal")
        let record = check.record
        XCTAssertEqual(record.skipped.photoOrScreen, 3)
        XCTAssertEqual(record.scores.count, 6, "Their match scores are still logged")
        XCTAssertEqual(record.timeToFirstMatch ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(record.matchOnly, 0)

        // A frame below the match line is a plain miss, whatever the detector said.
        var low = lookingCheck()
        low.observe(Synthetic.face(1.1, score: miss, photoScreen: Synthetic.photoScreen(0.2)), exposureSettled: true)
        XCTAssertEqual(low.record.skipped.photoOrScreen, 0)
    }

    func testWithoutTheDetectorFramesAreJudgedOnTheMatchAloneAndTheRecordSaysSo() {
        var check = lookingCheck()
        check.observe(Synthetic.face(1.1, score: miss), exposureSettled: true)
        for time in [1.2, 1.3, 1.4] { check.observe(Synthetic.face(time, score: match), exposureSettled: true) }
        XCTAssertEqual(check.state, .recognized)
        XCTAssertEqual(check.record.matchOnly, 3, "Only frames that counted toward the match")
    }

    func testTonightsHomeTestNumbersAgainstTheNewLineAndGate() {
        // Tripwire, from the owner's home test on 2026-10-30 (match, real-face score, one try each). At the old
        // 0.45 line with the detector only watching, the phone photo, both videos and the iPad all got in.
        let tries: [(String, ClosedRange<Float>, ClosedRange<Float>, FaceCheck.State)] = [
            ("owner straight", 0.82...0.84, 0.999...1.0, .recognized),
            ("owner dim", 0.81...0.82, 0.97...0.99, .recognized),
            ("owner with a lamp behind him", 0.72...0.73, 0.66...0.74, .recognized),
            ("owner looking at another monitor", 0.53...0.69, 0.99...1.0, .notRecognized),
            ("phone photo", 0.62...0.66, 0.92...0.99, .notRecognized),
            ("phone video at arm's length", 0.48...0.58, 0.99...0.99, .notRecognized),
            ("iPad video", 0.74...0.78, 0.53...0.57, .notRecognized),
            ("phone video held close", 0.29...0.38, 0.0...0.0, .notRecognized)
        ]
        for (name, matches, reals, expected) in tries {
            var check = lookingCheck()
            for step in 0..<20 {
                let mix = Float(step % 5) / 4
                let frame = Synthetic.face(1.1 + Double(step) / 30,
                                           score: matches.lowerBound + mix * (matches.upperBound - matches.lowerBound),
                                           photoScreen: Synthetic.photoScreen(reals.lowerBound + mix * (reals.upperBound - reals.lowerBound)))
                check.observe(frame, exposureSettled: true)
            }
            check.tick(now: 100)
            XCTAssertEqual(check.state, expected, name)
        }
    }

    func testRestingYawIsTheMedianOfTheFramesThatMadeTheMatch() {
        var check = lookingCheck()
        check.observe(Synthetic.face(1.05, score: match, yaw: -0.5), exposureSettled: true)
        XCTAssertNil(check.restingYaw, "Not recognized yet")
        check.observe(Synthetic.frame(.multipleFaces, 1.1), exposureSettled: true)  // clears that match
        check.observe(Synthetic.face(1.15, score: miss, yaw: 0.6), exposureSettled: true)
        check.observe(Synthetic.face(1.2, score: match, yaw: 0.31), exposureSettled: true)
        check.observe(Synthetic.face(1.3, score: match, yaw: 0.25), exposureSettled: true)
        check.observe(Synthetic.face(1.4, score: match, yaw: 0.28), exposureSettled: true)
        XCTAssertEqual(check.state, .recognized)
        XCTAssertEqual(check.restingYaw ?? 0, 0.28, accuracy: 0.0001)

        var noAngles = lookingCheck()
        for time in [1.1, 1.2, 1.3] {
            noAngles.observe(FaceObservation(kind: .face, timestamp: time, embedding: Synthetic.vector(score: match)),
                             exposureSettled: true)
        }
        XCTAssertEqual(noAngles.state, .recognized)
        XCTAssertNil(noAngles.restingYaw)
    }

    func testRestingPointsAreTheMedianOfTheFramesThatMadeTheMatch() {
        // The glance's flatness score compares the turned face with these.
        var check = lookingCheck()
        check.observe(Synthetic.face(1.05, score: miss, points: Synthetic.points(shift: 50)), exposureSettled: true)
        for (time, shift) in [(1.1, 4.0), (1.2, -2.0), (1.3, 1.0)] {
            XCTAssertNil(check.restingPoints, "Not recognized yet")
            check.observe(Synthetic.face(time, score: match, points: Synthetic.points(shift: shift)), exposureSettled: true)
        }
        XCTAssertEqual(check.state, .recognized)
        XCTAssertEqual(check.restingPoints, Synthetic.points(shift: 1), "The frame that didn't match is left out")

        var noPoints = lookingCheck()
        for time in [1.1, 1.2, 1.3] { noPoints.observe(Synthetic.face(time, score: match), exposureSettled: true) }
        XCTAssertEqual(noPoints.state, .recognized)
        XCTAssertNil(noPoints.restingPoints)
    }

    func testStoppedCheckReportsTimeSoFar() {
        var check = lookingCheck()
        check.tick(now: 2.5)
        XCTAssertEqual(check.record.outcome, .looking)
        XCTAssertEqual(check.record.totalTime, 2.5)
    }
}
