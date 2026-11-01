import Foundation
@testable import FaceIDCore

/// Synthetic unit embeddings and frames for tests. No real face data.
enum Synthetic {
    /// A unit vector along one axis. Distinct axes have cosine 0.
    static func axis(_ index: Int) -> [Float] {
        var values = [Float](repeating: 0, count: FaceMatch.dimensions)
        values[index] = 1
        return values
    }

    /// A unit vector whose cosine to `axis(base)` is `score`, padded along an orthogonal axis.
    static func vector(score: Float, base: Int = 0, other: Int = 1) -> [Float] {
        var values = [Float](repeating: 0, count: FaceMatch.dimensions)
        values[base] = score
        values[other] = (1 - score * score).squareRoot()
        return values
    }

    /// The owner's saved face for checks: one sample along axis 0.
    static let owner = FaceGallery(samples: [FaceGallery.Sample(pose: .center, embedding: axis(0))])

    /// One owner look for setup: near axis 0, each `variant` on its own noise axis (pairwise cosine about 0.9).
    static func ownerLook(_ variant: Int) -> [Float] { vector(score: 0.95, base: 0, other: 10 + variant % 100) }

    /// Someone else: near axis 1, unlike the owner (cosine about 0).
    static func strangerLook(_ variant: Int) -> [Float] { vector(score: 0.95, base: 1, other: 10 + variant % 100) }

    /// A check frame whose best score against `owner` is `score`.
    static func face(_ time: TimeInterval, score: Float, yaw: Double = 0, photoScreen: PhotoScreenScore? = nil,
                     points: FacePoints? = nil) -> FaceObservation {
        FaceObservation(kind: .face, timestamp: time, embedding: vector(score: score), yaw: yaw, roll: 0, quality: 0.5,
                        photoScreen: photoScreen, points: points)
    }

    /// Five face points with the eyes 80 px apart, moved `shift` pixels sideways as a flat picture moves, and the
    /// nose `nose` pixels further, as a real nose moves against the face in a head turn.
    static func points(shift: Double = 0, nose: Double = 0) -> FacePoints {
        FacePoints(leftEye: [600 + shift, 300], rightEye: [680 + shift, 300], nose: [640 + shift + nose, 350],
                   leftMouth: [608 + shift, 380], rightMouth: [672 + shift, 380])
    }

    /// Photo/screen detector outputs whose mean real-face probability is `real`, as the model's are.
    static func photoScreen(_ real: Float) -> PhotoScreenScore {
        PhotoScreenScore(real: real, probs27: [1 - real, real, 0], probs40: [0, real, 1 - real])
    }

    /// A setup frame with a given head angle.
    static func look(_ time: TimeInterval, yaw: Double, roll: Double = 0, quality: Float = 0.5,
                     embedding: [Float]? = nil, photoScreen: PhotoScreenScore? = nil) -> FaceObservation {
        FaceObservation(kind: .face, timestamp: time, embedding: embedding ?? ownerLook(Int(time * 30)),
                        yaw: yaw, roll: roll, quality: quality, photoScreen: photoScreen)
    }

    static func frame(_ kind: FaceObservation.Kind, _ time: TimeInterval) -> FaceObservation {
        FaceObservation(kind: kind, timestamp: time)
    }

    /// Times from `start` up to but not including `end`, at 30 frames a second.
    static func times(from start: TimeInterval, to end: TimeInterval) -> [TimeInterval] {
        var result: [TimeInterval] = []
        var index = 0
        while start + Double(index) / 30 < end {
            result.append(start + Double(index) / 30)
            index += 1
        }
        return result
    }
}
