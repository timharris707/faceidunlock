import XCTest
@testable import FaceIDCore

/// The flatness score on synthetic geometry: five face points in 3D, turned and projected through a pinhole camera,
/// with noise. No real face data.
final class FacePointsTests: XCTestCase {
    /// SplitMix64, so every run draws the same noise.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    /// The five points in eye distances (about 6.3 cm), in FacePoints order: x to the image's right, y down, z toward
    /// the camera. The nose tip stands 0.35 eye distances (about 2 cm) in front of the eyes and the mouth corners 0.1,
    /// a cautious nose: a real one sticks out further.
    private static let head: [SIMD3<Double>] = [[-0.5, 0, 0], [0.5, 0, 0], [0, 0.6, 0.35], [-0.4, 1, 0.1], [0.4, 1, 0.1]]
    /// The same points printed flat.
    private static let photo = head.map { SIMD3($0.x, $0.y, 0) }

    /// A photo bent round a vertical axis, `radius` eye distances, bulging toward the camera.
    private static func bent(radius: Double) -> [SIMD3<Double>] {
        photo.map { SIMD3($0.x, $0.y, -$0.x * $0.x / (2 * radius)) }
    }

    private static func degrees(_ value: Double) -> Double { value * .pi / 180 }

    /// The points turned (roll, then pitch, then yaw, about a pivot `pivotDepth` behind the eyes), set `distance`
    /// eye distances from an 800 px pinhole camera centred on a 1280x720 frame (at 9.5, about 60 cm, the eyes are
    /// about 84 px apart), with Gaussian noise of `noise` eye distances on every coordinate.
    private func project(_ points: [SIMD3<Double>], yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
                         pivotDepth: Double = 0, distance: Double = 9.5, noise: Double = 0,
                         _ generator: inout SeededGenerator) -> FacePoints {
        let pivot = SIMD3<Double>(0, 0.5, -pivotDepth), focal = 800.0
        let pixelsPerUnit = focal / distance
        let image = points.map { point -> SIMD2<Double> in
            var p = point - pivot
            p = SIMD3(p.x * cos(roll) - p.y * sin(roll), p.x * sin(roll) + p.y * cos(roll), p.z)
            p = SIMD3(p.x, p.y * cos(pitch) - p.z * sin(pitch), p.y * sin(pitch) + p.z * cos(pitch))
            p = SIMD3(p.x * cos(yaw) + p.z * sin(yaw), p.y, -p.x * sin(yaw) + p.z * cos(yaw))
            p += pivot
            let depth = distance - p.z
            let jitter = SIMD2(gaussian(&generator), gaussian(&generator)) * noise * pixelsPerUnit
            return SIMD2(640 + focal * p.x / depth, 360 + focal * p.y / depth) + jitter
        }
        return FacePoints(leftEye: image[0], rightEye: image[1], nose: image[2], leftMouth: image[3], rightMouth: image[4])
    }

