import Foundation
import CoreGraphics

public enum FaceMatch {
    public static let dimensions = 128

    public static func normalized(_ values: [Float]) -> [Float]? {
        guard values.count == dimensions, values.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(values.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.000001 else { return nil }
        return values.map { $0 / norm }
    }

    public static func cosine(_ first: [Float], _ second: [Float]) -> Float? {
        guard let a = normalized(first), let b = normalized(second) else { return nil }
        return min(1, max(-1, zip(a, b).reduce(Float.zero) { $0 + $1.0 * $1.1 }))
    }

    public static func centroid(_ samples: [[Float]]) -> [Float]? {
        guard !samples.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: dimensions)
        for sample in samples {
            guard let sample = normalized(sample) else { return nil }
            for index in sum.indices { sum[index] += sample[index] }
        }
        return normalized(sum)
    }
}

public enum FaceAlignment {
    /// Official OpenCV SFace template, with y converted for Core Image's bottom-left origin.
    public static let canonicalPoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 112 - 51.6963), CGPoint(x: 73.5318, y: 112 - 51.5014),
        CGPoint(x: 56.0252, y: 112 - 71.7366), CGPoint(x: 41.5493, y: 112 - 92.3655),
        CGPoint(x: 70.7299, y: 112 - 92.2041)
    ]

    /// Least-squares similarity fit; no shear, reflection, or fallback crop.
    public static func transform(from source: [CGPoint]) -> CGAffineTransform? {
        guard source.count == 5, source.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let destination = canonicalPoints
        let sourceMean = CGPoint(x: source.map(\.x).reduce(0, +) / 5, y: source.map(\.y).reduce(0, +) / 5)
        let targetMean = CGPoint(x: destination.map(\.x).reduce(0, +) / 5, y: destination.map(\.y).reduce(0, +) / 5)
        var denominator: CGFloat = 0, dot: CGFloat = 0, cross: CGFloat = 0
        for (point, target) in zip(source, destination) {
            let x = point.x - sourceMean.x, y = point.y - sourceMean.y
            let targetX = target.x - targetMean.x, targetY = target.y - targetMean.y
            denominator += x * x + y * y
            dot += x * targetX + y * targetY
            cross += x * targetY - y * targetX
        }
        guard denominator > 0.000001 else { return nil }
        let a = dot / denominator, b = cross / denominator
        let scale = hypot(a, b)
        guard scale > 0.05, scale < 20 else { return nil }
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
                                 tx: targetMean.x - a * sourceMean.x + b * sourceMean.y,
                                 ty: targetMean.y - b * sourceMean.x - a * sourceMean.y)
    }
}
