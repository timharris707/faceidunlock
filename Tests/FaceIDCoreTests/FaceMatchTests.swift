import CoreGraphics
import XCTest
@testable import FaceIDCore

final class FaceMatchTests: XCTestCase {
    func testEmbeddingsRequire128FiniteNonzeroValues() {
        XCTAssertNil(FaceMatch.normalized([]))
        XCTAssertNil(FaceMatch.normalized(Array(repeating: 0, count: 128)))
        XCTAssertNil(FaceMatch.normalized(Array(repeating: .nan, count: 128)))
        XCTAssertNil(FaceMatch.normalized(Array(repeating: .infinity, count: 128)))
        XCTAssertNil(FaceMatch.normalized(Array(repeating: .greatestFiniteMagnitude, count: 128)))
    }

    func testCosineIsScaleIndependentAndDistinguishesOrthogonalEmbeddings() {
        var a = Array(repeating: Float.zero, count: 128), b = a
        a[0] = 4; b[1] = 7
        XCTAssertEqual(FaceMatch.cosine(a, a), 1)
        XCTAssertEqual(FaceMatch.cosine(a, b), 0)
        XCTAssertEqual(FaceMatch.cosine(a, a.map { -$0 }), -1)
        XCTAssertEqual(FaceMatch.cosine(a, FaceMatch.centroid([a, a])!), 1)
    }

    func testCanonicalAlignmentPreservesIdentityAndRemovesRotationScaleTranslation() throws {
        let identity = try XCTUnwrap(FaceAlignment.transform(from: FaceAlignment.canonicalPoints))
        let disturbance = CGAffineTransform(a: 2.4, b: 0.3, c: -0.3, d: 2.4, tx: 70, ty: 30)
        let points = FaceAlignment.canonicalPoints.map { $0.applying(disturbance) }
        let correction = try XCTUnwrap(FaceAlignment.transform(from: points))
        for (point, target) in zip(points, FaceAlignment.canonicalPoints) {
            XCTAssertEqual(point.applying(correction).x, target.x, accuracy: 0.00001)
            XCTAssertEqual(point.applying(correction).y, target.y, accuracy: 0.00001)
            XCTAssertEqual(target.applying(identity).x, target.x, accuracy: 0.00001)
            XCTAssertEqual(target.applying(identity).y, target.y, accuracy: 0.00001)
        }
        XCTAssertEqual(FaceAlignment.canonicalPoints[0].y, 60.3037, accuracy: 0.00001)
    }

    func testAlignmentRejectsDegenerateOrMissingLandmarks() {
        XCTAssertNil(FaceAlignment.transform(from: []))
        XCTAssertNil(FaceAlignment.transform(from: Array(repeating: .zero, count: 5)))
        XCTAssertNil(FaceAlignment.transform(from: Array(repeating: CGPoint(x: CGFloat.nan, y: 0), count: 5)))
    }
}
