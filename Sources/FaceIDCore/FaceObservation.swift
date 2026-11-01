import Foundation

/// One analyzed camera frame. Holds no image data.
public struct FaceObservation: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case face, noFace, multipleFaces, tooDark, unusable }
    public let kind: Kind
    /// Capture time in seconds on the host clock.
    public let timestamp: TimeInterval
    /// Unit-length SFace embedding; present only when kind == .face.
    public let embedding: [Float]?
    /// Radians, Vision convention.
    public let yaw: Double?
    public let roll: Double?
    /// Vision face capture quality: only for ranking frames of the same person, never a pass mark.
    public let quality: Float?
    /// What the photo/screen detector said (decision L3; `MatchSettings.minimumReal` is its gate). Nil when the
    /// detector is missing or failed; only ever set when kind == .face.
    public let photoScreen: PhotoScreenScore?
    /// The eyes, nose tip and mouth corners, for the glance's flatness score; only when kind == .face.
    public let points: FacePoints?
    /// The face box the photo/screen detector cropped around, for Home Test pictures; only when kind == .face.
    public let faceBox: PhotoScreenCrop.FaceBox?

    public init(kind: Kind, timestamp: TimeInterval, embedding: [Float]? = nil, yaw: Double? = nil,
                roll: Double? = nil, quality: Float? = nil, photoScreen: PhotoScreenScore? = nil,
                points: FacePoints? = nil, faceBox: PhotoScreenCrop.FaceBox? = nil) {
        self.kind = kind
        self.timestamp = timestamp
        self.embedding = embedding
        self.yaw = yaw
        self.roll = roll
        self.quality = quality
        self.photoScreen = photoScreen
        self.points = points
        self.faceBox = faceBox
    }
}

/// The photo/screen detector's outputs for one face (docs/verification/minifasnet-model.md, step 5).
public struct PhotoScreenScore: Sendable, Equatable {
    /// The two models' mean real-face probability, 0...1.
    public let real: Float
    /// Each model's three class probabilities, index 1 real: MiniFASNetV2 on the 2.7x crop, MiniFASNetV1SE on
    /// the 4.0x crop. Upstream calls a face real when index 1 of their sum is the largest, which is not the
    /// same test as `real > 0.5`.
    public let probs27: [Float]
    public let probs40: [Float]

    public init(real: Float, probs27: [Float], probs40: [Float]) {
        self.real = real
        self.probs27 = probs27
        self.probs40 = probs40
    }
}

/// The saved face: a few separate samples, compared by best match.
public struct FaceGallery: Codable, Sendable, Equatable {
    public enum Pose: String, Codable, Sendable { case center, left, right }
    public struct Sample: Codable, Sendable, Equatable {
        public let pose: Pose
        public let embedding: [Float]
        public init(pose: Pose, embedding: [Float]) {
            self.pose = pose
            self.embedding = embedding
        }
    }
    public var samples: [Sample]
    public init(samples: [Sample]) { self.samples = samples }

    /// Highest cosine similarity between the embedding and any saved sample.
    public func bestScore(for embedding: [Float]) -> Float? {
        samples.compactMap { FaceMatch.cosine($0.embedding, embedding) }.max()
    }
}