    private func gaussian(_ generator: inout SeededGenerator) -> Double {
        let u = Double.random(in: Double.ulpOfOne..<1, using: &generator), v = Double.random(in: 0..<1, using: &generator)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    /// One glance: three resting frames, their median as the rest, then the turned frame, as the app takes them.
    private func score(_ points: [SIMD3<Double>], yaw: Double, pitch: Double = 0, roll: Double = 0,
                       restPitch: Double = 0, pivotDepth: Double = 0, distance: Double = 9.5, noise: Double = 0.01,
                       _ generator: inout SeededGenerator) throws -> Double {
        let rest = (0..<3).map { _ in
            project(points, pitch: restPitch, pivotDepth: pivotDepth, distance: distance, noise: noise, &generator)
        }
        let turned = project(points, yaw: yaw, pitch: restPitch + pitch, roll: roll, pivotDepth: pivotDepth,
                             distance: distance, noise: noise, &generator)
        return try XCTUnwrap(FacePoints.flatness(rest: FacePoints.median(rest), turned: turned))
    }

    /// A real head turns about the neck, about 8 cm (1.3 eye distances) behind the eyes.
    private func headScore(yaw: Double, noise: Double = 0.01, _ generator: inout SeededGenerator) throws -> Double {
        try score(Self.head, yaw: yaw, pivotDepth: 1.3, noise: noise, &generator)
    }

    /// The flat attacks: a photo turned, tilted back and rolled as well, shown half size on a phone held closer,
    /// held tilted back throughout, or bent.
    private func flatScores(yaw: Double, noise: Double = 0.01, _ generator: inout SeededGenerator) throws -> [Double] {
        [try score(Self.photo, yaw: yaw, noise: noise, &generator),
         try score(Self.photo, yaw: yaw, pitch: Self.degrees(15), roll: Self.degrees(10), noise: noise, &generator),
         try score(Self.photo.map { $0 * 0.5 }, yaw: yaw, distance: 4, noise: noise, &generator),
         try score(Self.photo, yaw: yaw, restPitch: Self.degrees(20), noise: noise, &generator),
         try score(Self.bent(radius: 3), yaw: yaw, noise: noise, &generator),
         try score(Self.bent(radius: -3), yaw: yaw, noise: noise, &generator)]
    }

    func testWithoutNoiseAPhotoStaysNearZeroAndARealHeadDoesNot() throws {
        // Measured 2026-10-30: head 0.063 at 10° to 0.160 at 25°; every flat picture 0.002-0.010, except the photo
        // bent toward the camera, 0.009 at 10° to 0.023 at 25° (a bend puts its middle, the nose, in front).
        var generator = SeededGenerator(state: 1)
        for yaw in [10.0, 15, 20, 25].map(Self.degrees) {
            for sign in [1.0, -1] {
                let head = try headScore(yaw: sign * yaw, noise: 0, &generator)
                let flat = try flatScores(yaw: sign * yaw, noise: 0, &generator)
                XCTAssertGreaterThan(head, 0.06, "yaw \(sign * yaw)")
                XCTAssertLessThan(flat.max() ?? 1, 0.025, "Perspective and a slight bend leave only a little: \(flat)")
                XCTAssertGreaterThan(head, 6 * (flat.max() ?? 1), "yaw \(sign * yaw)")
            }
        }
        // Held still, even a real head scores nothing: the score measures movement.
        XCTAssertLessThan(try headScore(yaw: 0, noise: 0, &generator), 1e-9)
    }

    func testWithNoiseARealHeadTurnScoresClearlyAboveAnyFlatPicture() throws {
        // Noise of 1% of the eye distance on every point of every frame; 40 tries per turn, each against all six
        // flat pictures. Measured 2026-10-30 (head median / 10th percentile, flat median / 90th / highest):
        // 10°: 0.066 / 0.046, 0.018 / 0.035 / 0.079. 15°: 0.098 / 0.086, 0.019 / 0.037 / 0.086.
        // 20°: 0.127 / 0.113, 0.020 / 0.041 / 0.097. 25°: 0.160 / 0.151, 0.022 / 0.047 / 0.073.
        var generator = SeededGenerator(state: 2024)
        for degrees in [10.0, 15, 20, 25] {
            var heads: [Double] = [], flats: [Double] = []
            for trial in 0..<40 {
                let yaw = Self.degrees(degrees) * (trial.isMultiple(of: 2) ? 1 : -1)
                heads.append(try headScore(yaw: yaw, &generator))
                flats += try flatScores(yaw: yaw, &generator)
            }
            heads.sort()
            flats.sort()
            XCTAssertGreaterThan(heads[heads.count / 2], 3 * flats[flats.count / 2], "\(degrees)°: medians")
            XCTAssertGreaterThan(heads[heads.count / 10], flats[flats.count * 9 / 10],
                                 "\(degrees)°: the head's 10th percentile is above the flat pictures' 90th")
            if degrees >= 25 { XCTAssertGreaterThan(heads[0], flats.last!, "\(degrees)°: every head above every picture") }
        }
    }

    func testTheScoreIgnoresWhereTheFaceIsAndHowBigItLooks() throws {
        var generator = SeededGenerator(state: 3)
        let rest = project(Self.head, pivotDepth: 1.3, noise: 0, &generator)
        let turned = project(Self.head, yaw: Self.degrees(20), pivotDepth: 1.3, noise: 0, &generator)
        let base = try XCTUnwrap(FacePoints.flatness(rest: rest, turned: turned))
        func moved(_ points: FacePoints, by offset: SIMD2<Double>, times scale: Double) -> FacePoints {
            FacePoints(leftEye: points.leftEye * scale + offset, rightEye: points.rightEye * scale + offset,
                       nose: points.nose * scale + offset, leftMouth: points.leftMouth * scale + offset,
                       rightMouth: points.rightMouth * scale + offset)
        }
        let elsewhere = try XCTUnwrap(FacePoints.flatness(rest: moved(rest, by: [-300, 120], times: 2),
                                                          turned: moved(turned, by: [-300, 120], times: 2)))
        XCTAssertEqual(elsewhere, base, accuracy: 1e-9, "Another frame size or position gives the same score")
    }

    func testAFaceBroughtCloserOrMovedBackDuringTheTurnScoresAsIfItHadnt() throws {
        // A photo held still while the face check matches, then brought twice as close as it turns, must not score
        // like a real head; nor may a real head that leans back during the turn lose its score.
        var generator = SeededGenerator(state: 5)
        func zoomed(_ points: FacePoints, _ scale: Double) -> FacePoints {
            let centre = SIMD2<Double>(640, 360)
            func zoom(_ point: SIMD2<Double>) -> SIMD2<Double> { centre + (point - centre) * scale }
            return FacePoints(leftEye: zoom(points.leftEye), rightEye: zoom(points.rightEye), nose: zoom(points.nose),
                              leftMouth: zoom(points.leftMouth), rightMouth: zoom(points.rightMouth))
        }
        for (points, pivotDepth, scale) in [(Self.photo, 0.0, 2.0), (Self.head, 1.3, 0.77)] {
            let rest = project(points, pivotDepth: pivotDepth, noise: 0, &generator)
            let turned = project(points, yaw: Self.degrees(15), pivotDepth: pivotDepth, noise: 0, &generator)
            let still = try XCTUnwrap(FacePoints.flatness(rest: rest, turned: turned))
            let moved = try XCTUnwrap(FacePoints.flatness(rest: rest, turned: zoomed(turned, scale)))
            XCTAssertEqual(moved, still, accuracy: 1e-3, "\(scale) times the size in the turned frame")
        }
    }

    func testMissingPointsATinyFaceOrPointsInALineGiveNoScore() {
        var generator = SeededGenerator(state: 4)
        let face = project(Self.head, noise: 0, &generator)
        XCTAssertNotNil(FacePoints.flatness(rest: face, turned: face))
        XCTAssertNil(FacePoints.flatness(rest: nil, turned: face))
        XCTAssertNil(FacePoints.flatness(rest: face, turned: nil))
        // Far away: eyes 10 px apart.
        let tiny = project(Self.head, distance: 80, noise: 0, &generator)
        XCTAssertLessThan(tiny.eyeDistance, FacePoints.minimumEyeDistance)
        XCTAssertNil(FacePoints.flatness(rest: tiny, turned: tiny))
        XCTAssertNil(FacePoints.flatness(rest: face, turned: tiny), "A face that collapses in the turned frame")
        var line = face
        (line.leftMouth, line.rightMouth) = ([600, 360], [680, 360])
        (line.leftEye, line.rightEye) = ([560, 360], [720, 360])
        XCTAssertNil(FacePoints.flatness(rest: line, turned: face), "Four points in a line fix no transform")
        var broken = face
        broken.nose.x = .nan
        XCTAssertNil(FacePoints.flatness(rest: face, turned: broken))
    }

    func testMedianTakesEachCoordinatesMiddleValue() throws {
        func points(_ value: Double) -> FacePoints {
            FacePoints(leftEye: [value, 1], rightEye: [value + 60, 1], nose: [value + 30, 40], leftMouth: [value + 5, 80],
                       rightMouth: [value + 55, 80 + value])
        }
        XCTAssertNil(FacePoints.median([]))
        XCTAssertEqual(FacePoints.median([points(3), points(1), points(10)]), points(3))
        let even = try XCTUnwrap(FacePoints.median([points(1), points(3), points(10), points(20)]))
        XCTAssertEqual(even.leftEye, [6.5, 1])
        XCTAssertEqual(even.rightMouth, [61.5, 86.5])
    }
}
