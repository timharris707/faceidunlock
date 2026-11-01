#!/usr/bin/env python3
"""Convert the pinned MiniFASNet anti-spoofing pair into one Core ML package, then verify it.

The network and crop code below is transcribed from minivision-ai/Silent-Face-Anti-Spoofing
(src/model_lib/MiniFASNet.py, src/generate_patches.py, src/anti_spoof_predict.py),
Copyright 2020 Minivision, Apache License 2.0. Modified: condensed (MiniFASNetSE became an
`se` flag, the per-stage channel lists a helper), unused classes dropped, and the two-model
pair with its softmax and real-class mean added. Layer names, shapes and arithmetic are
unchanged, so the original checkpoints load strictly. The downloaded repository's Python
files are only hashed and read by people; this script never imports or runs them.
Checkpoints load with weights_only=True.
"""
import argparse
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import platform
import subprocess
import time

import coremltools as ct
import cv2
import numpy as np
import torch
import torch.nn.functional as F
from torch.nn import (AdaptiveAvgPool2d, BatchNorm1d, BatchNorm2d, Conv2d, Linear, Module, PReLU, ReLU,
                      Sequential, Sigmoid)

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/minivision-ai/Silent-Face-Anti-Spoofing"
REVISION = "b6d5f04ad78778917853b25c778acef6d5626d15"
MODEL_27 = "resources/anti_spoof_models/2.7_80x80_MiniFASNetV2.pth"
MODEL_40 = "resources/anti_spoof_models/4_0_0_80x80_MiniFASNetV1SE.pth"
DETECTOR = ("resources/detection_model/deploy.prototxt", "resources/detection_model/Widerface-RetinaFace.caffemodel")
# Every source file this script reads or transcribes, with its SHA-256 at REVISION.
PINNED = {
    MODEL_27: "a5eb02e1843f19b5386b953cc4c9f011c3f985d0ee2bb9819eea9a142099bec0",
    MODEL_40: "84ee1d37d96894d5e82de5a57df044ef80a58be2b218b5ed7cdfd875ec2f5990",
    DETECTOR[0]: "9fe2f141b4baee039ed9442da2833e216af40a6ff3e639e7b39258812bcda808",
    DETECTOR[1]: "d08338a2c207df16a9c566f767fea67fb43ba6fff76ce11e938fe3fabefb9402",
    "LICENSE": "daf94bf1dc9cc5700fe5af2c7c0cbd1836e70d509ed78fd0bebef7432edee6fb",
    "images/sample/image_F1.jpg": "4b11b5d7a8a8e4a88f5f16a5426a0a7692e39e5bb45bb03b4ebe5e1606336860",
    "images/sample/image_F2.jpg": "fbbea73450ae9d9bb555c8ccac77bf39d234261fe3be4190e3ed2999690c485f",
    "images/sample/image_T1.jpg": "f4455149f488f76205fdee5499ec5261d08ef6279a1cff7b778ea85405331e94",
    "src/model_lib/MiniFASNet.py": "e498c4ec5e1ddfaba62b941a126c19d65aa564999f3309661fe43ee8bf38acd7",
    "src/generate_patches.py": "cd33552d5ca920088143daafceba3c19b7a64bf9aac125241803e1b4af698d65",
    "src/anti_spoof_predict.py": "ce95918e5a19895781877a1ac5c8d3b2d753579c1709664a0ea8f9259ce43f93",
    "src/data_io/functional.py": "8f779a775e01485800368e8a11104c49c8ba602629927e19ea223b74ff946898",
    "src/utility.py": "cff329a47f4f284465126b19adb080343942a2f2014e862dc85e1e7c2f9d1421",
    "test.py": "a6a6f053ac899b22607e7e9220742ce882aa4474e0395eebd5a502f3956b233b",
}
# Labels from the file names (F = fake, T = true face) and the verdicts upstream drew on
# images/sample/*_result.jpg with test.py: class name and the mean probability of that class.
SAMPLES = {"image_F1.jpg": ("spoof", "FakeFace", 0.73),
           "image_F2.jpg": ("spoof", "FakeFace", 0.82),
           "image_T1.jpg": ("real", "RealFace", 0.99)}
