import CoreVideo
import FaceIDCore
import Vision
import XCTest
@testable import FaceIDUnlock

final class FaceEngineTests: XCTestCase {
    /// A 64x48 BGRA frame of one gray level, optionally with a patch of another level (pixel rows run top-down).
    private func buffer(gray: UInt8, patch: (columns: Range<Int>, rows: Range<Int>, gray: UInt8)? = nil) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<48 {
            for column in 0..<64 {
                let inPatch = patch.map { $0.columns.contains(column) && $0.rows.contains(row) } ?? false
                let level = inPatch ? patch!.gray : gray
                let pixel = base + row * rowBytes + column * 4
                (pixel[0], pixel[1], pixel[2], pixel[3]) = (level, level, level, 255)
            }
        }
        return buffer
    }

    private func frame(_ buffer: CVPixelBuffer) -> CameraFrame {
        CameraFrame(pixelBuffer: buffer, timestamp: 42, generation: UUID())
    }

    /// An engine whose Vision step returns the given faces for every request and never loads the model.
    private func engine(_ faces: [VNFaceObservation]) -> FaceEngine {
        FaceEngine(modelURL: URL(fileURLWithPath: "/nonexistent/SFace.mlmodelc"), perform: { _, _ in faces })
    }

    private let centered = CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5)

    func testLumaReadsOnlyTheFaceBoxWithVisionsBottomLeftOrigin() throws {
        // Dark patch in the top-left quarter of the image.
        let image = try buffer(gray: 200, patch: (0..<32, 0..<24, 10))
        let topLeft = try XCTUnwrap(FaceEngine.meanLuma(of: image, in: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)))
        let bottomRight = try XCTUnwrap(FaceEngine.meanLuma(of: image, in: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)))
        XCTAssertEqual(topLeft, 10, accuracy: 0.5)
        XCTAssertEqual(bottomRight, 200, accuracy: 0.5)
    }

    func testLumaClipsABoxThatLeavesTheImage() throws {
        let image = try buffer(gray: 120)
        XCTAssertEqual(try XCTUnwrap(FaceEngine.meanLuma(of: image, in: CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5))), 120, accuracy: 0.5)
        XCTAssertNil(FaceEngine.meanLuma(of: image, in: CGRect(x: 1.2, y: 0, width: 0.2, height: 0.2)))
    }

    func testNoFaceAndSeveralFacesAreReportedNotThrown() async throws {
        let image = try buffer(gray: 150)
        let none = await engine([]).analyze(frame: frame(image))
        XCTAssertEqual(none, FaceIDCore.FaceObservation(kind: .noFace, timestamp: 42))
        let two = [VNFaceObservation(boundingBox: centered), VNFaceObservation(boundingBox: centered)]
        let several = await engine(two).analyze(frame: frame(image))
        XCTAssertEqual(several.kind, .multipleFaces)
        XCTAssertNil(several.embedding)
    }

    func testDarkFaceIsTooDarkAroundTheThreshold() async throws {
        let face = [VNFaceObservation(boundingBox: centered)]
        let dark = await engine(face).analyze(frame: frame(try buffer(gray: 39)))
        XCTAssertEqual(dark.kind, .tooDark)
        // Just bright enough: it moves on and fails only because the stand-in face has no landmarks.
        let lit = await engine(face).analyze(frame: frame(try buffer(gray: 41)))
        XCTAssertEqual(lit.kind, .unusable)
    }

    func testDarkFaceInABrightRoomIsTooDark() async throws {
        // Dark patch exactly under the face box: columns 19..<45, rows 12..<36 of 64x48.
        let image = try buffer(gray: 220, patch: (19..<45, 12..<36, 20))
        let result = await engine([VNFaceObservation(boundingBox: centered)]).analyze(frame: frame(image))
        XCTAssertEqual(result.kind, .tooDark)
    }

    func testSmallOrEdgeTouchingFaceIsUnusable() async throws {
        let image = try buffer(gray: 150)
        for box in [CGRect(x: 0.4, y: 0.4, width: 0.11, height: 0.15), CGRect(x: 0.0, y: 0.3, width: 0.3, height: 0.4),
                    CGRect(x: 0.75, y: 0.3, width: 0.25, height: 0.4), CGRect(x: 0.3, y: 0.6, width: 0.3, height: 0.4)] {
            let result = await engine([VNFaceObservation(boundingBox: box)]).analyze(frame: frame(image))
            XCTAssertEqual(result.kind, .unusable, "\(box)")
        }
    }

    func testMissingLandmarksAndVisionErrorsAreUnusable() async throws {
        let image = try buffer(gray: 150)
        let noLandmarks = await engine([VNFaceObservation(boundingBox: centered)]).analyze(frame: frame(image))
        XCTAssertEqual(noLandmarks, FaceIDCore.FaceObservation(kind: .unusable, timestamp: 42))
        struct VisionFailed: Error {}
        let failing = FaceEngine(perform: { _, _ in throw VisionFailed() })
        let failed = await failing.analyze(frame: frame(image))
        XCTAssertEqual(failed.kind, .unusable)
    }

    func testDetectionUsesRevisionThreeAndFeedsTheFaceToLandmarks() async throws {
        final class Requests: @unchecked Sendable { var seen: [VNImageBasedRequest] = [] }
        let requests = Requests()
        let face = VNFaceObservation(boundingBox: centered)
        let engine = FaceEngine(perform: { request, _ in requests.seen.append(request); return [face] })
        _ = await engine.analyze(frame: frame(try buffer(gray: 150)))
        let detection = try XCTUnwrap(requests.seen.first as? VNDetectFaceRectanglesRequest)
        XCTAssertEqual(detection.revision, VNDetectFaceRectanglesRequestRevision3)
        let landmarks = try XCTUnwrap(requests.seen.dropFirst().first as? VNDetectFaceLandmarksRequest)
        XCTAssertTrue(landmarks.inputFaceObservations?.first === face)
    }

    func testFacePointsKeepTheAlignmentOrderWithTheOriginAtTheTop() {
        // Vision's points count up from the bottom of the frame; the saved pictures count down from the top.
        let points = [CGPoint(x: 600, y: 420), CGPoint(x: 680, y: 421), CGPoint(x: 640, y: 370),
                      CGPoint(x: 610, y: 340), CGPoint(x: 670, y: 341)]
        XCTAssertEqual(FaceEngine.facePoints(points, imageHeight: 720),
                       FacePoints(leftEye: [600, 300], rightEye: [680, 299], nose: [640, 350], leftMouth: [610, 380],
                                  rightMouth: [670, 379]))
    }

    func testMissingModelIsAnErrorFromPrepare() async {
        do {
            try await FaceEngine(modelURL: nil).prepare()
            XCTFail("prepare() succeeded without a model")
        } catch {
            XCTAssertEqual(error as? FaceEngineError, .modelMissing)
        }
    }
}
