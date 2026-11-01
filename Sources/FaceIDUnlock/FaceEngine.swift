import CoreImage
import CoreML
import CoreVideo
import FaceIDCore
import Foundation
import Vision

enum FaceEngineError: LocalizedError {
    case modelMissing, invalidModel

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "The face model is missing. Reinstall Face ID Unlock."
        case .invalidModel: return "The face model didn't load. Reinstall Face ID Unlock."
        }
    }
}

/// Turns camera frames into face observations. Vision, alignment, the SFace model and the photo/screen
/// detector run off the main actor. Ordinary bad frames come back as a kind, never as an error; the caller
/// decides what to skip.
actor FaceEngine {
    typealias Perform = @Sendable (VNImageBasedRequest, CVPixelBuffer) throws -> [VNFaceObservation]

    /// Mean face-box brightness (0-255) below this counts as too dark.
    static let darkLuma = 40.0
    private var model: MLModel?
    private let modelURL: URL?
    /// Nil when its model is missing or won't load; checks then go on the match alone and log that (decision L3).
    private var detector: PhotoScreenDetector?
    private let detectorURL: URL?
    private let perform: Perform
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// `perform` runs one Vision request on a frame; tests replace it. Model URLs default to the app bundle.
    init(modelURL: URL? = nil, detectorURL: URL? = nil,
         perform: @escaping Perform = { try FaceEngine.visionPerform($0, $1) }) {
        self.modelURL = modelURL
        self.detectorURL = detectorURL
        self.perform = perform
    }

    /// Loads and warms up the models once. Safe to call repeatedly; call at launch so the first check is fast.
    /// Only the face model can make it fail; the photo/screen detector is simply left out if it won't load.
    func prepare() throws {
        guard model == nil else { return }
        guard let url = modelURL ?? Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc") else {
            throw FaceEngineError.modelMissing
        }
        let compiledURL = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loaded = try MLModel(contentsOf: compiledURL, configuration: configuration)
        guard loaded.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 3, 112, 112],
              loaded.modelDescription.outputDescriptionsByName["embedding"] != nil else {
            throw FaceEngineError.invalidModel
        }
        // CoreML sets up its prediction backend lazily; pay that cost here, not on a live frame.
        let input = try MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32)
        input.dataPointer.initializeMemory(as: Float.self, repeating: 0, count: input.count)
        _ = try loaded.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        model = loaded
        detector = (detectorURL ?? Bundle.main.url(forResource: "MiniFASNet", withExtension: "mlmodelc"))
            .flatMap { try? PhotoScreenDetector(url: $0) }
    }

    /// Classifies one frame: no face, several faces, too dark, unusable, or a face with its unit embedding, pose,
    /// photo/screen score, face points and box. Loads the models on first use if prepare() was not called; a face
    /// model that won't load makes every face unusable.
    /// Vision has its own FaceObservation type, hence the module prefix.
    func analyze(frame: CameraFrame) -> FaceIDCore.FaceObservation {
        let buffer = frame.pixelBuffer, timestamp = frame.timestamp
        func result(_ kind: FaceIDCore.FaceObservation.Kind) -> FaceIDCore.FaceObservation {
            FaceIDCore.FaceObservation(kind: kind, timestamp: timestamp)
        }
        let detection = VNDetectFaceRectanglesRequest()
        // Revision 3 supplies the continuous yaw and roll that landmark extraction carries forward.
        detection.revision = VNDetectFaceRectanglesRequestRevision3
        guard let faces = try? perform(detection, buffer) else { return result(.unusable) }
        guard !faces.isEmpty else { return result(.noFace) }
        guard faces.count == 1 else { return result(.multipleFaces) }
        let box = faces[0].boundingBox
        if let luma = Self.meanLuma(of: buffer, in: box), luma < Self.darkLuma { return result(.tooDark) }
        guard box.width >= 0.12, box.minX >= 0.01, box.minY >= 0.01, box.maxX <= 0.99, box.maxY <= 0.99 else {
            return result(.unusable)
        }
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = faces
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard let marked = try? perform(landmarks, buffer), marked.count == 1,
              let points = Self.alignmentPoints(marked[0], imageSize: size) else { return result(.unusable) }
        if model == nil { try? prepare() }
        guard let model, let embedding = embedding(buffer, points: points, model: model) else { return result(.unusable) }
        let face = marked[0]
        let pixelBox = PhotoScreenCrop.faceBox(box, width: Int(size.width), height: Int(size.height))
        return FaceIDCore.FaceObservation(kind: .face, timestamp: timestamp, embedding: embedding,
                                          yaw: face.yaw.map(\.doubleValue).flatMap(Self.finite),
                                          roll: face.roll.map(\.doubleValue).flatMap(Self.finite),
                                          quality: captureQuality(face, buffer),
                                          photoScreen: detector?.score(in: buffer, face: pixelBox),
                                          points: Self.facePoints(points, imageHeight: Double(size.height)),
                                          faceBox: pixelBox)
    }

    /// The five alignment points (image pixels, bottom-left origin) as FacePoints, with the origin at the top left.
    static func facePoints(_ points: [CGPoint], imageHeight: Double) -> FacePoints {
        let flipped = points.map { SIMD2(Double($0.x), imageHeight - Double($0.y)) }
        return FacePoints(leftEye: flipped[0], rightEye: flipped[1], nose: flipped[2], leftMouth: flipped[3],
                          rightMouth: flipped[4])
    }

    static func visionPerform(_ request: VNImageBasedRequest, _ buffer: CVPixelBuffer) throws -> [VNFaceObservation] {
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        return request.results as? [VNFaceObservation] ?? []
    }

    private static func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }

    /// Vision's capture quality, for ranking only; nil when Vision gives no usable score.
    private func captureQuality(_ face: VNFaceObservation, _ buffer: CVPixelBuffer) -> Float? {
        let request = VNDetectFaceCaptureQualityRequest()
        request.revision = VNDetectFaceCaptureQualityRequestRevision3
        request.inputFaceObservations = [face]
        guard let scored = try? perform(request, buffer), scored.count == 1, scored[0].uuid == face.uuid,
              let quality = scored[0].faceCaptureQuality, quality.isFinite, (0...1).contains(quality) else { return nil }
        return quality
    }

    /// The five SFace points in image pixels: eyes, nose tip, mouth corners. Nil when any is missing or implausible.
    static func alignmentPoints(_ face: VNFaceObservation, imageSize size: CGSize) -> [CGPoint]? {
        guard let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye, leftEye.pointCount > 0,
              let rightEye = landmarks.rightEye, rightEye.pointCount > 0,
              let nose = landmarks.noseCrest, nose.pointCount > 0,
              let lips = landmarks.outerLips, lips.pointCount > 1 else { return nil }
        func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let points = region.pointsInImage(imageSize: size)
            return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                           y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        // Frames are unmirrored, so sorting by image x gives OpenCV's point order.
        let eyes = [center(leftEye), center(rightEye)].sorted { $0.x < $1.x }
        let mouth = lips.pointsInImage(imageSize: size).sorted { $0.x < $1.x }
        // The bottom of the nose's center crest approximates the nose tip. No crop fallback.
        guard let tip = nose.pointsInImage(imageSize: size).min(by: { $0.y < $1.y }),
              let leftMouth = mouth.first, let rightMouth = mouth.last,
              eyes[1].x - eyes[0].x >= 15 else { return nil }
        return [eyes[0], eyes[1], tip, leftMouth, rightMouth]
    }

    /// OpenCV 5-point alignment to 112x112, RGB 0-255 into the 1x3x112x112 input, unit-length 128-d output.
    private func embedding(_ buffer: CVPixelBuffer, points: [CGPoint], model: MLModel) -> [Float]? {
        guard let transform = FaceAlignment.transform(from: points) else { return nil }
        let aligned = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        guard let rgb = context.createCGImage(aligned, from: CGRect(x: 0, y: 0, width: 112, height: 112), format: .RGBA8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
              let data = rgb.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              let input = try? MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32) else { return nil }
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        let channelStride = input.strides[1].intValue, rowStride = input.strides[2].intValue
        let columnStride = input.strides[3].intValue
        for y in 0..<112 {
            for x in 0..<112 {
                let offset = y * rgb.bytesPerRow + x * 4
                for channel in 0..<3 {
                    pointer[channel * channelStride + y * rowStride + x * columnStride] = Float(bytes[offset + channel])
                }
            }
        }
        guard let prediction = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let output = prediction.featureValue(for: "embedding")?.multiArrayValue,
              output.count == FaceMatch.dimensions else { return nil }
        return FaceMatch.normalized((0..<output.count).map { output[$0].floatValue })
    }

    /// Mean luma (0-255) of a Vision box (normalized, bottom-left origin) in a BGRA buffer,
    /// read on a 16x16 grid so it stays cheap. Nil for other pixel formats or a box outside the image.
    static func meanLuma(of buffer: CVPixelBuffer, in box: CGRect) -> Double? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        let region = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isNull, region.width > 0, region.height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let steps = 16
        var total = 0.0
        for row in 0..<steps {
            // Buffer rows run top-down, so flip Vision's y.
            let top = 1 - region.maxY + (Double(row) + 0.5) / Double(steps) * region.height
            let y = min(height - 1, Int(top * Double(height)))
            for column in 0..<steps {
                let left = region.minX + (Double(column) + 0.5) / Double(steps) * region.width
                let pixel = base + y * rowBytes + min(width - 1, Int(left * Double(width))) * 4
                total += 0.114 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.299 * Double(pixel[2])
            }
        }
        return total / Double(steps * steps)
    }
}
