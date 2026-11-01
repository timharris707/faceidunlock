import CoreVideo
import FaceIDCore
import ImageIO
import XCTest
@testable import FaceIDUnlock

/// Home Test pictures on made-up camera frames, written to a temporary folder only.
@MainActor
final class TestPicturesTests: XCTestCase {
    private var folder: URL!
    private let face = FaceGallery(samples: [.init(pose: .center, embedding: [1] + Array(repeating: 0, count: 127))])
    /// Scores 0.6 against `face`.
    private let look: [Float] = [0.6, 0.8] + Array(repeating: 0, count: 126)
    private let box = PhotoScreenCrop.FaceBox(x: 540, y: 220, width: 200, height: 260)
    private let points = FacePoints(leftEye: [600, 300], rightEye: [680, 300], nose: [640, 350], leftMouth: [608, 380],
                                    rightMouth: [672, 380])

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TestPicturesTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A 1280x720 BGRA frame of one colour, like the camera's.
    private func frame(blue: UInt8 = 10, green: UInt8 = 20, red: UInt8 = 200) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, nil, &created),
                       kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        paint(buffer, blue: blue, green: green, red: red)
        return buffer
    }

    private func paint(_ buffer: CVPixelBuffer, blue: UInt8, green: UInt8, red: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<720 {
            for column in 0..<1280 {
                let pixel = base + row * rowBytes + column * 4
                (pixel[0], pixel[1], pixel[2], pixel[3]) = (blue, green, red, 255)
            }
        }
    }

    private func observation(_ time: TimeInterval, kind: FaceObservation.Kind = .face, yaw: Double = 0.1) -> FaceObservation {
        guard kind == .face else { return FaceObservation(kind: kind, timestamp: time) }
        return FaceObservation(kind: .face, timestamp: time, embedding: look, yaw: yaw, roll: -0.02, quality: 0.5,
                               photoScreen: PhotoScreenScore(real: 0.9712, probs27: [0.02, 0.97, 0.01],
                                                             probs40: [0.03, 0.96, 0.01]),
                               points: points, faceBox: box)
    }

    /// Width and height of a saved picture, and its middle pixel's red, green and blue.
    private func picture(_ url: URL) throws -> (width: Int, height: Int, rgb: [Int]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.lastPathComponent)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return (image.width, image.height, pixel[0..<3].map(Int.init))
    }

    /// A real check's score-log entry: three matching frames, then a glance left whose nose moved 12 px against the
    /// face (flatness 0.15).
    private func record() -> ScoreRecord {
        var check = FaceCheck(gallery: face, startedAt: 0)
        for time in [0.0, 0.5, 0.6, 0.7] {
            check.observe(FaceObservation(kind: .face, timestamp: time, embedding: face.samples[0].embedding, yaw: 0,
                                          points: points), exposureSettled: true)
        }
        var glance = GlanceCheck(direction: .left, restingYaw: check.restingYaw, restingPoints: check.restingPoints,
                                 gallery: face, startedAt: 1)
        var turned = points
        turned.nose.x += 12
        glance.observe(FaceObservation(kind: .face, timestamp: 1.5, embedding: face.samples[0].embedding,
                                       yaw: MatchSettings.leftYawSign * 0.3, points: turned))
        var result = check.record
        result.glance = glance.record
        var entry = ScoreRecord(homeTest: result, subject: "phonePhoto", letIn: true, date: Date())
        entry.effects = VideoEffects(portrait: false, studioLight: false, centerStage: true)
        return entry
    }

    /// Every key in a JSON value, at any depth.
    private func keys(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return Set(object.keys).union(object.values.flatMap { keys($0) })
        }
        return (value as? [Any])?.reduce(into: Set<String>()) { $0.formUnion(keys($1)) } ?? []
    }

    func testATryIsSavedAsItsPicturesAndNumbersWithNoFaceData() async throws {
        let recorder = TestPictureRecorder(gallery: face, startedAt: 100)
        let camera = try frame()
        // A check that ends on a frame with no face, as a photo's timeout often does.
        for (index, time) in [100.2, 100.25, 100.3].enumerated() {
            recorder.add(camera, observation(time, kind: index == 2 ? .noFace : .face))
        }
        recorder.glanceStarted(at: 100.35)
        for (time, yaw) in [(100.4, 0.2), (100.45, 0.3), (100.5, 0.35)] { recorder.add(camera, observation(time, yaw: yaw)) }
        let capture = await recorder.finish()

        let tryFolder = try TestPictures(folder: folder).save(capture, record: record(), subject: "phonePhoto",
                                                                  session: "2026-10-30 22-15-00")
        XCTAssertEqual(tryFolder.path, folder.appendingPathComponent("2026-10-30 22-15-00/01-phonePhoto").path)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: tryFolder.path)),
                       ["frame.jpg", "detector-2.7x.png", "detector-4.0x.png", "face-224.png", "glance-001.jpg",
                        "glance-002.jpg", "glance-003.jpg", "try.json"])
        let full = try picture(tryFolder.appendingPathComponent("frame.jpg"))
        XCTAssertEqual([full.width, full.height], [1280, 720])
        for crop in ["detector-2.7x.png", "detector-4.0x.png"] {
            let detector = try picture(tryFolder.appendingPathComponent(crop))
            XCTAssertEqual([detector.width, detector.height], [80, 80], crop)
            XCTAssertEqual(detector.rgb, [200, 20, 10], "\(crop): the detector's own pixels, colours in the right order")
        }
        let wide = try picture(tryFolder.appendingPathComponent("face-224.png"))
        XCTAssertEqual([wide.width, wide.height], [224, 224])
        let glance = try picture(tryFolder.appendingPathComponent("glance-002.jpg"))
        XCTAssertEqual([glance.width, glance.height], [640, 360], "At most 640 px wide")
        XCTAssertEqual(Double(glance.rgb[0]), 200, accuracy: 6)

        let data = try Data(contentsOf: tryFolder.appendingPathComponent("try.json"))
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(file.keys), ["subject", "savedAt", "record", "glanceStart", "decisionFrame", "frames", "pictures"])
        XCTAssertEqual(file["subject"] as? String, "phonePhoto")
        XCTAssertEqual(file["glanceStart"] as? Double, 0.35)
        XCTAssertEqual(file["decisionFrame"] as? Int, 1, "The face check's last frame that showed a face")
        let logged = try XCTUnwrap(file["record"] as? [String: Any])
        XCTAssertEqual((logged["glance"] as? [String: Any])?["outcome"] as? String, "passed")
        XCTAssertEqual((logged["glance"] as? [String: Any])?["flatness"] as? Double, 0.15)
        XCTAssertEqual(logged["effects"] as? [String: Bool], ["portrait": false, "studioLight": false, "centerStage": true])
        let frames = try XCTUnwrap(file["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.map { $0["stage"] as? String }, ["check", "check", "check", "glance", "glance", "glance"])
        XCTAssertEqual(frames.map { $0["picture"] as? String }, [nil, nil, nil, "glance-001.jpg", "glance-002.jpg", "glance-003.jpg"])
        XCTAssertEqual(Set(frames[0].keys), ["time", "stage", "kind", "match", "real", "probs27", "probs40", "yaw", "roll",
                                             "points", "faceBox"])
        XCTAssertEqual(frames[2]["kind"] as? String, "noFace")
        XCTAssertEqual(frames[0]["time"] as? Double, 0.2)
        XCTAssertEqual(frames[0]["match"] as? Double, 0.6)
        XCTAssertEqual(frames[0]["real"] as? Double, 0.971)
        XCTAssertEqual(frames[4]["yaw"] as? Double, 0.3)
        XCTAssertEqual((frames[0]["points"] as? [String: [Double]])?["nose"], [640, 350])
        XCTAssertEqual((frames[0]["faceBox"] as? [String: Int])?["width"], 200)
        // Nothing that could rebuild the face or unlock anything.
        XCTAssertTrue(keys(file).allSatisfy { !$0.lowercased().contains("embedding") && !$0.lowercased().contains("password") },
                      "\(keys(file))")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("0.8"), "The embedding's other value is nowhere")
    }

    func testGlanceFramesAreCopiedAtOnceSoTheCameraBufferGoesBack() async throws {
        let recorder = TestPictureRecorder(gallery: face, startedAt: 0)
        recorder.glanceStarted(at: 0)
        let camera = try frame(blue: 0, green: 0, red: 250)
        recorder.add(camera, observation(0.1))
        paint(camera, blue: 0, green: 0, red: 0) // The camera reuses its buffer for a later frame.
        let capture = await recorder.finish()
        try TestPictures(folder: folder).save(capture, record: record(), subject: "me", session: "s")
        let glance = try picture(folder.appendingPathComponent("s/01-me/glance-001.jpg"))
        XCTAssertEqual(Double(glance.rgb[0]), 250, accuracy: 6, "The picture is the frame as it was seen")
        XCTAssertNil(capture.decisionFrame, "No face check frames, so no full frame or crops")
        XCTAssertNil(capture.pictures["frame.jpg"])
    }

    func testTriesAreNumberedCountedExcludedFromBackupAndDeletedTogether() throws {
        let pictures = TestPictures(folder: folder)
        XCTAssertEqual(pictures.count(), 0)
        XCTAssertNoThrow(try pictures.deleteAll(), "Nothing to delete is fine")
        let empty = TestCapture(frames: [], pictures: [:])
        try pictures.save(empty, record: record(), subject: "me", session: "one")
        // Finder's own file in the folder doesn't throw the numbering off.
        try Data().write(to: folder.appendingPathComponent("one/.DS_Store"))
        try pictures.save(empty, record: record(), subject: "printedPhoto", session: "one")
        try pictures.save(empty, record: record(), subject: "me", session: "two")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("one").path)),
                       [".DS_Store", "01-me", "02-printedPhoto"])
        XCTAssertEqual(pictures.count(), 3)
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // Past 99 tries in one window (the bake-off is about 170), the whole number counts.
        for name in ["99-me", "100-me"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("long/\(name)"),
                                                    withIntermediateDirectories: true)
        }
        XCTAssertEqual(try pictures.save(empty, record: record(), subject: "me", session: "long").lastPathComponent, "101-me")

        try pictures.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(pictures.count(), 0)
    }

    func testPicturesLiveInApplicationSupportInFoldersNamedByTime() throws {
        XCTAssertTrue(TestPictures.defaultFolder.path.hasSuffix("Library/Application Support/Face ID Unlock/Test Pictures"))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertFalse(TestPictures.defaultFolder.path.hasPrefix(repo.path), "Never inside the repo")
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 22,
                                                                             minute: 5, second: 9)))
        XCTAssertEqual(TestPictures.sessionName(for: date), "2026-10-30 22-05-09")
    }
}
