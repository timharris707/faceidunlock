import CoreGraphics
import CoreVideo
import FaceIDCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One analyzed frame of a Home Test try, as its try.json lists it. Numbers only, never the embedding.
struct TestFrame: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case check, glance }
    /// Seconds from the start of the check.
    var time: Double
    var stage: Stage
    /// `FaceObservation.Kind`'s code, such as "face" or "noFace".
    var kind: String
    /// Best match against the saved face, and the photo/screen detector's outputs, rounded to 3 decimals.
    var match: Float?
    var real: Float?
    var probs27: [Float]?
    var probs40: [Float]?
    /// Radians, Vision convention.
    var yaw: Double?
    var roll: Double?
    /// Pixels in the full frame, origin top left.
    var points: FacePoints?
    var faceBox: PhotoScreenCrop.FaceBox?
    /// This frame's picture in the try's folder: every glance frame has one.
    var picture: String?
}

/// Everything one try's folder holds, ready to write: the frames and the encoded pictures by file name.
struct TestCapture: Sendable {
    var frames: [TestFrame]
    /// Index in `frames` of the frame `frame.jpg` and the crops come from.
    var decisionFrame: Int?
    /// Seconds from the start of the check to the glance asking.
    var glanceStart: Double?
    var pictures: [String: Data]
}

/// Collects one Home Test try's pictures while its check runs, for the bake-off (vision AI research, section 3).
/// Fed from the camera loop on the main actor, it copies only what it needs: each glance frame is copied at once
/// and shrunk to at most 640 px wide on its own queue, and of the camera's own buffers it holds only one, the face
/// check's deciding frame, until the try is saved. Never sees the password; the embedding is used only to score
/// the frame, never kept.
@MainActor
final class TestPictureRecorder {
    private let gallery: FaceGallery
    private let startedAt: TimeInterval
    private var frames: [TestFrame] = []
    private var glanceStart: Double?
    private var glancePictures = 0
    /// The face check's latest frame showing one face, or, until one does, its latest frame.
    private var decision: (buffer: CVPixelBuffer, index: Int, isFace: Bool)?
    private let work = Work()

    /// `startedAt`: when the check starts, on the host clock frames use.
    init(gallery: FaceGallery, startedAt: TimeInterval) {
        self.gallery = gallery
        self.startedAt = startedAt
    }

    /// The glance has asked: the frames from now on are glance frames.
    func glanceStarted(at now: TimeInterval) { glanceStart = Self.rounded(now - startedAt) }

    /// One analyzed frame and what the engine found in it.
    func add(_ buffer: CVPixelBuffer, _ observation: FaceIDCore.FaceObservation) {
        let index = frames.count, isFace = observation.kind == .face
        let score = observation.embedding.flatMap { gallery.bestScore(for: $0) }
        var frame = TestFrame(time: Self.rounded(observation.timestamp - startedAt),
                              stage: glanceStart == nil ? .check : .glance, kind: observation.kind.rawValue,
                              match: score.map(Self.rounded), real: observation.photoScreen.map { Self.rounded($0.real) },
                              probs27: observation.photoScreen?.probs27.map(Self.rounded),
                              probs40: observation.photoScreen?.probs40.map(Self.rounded),
                              yaw: observation.yaw, roll: observation.roll, points: observation.points,
                              faceBox: observation.faceBox)
        if frame.stage == .glance {
            glancePictures += 1
            let name = String(format: "glance-%03d.jpg", glancePictures)
            frame.picture = name
            // Copied here, so the camera's buffer goes back at once even if the queue falls behind.
            if let copy = TestPictureImages.image(buffer) {
                work.queue.async { [work] in
                    work.add(name, TestPictureImages.shrunk(copy, maxWidth: 640).flatMap { TestPictureImages.jpeg($0) })
                }
            }
        } else if isFace || decision?.isFace != true {
            decision = (buffer, index, isFace)
        }
        frames.append(frame)
    }

    /// Waits for the glance pictures, then makes the deciding frame's: the full frame as JPEG, the photo/screen
    /// detector's two 80x80 crops and a wider 224x224 face crop as PNG. Off the main thread.
    func finish() async -> TestCapture {
        let frames = frames, glanceStart = glanceStart, work = work
        // Handed over to the queue: nothing else reads the buffer from now on.
        nonisolated(unsafe) let decision = decision.map {
            (buffer: $0.buffer, index: $0.index, face: frames[$0.index].faceBox)
        }
        self.decision = nil
        return await withCheckedContinuation { continuation in
            work.queue.async {
                if let decision, let full = TestPictureImages.image(decision.buffer) {
                    work.add("frame.jpg", TestPictureImages.jpeg(full))
                    if let face = decision.face {
                        for (name, scale) in [("detector-2.7x.png", 2.7), ("detector-4.0x.png", 4.0)] {
                            work.add(name, TestPictureImages.detectorCrop(decision.buffer, face: face, scale: scale)
                                .flatMap(TestPictureImages.png))
                        }
                        work.add("face-224.png", TestPictureImages.faceCrop(full, face: face).flatMap(TestPictureImages.png))
                    }
                }
                continuation.resume(returning: TestCapture(frames: frames, decisionFrame: decision?.index,
                                                           glanceStart: glanceStart, pictures: work.pictures))
            }
        }
    }

    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    private static func rounded(_ value: Float) -> Float { (value * 1000).rounded() / 1000 }

    /// The serial queue the pictures are made on, and the encoded pictures so far.
    private final class Work: @unchecked Sendable {
        let queue = DispatchQueue(label: "FaceIDUnlock.testPictures", qos: .utility)
        private let lock = NSLock()
        private var files: [String: Data] = [:]
        var pictures: [String: Data] { lock.withLock { files } }
        func add(_ name: String, _ data: Data?) { lock.withLock { files[name] = data } }
    }
}

