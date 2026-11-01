import XCTest
@testable import FaceIDCore

final class ScoreRecordTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testCheckRecordBecomesRoundedNumbersAndMilliseconds() throws {
        let check = CheckRecord(outcome: .recognized, scores: [0.45678, 0.1234, 0.9996],
                                skipped: SkippedFrames(noFace: 2, tooDark: 1),
                                timeToFirstFrame: 0.2344, timeToFirstMatch: 1.5, totalTime: 1.7006)
        let record = ScoreRecord(check: check, date: date, host: "com.apple.systempreferences")
        XCTAssertEqual(record.event, .check)
        XCTAssertEqual(record.outcome, "recognized")
        XCTAssertEqual(record.scores, [0.457, 0.123, 1.0])
        XCTAssertEqual(record.skipped, SkippedFrames(noFace: 2, tooDark: 1))
        XCTAssertEqual(record.firstFrameMs, 234)
        XCTAssertEqual(record.firstMatchMs, 1500)
        XCTAssertEqual(record.totalMs, 1701)
        XCTAssertEqual(record.host, "com.apple.systempreferences")
        XCTAssertNil(record.samples)

        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertTrue(json.contains("0.457"), json)
        XCTAssertEqual(try JSONDecoder().decode(ScoreRecord.self, from: Data(json.utf8)), record)
    }

    func testCheckOutcomes() {
        func outcome(_ state: FaceCheck.State) -> String {
            ScoreRecord(check: CheckRecord(outcome: state, scores: [], skipped: SkippedFrames(), totalTime: 0),
                        date: date, host: nil).outcome
        }
        XCTAssertEqual(outcome(.notRecognized), "notRecognized")
        XCTAssertEqual(outcome(.looking), "stopped")
        XCTAssertEqual(outcome(.warmingUp), "stopped")
    }

    func testSetupRecordKeepsSampleCountsAndFailureReason() throws {
        let setup = SetupRecord(outcome: .failed(.tooDark), samples: [.center: 2, .left: 0, .right: 1],
                                scores: [1, 0.91234], skipped: SkippedFrames(tooDark: 40),
                                timeToFirstFrame: 0.1, duration: 13)
        let record = ScoreRecord(setup: setup, date: date)
        XCTAssertEqual(record.event, .setup)
        XCTAssertEqual(record.outcome, "failed: tooDark")
        XCTAssertEqual(record.scores, [1, 0.912])
        XCTAssertEqual(record.samples, ["center": 2, "left": 0, "right": 1])
        XCTAssertEqual(record.firstFrameMs, 100)
        XCTAssertNil(record.firstMatchMs)
        XCTAssertEqual(record.totalMs, 13000)
        XCTAssertNil(record.host)

        var done = setup
        done.outcome = .done
        XCTAssertEqual(ScoreRecord(setup: done, date: date).outcome, "done")
        done.outcome = .turnSlowly
        XCTAssertEqual(ScoreRecord(setup: done, date: date).outcome, "stopped")
    }

    func testFillOutcomeTravelsWithTheCheck() throws {
        let check = CheckRecord(outcome: .recognized, scores: [0.6], skipped: SkippedFrames(), totalTime: 1.2)
        var record = ScoreRecord(check: check, date: date, host: "com.apple.SecurityAgent")
        record.fill = "filled:keyboard"
        record.fillMs = 2140
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(ScoreRecord.self, from: data), record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["fill"] as? String, "filled:keyboard")
        XCTAssertEqual(object["fillMs"] as? Int, 2140)
    }

    func testScanProblemRecordHoldsOnlyItsCode() throws {
        let record = ScoreRecord(scanProblem: "unreadable", date: date)
        XCTAssertEqual(record.event, .scan)
        XCTAssertEqual(record.outcome, "failed: unreadable")
        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["date", "event", "outcome", "scores", "skipped", "totalMs"])
    }

    func testPauseRecordHoldsOnlyItsCode() throws {
        let paused = ScoreRecord(pausedFor: "misses", date: date)
        XCTAssertEqual(paused.event, .pause)
        XCTAssertEqual(paused.outcome, "paused: misses")
        XCTAssertEqual(ScoreRecord(pausedFor: nil, date: date).outcome, "resumed")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(paused)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "pause")
        XCTAssertEqual(Set(object.keys), ["date", "event", "outcome", "scores", "skipped", "totalMs"])
    }

    func testVideoEffectsTravelWithTheCheckAsBooleans() throws {
        var record = ScoreRecord(check: CheckRecord(outcome: .recognized, scores: [0.6], skipped: SkippedFrames(),
                                                    totalTime: 1), date: date, host: nil)
        record.effects = VideoEffects(portrait: true, studioLight: false, centerStage: true)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(ScoreRecord.self, from: data), record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let effects = try XCTUnwrap(object["effects"] as? [String: Bool])
        XCTAssertEqual(effects, ["portrait": true, "studioLight": false, "centerStage": true])
    }

    func testPhotoScreenScoresAreRoundedLikeScoresAndLeftOutWhenNone() throws {
        // Contract step 5: `real` and both models' class probabilities, so upstream's own verdict
        // (argmax of probs27 + probs40) and each model's vote can be worked out from the log.
        let photoScreen = [PhotoScreenScore(real: 0.03581, probs27: [0.95012, 0.03019, 0.01969],
                                            probs40: [0.90001, 0.04143, 0.05856]),
                           PhotoScreenScore(real: 0.9996, probs27: [0.0003, 0.99961, 0.00009],
                                            probs40: [0.0001, 0.99959, 0.0003])]
        let check = CheckRecord(outcome: .recognized, scores: [0.6, 0.7], photoScreen: photoScreen,
                                skipped: SkippedFrames(), totalTime: 1)
        let record = ScoreRecord(check: check, date: date, host: nil)
        XCTAssertEqual(record.realScores, [0.036, 1.0])
        XCTAssertEqual(record.probs27, [[0.95, 0.03, 0.02], [0, 1, 0]])
        XCTAssertEqual(record.probs40, [[0.9, 0.041, 0.059], [0, 1, 0]])
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(ScoreRecord.self, from: data), record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["realScores"] as? [Double], [0.036, 1.0])
        XCTAssertEqual(object["probs27"] as? [[Double]], [[0.95, 0.03, 0.02], [0, 1, 0]])
        XCTAssertEqual(object["probs40"] as? [[Double]], [[0.9, 0.041, 0.059], [0, 1, 0]])

        let setup = SetupRecord(outcome: .done, samples: [.center: 3], scores: [1, 0.9],
                                photoScreen: [PhotoScreenScore(real: 0.97849, probs27: [0.01, 0.97, 0.02],
                                                               probs40: [0.001, 0.98698, 0.01202])],
                                skipped: SkippedFrames(), duration: 6)
        let logged = ScoreRecord(setup: setup, date: date)
        XCTAssertEqual(logged.realScores, [0.978])
        XCTAssertEqual(logged.probs27, [[0.01, 0.97, 0.02]])
        XCTAssertEqual(logged.probs40, [[0.001, 0.987, 0.012]])

        let none = ScoreRecord(check: CheckRecord(outcome: .notRecognized, scores: [0.2], skipped: SkippedFrames(),
                                                  totalTime: 5), date: date, host: nil)
        XCTAssertNil(none.realScores)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(none)) as? [String: Any])
        XCTAssertTrue(plain.keys.filter { ["realScores", "probs27", "probs40"].contains($0) }.isEmpty,
                      "No detector values, no fields")
    }

    func testHomeTestRecordIsACheckWithItsKindAndWhetherItWouldHaveFilled() throws {
        let check = CheckRecord(outcome: .recognized, scores: [0.61234],
                                photoScreen: [PhotoScreenScore(real: 0.0412, probs27: [0.9, 0.05, 0.05],
                                                               probs40: [0.95, 0.0324, 0.0176])],
                                skipped: SkippedFrames(), timeToFirstFrame: 0.2, timeToFirstMatch: 1.4, totalTime: 1.6)
        let record = ScoreRecord(homeTest: check, subject: "printedPhoto", letIn: true, date: date)
        XCTAssertEqual(record.event, .homeTest)
        XCTAssertEqual(record.outcome, "recognized")
        XCTAssertEqual(record.scores, [0.612])
        XCTAssertEqual(record.realScores, [0.041])
        XCTAssertNil(record.host, "No password box was open")
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(ScoreRecord.self, from: data), record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "homeTest")
        XCTAssertEqual(object["subject"] as? String, "printedPhoto")
        XCTAssertEqual(object["letIn"] as? Bool, true)
        XCTAssertEqual(Set(object.keys), ["date", "event", "subject", "letIn", "outcome", "scores", "realScores",
                                          "probs27", "probs40", "skipped", "firstFrameMs", "firstMatchMs", "totalMs"])
        let real = ScoreRecord(check: check, date: date, host: nil)
        XCTAssertNil(real.subject)
        XCTAssertNil(real.letIn, "Real checks don't carry the Home Test fields")
    }

    func testLoggedCheckHoldsOnlyNumbersNoEmbedding() throws {
        var check = FaceCheck(gallery: Synthetic.owner, startedAt: 0)
        for time in Synthetic.times(from: 0, to: 1) {
            check.observe(Synthetic.face(time, score: 0.9, photoScreen: Synthetic.photoScreen(0.99)), exposureSettled: true)
        }
        let data = try JSONEncoder().encode(ScoreRecord(check: check.record, date: date, host: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["date", "event", "outcome", "scores", "realScores", "probs27", "probs40",
                                          "skipped", "firstFrameMs", "firstMatchMs", "totalMs"])
        XCTAssertEqual((object["scores"] as? [Double])?.count, 3)
    }

    func testDetectorGateCountAndFramesJudgedWithoutTheDetectorAreLogged() throws {
        var check = CheckRecord(outcome: .notRecognized, scores: [0.8, 0.8], skipped: SkippedFrames(photoOrScreen: 2),
                                totalTime: 5)
        let gated = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ScoreRecord(check: check, date: date, host: nil))) as? [String: Any])
        XCTAssertEqual((gated["skipped"] as? [String: Int])?["photoOrScreen"], 2)
        XCTAssertNil(gated["matchOnly"], "Absent while the detector gave every frame a score")

        check.matchOnly = 3
        let record = ScoreRecord(check: check, date: date, host: nil)
        XCTAssertEqual(record.matchOnly, 3)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(object["matchOnly"] as? Int, 3)
    }

    func testGlanceTravelsWithTheCheckAsCodesAndRoundedNumbers() throws {
        var check = CheckRecord(outcome: .recognized, scores: [0.8], skipped: SkippedFrames(), totalTime: 2)
        check.glance = GlanceRecord(direction: .left, outcome: .passed, yawChange: 0.2468, timeToPass: 0.8204,
                                    timeToEnd: 0.8204, turnedScore: 0.51234, turnedReal: 0.98765)
        let record = ScoreRecord(check: check, date: date, host: "com.apple.SecurityAgent")
        XCTAssertEqual(record.glance, ScoreRecord.Glance(asked: .left, outcome: "passed", yawChange: 0.25, passMs: 820,
                                                         endMs: 820, turnedScore: 0.512, turnedReal: 0.988))
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(ScoreRecord.self, from: data), record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let glance = try XCTUnwrap(object["glance"] as? [String: Any])
        XCTAssertEqual(glance["asked"] as? String, "left")
        XCTAssertEqual(glance["outcome"] as? String, "passed")
        XCTAssertEqual(glance["yawChange"] as? Double, 0.25)
        XCTAssertEqual(glance["passMs"] as? Int, 820)
        XCTAssertEqual(glance["endMs"] as? Int, 820)
        XCTAssertEqual(glance["turnedScore"] as? Double, 0.512)
        XCTAssertEqual(glance["turnedReal"] as? Double, 0.988)

        for (outcome, code) in [(GlanceCheck.Outcome.wrongWay, "wrongWay"), (.timeout, "timeout"), (.lostFace, "lostFace"),
                                (.notReal, "notReal")] {
            check.glance = GlanceRecord(direction: .right, outcome: outcome, yawChange: -0.234, timeToEnd: 0.3104)
            let failed = ScoreRecord(check: check, date: date, host: nil).glance
            XCTAssertEqual(failed, ScoreRecord.Glance(asked: .right, outcome: code, yawChange: -0.23, endMs: 310),
                           "Failures carry their time too")
        }
        check.glance = GlanceRecord(direction: .right)
        XCTAssertEqual(ScoreRecord(check: check, date: date, host: nil).glance,
                       ScoreRecord.Glance(asked: .right, outcome: "stopped"), "Stopped part-way, nothing measured")

        check.glance = GlanceRecord(direction: .left, outcome: .passed, yawChange: 0.3, flatness: 0.12345)
        let flatness = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ScoreRecord(check: check, date: date, host: nil))) as? [String: Any])
        XCTAssertEqual((flatness["glance"] as? [String: Any])?["flatness"] as? Double, 0.123, "Rounded to 3 decimals")
        XCTAssertNil(glance["flatness"], "Absent when there was no score")

        check.glance = nil
        let none = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ScoreRecord(check: check, date: date, host: nil))) as? [String: Any])
        XCTAssertNil(none["glance"], "No glance asked, no field")
    }
}
