# SFace conversion verification

The native model is `Resources/SFace.mlpackage`, compiled by the app build into `SFace.mlmodelc`. Conversion and numerical verification completed on an Apple Silicon Mac with macOS 27.0, Python 3.12.13. No paid inference API, camera, credentials, or personal photos were used.

## Provenance and license

- Official OpenCV Zoo revision: [`47534e27c9851bb1128ccc0102f1145e27f23f98`](https://github.com/opencv/opencv_zoo/tree/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_recognition_sface).
- Source: `face_recognition_sface_2021dec.onnx`, opset 11.
- SHA-256: `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79`.
- Apache 2.0 license and attribution are bundled in `Resources/ThirdParty/SFace-LICENSE` and `SFace-NOTICE.md`.
- Exact conversion dependencies are pinned in `Resources/ThirdParty/SFace-conversion-requirements.txt`. Main tools: coremltools 9.0, torch 2.7.0, onnx 1.18.0, onnxruntime 1.22.0, numpy 2.5.3.
- Per-file package checksums, machine information, thresholds, and every measured result are in `Resources/ThirdParty/SFace-verification.json`.

## App contract

| Field | Required value |
|---|---|
| Model type | Core ML ML Program, float32; minimum macOS 13 |
| Input name | `image` |
| Input type and shape | Float32 multi-array `[1, 3, 112, 112]`, NCHW |
| Channels | RGB, each value in `0...255` |
| Geometry | Upright face aligned to the five-point 112 × 112 SFace template |
| Output name | `embedding` |
| Output type and shape | Float32 multi-array `[1, 128]` |
| Matching | L2-normalize the output before cosine similarity |

Do not divide by 255 or normalize the input in app code. The graph's first two nodes already compute `(image − 127.5) × 0.0078125`, or `(image − 127.5) / 128`.

This agrees with the official [`FaceRecognizerSF::feature` implementation](https://github.com/opencv/opencv/blob/4.12.0/modules/objdetect/src/face_recognize.cpp#L56): `blobFromImage` uses scale 1, zero mean, 112 × 112, and swaps the BGR input to RGB. The [Zoo Python wrapper](https://github.com/opencv/opencv_zoo/blob/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_recognition_sface/sface.py) delegates to this implementation. OpenCV `match` L2-normalizes the output before cosine matching.

The alignment destination coordinates, in top-left image coordinates and left-to-right feature order, are:

```text
left image eye:    (38.2946, 51.6963)
right image eye:   (73.5318, 51.5014)
nose:             (56.0252, 71.7366)
left image mouth: (41.5493, 92.3655)
right image mouth:(70.7299, 92.2041)
```

## Conversion and checks

`scripts/convert-sface.py` loads the source only after verifying its exact SHA-256. It maps the eight observed operation types directly into PyTorch: Sub, Mul, Conv, BatchNormalization, PRelu, inference Dropout (identity), Flatten, and Gemm. It retains the original weights, convolution parameters, batch-normalization epsilon values, and internal input normalization. The traced inference module converts with float32 precision and macOS 13 as the deployment target.

Twelve deterministic synthetic inputs cover black, white, midgray, distinct RGB spatial gradients, and eight seeded uniform noise images. Each is evaluated in the original ONNX Runtime CPU engine and compared with PyTorch, native Core ML CPU-only, and native Core ML with all compute units permitted: **36 comparisons passed**.

- Largest cosine drift across the 36 comparisons: **5.783 × 10⁻¹⁰**.
- Largest relative L2 output error: **3.423 × 10⁻⁵**.
- Required PyTorch relative L2 error: below `1e-4`.
- Required native Core ML relative L2 error: below `1e-3`; cosine drift: below `1e-6`.
- Every result must have shape `[1,128]` and contain only finite values.
- Native model input and output names/shapes are asserted during verification.

These checks validate conversion fidelity and the model schema. They do not establish camera alignment quality, face matching accuracy, spoof resistance, or a safe authentication threshold. No public face-photo fixture was used; the fixtures are generated from code and carry no personal data.

Rebuild and verify, on macOS with Python 3.12 installed:

```sh
./scripts/prepare-model.sh
```

Repeat the regression check on the existing package without conversion:

```sh
./scripts/prepare-model.sh --verify-only
```

Both commands check the source digest, use the pinned development environment under ignored `.model-tools`, and fail if numerical thresholds are exceeded. The latter refreshes the machine-specific verification JSON; it does not change the model package.