/// Picture copying, cropping and encoding for the Home Test pictures. Frames are the camera's BGRA buffers.
enum TestPictureImages {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bgra = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                           | CGBitmapInfo.byteOrder32Little.rawValue)

    /// A copy of a BGRA frame; nil for other pixel formats.
    static func image(_ buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let provider = CGDataProvider(data: Data(bytes: base, count: rowBytes * height) as CFData) else { return nil }
        return CGImage(width: CVPixelBufferGetWidth(buffer), height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: sRGB, bitmapInfo: bgra, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// `image` scaled down to at most `maxWidth` pixels wide, keeping its shape.
    static func shrunk(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let height = (Double(image.height * maxWidth) / Double(image.width)).rounded()
        return resized(image, width: maxWidth, height: max(1, Int(height)))
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: bgra.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The 80x80 picture the photo/screen detector is fed for one crop scale, pixel for pixel (`PhotoScreenCrop`).
    /// Nil when the crop doesn't fit inside the frame, as the detector then gives no score.
    static func detectorCrop(_ buffer: CVPixelBuffer, face: PhotoScreenCrop.FaceBox, scale: Double) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let crop = PhotoScreenCrop.cropBox(face, width: width, height: height, scale: scale)
        guard crop.left >= 0, crop.top >= 0, crop.right < width, crop.bottom < height else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let side = PhotoScreenCrop.side
        var planes = [Float](repeating: 0, count: 3 * side * side)
        planes.withUnsafeMutableBufferPointer {
            PhotoScreenCrop.fill($0.baseAddress!, from: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), crop: crop)
        }
        // Planes are blue, green, red; the picture's pixels are blue, green, red, unused.
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for row in 0..<side {
            for column in 0..<side {
                for channel in 0..<3 {
                    pixels[(row * side + column) * 4 + channel] = UInt8(planes[(channel * side + row) * side + column])
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: sRGB, bitmapInfo: bgra, provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// A square around the face, 1.5 times its longer side, slid inside the frame, at 224x224.
    static func faceCrop(_ image: CGImage, face: PhotoScreenCrop.FaceBox) -> CGImage? {
        let side = max(face.width, face.height)
        let square = PhotoScreenCrop.FaceBox(x: face.x + (face.width - side) / 2, y: face.y + (face.height - side) / 2,
                                             width: side, height: side)
        let crop = PhotoScreenCrop.cropBox(square, width: image.width, height: image.height, scale: 1.5)
        guard let part = image.cropping(to: CGRect(x: crop.left, y: crop.top, width: crop.width, height: crop.height))
        else { return nil }
        return resized(part, width: 224, height: 224)
    }

    static func jpeg(_ image: CGImage) -> Data? { encoded(image, as: .jpeg, quality: 0.85) }
    static func png(_ image: CGImage) -> Data? { encoded(image, as: .png) }

    private static func encoded(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// The Home Test's saved pictures, kept only in Application Support/Face ID Unlock/Test Pictures and excluded from
/// backup: one folder per Home Test window, named by when its first try was saved, and one per try in it,
/// `<NN-subject>`, holding the pictures and try.json. Nothing here goes in the score log.
struct TestPictures: Sendable {
    static let defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Face ID Unlock/Test Pictures", isDirectory: true)
    static let tryFile = "try.json"
    let folder: URL

    init(folder: URL = TestPictures.defaultFolder) { self.folder = folder }

    /// The window folder's name for a date, "yyyy-MM-dd HH-mm-ss" in local time.
    static func sessionName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }

    /// What try.json holds: what was in front of the camera, when, the try's score-log entry (outcome, scores,
    /// the glance with its flatness score, video effects), every analyzed frame, and the picture files.
    struct TryFile: Codable {
        var subject: String
        var savedAt: Date
        var record: ScoreRecord
        var glanceStart: Double?
        var decisionFrame: Int?
        var frames: [TestFrame]
        var pictures: [String]
    }

    /// Writes one try into `session` as the next `<NN-subject>` folder, numbered after the highest there, and
    /// returns that folder.
    @discardableResult
    func save(_ capture: TestCapture, record: ScoreRecord, subject: String, session: String,
              date: Date = Date()) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = folder
        try marked.setResourceValues(values)
        let sessionFolder = folder.appendingPathComponent(session, isDirectory: true)
        try manager.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        let taken = try manager.contentsOfDirectory(atPath: sessionFolder.path).compactMap { name in
            name.split(separator: "-").first.flatMap { Int($0) }
        }
        let number = (taken.max() ?? 0) + 1
        let tryFolder = sessionFolder.appendingPathComponent(String(format: "%02d-%@", number, subject), isDirectory: true)
        try manager.createDirectory(at: tryFolder, withIntermediateDirectories: false)
        let file = TryFile(subject: subject, savedAt: date, record: record, glanceStart: capture.glanceStart,
                           decisionFrame: capture.decisionFrame, frames: capture.frames,
                           pictures: capture.pictures.keys.sorted())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // try.json first: a save cut short still leaves a folder that is counted, so Delete Test Pictures shows.
        try encoder.encode(file).write(to: tryFolder.appendingPathComponent(Self.tryFile))
        for (name, data) in capture.pictures { try data.write(to: tryFolder.appendingPathComponent(name)) }
        return tryFolder
    }

    /// Tries saved, over every window folder.
    func count() -> Int {
        let manager = FileManager.default
        let sessions = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return sessions.reduce(0) { total, session in
            let tries = (try? manager.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
            return total + tries.filter { manager.fileExists(atPath: $0.appendingPathComponent(Self.tryFile).path) }.count
        }
    }

    /// Removes the whole Test Pictures folder.
    func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }
}
