import CoreGraphics
import XCTest
@testable import FaceIDCore

/// The photo/screen detector's preprocessing against docs/verification/minifasnet-model.md.
final class PhotoScreenCropTests: XCTestCase {
    private typealias Box = PhotoScreenCrop.CropBox

    // MARK: Step 1

    func testVisionBoxBecomesTruncatedTopLeftPixels() {
        // 0.25...0.75 across and 0.25...0.625 up on 1280x720: left 320, right 960, top 270, bottom 540.
        let box = PhotoScreenCrop.faceBox(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.375), width: 1280, height: 720)
        XCTAssertEqual(box, PhotoScreenCrop.FaceBox(x: 320, y: 270, width: 641, height: 271))
    }

    func testVisionBoxesOfTheUpstreamSamplesMatchTheEvidence() throws {
        // vision-box-check.json: Vision's raw top-left boxes on the 480x640 samples and the integers step 1 gives.
        let rows: [([Double], [Int])] = [
            ([150.17470836639404, 145.42537689208984, 209.32442665100098, 209.32443618774414], [150, 145, 210, 210]),
            ([108.54979991912842, 252.52479553222656, 267.2072696685791, 267.20727920532227], [108, 252, 268, 268]),
            ([134.5580005645752, 162.24050521850586, 177.3358154296875, 177.3358154296875], [134, 162, 178, 178])
        ]
        for (raw, expected) in rows {
            let normalized = CGRect(x: raw[0] / 480, y: 1 - (raw[1] + raw[3]) / 640, width: raw[2] / 480, height: raw[3] / 640)
            let box = PhotoScreenCrop.faceBox(normalized, width: 480, height: 640)
            XCTAssertEqual([box.x, box.y, box.width, box.height], expected, "\(raw)")
        }
    }

    // MARK: Step 2

    func testWorkedExampleIsHeightLimitedAndBothScalesShareOneCrop() {
        let face = PhotoScreenCrop.FaceBox(x: 500, y: 200, width: 240, height: 280)
        for scale in [2.7, 4.0] {
            let crop = PhotoScreenCrop.cropBox(face, width: 1280, height: 720, scale: scale)
            XCTAssertEqual(crop, Box(left: 311, top: 0, right: 928, bottom: 719))
            XCTAssertEqual(crop.width, 618)
            XCTAssertEqual(crop.height, 720)
        }
        let small = PhotoScreenCrop.FaceBox(x: 590, y: 300, width: 100, height: 120)
        XCTAssertEqual(PhotoScreenCrop.cropBox(small, width: 1280, height: 720, scale: 2.7),
                       Box(left: 505, top: 198, right: 775, bottom: 522))
        XCTAssertEqual(PhotoScreenCrop.cropBox(small, width: 1280, height: 720, scale: 4.0),
                       Box(left: 440, top: 120, right: 840, bottom: 600))
    }

    func testEveryCropBoxExampleInTheVerificationFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "../../Resources/ThirdParty/MiniFASNet-verification.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let examples = try XCTUnwrap(json["crop_box_examples"] as? [[String: Any]])
        XCTAssertEqual(examples.count, 5, "The contract's table has five rows.")
        for example in examples {
            let name = example["name"] as? String ?? "?"
            let face = try XCTUnwrap(example["face_box_xywh"] as? [Int])
            let width = try XCTUnwrap(example["image_width"] as? Int), height = try XCTUnwrap(example["image_height"] as? Int)
            for (key, scale) in [("crop27", 2.7), ("crop40", 4.0)] {
                let expected = try XCTUnwrap(example[key] as? [String: Any])
                let edges = try XCTUnwrap(expected["left_top_right_bottom_inclusive"] as? [Int])
                let crop = PhotoScreenCrop.cropBox(PhotoScreenCrop.FaceBox(x: face[0], y: face[1], width: face[2], height: face[3]),
                                                   width: width, height: height, scale: scale)
                XCTAssertEqual([crop.left, crop.top, crop.right, crop.bottom], edges, "\(name) \(key)")
                XCTAssertEqual(crop.width, expected["width"] as? Int, "\(name) \(key)")
                XCTAssertEqual(crop.height, expected["height"] as? Int, "\(name) \(key)")
            }
        }
    }

    // MARK: Steps 3 and 4

    /// A BGRA image whose pixel (column, row) has the given blue, green and red, with 8 junk bytes per row
    /// after the last pixel so a fill that steps rows by 4 x width reads the wrong pixels.
    private struct Image {
        let width: Int, height: Int
        var bytesPerRow: Int { width * 4 + 8 }
        var bytes: [UInt8]

        init(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) {
            self.width = width
            self.height = height
            bytes = [UInt8](repeating: 99, count: (width * 4 + 8) * height)
            for row in 0..<height {
                for column in 0..<width {
                    let (blue, green, red) = pixel(column, row)
                    let offset = row * bytesPerRow + column * 4
                    (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]) = (blue, green, red, 7)
                }
            }
        }

        /// The resized crop as [channel][row][column].
        func resized(_ crop: Box, side: Int) -> [[[Float]]] {
            var input = [Float](repeating: -1, count: 3 * side * side)
            input.withUnsafeMutableBufferPointer { output in
                bytes.withUnsafeBufferPointer { pixels in
                    PhotoScreenCrop.fill(output.baseAddress!, from: pixels.baseAddress!, bytesPerRow: bytesPerRow,
                                         crop: crop, side: side)
                }
            }
            return (0..<3).map { c in (0..<side).map { r in Array(input[((c * side + r) * side)..<((c * side + r + 1) * side)]) } }
        }
    }

    func testUpscaleBlendsHalfPixelCentresClampsEdgesAndRoundsHalfUp() {
        // Two columns, 0 and 10, to four: centres at -0.25 (clamped), 0.25, 0.75, 1.25 (clamped).
        let image = Image(width: 2, height: 1) { column, _ in (column == 0 ? 0 : 10, 0, 0) }
        let blue = image.resized(Box(left: 0, top: 0, right: 1, bottom: 0), side: 4)[0]
        XCTAssertEqual(blue, Array(repeating: [0, 3, 8, 10], count: 4), "2.5 rounds to 3 and 7.5 to 8, as OpenCV does")
    }

    func testDownscaleAveragesNeighboursWithoutAntialiasing() {
        // Four columns to two: centres at 0.5 and 2.5, so each output is the mean of a pair, not of all four.
        let image = Image(width: 4, height: 1) { column, _ in ([10, 20, 30, 41][column], 0, 0) }
        XCTAssertEqual(image.resized(Box(left: 0, top: 0, right: 3, bottom: 0), side: 2)[0], [[15, 36], [15, 36]])
    }

    func testRowsBlendLikeColumns() {
        // Two rows, 0 and 100, to four rows; every column is the same.
        let image = Image(width: 3, height: 2) { _, row in (0, row == 0 ? 0 : 100, 0) }
        let green = image.resized(Box(left: 0, top: 0, right: 2, bottom: 1), side: 4)[1]
        XCTAssertEqual(green.map { $0[0] }, [0, 25, 75, 100])
        XCTAssertTrue(green.allSatisfy { Set($0).count == 1 })
    }

    func testPlanesAreBlueGreenRedFromTheCropSteppingRowsByBytesPerRow() {
        // Inside a 6x5 image, the 2x2 crop at columns 3...4, rows 1...2, resized to 2x2, is copied as is.
        let image = Image(width: 6, height: 5) { column, row in
            (UInt8(10 * row + column), UInt8(100 + 10 * row + column), UInt8(200 + 10 * row + column))
        }
        let planes = image.resized(Box(left: 3, top: 1, right: 4, bottom: 2), side: 2)
        XCTAssertEqual(planes[0], [[13, 14], [23, 24]], "Channel 0 is blue")
        XCTAssertEqual(planes[1], [[113, 114], [123, 124]], "Channel 1 is green")
        XCTAssertEqual(planes[2], [[213, 214], [223, 224]], "Channel 2 is red")
    }

    func testValuesStayRawZeroTo255() {
        let image = Image(width: 2, height: 2) { _, _ in (255, 128, 0) }
        let planes = image.resized(Box(left: 0, top: 0, right: 1, bottom: 1), side: PhotoScreenCrop.side)
        XCTAssertEqual(Set(planes[0].joined()), [255])
        XCTAssertEqual(Set(planes[1].joined()), [128])
        XCTAssertEqual(Set(planes[2].joined()), [0])
    }
}
