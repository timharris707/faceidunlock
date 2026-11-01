import CoreGraphics
import CoreML
import CoreVideo
import FaceIDCore
import Foundation

/// The MiniFASNet photo/screen detector (decision L3): a matching frame it rates below `MatchSettings.minimumReal`
/// doesn't count, and its scores go to the score log. Feeds the model as docs/verification/minifasnet-model.md
/// says. Reuses its two input arrays, so one detector serves one caller at a time (FaceEngine's actor).
final class PhotoScreenDetector {
    private let model: MLModel
    private let crop27: MLMultiArray
    private let crop40: MLMultiArray

    /// Loads the model (compiling an .mlpackage first), checks its inputs and outputs, and runs it once so the
    /// first live frame is not slow.
    init(url: URL) throws {
        let compiledURL = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        let shape = [1, 3, PhotoScreenCrop.side, PhotoScreenCrop.side]
        let description = model.modelDescription
        guard ["crop27", "crop40"].allSatisfy({
                  description.inputDescriptionsByName[$0]?.multiArrayConstraint?.shape.map(\.intValue) == shape
              }),
              ["real", "probs27", "probs40"].allSatisfy({ description.outputDescriptionsByName[$0] != nil })
        else { throw FaceEngineError.invalidModel }
        crop27 = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        crop40 = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        for input in [crop27, crop40] {
            input.dataPointer.initializeMemory(as: Float.self, repeating: 0, count: input.count)
        }
        _ = try predict()
    }

    private func predict() throws -> MLFeatureProvider {
        try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["crop27": crop27, "crop40": crop40]))
    }

    /// The model's outputs for the face in Vision's `box` (normalized, bottom-left origin) on an upright,
    /// unmirrored BGRA frame. Nil for another pixel format or when the model fails.
    func score(in buffer: CVPixelBuffer, face box: CGRect) -> PhotoScreenScore? {
        score(in: buffer, face: PhotoScreenCrop.faceBox(box, width: CVPixelBufferGetWidth(buffer),
                                                         height: CVPixelBufferGetHeight(buffer)))
    }

    /// The same for a face box already in pixels.
    func score(in buffer: CVPixelBuffer, face: PhotoScreenCrop.FaceBox) -> PhotoScreenScore? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func fill(_ input: MLMultiArray, scale: Double) -> Bool {
            let crop = PhotoScreenCrop.cropBox(face, width: width, height: height, scale: scale)
            guard crop.left >= 0, crop.top >= 0, crop.right < width, crop.bottom < height else { return false }
            PhotoScreenCrop.fill(input.dataPointer.bindMemory(to: Float.self, capacity: input.count), from: base,
                                 bytesPerRow: rowBytes, crop: crop)
            return true
        }
        guard fill(crop27, scale: 2.7), fill(crop40, scale: 4.0), let output = try? predict(),
              let real = Self.probabilities(output, "real", shape: [1])?.first,
              let probs27 = Self.probabilities(output, "probs27", shape: [1, 3]),
              let probs40 = Self.probabilities(output, "probs40", shape: [1, 3]) else { return nil }
        return PhotoScreenScore(real: real, probs27: probs27, probs40: probs40)
    }

    /// Output `name` in index order, or nil unless it has `shape` and every value is in 0...1.
    private static func probabilities(_ output: MLFeatureProvider, _ name: String, shape: [Int]) -> [Float]? {
        guard let array = output.featureValue(for: name)?.multiArrayValue, array.shape.map(\.intValue) == shape
        else { return nil }
        let leading = Array(repeating: NSNumber(value: 0), count: shape.count - 1)
        let values = (0..<shape[shape.count - 1]).map { array[leading + [NSNumber(value: $0)]].floatValue }
        return values.allSatisfy { $0.isFinite && (0...1).contains($0) } ? values : nil
    }
}
