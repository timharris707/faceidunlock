# MiniFASNet photo/screen detector: conversion and app contract

Converted and independently verified 2026-10-30 (workflow `wf_8988a8c3-b64`, Claude Opus 5.5 via Claude Code). Use: watch-only liveness score (decision L3). Upstream minivision-ai/Silent-Face-Anti-Spoofing at commit b6d5f04ad78778917853b25c778acef6d5626d15, Apache-2.0 (code and weights). Core ML matches PyTorch within 3.2e-6 (27 inputs) and 1.9e-6 (3 samples, all labels correct); independent re-check within 9.5e-7 on 30 fresh inputs. About 0.8-0.9 ms per call on the M5 Max. Getting channel order wrong is severe: fed RGB instead of BGR, a printed photo scores 0.94 real.

Known limits: the score jumps with 1-pixel box changes, so judge it across frames. Vision boxes differ from the RetinaFace boxes it was trained with. Pure noise scores about 0.99 real, so score only frames with a face. At laptop distance the 2.7 and 4.0 crops are often identical.


`MiniFASNet.mlpackage` runs both upstream Silent-Face-Anti-Spoofing models in one call: MiniFASNetV2 on a 2.7× face crop and MiniFASNetV1SE on a 4.0× face crop. This page is what the Swift app must do to feed it the same pixels the upstream `test.py` feeds the PyTorch models. Every rule below is taken from the pinned upstream source (revision `b6d5f04ad78778917853b25c778acef6d5626d15`): `src/generate_patches.py` (crop box), `src/anti_spoof_predict.py` (detector box, softmax), `src/data_io/functional.py` (`to_tensor`), and `test.py` (averaging).

## App contract

