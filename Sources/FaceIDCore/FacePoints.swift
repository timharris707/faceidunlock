import Foundation

/// Five points on one face in one frame, in image pixels with the origin at the top left: the two eye centres, the
/// nose tip (the bottom of the nose crest) and the two mouth corners, each pair left to right in the image. Never
/// in the score log; saved only with Home Test pictures.
public struct FacePoints: Sendable, Equatable, Codable {
    public var leftEye, rightEye, nose, leftMouth, rightMouth: SIMD2<Double>

    /// Eyes closer than this, in pixels, are too small to measure; face alignment needs as much.
    public static let minimumEyeDistance = 15.0

    public init(leftEye: SIMD2<Double>, rightEye: SIMD2<Double>, nose: SIMD2<Double>, leftMouth: SIMD2<Double>,
                rightMouth: SIMD2<Double>) {
        (self.leftEye, self.rightEye, self.nose, self.leftMouth, self.rightMouth) = (leftEye, rightEye, nose, leftMouth,
                                                                                     rightMouth)
    }

    private var all: [SIMD2<Double>] { [leftEye, rightEye, nose, leftMouth, rightMouth] }

    public var eyeDistance: Double { Self.length(rightEye - leftEye) }

    /// Each coordinate's median over `frames`, the middle two averaged for an even count; nil for no frames.
    public static func median(_ frames: [FacePoints]) -> FacePoints? {
        guard !frames.isEmpty else { return nil }
        func middle(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
        }
        let points = (0..<5).map { index in
            SIMD2(middle(frames.map { $0.all[index].x }), middle(frames.map { $0.all[index].y }))
        }
        return FacePoints(leftEye: points[0], rightEye: points[1], nose: points[2], leftMouth: points[3],
                          rightMouth: points[4])
    }

    /// The flatness score for a head turn: fits the move from `rest` to `turned` of the eyes and mouth corners as
    /// one flat motion (a least-squares 2D affine transform), predicts the nose from it, and returns how far the
    /// real nose lands from that prediction, in the turned face's eye distances (divided by the motion's own scale),
    /// so a face brought closer or moved back during the turn scores the same. Every point of a photo, or a still
    /// picture on a screen, moves together, even tilted, so it stays near 0; a real nose sticks out of the face and
    /// moves against the rest. Nil when either frame is missing, a face is too small, or the points can't fix a
    /// motion.
    public static func flatness(rest: FacePoints?, turned: FacePoints?) -> Double? {
        guard let rest, let turned, (rest.all + turned.all).allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              rest.eyeDistance >= minimumEyeDistance, turned.eyeDistance >= minimumEyeDistance else { return nil }
        // Measured from the resting eyes' midpoint in resting eye distances, so the sums below stay well scaled.
        let origin = (rest.leftEye + rest.rightEye) / 2, scale = rest.eyeDistance
        func local(_ point: SIMD2<Double>) -> SIMD3<Double> {
            let p = (point - origin) / scale
            return SIMD3(p.x, p.y, 1)
        }
        // Normal equations: x' = a·(x, y, 1) and y' = b·(x, y, 1), over the four points that aren't the nose.
        var normal = [SIMD3<Double>](repeating: .zero, count: 3)
        var towardX = SIMD3<Double>.zero, towardY = SIMD3<Double>.zero
        for (from, to) in zip([rest.leftEye, rest.rightEye, rest.leftMouth, rest.rightMouth].map(local),
                              [turned.leftEye, turned.rightEye, turned.leftMouth, turned.rightMouth].map(local)) {
            for row in 0..<3 { normal[row] += from * from[row] }
            towardX += from * to.x
            towardY += from * to.y
        }
        guard let a = solve(normal, towardX), let b = solve(normal, towardY) else { return nil }
        let zoom = abs(a.x * b.y - a.y * b.x).squareRoot()
        guard zoom > 0.1 else { return nil }
        let nose = local(rest.nose), actual = local(turned.nose)
        return length(SIMD2(actual.x - (a * nose).sum(), actual.y - (b * nose).sum())) / zoom
    }

    /// Solves the symmetric 3x3 system `rows` · x = `value` by Cramer's rule; nil when it is (nearly) singular.
    private static func solve(_ rows: [SIMD3<Double>], _ value: SIMD3<Double>) -> SIMD3<Double>? {
        func determinant(_ c0: SIMD3<Double>, _ c1: SIMD3<Double>, _ c2: SIMD3<Double>) -> Double {
            c0.x * (c1.y * c2.z - c1.z * c2.y) - c1.x * (c0.y * c2.z - c0.z * c2.y) + c2.x * (c0.y * c1.z - c0.z * c1.y)
        }
        // Symmetric, so the rows are also the columns.
        let (c0, c1, c2) = (rows[0], rows[1], rows[2])
        let whole = determinant(c0, c1, c2)
        guard abs(whole) > 1e-9 else { return nil }
        return SIMD3(determinant(value, c1, c2), determinant(c0, value, c2), determinant(c0, c1, value)) / whole
    }

    private static func length(_ vector: SIMD2<Double>) -> Double { (vector * vector).sum().squareRoot() }
}
