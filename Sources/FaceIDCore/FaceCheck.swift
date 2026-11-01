import Foundation

/// Something the person can fix, judged from the last few frames.
public enum FaceHint: Sendable, Equatable {
    case noFace, multipleFaces, tooDark

    /// The problem seen in more than half of the recent frames, if any.
    init?(recent: [FaceObservation.Kind]) {
        let problems: [(FaceObservation.Kind, FaceHint)] = [(.noFace, .noFace), (.multipleFaces, .multipleFaces),
                                                             (.tooDark, .tooDark)]
        guard let found = problems.first(where: { kind, _ in recent.filter { $0 == kind }.count * 2 > recent.count })
        else { return nil }
        self = found.1
    }
}

/// Frames passed over because they showed no single clear face, by reason, and (`photoOrScreen`) matching faces
/// the photo/screen detector turned away.
public struct SkippedFrames: Codable, Sendable, Equatable {
    public var noFace = 0, multipleFaces = 0, tooDark = 0, unusable = 0, photoOrScreen = 0

    mutating func count(_ kind: FaceObservation.Kind) {
        switch kind {
        case .face: break
        case .noFace: noFace += 1
        case .multipleFaces: multipleFaces += 1
        case .tooDark: tooDark += 1
        case .unusable: unusable += 1
        }
    }
}

/// Numbers from one face check, for the local score log. Holds no face data.
public struct CheckRecord: Sendable, Equatable {
    public var outcome: FaceCheck.State
    /// Best score of every usable frame after warm-up, in capture order.
    public var scores: [Float]
    /// What the photo/screen detector said about those same frames, where it gave a score.
    public var photoScreen: [PhotoScreenScore] = []
    public var skipped: SkippedFrames
    /// Seconds from the check's start.
    public var timeToFirstFrame: TimeInterval?
    public var timeToFirstMatch: TimeInterval?
    public var totalTime: TimeInterval
    /// Matching frames counted on the match alone because the detector gave them no score (its model didn't load).
    public var matchOnly = 0
    /// The glance after a match, when the box asked for one; set by whoever ran it.
    public var glance: GlanceRecord?
}

/// One everyday face check. Recognized once `requiredMatches` frames score at or above the threshold
/// within `matchWindow` (inclusive) with no second face in view between them. A frame counts only if the
/// photo/screen detector, when it gave a score, rated it at least `minimumReal`. Any other frame, including a
/// face turned further than `MatchSettings.maximumYaw`, is skipped, never fatal. Gives up `checkTimeout`
/// after warm-up ends: a frame captured at that moment or later is too late.
public struct FaceCheck: Sendable {
    public enum State: Sendable, Equatable { case warmingUp, looking, recognized, notRecognized }

    public let startedAt: TimeInterval
    public let threshold: Float
    public private(set) var state = State.warmingUp
    public private(set) var hint: FaceHint?
    private let gallery: FaceGallery
    private var warmUp = CameraWarmUp()
    private var matches: [(time: TimeInterval, yaw: Double?, points: FacePoints?)] = []
    private var recent: [FaceObservation.Kind] = []
    private var scores: [Float] = []
    private var photoScreen: [PhotoScreenScore] = []
    private var skipped = SkippedFrames()
    private var matchOnly = 0
    private var lastFrameAt: TimeInterval?
    private var firstMatchAt: TimeInterval?
    private var lastSeen: TimeInterval
    private var finishedAt: TimeInterval?

    /// `threshold` is held at or above `MatchSettings.minimumThreshold`. All times share the host clock.
    public init(gallery: FaceGallery, startedAt: TimeInterval, threshold: Float = MatchSettings.threshold) {
        self.gallery = gallery
        self.startedAt = startedAt
        self.threshold = MatchSettings.clampedThreshold(threshold)
        lastSeen = startedAt
    }

    public var record: CheckRecord {
        CheckRecord(outcome: state, scores: scores, photoScreen: photoScreen, skipped: skipped,
                    timeToFirstFrame: warmUp.firstFrameAt.map { $0 - startedAt },
                    timeToFirstMatch: firstMatchAt.map { $0 - startedAt },
                    totalTime: (finishedAt ?? lastSeen) - startedAt, matchOnly: matchOnly)
    }

    /// Once recognized: the median head angle of the frames that made the match, which the glance counts from.
    /// Nil before, or when none of them had an angle.
    public var restingYaw: Double? {
        let yaws = matches.compactMap { $0.yaw }.filter(\.isFinite).sorted()
        guard state == .recognized, !yaws.isEmpty else { return nil }
        return (yaws[(yaws.count - 1) / 2] + yaws[yaws.count / 2]) / 2
    }

    /// Once recognized: the median face points of the frames that made the match, for the glance's flatness score.
    public var restingPoints: FacePoints? {
        state == .recognized ? FacePoints.median(matches.compactMap(\.points)) : nil
    }

    private var deadline: TimeInterval { warmUp.end(startedAt: startedAt) + MatchSettings.checkTimeout }

    /// Feeds one analyzed frame. Frames from before the start, out of order, or during warm-up are ignored.
    @discardableResult
    public mutating func observe(_ frame: FaceObservation, exposureSettled: Bool) -> State {
        let time = frame.timestamp
        guard finishedAt == nil, time.isFinite, time >= startedAt,
              lastFrameAt.map({ time > $0 }) ?? true else { return state }
        lastFrameAt = time
        lastSeen = max(lastSeen, time)
        let usable = warmUp.observeFrame(at: time, exposureSettled: exposureSettled)
        if time >= deadline { return finish(.notRecognized, at: deadline) }
        guard usable else { return state }
        state = .looking
        recent = Array((recent + [frame.kind]).suffix(MatchSettings.hintFrames))
        hint = FaceHint(recent: recent)
        guard frame.kind == .face else {
            skipped.count(frame.kind)
            // A second face in view refuses: the matches so far stop counting.
            if frame.kind == .multipleFaces { matches = [] }
            return state
        }
        // A face turned further than setup ever saves (looking at another screen) is skipped, not scored.
        guard let embedding = frame.embedding, abs(frame.yaw ?? 0) <= MatchSettings.maximumYaw,
              let score = gallery.bestScore(for: embedding) else {
            skipped.count(.unusable)
            return state
        }
        scores.append(score)
        if let score = frame.photoScreen { photoScreen.append(score) }
        guard score >= threshold else { return state }
        if let real = frame.photoScreen?.real {
            guard real >= MatchSettings.minimumReal else {
                skipped.photoOrScreen += 1
                return state
            }
        } else {
            matchOnly += 1
        }
        if firstMatchAt == nil { firstMatchAt = time }
        matches = matches.filter { time - $0.time <= MatchSettings.matchWindow } + [(time, frame.yaw, frame.points)]
        return matches.count >= MatchSettings.requiredMatches ? finish(.recognized, at: time) : state
    }

    /// Moves the clock on, so warm-up and the timeout still happen when no frames arrive.
    @discardableResult
    public mutating func tick(now: TimeInterval) -> State {
        guard finishedAt == nil, now.isFinite else { return state }
        lastSeen = max(lastSeen, now)
        warmUp.tick(now: now)
        if now >= deadline { return finish(.notRecognized, at: deadline) }
        if warmUp.isReady { state = .looking }
        return state
    }

    private mutating func finish(_ outcome: State, at time: TimeInterval) -> State {
        state = outcome
        finishedAt = time
        return state
    }
}
