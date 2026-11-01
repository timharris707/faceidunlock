import Foundation

/// One entry in the local score log: numbers and fixed codes only, never images, embeddings, passwords
/// or text from a password box.
public struct ScoreRecord: Codable, Sendable, Equatable {
    /// `scan`: a password-box scan that failed. `pause`: face unlock paused or turned back on. `homeTest`: a
    /// check from the hidden Home Test window, with no password box and nothing filled (decision L5).
    public enum Event: String, Codable, Sendable { case check, setup, scan, pause, homeTest }

    public var date: Date
    public var event: Event
    /// "recognized", "notRecognized", "done", "failed: <reason code>", or "stopped" when ended early.
    public var outcome: String
    /// Rounded to 3 decimals.
    public var scores: [Float]
    /// The photo/screen detector's real-face scores for the same frames or samples (decision L3),
    /// and each model's class probabilities behind them (`PhotoScreenScore`), rounded to 3 decimals. All three
    /// are absent when the detector gave none.
    public var realScores: [Float]?
    public var probs27: [[Float]]?
    public var probs40: [[Float]]?
    public var skipped: SkippedFrames
    public var firstFrameMs: Int?
    /// Checks only.
    public var firstMatchMs: Int?
    public var totalMs: Int
    /// Setup only: samples kept per pose, keyed "center", "left", "right".
    public var samples: [String: Int]?
    /// Bundle identifier of the app that asked for the password; checks only.
    public var host: String?
    /// Checks that matched: how the fill went, as a fixed code such as "filled:keyboard" or "failed:clickTheBox";
    /// "+approved" when the app also approved the box itself (System Settings, Passwords' lock screen).
    public var fill: String?
    /// Checks that matched: milliseconds from first seeing the password box to the end of the fill.
    public var fillMs: Int?
    /// Checks only: which macOS video effects the camera had on.
    public var effects: VideoEffects?
    /// Home tests only: a fixed code for what was in front of the camera, such as "me" or "printedPhoto".
    public var subject: String?
    /// Home tests only: whether a real password box would have been filled.
    public var letIn: Bool?
    /// Checks only: matching frames judged on the match alone because the photo/screen detector gave them no
    /// score (its model didn't load). Absent when none.
    public var matchOnly: Int?
    /// Checks of boxes that asked for the glance, and Home Tests (decision L4).
    public var glance: Glance?

    public struct Glance: Codable, Sendable, Equatable {
        public var asked: GlanceCheck.Direction
        /// "passed", "wrongWay", "timeout", "lostFace", "notReal", or "stopped" when ended early.
        public var outcome: String
        /// Radians, signed as Vision's yaw (`GlanceRecord.yawChange`), rounded to 2 decimals.
        public var yawChange: Double?
        /// Milliseconds from asking to passing.
        public var passMs: Int?
        /// Milliseconds from asking to the end, whatever the outcome (`GlanceRecord.timeToEnd`); absent when stopped.
        public var endMs: Int?
        /// The best match and real-face scores of the frames turned the asked way (`GlanceRecord.turnedScore`),
        /// rounded to 3 decimals; absent when there were none.
        public var turnedScore: Float?
        public var turnedReal: Float?
        /// The flatness score of the turned frame (`GlanceRecord.flatness`), rounded to 3 decimals; absent without one.
        public var flatness: Double?
    }

    public init(check: CheckRecord, date: Date, host: String?) {
        self.date = date
        event = .check
        switch check.outcome {
        case .recognized: outcome = "recognized"
        case .notRecognized: outcome = "notRecognized"
        case .warmingUp, .looking: outcome = "stopped"
        }
        scores = check.scores.map(Self.rounded)
        (realScores, probs27, probs40) = Self.rounded(check.photoScreen)
        skipped = check.skipped
        firstFrameMs = check.timeToFirstFrame.map(Self.milliseconds)
        firstMatchMs = check.timeToFirstMatch.map(Self.milliseconds)
        totalMs = Self.milliseconds(check.totalTime)
        self.host = host
        matchOnly = check.matchOnly > 0 ? check.matchOnly : nil
        glance = check.glance.map {
            Glance(asked: $0.direction, outcome: $0.outcome?.rawValue ?? "stopped",
                   yawChange: $0.yawChange.map { ($0 * 100).rounded() / 100 }, passMs: $0.timeToPass.map(Self.milliseconds),
                   endMs: $0.timeToEnd.map(Self.milliseconds), turnedScore: $0.turnedScore.map(Self.rounded),
                   turnedReal: $0.turnedReal.map(Self.rounded), flatness: $0.flatness.map { ($0 * 1000).rounded() / 1000 })
        }
    }

    /// A Home Test check: the same numbers as a real check, with the fixed code for what was in front of the
    /// camera and whether a real box would have been filled. No host: no password box was open.
    public init(homeTest check: CheckRecord, subject: String, letIn: Bool, date: Date) {
        self.init(check: check, date: date, host: nil)
        event = .homeTest
        self.subject = subject
        self.letIn = letIn
    }

    public init(setup: SetupRecord, date: Date) {
        self.date = date
        event = .setup
        switch setup.outcome {
        case .done: outcome = "done"
        case .failed(let problem): outcome = "failed: \(problem.rawValue)"
        case .lookAtScreen, .turnSlowly: outcome = "stopped"
        }
        scores = setup.scores.map(Self.rounded)
        (realScores, probs27, probs40) = Self.rounded(setup.photoScreen)
        skipped = setup.skipped
        firstFrameMs = setup.timeToFirstFrame.map(Self.milliseconds)
        totalMs = Self.milliseconds(setup.duration)
        samples = Dictionary(uniqueKeysWithValues: setup.samples.map { ($0.key.rawValue, $0.value) })
    }

    /// A password-box scan that failed, by its fixed reason code.
    public init(scanProblem code: String, date: Date) {
        self.date = date
        event = .scan
        outcome = "failed: \(code)"
        scores = []
        skipped = SkippedFrames()
        totalMs = 0
    }

    /// Face unlock paused for a reason code, or turned back on when `reason` is nil.
    public init(pausedFor reason: String?, date: Date) {
        self.date = date
        event = .pause
        outcome = reason.map { "paused: \($0)" } ?? "resumed"
        scores = []
        skipped = SkippedFrames()
        totalMs = 0
    }

    static func rounded(_ score: Float) -> Float { (score * 1000).rounded() / 1000 }
    /// The detector's values as three rounded lists in frame order, or nils when there are none so the log
    /// leaves the fields out.
    static func rounded(_ scores: [PhotoScreenScore]) -> ([Float]?, [[Float]]?, [[Float]]?) {
        guard !scores.isEmpty else { return (nil, nil, nil) }
        return (scores.map { rounded($0.real) }, scores.map { $0.probs27.map(rounded) },
                scores.map { $0.probs40.map(rounded) })
    }
    static func milliseconds(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
}

/// Whether Portrait, Studio Light and Center Stage were on for the camera. Logged, never blocking.
public struct VideoEffects: Codable, Sendable, Equatable {
    public var portrait: Bool
    public var studioLight: Bool
    public var centerStage: Bool

    public init(portrait: Bool, studioLight: Bool, centerStage: Bool) {
        self.portrait = portrait
        self.studioLight = studioLight
        self.centerStage = centerStage
    }
}
