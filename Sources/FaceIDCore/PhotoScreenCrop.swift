import CoreGraphics
import Foundation

/// The pixels the MiniFASNet photo/screen detector is fed, exactly as docs/verification/minifasnet-model.md
/// says (steps 1 to 4): the face box in pixels, upstream's crop box per scale, and the 80x80 resize into
/// blue, green, red planes of raw 0-255 values. Arithmetic only; the model runs in the app.
public enum PhotoScreenCrop {
    /// Each model input is `side` x `side` pixels.
    public static let side = 80

    /// A face box in whole pixels, top-left origin.
    public struct FaceBox: Sendable, Equatable, Codable {
        public let x, y, width, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            (self.x, self.y, self.width, self.height) = (x, y, width, height)
        }
    }

    /// An inclusive pixel box: columns `left...right`, rows `top...bottom`.
    public struct CropBox: Sendable, Equatable {
        public let left, top, right, bottom: Int
        public var width: Int { right - left + 1 }
        public var height: Int { bottom - top + 1 }
        public init(left: Int, top: Int, right: Int, bottom: Int) {
            (self.left, self.top, self.right, self.bottom) = (left, top, right, bottom)
        }
    }

    /// Step 1: a Vision box (normalized, bottom-left origin) on a `width` x `height` frame, truncated the way
    /// upstream truncates its detector's box.
    public static func faceBox(_ box: CGRect, width: Int, height: Int) -> FaceBox {
        let frameWidth = Double(width), frameHeight = Double(height)
        let left = Double(box.minX) * frameWidth, right = Double(box.maxX) * frameWidth
        let top = (1 - Double(box.maxY)) * frameHeight, bottom = (1 - Double(box.minY)) * frameHeight
        return FaceBox(x: Int(left), y: Int(top), width: Int(right - left + 1), height: Int(bottom - top + 1))
    }

    /// Step 2: upstream's crop box for one scale (2.7 or 4.0), with its operation order kept so the result
    /// matches Python bit for bit. It keeps the face's centre and shape, slides back inside the frame instead
    /// of padding, and shrinks the scale when the crop would not fit.
    public static func cropBox(_ face: FaceBox, width: Int, height: Int, scale wanted: Double) -> CropBox {
        let maxX = Double(width - 1), maxY = Double(height - 1)
        let scale = min(maxY / Double(face.height), min(maxX / Double(face.width), wanted))
        let newWidth = Double(face.width) * scale, newHeight = Double(face.height) * scale
        let centerX = Double(face.width) / 2 + Double(face.x), centerY = Double(face.height) / 2 + Double(face.y)
        var left = centerX - newWidth / 2, top = centerY - newHeight / 2
        var right = centerX + newWidth / 2, bottom = centerY + newHeight / 2
        if left < 0 { right -= left; left = 0 }
        if top < 0 { bottom -= top; top = 0 }
        if right > maxX { left -= right - Double(width) + 1; right = maxX }
        if bottom > maxY { top -= bottom - Double(height) + 1; bottom = maxY }
        return CropBox(left: Int(left), top: Int(top), right: Int(right), bottom: Int(bottom))
    }

    /// Steps 3 and 4: resizes `crop` of a BGRA image to `side` x `side` (bilinear, half-pixel centres,
    /// edge-clamped, no antialiasing, rounded half up like OpenCV) and writes channel c (0 blue, 1 green,
    /// 2 red) of row r, column q to `input[(c * side + r) * side + q]`. Rows step by `bytesPerRow`; alpha is
    /// ignored. The caller keeps `crop` inside the image and `input` at least 3 * side * side long.
    public static func fill(_ input: UnsafeMutablePointer<Float>, from pixels: UnsafePointer<UInt8>,
                            bytesPerRow: Int, crop: CropBox, side: Int = PhotoScreenCrop.side) {
        withUnsafeTemporaryAllocation(of: Tap.self, capacity: side) { columns in
            for q in 0..<side { columns[q] = Tap(q, source: crop.width, side: side) }
            for r in 0..<side {
                let row = Tap(r, source: crop.height, side: side), b = row.weight
                let upper = pixels + (crop.top + row.first) * bytesPerRow + crop.left * 4
                let lower = pixels + (crop.top + row.second) * bytesPerRow + crop.left * 4
                for q in 0..<side {
                    let column = columns[q], a = column.weight
                    let first = column.first * 4, second = column.second * 4
                    for c in 0..<3 {
                        let top = (1 - a) * Double(upper[first + c]) + a * Double(upper[second + c])
                        let bottom = (1 - a) * Double(lower[first + c]) + a * Double(lower[second + c])
                        input[(c * side + r) * side + q] = Float(((1 - b) * top + b * bottom).rounded())
                    }
                }
            }
        }
    }

    /// The two source pixels one output pixel blends along one axis, and the second one's weight.
    private struct Tap {
        let first: Int, second: Int, weight: Double

        init(_ index: Int, source: Int, side: Int) {
            let f = (Double(index) + 0.5) * Double(source) / Double(side) - 0.5
            var first = Int(f.rounded(.down)), weight = f - f.rounded(.down)
            if first < 0 { first = 0; weight = 0 }
            if first >= source - 1 { first = source - 1; weight = 0 }
            self.first = first
            second = min(first + 1, source - 1)
            self.weight = weight
        }
    }
}