REAL_CLASS = 1
THRESHOLDS = {"pytorch_pair_vs_reference_path": 1e-6, "coreml_max_abs_probability_difference": 1e-4,
              "contract_resize_max_pixel_difference": 1}


# ---- Network, transcribed from src/model_lib/MiniFASNet.py (Apache-2.0, Copyright 2020 Minivision) ----
class Flatten(Module):
    def forward(self, input):
        return input.view(input.size(0), -1)


class Conv_block(Module):
    def __init__(self, in_c, out_c, kernel=(1, 1), stride=(1, 1), padding=(0, 0), groups=1):
        super().__init__()
        self.conv = Conv2d(in_c, out_c, kernel_size=kernel, groups=groups, stride=stride, padding=padding, bias=False)
        self.bn = BatchNorm2d(out_c)
        self.prelu = PReLU(out_c)

    def forward(self, x):
        return self.prelu(self.bn(self.conv(x)))


class Linear_block(Module):
    def __init__(self, in_c, out_c, kernel=(1, 1), stride=(1, 1), padding=(0, 0), groups=1):
        super().__init__()
        self.conv = Conv2d(in_c, out_channels=out_c, kernel_size=kernel, groups=groups, stride=stride,
                           padding=padding, bias=False)
        self.bn = BatchNorm2d(out_c)

    def forward(self, x):
        return self.bn(self.conv(x))


class Depth_Wise(Module):
    def __init__(self, c1, c2, c3, residual=False, kernel=(3, 3), stride=(2, 2), padding=(1, 1), groups=1):
        super().__init__()
        self.conv = Conv_block(c1[0], out_c=c1[1], kernel=(1, 1), padding=(0, 0), stride=(1, 1))
        self.conv_dw = Conv_block(c2[0], c2[1], groups=c2[0], kernel=kernel, padding=padding, stride=stride)
        self.project = Linear_block(c3[0], c3[1], kernel=(1, 1), padding=(0, 0), stride=(1, 1))
        self.residual = residual

    def forward(self, x):
        y = self.project(self.conv_dw(self.conv(x)))
        return x + y if self.residual else y


class Residual(Module):
    def __init__(self, c1, c2, c3, num_block, groups, kernel=(3, 3), stride=(1, 1), padding=(1, 1)):
        super().__init__()
        self.model = Sequential(*[Depth_Wise(c1[i], c2[i], c3[i], residual=True, kernel=kernel, padding=padding,
                                             stride=stride, groups=groups) for i in range(num_block)])

    def forward(self, x):
        return self.model(x)


