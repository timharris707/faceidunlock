import Foundation

/// Numbers from one face setup, for the local score log. Holds no face data.
public struct SetupRecord: Sendable, Equatable {
    /// `.lookAtScreen` or `.turnSlowly` here means setup was stopped before it ended.
    public var outcome: FaceSetupCollector.Instruction
    /// Samples kept per pose, before outliers are dropped.
    public var samples: [FaceGallery.Pose: Int]
    /// Each kept sample's similarity to the typical straight-ahead sample.
    public var scores: [Float]
    /// What the photo/screen detector said about those same samples, where it gave a score (decision L3:
    /// a baseline of the owner's own values, logged only).
    public var photoScreen: [PhotoScreenScore] = []
    public var skipped: SkippedFrames
    /// Seconds from the start of setup.
    public var timeToFirstFrame: TimeInterval?
    public var duration: TimeInterval
}

/// "Set up my face": a few straight-ahead samples, then a few with the head turned a little each way,
/// sides in either order. Head angles count from the person's resting angle while looking at the screen,
/// so a camera off to one side still works. Bad frames are skipped, never fatal. When `setupTimeout` passes
/// after warm-up, setup ends with what it has if there are enough straight-ahead samples, and fails otherwise.
public struct FaceSetupCollector: Sendable {
    public enum Instruction: Sendable, Equatable { case lookAtScreen, turnSlowly, done, failed(Problem) }
    /// Why setup failed: the commonest reason a frame gave no straight-ahead sample.
    /// `.turnedAway`: the camera sees the person from the side. `.unusable` also covers a face that never held still.
    public enum Problem: String, Sendable, Equatable { case noFace, multipleFaces, tooDark, turnedAway, unusable }

    private struct Candidate: Sendable {
        let embedding: [Float]
        let time: TimeInterval
        let quality: Float
        let yaw: Double
        let roll: Double
        let photoScreen: PhotoScreenScore?
    }

    private static let poses: [FaceGallery.Pose] = [.center, .left, .right]

    public let startedAt: TimeInterval
    public private(set) var instruction = Instruction.lookAtScreen
    public private(set) var hint: FaceHint?
    private var warmUp = CameraWarmUp()
    private var bins: [FaceGallery.Pose: [Candidate]] = [:]
    private var recent: [FaceObservation.Kind] = []
    private var skipped = SkippedFrames()
    /// Face frames after warm-up, those that were straight ahead, and those turned too far from the camera.
    private var faceFrames = 0
    private var centerFrames = 0
    private var turnedAwayFrames = 0
    /// The last few face frames while the straight-ahead samples are being taken, and the resting angle from them.
    private var recentLooks: [Candidate] = []
    private var restYaw: Double?
    private var lastFrameAt: TimeInterval?
    private var lastSeen: TimeInterval
    private var finishedAt: TimeInterval?

