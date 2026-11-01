import XCTest
@testable import FaceIDCore

final class FaceSetupCollectorTests: XCTestCase {
    /// Head yaw in a realistic setup: look for 1 s, turn one way and back over 2 s, then the other way and back.
    private func realisticYaw(_ time: TimeInterval, firstSide: Double) -> Double {
        switch time {
        case ..<1.0: return 0.02 * sin(time * 7)
        case ..<3.0: return firstSide * 0.35 * sin((time - 1.0) / 2.0 * .pi)
        case ..<5.0: return -firstSide * 0.35 * sin((time - 3.0) / 2.0 * .pi)
        default: return 0
        }
    }

    /// Feeds frames and returns the instructions seen, without repeats.
    @discardableResult
    private func feed(_ setup: inout FaceSetupCollector, _ frames: [FaceObservation],
                      settledFrom: TimeInterval = 0.3) -> [FaceSetupCollector.Instruction] {
        var seen = [setup.instruction]
        for frame in frames {
            let instruction = setup.observe(frame, exposureSettled: frame.timestamp >= settledFrom)
            if instruction != seen.last { seen.append(instruction) }
        }
        return seen
    }

    private func poses(_ gallery: FaceGallery?) -> [FaceGallery.Pose: Int] {
        Dictionary(grouping: gallery?.samples ?? [], by: \.pose).mapValues(\.count)
    }

    private func normalized(_ embedding: [Float]) -> [Float] { FaceMatch.normalized(embedding)! }

    func testRealisticSetupCompletesWithSidesInEitherOrder() {
        for firstSide in [1.0, -1.0] {
            var setup = FaceSetupCollector(startedAt: 0)
            let frames = Synthetic.times(from: 0, to: 6).map { time in
                Synthetic.look(time, yaw: realisticYaw(time, firstSide: firstSide), roll: 0.05,
                               quality: Float(0.5 + 0.2 * sin(time * 13)))
            }
            XCTAssertEqual(feed(&setup, frames, settledFrom: 0.4), [.lookAtScreen, .turnSlowly, .done])
            XCTAssertEqual(setup.progress, 1)
            XCTAssertLessThan(setup.record.duration, 5, "Setup should end during the second turn.")
            XCTAssertEqual(poses(setup.finish()), [.center: 3, .left: 3, .right: 3])
        }
    }

    func testBadFramesInterleavedThroughSetupAreSkipped() {
        var setup = FaceSetupCollector(startedAt: 0)
        let badKinds: [FaceObservation.Kind] = [.noFace, .tooDark, .multipleFaces, .unusable]
        let frames = Synthetic.times(from: 0, to: 8).enumerated().map { index, time in
            index % 3 == 2 ? Synthetic.frame(badKinds[index / 3 % 4], time)
                           : Synthetic.look(time, yaw: realisticYaw(time, firstSide: 1))
        }
        XCTAssertEqual(feed(&setup, frames).last, .done)
        XCTAssertEqual(poses(setup.finish()), [.center: 3, .left: 3, .right: 3])
        let skipped = setup.record.skipped
        XCTAssertGreaterThan(skipped.noFace, 0)
        XCTAssertGreaterThan(skipped.tooDark, 0)
        XCTAssertGreaterThan(skipped.multipleFaces, 0)
        XCTAssertGreaterThan(skipped.unusable, 0)
    }

    func testTimeoutFinishesWithStraightAheadSamplesOnly() {
        var setup = FaceSetupCollector(startedAt: 0)
        let frames = Synthetic.times(from: 0, to: 14).map { Synthetic.look($0, yaw: 0) }
        XCTAssertEqual(feed(&setup, frames), [.lookAtScreen, .turnSlowly, .done])
        // Warm-up ended with the frame at 0.3 s; setup ends 12 s later.
        XCTAssertEqual(setup.record.duration, 0.3 + MatchSettings.setupTimeout, accuracy: 0.0001)
        XCTAssertEqual(poses(setup.finish()), [.center: 3])
        XCTAssertEqual(setup.progress, 1)
    }

    func testClockAloneEndsSetupWhenFramesStop() {
        var setup = FaceSetupCollector(startedAt: 0)
        feed(&setup, Synthetic.times(from: 0, to: 1).map { Synthetic.look($0, yaw: 0) })
        XCTAssertEqual(setup.tick(now: 12.29), .turnSlowly)
        XCTAssertEqual(setup.tick(now: 0.3 + MatchSettings.setupTimeout), .done)
    }

