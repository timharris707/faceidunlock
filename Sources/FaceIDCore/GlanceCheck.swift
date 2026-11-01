import Foundation

/// Numbers from one glance, for the local score log. Holds no face data.
public struct GlanceRecord: Sendable, Equatable {
    public var direction: GlanceCheck.Direction
    /// Nil when the glance was stopped before it ended.
    public var outcome: GlanceCheck.Outcome?
    /// Radians, signed as Vision's yaw: the change from the resting angle of the frame that passed or turned the
    /// wrong way, otherwise of the frame turned furthest the asked way. Nil when no face with a head angle was seen.
    public var yawChange: Double?
    /// Seconds from asking to the frame that passed.
    public var timeToPass: TimeInterval?
    /// Seconds from asking to the end, whatever the outcome; nil when stopped. Only a second face ends a glance as
    /// `lostFace` before `glanceTimeout`.
    public var timeToEnd: TimeInterval?
    /// The best match score and the best real-face score among frames turned at least `glanceYaw` the asked way,
    /// for tuning the glance line and the detector line. Nil when there was none, or no detector score.
    public var turnedScore: Float?
    public var turnedReal: Float?
    /// The flatness score (`FacePoints.flatness`) of the frame `yawChange` comes from, against the resting points:
    /// near 0 for a flat picture. Watch-only until `MatchSettings.flatnessLine` is set. Nil without points.
    public var flatness: Double?
}

/// The random glance after a face check recognizes someone, for the boxes that need it (decision L4): the bar
/// asks them to look left or right, picked at random, while the camera keeps running. A replayed photo or video
/// can't know the way in advance. Passes on a single-face frame turned at least `glanceYaw` from the resting angle
/// the asked way within `glanceTimeout`, that still matches the saved face at `glanceThreshold` and passes the
/// photo/screen detector. A turn as far the other way first, or a second face, fails at once; smaller wobbles
/// decide nothing, and a turned frame that doesn't match or looks like a photo or screen is skipped.
public struct GlanceCheck: Sendable {
    public enum Direction: String, Codable, Sendable, CaseIterable {
        case left, right

        /// Left or right with even odds, from `generator`, so tests can fix the sequence.
        public static func random<Generator: RandomNumberGenerator>(using generator: inout Generator) -> Direction {
            Bool.random(using: &generator) ? .left : .right
        }

        public static func random() -> Direction {
            var generator = SystemRandomNumberGenerator()
            return random(using: &generator)
        }

        /// The sign of the yaw change when the head turns this way.
        var yawSign: Double { self == .left ? MatchSettings.leftYawSign : -MatchSettings.leftYawSign }
    }

    /// How a glance ended; the raw values are the score log's codes. `lostFace`: a second face came into view, or
    /// the turned face didn't match. `notReal`: the turned face matched but the photo/screen detector turned it away.
    /// A timeout after either says which.
    public enum Outcome: String, Sendable { case passed, wrongWay, timeout, lostFace, notReal }

    public let direction: Direction
    public let startedAt: TimeInterval
    public private(set) var outcome: Outcome?
    private let restingYaw: Double?
    private let restingPoints: FacePoints?
    private let gallery: FaceGallery
    private var lastFrameAt: TimeInterval?
    private var turnedAway: Outcome?
    private var yawChange: Double?
    /// The points of the frame `yawChange` comes from.
    private var turnedPoints: FacePoints?
    private var endedAt: TimeInterval?
    private var turnedScore: Float?
    private var turnedReal: Float?

    /// `restingYaw` and `restingPoints` are the face check's (`FaceCheck.restingYaw`, `.restingPoints`); without a
    /// resting angle nothing can pass, without points there is no flatness score. `startedAt` is when the bar asks,
    /// on the host clock frames use.
    public init(direction: Direction, restingYaw: Double?, restingPoints: FacePoints?, gallery: FaceGallery,
                startedAt: TimeInterval) {
        self.direction = direction
        self.restingYaw = restingYaw
        self.restingPoints = restingPoints
        self.gallery = gallery
        self.startedAt = startedAt
    }

    public var record: GlanceRecord {
        let elapsed = endedAt.map { $0 - startedAt }
        return GlanceRecord(direction: direction, outcome: outcome, yawChange: yawChange,
                            timeToPass: outcome == .passed ? elapsed : nil, timeToEnd: elapsed,
                            turnedScore: turnedScore, turnedReal: turnedReal,
                            flatness: FacePoints.flatness(rest: restingPoints, turned: turnedPoints))
    }

    private var deadline: TimeInterval { startedAt + MatchSettings.glanceTimeout }

    /// Feeds one analyzed frame. Frames from before the start or out of order are ignored; one captured at the
    /// deadline or later is too late.
    @discardableResult
    public mutating func observe(_ frame: FaceObservation) -> Outcome? {
        let time = frame.timestamp
        guard outcome == nil, time.isFinite, time >= startedAt, lastFrameAt.map({ time > $0 }) ?? true else { return outcome }
        lastFrameAt = time
        if time >= deadline { return finish(turnedAway ?? .timeout, at: deadline) }
        if frame.kind == .multipleFaces { return finish(.lostFace, at: time) }
        guard frame.kind == .face, let restingYaw, let yaw = frame.yaw, yaw.isFinite else { return outcome }
        let change = yaw - restingYaw, toward = change * direction.yawSign
        if toward > yawChange.map({ $0 * direction.yawSign }) ?? -.infinity {
            (yawChange, turnedPoints) = (change, frame.points)
        }
        if toward <= -MatchSettings.glanceYaw { return finish(.wrongWay, at: time, turn: (change, frame.points)) }
        guard toward >= MatchSettings.glanceYaw else { return outcome }
        let score = frame.embedding.flatMap { gallery.bestScore(for: $0) }, real = frame.photoScreen?.real
        if let score { turnedScore = max(turnedScore ?? score, score) }
        if let real { turnedReal = max(turnedReal ?? real, real) }
        guard let score, score >= MatchSettings.glanceThreshold else {
            turnedAway = .lostFace
            return outcome
        }
        if let real, !(real >= MatchSettings.minimumReal) {
            turnedAway = .notReal
            return outcome
        }
        return finish(.passed, at: time, turn: (change, frame.points))
    }

    /// Moves the clock on, so the timeout still happens when no frames arrive.
    @discardableResult
    public mutating func tick(now: TimeInterval) -> Outcome? {
        guard outcome == nil, now.isFinite, now >= deadline else { return outcome }
        return finish(turnedAway ?? .timeout, at: deadline)
    }

    /// `turn`: the yaw change and points of the frame that ended it, when one did.
    private mutating func finish(_ result: Outcome, at time: TimeInterval,
                                 turn: (change: Double, points: FacePoints?)? = nil) -> Outcome? {
        outcome = result
        endedAt = time
        if let turn { (yawChange, turnedPoints) = turn }
        return outcome
    }
}