class SEModule(Module):
    def __init__(self, channels, reduction):
        super().__init__()
        self.avg_pool = AdaptiveAvgPool2d(1)
        self.fc1 = Conv2d(channels, channels // reduction, kernel_size=1, padding=0, bias=False)
        self.bn1 = BatchNorm2d(channels // reduction)
        self.relu = ReLU()  # upstream uses inplace=True; same values
        self.fc2 = Conv2d(channels // reduction, channels, kernel_size=1, padding=0, bias=False)
        self.bn2 = BatchNorm2d(channels)
        self.sigmoid = Sigmoid()

    def forward(self, x):
        w = self.sigmoid(self.bn2(self.fc2(self.relu(self.bn1(self.fc1(self.avg_pool(x)))))))
        return x * w


class Depth_Wise_SE(Module):
    def __init__(self, c1, c2, c3, residual=False, kernel=(3, 3), stride=(2, 2), padding=(1, 1), groups=1,
                 se_reduct=8):
        super().__init__()
        self.conv = Conv_block(c1[0], out_c=c1[1], kernel=(1, 1), padding=(0, 0), stride=(1, 1))
        self.conv_dw = Conv_block(c2[0], c2[1], groups=c2[0], kernel=kernel, padding=padding, stride=stride)
        self.project = Linear_block(c3[0], c3[1], kernel=(1, 1), padding=(0, 0), stride=(1, 1))
        self.residual = residual
        self.se_module = SEModule(c3[1], se_reduct)

    def forward(self, x):
        y = self.project(self.conv_dw(self.conv(x)))
        return x + self.se_module(y) if self.residual else y


class ResidualSE(Module):
    def __init__(self, c1, c2, c3, num_block, groups, kernel=(3, 3), stride=(1, 1), padding=(1, 1), se_reduct=4):
        super().__init__()
        blocks = []
        for i in range(num_block):
            block = Depth_Wise_SE if i == num_block - 1 else Depth_Wise
            extra = {"se_reduct": se_reduct} if i == num_block - 1 else {}
            blocks.append(block(c1[i], c2[i], c3[i], residual=True, kernel=kernel, padding=padding, stride=stride,
                                groups=groups, **extra))
        self.model = Sequential(*blocks)

    def forward(self, x):
        return self.model(x)


def stage_channels(keep, first, count):
    """The (in, out) channel pairs of one stage, indexed into keep exactly as upstream writes them out."""
    starts = [first + 3 * i for i in range(count)]
    return ([(keep[s], keep[s + 1]) for s in starts], [(keep[s + 1], keep[s + 2]) for s in starts],
            [(keep[s + 2], keep[s + 3]) for s in starts])


class MiniFASNet(Module):
    def __init__(self, keep, embedding_size, conv6_kernel=(7, 7), drop_p=0.0, num_classes=3, img_channel=3,
                 se=False):
        super().__init__()
        self.embedding_size = embedding_size
        residual = ResidualSE if se else Residual
        self.conv1 = Conv_block(img_channel, keep[0], kernel=(3, 3), stride=(2, 2), padding=(1, 1))
        self.conv2_dw = Conv_block(keep[0], keep[1], kernel=(3, 3), stride=(1, 1), padding=(1, 1), groups=keep[1])
        self.conv_23 = Depth_Wise((keep[1], keep[2]), (keep[2], keep[3]), (keep[3], keep[4]),
                                  kernel=(3, 3), stride=(2, 2), padding=(1, 1), groups=keep[3])
        self.conv_3 = residual(*stage_channels(keep, 4, 4), num_block=4, groups=keep[4])
        self.conv_34 = Depth_Wise((keep[16], keep[17]), (keep[17], keep[18]), (keep[18], keep[19]),
                                  kernel=(3, 3), stride=(2, 2), padding=(1, 1), groups=keep[19])
        self.conv_4 = residual(*stage_channels(keep, 19, 6), num_block=6, groups=keep[19])
        self.conv_45 = Depth_Wise((keep[37], keep[38]), (keep[38], keep[39]), (keep[39], keep[40]),
                                  kernel=(3, 3), stride=(2, 2), padding=(1, 1), groups=keep[40])
        self.conv_5 = residual(*stage_channels(keep, 40, 2), num_block=2, groups=keep[40])
        self.conv_6_sep = Conv_block(keep[46], keep[47], kernel=(1, 1), stride=(1, 1), padding=(0, 0))
        self.conv_6_dw = Linear_block(keep[47], keep[48], groups=keep[48], kernel=conv6_kernel, stride=(1, 1),
                                      padding=(0, 0))
        self.conv_6_flatten = Flatten()
        self.linear = Linear(512, embedding_size, bias=False)
        self.bn = BatchNorm1d(embedding_size)
        self.drop = torch.nn.Dropout(p=drop_p)
        self.prob = Linear(embedding_size, num_classes, bias=False)

    def forward(self, x):
        for layer in [self.conv1, self.conv2_dw, self.conv_23, self.conv_3, self.conv_34, self.conv_4, self.conv_45,
                      self.conv_5, self.conv_6_sep, self.conv_6_dw, self.conv_6_flatten]:
            x = layer(x)
        if self.embedding_size != 512:
            x = self.linear(x)
        return self.prob(self.drop(self.bn(x)))


KEEP = {"1.8M": [32, 32, 103, 103, 64, 13, 13, 64, 26, 26, 64, 13, 13, 64, 52, 52, 64, 231, 231, 128,
                 154, 154, 128, 52, 52, 128, 26, 26, 128, 52, 52, 128, 26, 26, 128, 26, 26, 128, 308, 308,
                 128, 26, 26, 128, 26, 26, 128, 512, 512],
        "1.8M_": [32, 32, 103, 103, 64, 13, 13, 64, 13, 13, 64, 13, 13, 64, 13, 13, 64, 231, 231, 128,
                  231, 231, 128, 52, 52, 128, 26, 26, 128, 77, 77, 128, 26, 26, 128, 26, 26, 128, 308, 308,
                  128, 26, 26, 128, 26, 26, 128, 512, 512]}
# utility.get_kernel(80, 80) = ((80 + 15) // 16, (80 + 15) // 16)
CONV6_KERNEL = (5, 5)


def minifasnet_v2():
    return MiniFASNet(KEEP["1.8M_"], 128, CONV6_KERNEL, drop_p=0.2, num_classes=3)


def minifasnet_v1se():
    return MiniFASNet(KEEP["1.8M"], 128, CONV6_KERNEL, drop_p=0.75, num_classes=3, se=True)


def load_checkpoint(model, path):
    """Load as anti_spoof_predict._load_model does (strip DataParallel's 'module.'), but strictly and data-only."""
    state = torch.load(path, map_location="cpu", weights_only=True)
    state = {(k[7:] if k.startswith("module.") else k): v for k, v in state.items()}
    model.load_state_dict(state, strict=True)
    return model.eval(), len(state)


class MiniFASNetPair(Module):
    """Both scales in one graph: softmax per model, then the mean real-face probability."""

    def __init__(self, scale27, scale40):
        super().__init__()
        self.scale27, self.scale40 = scale27, scale40

    def forward(self, crop27, crop40):
        probs27 = F.softmax(self.scale27(crop27), dim=1)
        probs40 = F.softmax(self.scale40(crop40), dim=1)
        real = (probs27[:, REAL_CLASS] + probs40[:, REAL_CLASS]) * 0.5
        return real, probs27, probs40


# ---- Reference preprocessing, transcribed from src/generate_patches.py and src/anti_spoof_predict.py ----
def crop_box(src_w, src_h, bbox, scale):
    """CropImage._get_new_box: inclusive pixel box (left, top, right, bottom) and the scale actually used."""
    x, y, box_w, box_h = bbox
    scale = min((src_h - 1) / box_h, min((src_w - 1) / box_w, scale))
    new_width, new_height = box_w * scale, box_h * scale
    center_x, center_y = box_w / 2 + x, box_h / 2 + y
    left, top = center_x - new_width / 2, center_y - new_height / 2
    right, bottom = center_x + new_width / 2, center_y + new_height / 2
    if left < 0:
        right -= left
        left = 0
    if top < 0:
        bottom -= top
        top = 0
    if right > src_w - 1:
        left -= right - src_w + 1
        right = src_w - 1
    if bottom > src_h - 1:
        top -= bottom - src_h + 1
        bottom = src_h - 1
    return (int(left), int(top), int(right), int(bottom)), scale


def reference_crop(image, bbox, scale, interpolation=cv2.INTER_LINEAR):
    """CropImage.crop then ToTensor: BGR uint8 HWC -> float32 [1,3,80,80], values left at 0..255."""
    (left, top, right, bottom), _ = crop_box(image.shape[1], image.shape[0], bbox, scale)
    patch = cv2.resize(image[top:bottom + 1, left:right + 1], (80, 80), interpolation=interpolation)
    return patch.transpose(2, 0, 1)[None].astype(np.float32)


def reference_bbox(image, net):
    """Detection.get_bbox: the RetinaFace (Caffe) box with the highest confidence, as [x, y, w, h]."""
    height, width = image.shape[:2]
    aspect_ratio = width / height
    small = image
    if width * height >= 192 * 192:
        small = cv2.resize(image, (int(192 * math.sqrt(aspect_ratio)), int(192 / math.sqrt(aspect_ratio))),
                           interpolation=cv2.INTER_LINEAR)
    net.setInput(cv2.dnn.blobFromImage(small, 1, mean=(104, 117, 123)), "data")
    out = net.forward("detection_out").reshape(-1, 7)
    best = out[np.argmax(out[:, 2])]
    left, top, right, bottom = best[3] * width, best[4] * height, best[5] * width, best[6] * height
    return [int(left), int(top), int(right - left + 1), int(bottom - top + 1)], float(best[2])


# ---- The app's contract (CONTRACT.md), implemented independently of OpenCV ----
def contract_resize(patch, size=80):
    """Bilinear, half-pixel centres, edge-clamped, no antialiasing; float output (not rounded)."""
    def taps(n_src):
        f = (np.arange(size) + 0.5) * (n_src / size) - 0.5
        i0 = np.floor(f).astype(int)
        a = f - i0
        a[i0 < 0], i0[i0 < 0] = 0, 0
        last = i0 >= n_src - 1
        a[last], i0[last] = 0, n_src - 1
        return i0, np.minimum(i0 + 1, n_src - 1), a
    y0, y1, ay = taps(patch.shape[0])
    x0, x1, ax = taps(patch.shape[1])
    p = patch.astype(np.float64)
    rows = p[y0] * (1 - ay)[:, None, None] + p[y1] * ay[:, None, None]
    return rows[:, x0] * (1 - ax)[None, :, None] + rows[:, x1] * ax[None, :, None]


def contract_crop(image, bbox, scale):
    (left, top, right, bottom), _ = crop_box(image.shape[1], image.shape[0], bbox, scale)
    return contract_resize(image[top:bottom + 1, left:right + 1])


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fixtures():
    """At least 20 seeded random crop pairs across 0..255, plus constant images; no camera or personal data."""
    rng = np.random.default_rng(20261030)
    shape = (1, 3, 80, 80)
    for name, value in [("black", 0.0), ("midgray", 127.5), ("white", 255.0)]:
        yield name, np.full(shape, value, np.float32), np.full(shape, value, np.float32)
    for index in range(12):
        yield f"uniform_{index}", *(rng.uniform(0, 255, shape).astype(np.float32) for _ in range(2))
    for index in range(12):
        yield f"integer_{index}", *(rng.integers(0, 256, shape).astype(np.float32) for _ in range(2))


def run_coreml(model, crop27, crop40):
    out = model.predict({"crop27": crop27, "crop40": crop40})
    assert {k: np.shape(v) for k, v in out.items()} == {"real": (1,), "probs27": (1, 3), "probs40": (1, 3)}
    return {k: np.asarray(out[k], np.float64).reshape(-1) for k in ["real", "probs27", "probs40"]}


def run_torch(pair, crop27, crop40):
    with torch.no_grad():
        real, p27, p40 = pair(torch.from_numpy(crop27), torch.from_numpy(crop40))
    return {"real": real.double().numpy().reshape(-1), "probs27": p27.double().numpy().reshape(-1),
            "probs40": p40.double().numpy().reshape(-1)}


def reference_path(net, crop):
    """anti_spoof_predict.predict: one model, F.softmax over the class axis."""
    with torch.no_grad():
        return F.softmax(net(torch.from_numpy(crop)), dim=1).double().numpy().reshape(-1)


def max_diff(a, b):
    return float(max(np.max(np.abs(a[k] - b[k])) for k in ["real", "probs27", "probs40"]))


def latency(model, crop27, crop40, runs, warmup=5):
    for _ in range(warmup):
        model.predict({"crop27": crop27, "crop40": crop40})
    times = []
    for _ in range(runs):
        start = time.perf_counter()
        model.predict({"crop27": crop27, "crop40": crop40})
        times.append((time.perf_counter() - start) * 1000)
    t = np.array(times)
    return {"runs": runs, "warmup_runs": warmup, "median_ms": float(np.median(t)), "mean_ms": float(t.mean()),
            "p95_ms": float(np.percentile(t, 95)), "min_ms": float(t.min()), "max_ms": float(t.max())}


def compute_devices(package, units):
    """Which device Core ML plans for each operation (MLComputePlan, macOS 14.4+)."""
    from coremltools.models.compute_plan import MLComputePlan
    compiled = ct.models.utils.compile_model(str(package))
    plan = MLComputePlan.load_from_path(path=compiled, compute_units=units)
    counts = {}
    for op in plan.model_structure.program.functions["main"].block.operations:
        usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
        if usage is None:
            continue
        name = type(usage.preferred_compute_device).__name__
        counts[name] = counts.get(name, 0) + 1
    return counts


def crop_examples():
    """Crop-box test vectors for the app, computed by the transcribed reference function."""
    cases = [("worked_example_1280x720", 1280, 720, [500, 200, 240, 280]),
             ("small_centred_face", 1280, 720, [590, 300, 100, 120]),
             ("face_at_left_edge", 1280, 720, [10, 250, 150, 180]),
             ("face_at_bottom_right", 1280, 720, [1100, 560, 150, 150]),
             ("face_at_top_edge", 1280, 720, [600, 5, 120, 140])]
    out = []
    for name, w, h, bbox in cases:
        row = {"name": name, "image_width": w, "image_height": h, "face_box_xywh": bbox}
        for key, scale in [("crop27", 2.7), ("crop40", 4.0)]:
            box, used = crop_box(w, h, bbox, scale)
            row[key] = {"scale_used": used, "left_top_right_bottom_inclusive": list(box),
                        "width": box[2] - box[0] + 1, "height": box[3] - box[1] + 1}
        out.append(row)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", type=Path, default=ROOT / ".model-tools/downloads/Silent-Face-Anti-Spoofing",
                        help=f"checkout of {REPOSITORY} at {REVISION}")
    parser.add_argument("--package", type=Path, default=ROOT / "Resources/MiniFASNet.mlpackage")
    parser.add_argument("--evidence", type=Path, default=ROOT / "Resources/ThirdParty/MiniFASNet-verification.json")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--latency-runs", type=int, default=50)
    args = parser.parse_args()

    for relative, expected in PINNED.items():
        assert sha256(args.source / relative) == expected, f"Untrusted or changed source file: {relative}"
    torch.set_num_threads(1)
    net27, keys27 = load_checkpoint(minifasnet_v2(), args.source / MODEL_27)
    net40, keys40 = load_checkpoint(minifasnet_v1se(), args.source / MODEL_40)
    pair = MiniFASNetPair(net27, net40).eval()

    if not args.verify_only:
        example = torch.zeros((1, 3, 80, 80))
        traced = torch.jit.trace(pair, (example, example), check_trace=True)
        spec = lambda name: ct.TensorType(name=name, shape=(1, 3, 80, 80), dtype=np.float32)
        model = ct.convert(traced, inputs=[spec("crop27"), spec("crop40")],
                           outputs=[ct.TensorType(name=n, dtype=np.float32) for n in ["real", "probs27", "probs40"]],
                           minimum_deployment_target=ct.target.macOS13, convert_to="mlprogram",
                           compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_ONLY)
        model.short_description = ("Silent-Face-Anti-Spoofing MiniFASNet pair (2.7x MiniFASNetV2 + 4.0x MiniFASNetV1SE): "
                                   "face crops to mean real-face probability")
        model.author = "Minivision (Silent-Face-Anti-Spoofing); converted for FaceID Unlock"
        model.license = "Apache-2.0; see ThirdParty/MiniFASNet-LICENSE"
        model.version = "minifasnet-2.7v2-4.0v1se-fp32-v1"
        crop_text = ("Float32 NCHW [1,3,80,80]: {}x face crop resized bilinearly to 80x80; channels B,G,R; "
                     "values 0..255, not divided or normalized.")
        model.input_description["crop27"] = crop_text.format("2.7")
        model.input_description["crop40"] = crop_text.format("4.0")
        model.output_description["real"] = "Float32 [1]: mean of the two models' real-face (class 1) probabilities."
        model.output_description["probs27"] = "Float32 [1,3]: softmax of the 2.7x MiniFASNetV2; index 1 is real."
        model.output_description["probs40"] = "Float32 [1,3]: softmax of the 4.0x MiniFASNetV1SE; index 1 is real."
        model.user_defined_metadata.update({"source_repository": REPOSITORY, "source_revision": REVISION,
                                            "sha256_" + Path(MODEL_27).name: PINNED[MODEL_27],
                                            "sha256_" + Path(MODEL_40).name: PINNED[MODEL_40]})
        model.save(str(args.package))

    unit_names = {"cpu_only": ct.ComputeUnit.CPU_ONLY, "all": ct.ComputeUnit.ALL}
    models = {name: ct.models.MLModel(str(args.package), compute_units=units) for name, units in unit_names.items()}
    description = models["all"].get_spec().description
    assert [(i.name, list(i.type.multiArrayType.shape)) for i in description.input] == \
        [("crop27", [1, 3, 80, 80]), ("crop40", [1, 3, 80, 80])]
    assert [o.name for o in description.output] == ["real", "probs27", "probs40"]

    # (a) Random and constant inputs.
    random_rows = []
    for name, crop27, crop40 in fixtures():
        expected = run_torch(pair, crop27, crop40)
        ref27, ref40 = reference_path(net27, crop27), reference_path(net40, crop40)
        path_diff = float(max(np.abs(ref27 - expected["probs27"]).max(), np.abs(ref40 - expected["probs40"]).max(),
                              abs((ref27[1] + ref40[1]) / 2 - expected["real"][0])))
        assert path_diff < THRESHOLDS["pytorch_pair_vs_reference_path"], (name, path_diff)
        row = {"fixture": name, "pytorch_real": float(expected["real"][0]), "pytorch_pair_vs_reference_path": path_diff}
        for units, model in models.items():
            actual = run_coreml(model, crop27, crop40)
            assert all(np.isfinite(v).all() for v in actual.values())
            assert actual["probs27"].shape == actual["probs40"].shape == (3,) and actual["real"].shape == (1,)
            row[f"coreml_{units}_max_abs_difference"] = max_diff(expected, actual)
            assert row[f"coreml_{units}_max_abs_difference"] < THRESHOLDS["coreml_max_abs_probability_difference"], row
        random_rows.append(row)

    # (b) Upstream sample images, boxed by the upstream RetinaFace detector as test.py does.
    detector = cv2.dnn.readNetFromCaffe(str(args.source / DETECTOR[0]), str(args.source / DETECTOR[1]))
    sample_rows = []
    for file_name, (label, upstream_class, upstream_score) in SAMPLES.items():
        image = cv2.imread(str(args.source / "images/sample" / file_name))
        bbox, confidence = reference_bbox(image, detector)
        crop27, crop40 = reference_crop(image, bbox, 2.7), reference_crop(image, bbox, 4.0)
        expected = run_torch(pair, crop27, crop40)
        summed = expected["probs27"] + expected["probs40"]
        predicted = int(np.argmax(summed))
        row = {"image": file_name, "image_width": image.shape[1], "image_height": image.shape[0],
               "detector_box_xywh": bbox, "detector_confidence": confidence,
               "crop_boxes": {key: {"left_top_right_bottom_inclusive": list(box), "scale_used": used}
                              for key, (box, used) in [("crop27", crop_box(image.shape[1], image.shape[0], bbox, 2.7)),
                                                       ("crop40", crop_box(image.shape[1], image.shape[0], bbox, 4.0))]},
               "documented_label": label,
               "documented_upstream_verdict": {"class": upstream_class, "score": upstream_score},
               "pytorch": {k: v.tolist() for k, v in expected.items()},
               "predicted_class_index": predicted, "predicted_label": "real" if predicted == REAL_CLASS else "spoof",
               "predicted_class_mean_probability": float(summed[predicted] / 2)}
        row["prediction_matches_documented_label"] = row["predicted_label"] == label
        for units, model in models.items():
            actual = run_coreml(model, crop27, crop40)
            row[f"coreml_{units}"] = {k: v.tolist() for k, v in actual.items()}
            row[f"coreml_{units}_max_abs_difference"] = max_diff(expected, actual)
            row[f"coreml_{units}_prediction_matches_documented_label"] = (
                (int(np.argmax(actual["probs27"] + actual["probs40"])) == REAL_CLASS) == (label == "real"))
            assert row[f"coreml_{units}_max_abs_difference"] < THRESHOLDS["coreml_max_abs_probability_difference"], row
        # The app's contract implemented without OpenCV, then an area-averaging resize for contrast.
        c27, c40 = contract_crop(image, bbox, 2.7), contract_crop(image, bbox, 4.0)
        pixel = float(max(np.abs(c27 - crop27[0].transpose(1, 2, 0)).max(), np.abs(c40 - crop40[0].transpose(1, 2, 0)).max()))
        assert pixel <= THRESHOLDS["contract_resize_max_pixel_difference"], (file_name, pixel)
        as_input = lambda c: np.ascontiguousarray(c.transpose(2, 0, 1)[None], np.float32)
        contract = run_coreml(models["all"], as_input(c27), as_input(c40))
        contract_rounded = run_coreml(models["all"], as_input(np.round(c27)), as_input(np.round(c40)))
        area = run_coreml(models["all"], reference_crop(image, bbox, 2.7, cv2.INTER_AREA),
                          reference_crop(image, bbox, 4.0, cv2.INTER_AREA))
        shifted = []  # every combination of -1/0/+1 pixel on x, y, w and h of the detector box
        for delta in np.ndindex(3, 3, 3, 3):
            box = [v + d - 1 for v, d in zip(bbox, delta)]
            shifted.append(run_coreml(models["cpu_only"], reference_crop(image, box, 2.7), reference_crop(image, box, 4.0)))
        row["preprocessing_sensitivity"] = {
            "contract_resize_max_pixel_difference_vs_opencv": pixel,
            "contract_unrounded_real": float(contract["real"][0]),
            "contract_rounded_real": float(contract_rounded["real"][0]),
            "area_average_resize_real": float(area["real"][0]),
            "one_pixel_box_shifts": {
                "count": len(shifted),
                "real_min_max": [min(s["real"][0] for s in shifted), max(s["real"][0] for s in shifted)],
                "predicted_class_mean_probability_min_max": [min((s["probs27"] + s["probs40"]).max() / 2 for s in shifted),
                                                             max((s["probs27"] + s["probs40"]).max() / 2 for s in shifted)],
                "predicted_classes": sorted({int(np.argmax(s["probs27"] + s["probs40"])) for s in shifted})}}
        sample_rows.append(row)

    probe27, probe40 = next((c27, c40) for name, c27, c40 in fixtures() if name == "uniform_0")
    timing = {name: latency(model, probe27, probe40, args.latency_runs) for name, model in models.items()}
    devices = {name: compute_devices(args.package, units) for name, units in unit_names.items()}

    downloaded = {str(p.relative_to(args.source)): sha256(p) for p in sorted(args.source.rglob("*"))
                  if p.is_file() and ".git" not in p.relative_to(args.source).parts}
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    evidence = {
        "source_repository": REPOSITORY, "source_revision": REVISION, "pinned_sha256": PINNED,
        "downloaded_files_sha256": downloaded,
        "checkpoint_keys_loaded": {Path(MODEL_27).name: keys27, Path(MODEL_40).name: keys40},
        "parameters": {Path(MODEL_27).name: sum(p.numel() for p in net27.parameters()),
                       Path(MODEL_40).name: sum(p.numel() for p in net40.parameters())},
        "platform": platform.platform(), "machine": chip, "python": platform.python_version(),
        "dependencies": {d: importlib.metadata.version(d)
                         for d in ["numpy", "torch", "coremltools", "opencv-python-headless"]},
        "package_sha256": {str(p.relative_to(args.package)): sha256(p)
                           for p in sorted(args.package.rglob("*")) if p.is_file()},
        "thresholds": THRESHOLDS,
        "random_inputs": {"count": len(random_rows),
                          "max_abs_difference": {u: max(r[f"coreml_{u}_max_abs_difference"] for r in random_rows)
                                                 for u in models},
                          "rows": random_rows},
        "sample_images": {"max_abs_difference": {u: max(r[f"coreml_{u}_max_abs_difference"] for r in sample_rows)
                                                 for u in models},
                          "rows": sample_rows},
        "crop_box_examples": crop_examples(),
        "latency_one_call": timing,
        "planned_compute_devices": devices,
    }
    args.evidence.write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({"random_inputs": evidence["random_inputs"]["max_abs_difference"],
                      "sample_images": evidence["sample_images"]["max_abs_difference"],
                      "samples": {r["image"]: [round(r["pytorch"]["real"][0], 4), round(r["coreml_all"]["real"][0], 4),
                                               r["predicted_label"], r["prediction_matches_documented_label"]]
                                  for r in sample_rows},
                      "latency_ms_median": {k: round(v["median_ms"], 3) for k, v in timing.items()},
                      "devices": devices}, indent=2))


if __name__ == "__main__":
    main()
