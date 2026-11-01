import CoreML
import CoreVideo
import FaceIDCore
import ImageIO
import Vision
import XCTest
@testable import FaceIDUnlock

/// Parity with the upstream pipeline on its own sample photos (decision L3): the tripwire for channel order and
/// preprocessing. Fed red, green, blue instead of blue, green, red, the printed photo scores 0.87 to 0.94 real.
final class PhotoScreenDetectorTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let fixtures = repo.appendingPathComponent("Tests/FaceIDUnlockTests/Fixtures/MiniFASNet")
    /// Compiled once for the whole class: compiling a package takes a moment.
    private static let detectorModel = Result {
        try MLModel.compileModel(at: repo.appendingPathComponent("Resources/MiniFASNet.mlpackage"))
    }
    private static let faceModel = Result { try MLModel.compileModel(at: repo.appendingPathComponent("Resources/SFace.mlpackage")) }

    /// One row of docs/verification/minifasnet-evidence/vision-box-check.json: what the upstream Python pipeline
    /// gave with Vision's box in place of its own detector's.
    private struct Evidence {
        let image: String
        let box: [Int]
        let real: Float
    }

    private func evidence() throws -> [Evidence] {
        let url = Self.repo.appendingPathComponent("docs/verification/minifasnet-evidence/vision-box-check.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try XCTUnwrap(json["rows"] as? [[String: Any]])
        return try rows.map { row in
            Evidence(image: try XCTUnwrap(row["image"] as? String), box: try XCTUnwrap(row["vision_rev3_box_xywh"] as? [Int]),
                     real: Float(try XCTUnwrap(row["real_with_vision_box"] as? Double)))
        }
    }

    /// A sample JPEG with its EXIF orientation applied (480x640 portrait), drawn into a BGRA buffer like the camera's:
    /// the whole buffer by default, or centred at its natural size on a black buffer of `width` x `height`.
    private func frame(_ name: String, width: Int = 480, height: Int = 640) throws -> CVPixelBuffer {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(Self.fixtures.appendingPathComponent(name) as CFURL, nil))
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true]
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
        XCTAssertEqual([image.width, image.height], [480, 640], name)
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &created),
                       kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: try XCTUnwrap(image.colorSpace),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: (width - image.width) / 2, y: (height - image.height) / 2,
                                       width: image.width, height: image.height))
        return buffer
    }

    /// Vision's face box, asked for exactly as FaceEngine asks.
    private func visionBox(_ buffer: CVPixelBuffer) throws -> CGRect {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let faces = try FaceEngine.visionPerform(request, buffer)
        XCTAssertEqual(faces.count, 1)
        return try XCTUnwrap(faces.first).boundingBox
    }

    /// Measured on the M5 Max, macOS 27 (docs/verification/minifasnet-model.md, "In the app"). Fed the pixels of
    /// upstream's own JPEG decoder, this code reproduced every upstream score to 7 digits, so what is left with
    /// upstream's box is ImageIO decoding the JPEGs slightly differently: up to 0.018, inside `scoreTolerance`.
    /// Vision's own box is only held to `boxTolerance` and to the right side of 0.5: it moved up to 8 px with
    /// tiny input changes, and one row of crop shift moves the screen sample from 0.19 to 0.12 or 0.25. Both
    /// legs still fail red-green-blue order (printed photo 0.87, screen 1.00) and dividing by 255 (screen and
    /// real face 0.01).
    private static let boxTolerance = 12
    private static let scoreTolerance: Float = 0.04

    func testSamplePhotosScoreLikeTheUpstreamPipeline() throws {
        let detector = try PhotoScreenDetector(url: Self.detectorModel.get())
        let rows = try evidence()
        XCTAssertEqual(rows.map(\.image), ["image_F1.jpg", "image_F2.jpg", "image_T1.jpg"])
        for row in rows {
            let buffer = try frame(row.image)
            // Upstream's box (step 1 already done): only the JPEG decoding differs.
            let upstream = PhotoScreenCrop.FaceBox(x: row.box[0], y: row.box[1], width: row.box[2], height: row.box[3])
            let fixed = try XCTUnwrap(detector.score(in: buffer, face: upstream), row.image)
            XCTAssertEqual(fixed.real, row.real, accuracy: Self.scoreTolerance, "\(row.image) with upstream's box")
            // `real` is the mean of the two models' real-face probabilities, each a softmax.
            XCTAssertEqual(fixed.real, (fixed.probs27[1] + fixed.probs40[1]) / 2, accuracy: 0.0001, row.image)
            for probs in [fixed.probs27, fixed.probs40] { XCTAssertEqual(probs.reduce(0, +), 1, accuracy: 0.001, row.image) }
            // The app's whole path: Vision's own box on these pixels.
            let box = try visionBox(buffer)
            let face = PhotoScreenCrop.faceBox(box, width: 480, height: 640)
            for (measured, expected) in zip([face.x, face.y, face.width, face.height], row.box) {
                XCTAssertEqual(measured, expected, accuracy: Self.boxTolerance, "\(row.image) Vision box")
            }
            let real = try XCTUnwrap(detector.score(in: buffer, face: box), row.image).real
            XCTAssertEqual(real > 0.5, row.real > 0.5, "\(row.image) with Vision's box: \(real) vs \(row.real)")
        }
    }

    func testEachCropGoesToItsOwnModelInput() throws {
        // On the 480x640 samples both scales are cut to the frame width, so the two crops are about the same
        // pixels and swapping them changes nothing. Centred on a 1280x720 frame they differ.
        let detectorURL = try Self.detectorModel.get()
        let buffer = try frame("image_T1.jpg", width: 1280, height: 720)
        let face = PhotoScreenCrop.FaceBox(x: 134 + 400, y: 162 + 40, width: 178, height: 178)
        let score = try XCTUnwrap(PhotoScreenDetector(url: detectorURL).score(in: buffer, face: face))

        let model = try MLModel(contentsOf: detectorURL)
        func outputs(crop27 scale27: Double, crop40 scale40: Double) throws -> [Float] {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            var inputs: [String: MLMultiArray] = [:]
            for (name, scale) in [("crop27", scale27), ("crop40", scale40)] {
                let input = try MLMultiArray(shape: [1, 3, 80, 80], dataType: .float32)
                PhotoScreenCrop.fill(input.dataPointer.bindMemory(to: Float.self, capacity: input.count), from: pixels,
                                     bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                     crop: PhotoScreenCrop.cropBox(face, width: 1280, height: 720, scale: scale))
                inputs[name] = input
            }
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
            return try ["probs27", "probs40"].flatMap { name in
                let array = try XCTUnwrap(output.featureValue(for: name)?.multiArrayValue)
                return (0..<3).map { array[[0, $0] as [NSNumber]].floatValue }
            }
        }
        let right = try outputs(crop27: 2.7, crop40: 4.0), swapped = try outputs(crop27: 4.0, crop40: 2.7)
        for (detector, direct) in zip(score.probs27 + score.probs40, right) {
            XCTAssertEqual(detector, direct, accuracy: 0.0001)
        }
        XCTAssertGreaterThan(zip(right, swapped).map { abs($0 - $1) }.max() ?? 0, 0.01, "The test can tell a swap")
    }

    func testEngineAddsTheScoreToUsableFacesOnlyAndNothingElseChanges() async throws {
        let faceModel = try Self.faceModel.get()
        let watched = FaceEngine(modelURL: faceModel, detectorURL: try Self.detectorModel.get())
        let plain = FaceEngine(modelURL: faceModel, detectorURL: URL(fileURLWithPath: "/nonexistent/MiniFASNet.mlmodelc"))
        try await watched.prepare()
        try await plain.prepare()
        let buffer = try frame("image_T1.jpg")
        let camera = CameraFrame(pixelBuffer: buffer, timestamp: 7, generation: UUID())
        let face = await watched.analyze(frame: camera)
        XCTAssertEqual(face.kind, .face)
        let direct = try PhotoScreenDetector(url: Self.detectorModel.get()).score(in: buffer, face: visionBox(buffer))
        XCTAssertEqual(try XCTUnwrap(face.photoScreen?.real), try XCTUnwrap(direct?.real), accuracy: 0.0001)

        // A detector that won't load leaves the score out and everything else exactly as it was.
        let without = await plain.analyze(frame: camera)
        XCTAssertNil(without.photoScreen)
        XCTAssertEqual(without, FaceIDCore.FaceObservation(kind: face.kind, timestamp: face.timestamp, embedding: face.embedding,
                                                           yaw: face.yaw, roll: face.roll, quality: face.quality,
                                                           points: face.points, faceBox: face.faceBox))
        // The face points and box come with every face, detector or not: the box is the one the detector crops.
        XCTAssertNotNil(face.points)
        XCTAssertEqual(face.faceBox, PhotoScreenCrop.faceBox(try visionBox(buffer), width: CVPixelBufferGetWidth(buffer),
                                                             height: CVPixelBufferGetHeight(buffer)))

        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 480, 640, kCVPixelFormatType_32BGRA, nil, &created), kCVReturnSuccess)
        let empty = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(empty, [])
        memset(CVPixelBufferGetBaseAddress(empty), 128, CVPixelBufferGetDataSize(empty))
        CVPixelBufferUnlockBaseAddress(empty, [])
        let none = await watched.analyze(frame: CameraFrame(pixelBuffer: empty, timestamp: 8, generation: UUID()))
        XCTAssertEqual(none, FaceIDCore.FaceObservation(kind: .noFace, timestamp: 8), "No face, no score")
    }
}