    func testNoStraightAheadSamplesFailWithTheCommonestProblem() {
        var dark = FaceSetupCollector(startedAt: 0)
        feed(&dark, Synthetic.times(from: 0, to: 14).map { Synthetic.frame(.tooDark, $0) })
        XCTAssertEqual(dark.instruction, .failed(.tooDark))
        XCTAssertNil(dark.finish())

        var crowded = FaceSetupCollector(startedAt: 0)
        feed(&crowded, Synthetic.times(from: 0, to: 14).enumerated().map { index, time in
            Synthetic.frame(index % 3 == 0 ? .noFace : .multipleFaces, time)
        })
        XCTAssertEqual(crowded.instruction, .failed(.multipleFaces))

        var restless = FaceSetupCollector(startedAt: 0)
        let restlessFrames = Synthetic.times(from: 0, to: 14).enumerated().map { index, time in
            Synthetic.look(time, yaw: index % 2 == 0 ? 0.3 : -0.3)
        }
        XCTAssertEqual(feed(&restless, restlessFrames), [.lookAtScreen, .failed(.unusable)],
                       "A face that never holds still has no resting angle, so it cannot finish.")

        var empty = FaceSetupCollector(startedAt: 0)
        XCTAssertEqual(empty.tick(now: 12.9), .lookAtScreen)
        XCTAssertEqual(empty.tick(now: MatchSettings.warmUpMaximum + MatchSettings.setupTimeout), .failed(.noFace))
    }

    func testTooFewStraightAheadSamplesAtTimeoutFail() {
        var setup = FaceSetupCollector(startedAt: 0)
        setup.observe(Synthetic.frame(.noFace, 0), exposureSettled: true)
        setup.observe(Synthetic.look(0.3, yaw: 0), exposureSettled: true)
        setup.observe(Synthetic.look(0.5, yaw: 0), exposureSettled: true)
        setup.observe(Synthetic.look(0.55, yaw: 0), exposureSettled: true)
        for time in Synthetic.times(from: 0.6, to: 14) { setup.observe(Synthetic.frame(.noFace, time), exposureSettled: true) }
        XCTAssertEqual(setup.instruction, .failed(.noFace))
        XCTAssertEqual(setup.record.samples[.center], 2)
    }

    func testOutlierSideSampleIsDropped() {
        var setup = FaceSetupCollector(startedAt: 0)
        let stranger = Synthetic.strangerLook(50)
        let frames = [
            Synthetic.frame(.noFace, 0),
            Synthetic.look(0.3, yaw: 0, embedding: Synthetic.ownerLook(1)),
            Synthetic.look(0.45, yaw: 0.02, embedding: Synthetic.ownerLook(2)),
            Synthetic.look(0.6, yaw: -0.02, embedding: Synthetic.ownerLook(3)),
            Synthetic.look(1.0, yaw: 0.2, embedding: Synthetic.ownerLook(4)),
            Synthetic.look(1.15, yaw: 0.25, quality: 0.9, embedding: stranger),
            Synthetic.look(1.3, yaw: 0.2, embedding: Synthetic.ownerLook(5)),
            Synthetic.look(2.0, yaw: -0.2, embedding: Synthetic.ownerLook(6)),
            Synthetic.look(2.15, yaw: -0.25, embedding: Synthetic.ownerLook(7)),
            Synthetic.look(2.3, yaw: -0.2, embedding: Synthetic.ownerLook(8))
        ]
        XCTAssertEqual(feed(&setup, frames).last, .done)
        let gallery = setup.finish()
        XCTAssertEqual(poses(gallery), [.center: 3, .left: 2, .right: 3])
        XCTAssertFalse(gallery?.samples.contains { $0.embedding == normalized(stranger) } ?? true)
        XCTAssertEqual(setup.record.samples, [.center: 3, .left: 3, .right: 3], "The record counts samples before outliers go.")
        XCTAssertEqual(setup.record.scores.filter { $0 < MatchSettings.outlierCosine }.count, 1)
    }

