import FaceIDCore
import XCTest
@testable import FaceIDUnlock

final class ScoreLogTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScoreLogTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func record(_ score: Float) -> ScoreRecord {
        var check = FaceCheck(gallery: FaceGallery(samples: []), startedAt: 0)
        check.tick(now: 100)
        var record = ScoreRecord(check: check.record, date: Date(timeIntervalSince1970: 0), host: "com.apple.SecurityAgent")
        record.scores = [score]
        return record
    }

    func testCreatesItsFolderAndWritesOneJSONLinePerRecord() throws {
        let log = ScoreLog(url: folder.appendingPathComponent("Face ID Unlock/scores.jsonl"))
        try log.append(record(0.5))
        try log.append(record(0.25))
        let text = try String(contentsOf: log.url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(text.hasSuffix("\n"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ScoreRecord.self, from: Data(lines[1].utf8)).scores, [0.25])
    }

    func testKeepsOnlyTheNewestLines() throws {
        let log = ScoreLog(url: folder.appendingPathComponent("scores.jsonl"), limit: 3)
        for score in [0.1, 0.2, 0.3, 0.4, 0.5] as [Float] { try log.append(record(score)) }
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains(#""scores":[0.3]"#), String(lines[0]))
        XCTAssertTrue(lines[2].contains(#""scores":[0.5]"#), String(lines[2]))
    }

    func testDefaultLogLivesInApplicationSupportAndKeepsAThousandLines() {
        XCTAssertTrue(ScoreLog.defaultURL.path.hasSuffix("Library/Application Support/Face ID Unlock/scores.jsonl"))
        XCTAssertEqual(ScoreLog().limit, 1000)
    }
}