    /// All times share the host clock.
    public init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        lastSeen = startedAt
    }

    /// 0...1, for the progress ring.
    public var progress: Double {
        if instruction == .done { return 1 }
        let target = MatchSettings.samplesPerPose
        return Double(Self.poses.reduce(0) { $0 + min(count($1), target) }) / Double(Self.poses.count * target)
    }

    /// 0...1 for each pose, for the sides of the setup ring; 1 for every pose once done.
    public var poseProgress: [FaceGallery.Pose: Double] {
        let target = MatchSettings.samplesPerPose
        return Dictionary(uniqueKeysWithValues: Self.poses.map { pose in
            (pose, instruction == .done ? 1 : Double(min(count(pose), target)) / Double(target))
        })
    }

    public var record: SetupRecord {
        let medoid = centerMedoid, kept = Self.poses.flatMap { bins[$0] ?? [] }
        return SetupRecord(
            outcome: instruction,
            samples: Dictionary(uniqueKeysWithValues: Self.poses.map { ($0, count($0)) }),
            scores: medoid.map { medoid in kept.map { FaceMatch.cosine($0.embedding, medoid) ?? -1 } } ?? [],
            photoScreen: kept.compactMap(\.photoScreen),
            skipped: skipped,
            timeToFirstFrame: warmUp.firstFrameAt.map { $0 - startedAt },
            duration: (finishedAt ?? lastSeen) - startedAt)
    }

    private var deadline: TimeInterval { warmUp.end(startedAt: startedAt) + MatchSettings.setupTimeout }

    /// Feeds one analyzed frame. Frames from before the start, out of order, or during warm-up are ignored.
    @discardableResult
    public mutating func observe(_ frame: FaceObservation, exposureSettled: Bool) -> Instruction {
        let time = frame.timestamp
        guard finishedAt == nil, time.isFinite, time >= startedAt,
              lastFrameAt.map({ time > $0 }) ?? true else { return instruction }
        lastFrameAt = time
        lastSeen = max(lastSeen, time)
        let usable = warmUp.observeFrame(at: time, exposureSettled: exposureSettled)
        if time >= deadline { return timeOut() }
        guard usable else { return instruction }
        recent = Array((recent + [frame.kind]).suffix(MatchSettings.hintFrames))
        hint = FaceHint(recent: recent)
        guard frame.kind == .face else { skipped.count(frame.kind); return instruction }
        guard let embedding = frame.embedding.flatMap(FaceMatch.normalized),
              let yaw = frame.yaw, let roll = frame.roll, yaw.isFinite, roll.isFinite else {
            skipped.count(.unusable)
            return instruction
        }
        faceFrames += 1
        guard abs(yaw) <= MatchSettings.maximumYaw else { turnedAwayFrames += 1; return instruction }
        let look = Candidate(embedding: embedding, time: time, quality: frame.quality ?? 0, yaw: yaw, roll: roll,
                             photoScreen: frame.photoScreen)
        let target = MatchSettings.samplesPerPose
        var looks = [look]
        if count(.center) < target {
            recentLooks = Array((recentLooks + [look]).suffix(MatchSettings.restFrames))
            let yaws = recentLooks.map(\.yaw).sorted()
            if yaws.count == MatchSettings.restFrames, yaws[yaws.count - 1] - yaws[0] <= MatchSettings.restSpread {
                // The steady frames that first set the resting angle are placed too.
                if restYaw == nil { looks = recentLooks }
                restYaw = yaws[yaws.count / 2]
            }
        }
        guard let restYaw else { return instruction }
        guard abs(restYaw) <= MatchSettings.maximumRestYaw else { turnedAwayFrames += 1; return instruction }
        for look in looks {
            guard let pose = Self.pose(yaw: look.yaw - restYaw, roll: look.roll) else { continue }
            if pose == .center { centerFrames += 1 }
            add(look, to: pose)
        }

        if count(.center) < target {
            instruction = .lookAtScreen
        } else if count(.left) < target || count(.right) < target {
            instruction = .turnSlowly
        } else {
            instruction = .done
            finishedAt = time
        }
        return instruction
    }

    /// Moves the clock on, so the timeout still happens when no frames arrive.
    @discardableResult
    public mutating func tick(now: TimeInterval) -> Instruction {
        guard finishedAt == nil, now.isFinite else { return instruction }
        lastSeen = max(lastSeen, now)
        warmUp.tick(now: now)
        return now >= deadline ? timeOut() : instruction
    }

    /// The saved face: every sample at least `outlierCosine` similar to the typical straight-ahead sample.
    /// Nil when fewer than `samplesPerPose` straight-ahead samples remain; the person should try again.
    public func finish() -> FaceGallery? {
        guard let medoid = centerMedoid else { return nil }
        let kept = Self.poses.flatMap { pose in
            (bins[pose] ?? [])
                .filter { (FaceMatch.cosine($0.embedding, medoid) ?? -1) >= MatchSettings.outlierCosine }
                .map { FaceGallery.Sample(pose: pose, embedding: $0.embedding) }
        }
        guard kept.filter({ $0.pose == .center }).count >= MatchSettings.samplesPerPose else { return nil }
        return FaceGallery(samples: kept)
    }

    /// Which bin a head angle, measured from the resting angle, belongs in. Positive yaw is `.left`,
    /// but nothing depends on which side is which.
    static func pose(yaw: Double, roll: Double) -> FaceGallery.Pose? {
        guard abs(roll) < MatchSettings.maximumRoll else { return nil }
        if abs(yaw) < MatchSettings.centerYaw { return .center }
        guard (MatchSettings.sideYawMin...MatchSettings.sideYawMax).contains(abs(yaw)) else { return nil }
        return yaw > 0 ? .left : .right
    }

    private func count(_ pose: FaceGallery.Pose) -> Int { bins[pose]?.count ?? 0 }

    /// Keeps the best-quality samples for a pose, each at least `minimumSampleSpacing` after the others.
    private mutating func add(_ candidate: Candidate, to pose: FaceGallery.Pose) {
        var bin = bins[pose] ?? []
        guard bin.allSatisfy({ candidate.time - $0.time >= MatchSettings.minimumSampleSpacing }) else { return }
        if bin.count < MatchSettings.samplesPerPose {
            bin.append(candidate)
        } else if let worst = bin.indices.min(by: { bin[$0].quality < bin[$1].quality }),
                  bin[worst].quality < candidate.quality {
            bin[worst] = candidate
        }
        bins[pose] = bin
    }

    /// The straight-ahead sample most like the others.
    private var centerMedoid: [Float]? {
        let center = (bins[.center] ?? []).map(\.embedding)
        func total(_ sample: [Float]) -> Float { center.reduce(0) { $0 + (FaceMatch.cosine(sample, $1) ?? -1) } }
        return center.max { total($0) < total($1) }
    }

    private mutating func timeOut() -> Instruction {
        finishedAt = deadline
        instruction = count(.center) >= MatchSettings.samplesPerPose ? .done : .failed(mainProblem)
        return instruction
    }

    /// The commonest reason frames gave no straight-ahead sample; ties go to the earlier case.
    private var mainProblem: Problem {
        let offCenter = faceFrames - centerFrames - turnedAwayFrames
        let tally: [(Problem, Int)] = [(.noFace, skipped.noFace), (.multipleFaces, skipped.multipleFaces),
                                      (.tooDark, skipped.tooDark), (.turnedAway, turnedAwayFrames),
                                      (.unusable, skipped.unusable + offCenter)]
        guard let top = tally.max(by: { $0.1 < $1.1 }), top.1 > 0 else { return .noFace }
        return top.0
    }
}