    func testOutlierAmongStraightAheadSamplesLeavesTooFewToSave() {
        var setup = FaceSetupCollector(startedAt: 0)
        let frames = [
            Synthetic.frame(.noFace, 0),
            Synthetic.look(0.3, yaw: 0, embedding: Synthetic.ownerLook(1)),
            Synthetic.look(0.45, yaw: 0, embedding: Synthetic.strangerLook(2)),
            Synthetic.look(0.6, yaw: 0, embedding: Synthetic.ownerLook(3))
        ] + [1.0, 1.15, 1.3].map { Synthetic.look($0, yaw: 0.2) } + [2.0, 2.15, 2.3].map { Synthetic.look($0, yaw: -0.2) }
        XCTAssertEqual(feed(&setup, frames).last, .done)
        XCTAssertNil(setup.finish())
    }

    func testWarmUpFramesGiveNoSamples() {
        var setup = FaceSetupCollector(startedAt: 0)
        for time in [0, 0.25, 0.5, 0.75] { setup.observe(Synthetic.look(time, yaw: 0), exposureSettled: false) }
        XCTAssertEqual(setup.progress, 0)
        XCTAssertNil(setup.hint)
        setup.observe(Synthetic.look(1.0, yaw: 0), exposureSettled: false)
        setup.observe(Synthetic.look(1.03, yaw: 0), exposureSettled: false)
        XCTAssertEqual(setup.progress, 0, "The resting angle needs a few steady frames first.")
        setup.observe(Synthetic.look(1.06, yaw: 0), exposureSettled: false)
        XCTAssertEqual(setup.progress, 1.0 / 9, accuracy: 0.0001, "The steady frames that set it are used too.")
    }

    func testSamplesAreSpacedAndTheBestQualityIsKept() {
        var setup = FaceSetupCollector(startedAt: 0)
        setup.observe(Synthetic.frame(.noFace, 0), exposureSettled: true)
        let frames: [(TimeInterval, Float, Int)] = [(0.3, 0.2, 1), (0.35, 0.9, 2), (0.45, 0.3, 3), (0.6, 0.4, 4),
                                                    (0.75, 0.8, 5), (0.8, 0.95, 6)]
        for (time, quality, variant) in frames {
            setup.observe(Synthetic.look(time, yaw: 0, quality: quality, embedding: Synthetic.ownerLook(variant)),
                          exposureSettled: true)
        }
        let center = Set((setup.finish()?.samples ?? []).map(\.embedding))
        XCTAssertEqual(center, Set([3, 4, 5].map { normalized(Synthetic.ownerLook($0)) }),
                       "Too-close frames are skipped and the lowest quality is replaced.")
    }

    func testOffAxisCameraCompletesFromTheRestingAngle() {
        // Tripwire: the camera sits off to one side, so the person's resting head angle is about 0.25 rad
        // (14 degrees), with jitter of about 0.05. Absolute bins put every resting frame in a side bin and
        // setup failed after 12 s.
        for firstSide in [1.0, -1.0] {
            var setup = FaceSetupCollector(startedAt: 0)
            let frames = Synthetic.times(from: 0, to: 6).map { time in
                Synthetic.look(time, yaw: 0.25 + 0.05 * sin(time * 11) + realisticYaw(time, firstSide: firstSide))
            }
            XCTAssertEqual(feed(&setup, frames), [.lookAtScreen, .turnSlowly, .done])
            XCTAssertLessThan(setup.record.duration, 5)
            XCTAssertEqual(poses(setup.finish()), [.center: 3, .left: 3, .right: 3])
        }
    }

    func testFaceHeldAtOneAngleIsItsRestingAngle() {
        var setup = FaceSetupCollector(startedAt: 0)
        let frames = Synthetic.times(from: 0, to: 14).enumerated().map { index, time in
            index % 4 == 0 ? Synthetic.frame(.noFace, time) : Synthetic.look(time, yaw: 0.3)
        }
        XCTAssertEqual(feed(&setup, frames), [.lookAtScreen, .turnSlowly, .done],
                       "Without turning, setup still ends with the straight-ahead samples.")
        XCTAssertEqual(poses(setup.finish()), [.center: 3])
        XCTAssertEqual(setup.poseProgress, [.center: 1, .left: 1, .right: 1], "Done fills the whole ring.")
    }

    func testCameraFarToTheSideFailsAsTurnedAway() {
        var setup = FaceSetupCollector(startedAt: 0)
        let frames = Synthetic.times(from: 0, to: 14).map { Synthetic.look($0, yaw: 0.6 + 0.02 * sin($0 * 7)) }
        XCTAssertEqual(feed(&setup, frames), [.lookAtScreen, .failed(.turnedAway)])
        XCTAssertNil(setup.finish())
    }

