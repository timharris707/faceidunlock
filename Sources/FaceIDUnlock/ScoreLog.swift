import FaceIDCore
import Foundation

/// The local score log (decision D4): one JSON line per face check or face setup, numbers only,
/// keeping the newest `limit` lines. Used to tune the match threshold from real scores.
struct ScoreLog: Sendable {
    static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Face ID Unlock/scores.jsonl")
    let url: URL
    let limit: Int

    init(url: URL = ScoreLog.defaultURL, limit: Int = 1000) {
        self.url = url
        self.limit = limit
    }

    func append(_ record: ScoreRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let line = String(decoding: try encoder.encode(record), as: UTF8.self)
        let existing = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let kept = (existing + [line]).suffix(limit)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (kept.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