| Field | Required value |
|---|---|
| Model type | Core ML ML Program, float32; minimum macOS 13 |
| Input names | `crop27` (2.7× crop) and `crop40` (4.0× crop) |
| Input type and shape | Float32 multi-array `[1, 3, 80, 80]` each, NCHW |
| Channels | B, G, R: channel 0 = blue, 1 = green, 2 = red |
| Values | Raw 8-bit pixel values `0...255` as floats. Do not divide by 255, subtract a mean or scale. Upstream's `to_tensor` has `div(255)` commented out, in both inference and training. |
| Source frame | The upright, unmirrored analysis frame Vision boxed (the app's 1280 × 720 BGRA buffer, orientation `.up`) |
| Crop | Step 2 below, per scale; inclusive pixel box, no padding |
| Resize | Whole crop to exactly 80 × 80 (aspect ratio is not kept); bilinear with half-pixel centres, edge-clamped, no antialiasing (OpenCV `INTER_LINEAR`); round to whole numbers |
| Output `real` | Float32 `[1]`: `(probs27[1] + probs40[1]) / 2`, the mean real-face probability |
| Outputs `probs27`, `probs40` | Float32 `[1, 3]` softmax per model. Index 1 is real; 0 and 2 are spoof classes the upstream repository does not name |
| Upstream verdict | `argmax(probs27 + probs40) == 1` means real. This is not the same test as `real > 0.5`. |

## Step 1: face box in pixels

The crop needs a face box `x, y, w, h` as integers, in pixels, top-left origin. Upstream gets it from its RetinaFace detector as `[int(left), int(top), int(right - left + 1), int(bottom - top + 1)]`, where `int` truncates toward zero.

From a Vision `boundingBox` (normalized, bottom-left origin) on a `W × H` frame, the equivalent is:

```text
left   = minX * W            top    = (1 - maxY) * H
right  = maxX * W            bottom = (1 - minY) * H
x = Int(left)   y = Int(top)   w = Int(right - left + 1)   h = Int(bottom - top + 1)
```

Vision's box is not RetinaFace's box. Vision returns a square. On the three upstream samples its side was 14–17 % shorter than RetinaFace's width and height (real face) to 5–6 % longer (screen), and its centre was up to 34 px off horizontally (turned face). See Known limits.

## Step 2: crop box for each scale

Run this once with `s = 2.7` (for `crop27`) and once with `s = 4.0` (for `crop40`). Use `Double`, this operation order, and the checks in this order; Swift `Double` matches Python's float bit for bit when the order is the same. `W`, `H` are the frame width and height.

```swift
let scale = min(Double(H - 1) / Double(h), min(Double(W - 1) / Double(w), s))
let newWidth = Double(w) * scale, newHeight = Double(h) * scale
let centerX = Double(w) / 2 + Double(x), centerY = Double(h) / 2 + Double(y)
var left = centerX - newWidth / 2, top = centerY - newHeight / 2
var right = centerX + newWidth / 2, bottom = centerY + newHeight / 2
if left < 0 { right -= left; left = 0 }
if top < 0 { bottom -= top; top = 0 }
if right > Double(W - 1) { left -= right - Double(W) + 1; right = Double(W - 1) }
if bottom > Double(H - 1) { top -= bottom - Double(H) + 1; bottom = Double(H - 1) }
let box = (left: Int(left), top: Int(top), right: Int(right), bottom: Int(bottom))  // truncate, never round
```

The crop is columns `box.left...box.right` and rows `box.top...box.bottom`, both inclusive, so it is `right - left + 1` pixels wide.

How edges behave:

- The box keeps the face box's centre and aspect ratio and is never padded. A box that runs off one side slides back inside the frame.
- When `s × h` would exceed `H − 1` (or `s × w` would exceed `W − 1`), the scale shrinks to fit instead. On a 720-pixel-high frame this happens for `crop27` once the face box is taller than 266 px and for `crop40` once it is taller than 179 px. When both scales shrink to the same value, `crop27` and `crop40` are the same pixels. Upstream behaves this way; do not "fix" it.

## Step 3: resize to 80 × 80

For a crop `P` of `cw × ch` pixels, compute each output column `j` in `0..<80` like this, and each output row the same way with `ch`:

```text
f  = (j + 0.5) * cw / 80 - 0.5
x0 = floor(f);  a = f - x0
if x0 < 0       { x0 = 0;      a = 0 }
if x0 >= cw - 1 { x0 = cw - 1; a = 0 }
x1 = min(x0 + 1, cw - 1)
out = (1 - b) * ((1 - a) * P[y0][x0] + a * P[y0][x1]) + b * ((1 - a) * P[y1][x0] + a * P[y1][x1])
```

Here `y0, y1, b` come from the row computation. Do this per channel and round each result to the nearest whole number; upstream's `cv2.resize` returns 8-bit values. This formula, rounded, matched OpenCV within 1 on every pixel of the six sample crops, with 87–90 % of pixels identical. The rest is OpenCV's 11-bit fixed-point weights.

Do not use an antialiasing or area-averaging scaler (vImage scale, Core Image Lanczos, Core Graphics high-quality interpolation). With area averaging, the upstream screen-replay sample's `real` went from 0.181 to 0.054 and the real sample's from 0.995 to 0.978.

## Step 4: fill the inputs

For the app's `kCVPixelFormatType_32BGRA` buffer, pixel bytes are B, G, R, A. Ignore A and step rows by `bytesPerRow`, not `4 × width`. Write the resized value for channel `c` (0 = B, 1 = G, 2 = R), row `r` and column `q` to flat index `(c * 80 + r) * 80 + q` of a Float32 `MLMultiArray` shaped `[1, 3, 80, 80]`. Fill `crop27` and `crop40` from their own crop boxes, then call the model once.

## Step 5: read the outputs

Log `real`, `probs27` and `probs40`. `real` is upstream's score for the real class. Upstream's demo shows `argmax(probs27 + probs40)` and half that class's summed probability. Its Android APK calls a face real when that confidence is above a user-set threshold. No threshold is chosen here; in watch-only mode the score blocks nothing.

## Worked example

Frame 1280 × 720, face box `x = 500, y = 200, w = 240, h = 280`.

| Quantity | `crop27` (s = 2.7) | `crop40` (s = 4.0) |
|---|---|---|
| `(H − 1) / h` = 719 / 280 | 2.567857142857143 | 2.567857142857143 |
| `(W − 1) / w` = 1279 / 240 | 5.329166666666667 | 5.329166666666667 |
| scale used | 2.567857142857143 (height-limited) | 2.567857142857143 (height-limited) |
| new width × height | 616.2857142857143 × 719.0 | same |
| centre | (620.0, 340.0) | same |
| left, top, right, bottom before edges | 311.857…, −19.5, 928.142…, 699.5 | same |
| `top < 0`: shift down by 19.5 | top 0, bottom 719.0 | same |
| `right > 1279`? `bottom > 719`? | no, no | no, no |
| inclusive box (left, top, right, bottom) | (311, 0, 928, 719) | (311, 0, 928, 719) |
| crop size, then resized to 80 × 80 | 618 × 720 | 618 × 720 |

At this size the face is too tall for either scale, so both inputs are the same crop. A smaller face in the same frame, `x = 590, y = 300, w = 100, h = 120`, keeps both scales: `crop27` = (505, 198, 775, 522), 271 × 325, and `crop40` = (440, 120, 840, 600), 401 × 481.

## Test vectors for the crop box

All on a 1280 × 720 frame; boxes are inclusive (left, top, right, bottom). They come from the transcribed upstream function and are stored in `MiniFASNet-verification.json` under `crop_box_examples`.

| Face box x, y, w, h | `crop27` box | scale | `crop40` box | scale |
|---|---|---|---|---|
| 500, 200, 240, 280 | 311, 0, 928, 719 | 2.567857 | 311, 0, 928, 719 | 2.567857 |
| 590, 300, 100, 120 | 505, 198, 775, 522 | 2.7 | 440, 120, 840, 600 | 4.0 |
| 10, 250, 150, 180 (left edge) | 0, 96, 405, 583 | 2.7 | 0, 0, 599, 719 | 3.994444 |
| 1100, 560, 150, 150 (bottom-right) | 874, 314, 1279, 719 | 2.7 | 679, 119, 1279, 719 | 4.0 |
| 600, 5, 120, 140 (top edge) | 498, 0, 822, 378 | 2.7 | 420, 0, 900, 560 | 4.0 |

## Known limits (measured)

- **The score is sensitive to small preprocessing differences.** Moving the detector box by one pixel (all 81 combinations of ±1 on x, y, w, h) moved `real` from 0.040 to 0.084 on the printed-photo sample and from 0.103 to 0.226 on the screen sample. On the real-face sample it stayed between 0.990 and 0.996, and no shift changed any sample's verdict. Per-frame scores will jitter, so compare scores across many frames.
- **Vision boxes are not the boxes the model was trained with.** On the three samples, using the Vision revision 3 box (step 1) instead of RetinaFace's changed `real` from 0.084 to 0.036 (printed photo), 0.181 to 0.209 (screen) and 0.995 to 0.979 (real face). All three verdicts held, but three images cannot calibrate the difference. See `vision-box-check.json`.
- **The score only means something when a face is in the crop.** All 24 seeded random-noise inputs scored between 0.985 and 0.998 real. All-black scored 0.018.
- **The upstream samples are 480 × 640 portrait phone frames**, and upstream `test.py` rejects anything but 3:4 portrait. The Mac camera gives 16:9 landscape. The crop rule is the same either way, but the camera, lighting and framing differ from the training data, which upstream says matters.
- **Mirroring:** upstream trained with random horizontal flips, so it should not matter whether the frame is mirrored. Still, feed the unmirrored analysis frame that Vision boxed, so the box and pixels agree.

## In the app

Built 2026-10-30 (decision L3, watch-only; Claude Opus 5.5 via Claude Code). The score is written to the score log and shown only in the hidden Home Test window's result line; checks, setup, fills, misses and the daily screens behave exactly as without it.

- `Sources/FaceIDCore/PhotoScreenCrop.swift`: steps 1–4 as plain arithmetic (box conversion, crop box, resize straight from the BGRA buffer into the blue, green, red planes). Rounds half up, as OpenCV does.
- `Sources/FaceIDUnlock/PhotoScreenDetector.swift`: loads and checks the model, reuses its two input arrays, returns `real`, `probs27` and `probs40` (`PhotoScreenScore`), or nil if anything fails.
- `Sources/FaceIDUnlock/FaceEngine.swift`: `prepare()` loads `MiniFASNet.mlmodelc` from the app bundle after SFace. If it won't load, it is left out and nothing else changes. `analyze` sets `FaceObservation.photoScreen` only for `.face` frames, from the same buffer and the same revision 3 box.
- `FaceCheck` and `FaceSetupCollector` keep the score for the frames (checks) and kept samples (setup) whose match scores they already record. `ScoreRecord` logs them as `realScores`, `probs27` and `probs40` (step 5), one entry per frame or sample, rounded to 3 decimals, so upstream's own verdict and each model's vote can be worked out later. The fields are left out when there are none.
- `scripts/build-app.sh` compiles `MiniFASNet.mlpackage` into the bundle next to SFace.

Tests: `Tests/FaceIDCoreTests/PhotoScreenCropTests.swift` covers step 1 on the three Vision boxes in `vision-box-check.json`, step 2 on every `crop_box_examples` row, and step 3 on small hand-checked images (edges, rounding, channel order, `bytesPerRow`). The parity test, `Tests/FaceIDUnlockTests/PhotoScreenDetectorTests.swift`, loads the three upstream samples (`Tests/FaceIDUnlockTests/Fixtures/MiniFASNet`, SHA-256 checked against `pinned_sha256`) with ImageIO, applying EXIF orientation 6 so they are 480 × 640, and draws them into a BGRA buffer. It then runs Vision and the app's own code.

| Sample | Upstream `real` (Vision box) | App, upstream's box | App, its own Vision box | Its own Vision box vs evidence |
|---|---|---|---|---|
| F1 printed photo | 0.0358 | 0.0338 | 0.0338 | 154, 146, 207, 207 vs 150, 145, 210, 210 |
| F2 screen | 0.2085 | 0.1902 | 0.1902 | 107, 251, 270, 270 vs 108, 252, 268, 268 |
| T1 real face | 0.9790 | 0.9760 | 0.9987 | 139, 170, 171, 171 vs 134, 162, 178, 178 |

The gap comes from the JPEG decoder, not the preprocessing. Fed the pixels OpenCV decoded during verification, with upstream's boxes, the same Swift code gave 0.035810534, 0.20854908 and 0.97901, equal to the Python scores to 7 digits. ImageIO's decode differs from OpenCV's by 0.16–0.25 levels on average and up to 26 levels. Vision's box also moves with tiny input changes: the same pixels passed as an image or as a pixel buffer moved it by up to 7 px. Tolerances: with upstream's box, 0.04 on `real` (decoding alone moved it up to 0.018). With the app's own Vision box, 12 px on the box and only which side of 0.5 `real` falls on: for these 480 × 640 frames only the crop's top row depends on the box, and one row moves the screen sample from 0.190 to 0.122 (up) or 0.248 (down), while the app's box for it is within 0.1 px of rounding to another row. A closer check would fail on another Mac or after a macOS update with correct code. Both legs fail with red, green, blue order (printed photo 0.87, screen 1.00); dividing by 255 fails the first leg (screen 0.014, real face 0.015) and the real face on the second (0.015). `testEachCropGoesToItsOwnModelInput` centres the real-face sample on a 1280 × 720 frame, where the two crops differ, and checks both models' outputs against a direct model call; with the crops swapped they are about 1.0 off.

Cost per frame, M5 Max, release build: 0.79 ms median (0.84 ms at the 95th percentile) for both crops plus the model call. The crops and resizes take 0.036 ms of that. A debug build takes about 4.8 ms.