    func testPoseBins() {
        let cases: [(Double, Double, FaceGallery.Pose?)] = [
            (0, 0, .center), (0.099, 0, .center), (-0.099, 0.3, .center), (0.10, 0, nil), (0.12, 0, nil),
            (0.15, 0, .left), (0.45, 0, .left), (0.46, 0, nil), (-0.15, 0, .right), (-0.45, 0, .right),
            (0, 0.35, nil), (0.2, -0.36, nil)
        ]
        for (yaw, roll, expected) in cases {
            XCTAssertEqual(FaceSetupCollector.pose(yaw: yaw, roll: roll), expected, "yaw \(yaw), roll \(roll)")
        }
    }

    func testProgressHintAndRecord() {
        var setup = FaceSetupCollector(startedAt: 10)
        XCTAssertEqual(setup.progress, 0)
        setup.observe(Synthetic.frame(.tooDark, 10.5), exposureSettled: false)
        setup.observe(Synthetic.frame(.tooDark, 10.875), exposureSettled: true)
        XCTAssertEqual(setup.hint, .tooDark)
        setup.observe(FaceObservation(kind: .face, timestamp: 11, embedding: Synthetic.ownerLook(1)), exposureSettled: true)
        for time in [11.25, 11.5, 11.75] { setup.observe(Synthetic.look(time, yaw: 0), exposureSettled: true) }
        XCTAssertNil(setup.hint)
        XCTAssertEqual(setup.instruction, .turnSlowly)
        XCTAssertEqual(setup.progress, 3.0 / 9, accuracy: 0.0001)
        setup.observe(Synthetic.look(12, yaw: 0.3), exposureSettled: true)
        XCTAssertEqual(setup.progress, 4.0 / 9, accuracy: 0.0001)
        XCTAssertEqual(setup.poseProgress, [.center: 1, .left: 1.0 / 3, .right: 0])

        let record = setup.record
        XCTAssertEqual(record.outcome, .turnSlowly)
        XCTAssertEqual(record.samples, [.center: 3, .left: 1, .right: 0])
        XCTAssertEqual(record.skipped, SkippedFrames(tooDark: 1, unusable: 1), "A face with no angle is unusable.")
        XCTAssertEqual(record.timeToFirstFrame, 0.5)
        XCTAssertEqual(record.duration, 2)
        XCTAssertEqual(record.scores.count, 4)
    }

    func testPhotoScreenScoresOfKeptSamplesAreRecordedAndChangeNothing() {
        // Decision L3, watch-only: a baseline of the owner's own values, one per kept sample.
        func run(_ real: @escaping (TimeInterval) -> PhotoScreenScore?) -> (gallery: FaceGallery?, record: SetupRecord) {
            var setup = FaceSetupCollector(startedAt: 0)
            feed(&setup, Synthetic.times(from: 0, to: 6).map {
                Synthetic.look($0, yaw: realisticYaw($0, firstSide: 1), photoScreen: real($0))
            })
            return (setup.finish(), setup.record)
        }
        let watched = run { Synthetic.photoScreen(0.5 + Float($0) / 100) }, plain = run { _ in nil }
        XCTAssertEqual(watched.record.photoScreen.count, 9)
        XCTAssertEqual(watched.record.photoScreen.count, watched.record.scores.count)
        XCTAssertTrue(watched.record.photoScreen.allSatisfy { (0.5..<0.56).contains($0.real) })
        XCTAssertEqual(plain.record.photoScreen, [])
        XCTAssertEqual(watched.gallery, plain.gallery)
        var stripped = watched.record
        stripped.photoScreen = []
        XCTAssertEqual(stripped, plain.record)
    }

    func testFinishedSetupIgnoresLaterFrames() {
        var setup = FaceSetupCollector(startedAt: 0)
        feed(&setup, Synthetic.times(from: 0, to: 6).map { Synthetic.look($0, yaw: realisticYaw($0, firstSide: 1)) })
        let record = setup.record
        setup.observe(Synthetic.frame(.noFace, 7), exposureSettled: true)
        setup.tick(now: 30)
        XCTAssertEqual(setup.record, record)
        XCTAssertEqual(setup.instruction, .done)
    }
}
