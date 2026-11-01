#!/usr/bin/env python3
"""Convert the pinned SFace inference graph, then test against ONNX Runtime."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
from collections import Counter

import coremltools as ct
import numpy as np
import onnx
from onnx import numpy_helper, helper
import onnxruntime as ort
import torch
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parents[1]
SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
REVISION = "47534e27c9851bb1128ccc0102f1145e27f23f98"


class SFaceGraph(torch.nn.Module):
    """Translate each of this pinned ONNX graph's eight operation types literally."""

    def __init__(self, graph):
        super().__init__()
        self.nodes = list(graph.node)
        self.names = {}
        for index, value in enumerate(graph.initializer):
            name = f"weight_{index}"
            self.register_buffer(name, torch.from_numpy(numpy_helper.to_array(value).copy()))
            self.names[value.name] = name
        supported = {"Sub", "Mul", "Conv", "BatchNormalization", "PRelu", "Dropout", "Flatten", "Gemm"}
        assert {node.op_type for node in self.nodes} <= supported

    def forward(self, image):
        values = {name: getattr(self, key) for name, key in self.names.items()}
        values["data"] = image
        for node in self.nodes:
            x = [values[name] for name in node.input]
            a = {attr.name: helper.get_attribute_value(attr) for attr in node.attribute}
            if node.op_type == "Sub":
                y = x[0] - x[1]
            elif node.op_type == "Mul":
                y = x[0] * x[1]
            elif node.op_type == "Conv":
                pads = a.get("pads", [0, 0, 0, 0])
                assert pads[:2] == pads[2:]
                y = F.conv2d(x[0], x[1], x[2] if len(x) == 3 else None,
                             stride=a.get("strides", [1, 1]), padding=pads[:2],
                             dilation=a.get("dilations", [1, 1]), groups=a.get("group", 1))
            elif node.op_type == "BatchNormalization":
                y = F.batch_norm(x[0], x[3], x[4], x[1], x[2], training=False,
                                 eps=a.get("epsilon", 1e-5))
            elif node.op_type == "PRelu":
                y = F.prelu(x[0], x[1].flatten())
            elif node.op_type == "Dropout":
                y = x[0]  # ONNX inference: dropout is disabled.
            elif node.op_type == "Flatten":
                assert a.get("axis", 1) == 1
                y = x[0].flatten(start_dim=1)
            elif node.op_type == "Gemm":
                assert a == {"alpha": 1.0, "beta": 1.0, "transA": 0, "transB": 1}
                y = F.linear(x[0], x[1], x[2])
            assert len(node.output) == 1
            values[node.output[0]] = y
        return values["fc1"]


def fixtures():
    """Publicly reproducible synthetic inputs; no camera access or personal data."""
    rng = np.random.default_rng(20260922)
    shape = (1, 3, 112, 112)
    yield "black", np.zeros(shape, dtype=np.float32)
    yield "white", np.full(shape, 255, dtype=np.float32)
    yield "midgray", np.full(shape, 127.5, dtype=np.float32)
    grid = np.indices((112, 112), dtype=np.float32)
    gradient = np.stack((grid[1] * 255 / 111, grid[0] * 255 / 111, (grid.sum(axis=0) % 16) * 17))[None]
    yield "rgb_gradient", gradient
    for index in range(8):
        yield f"seeded_noise_{index}", rng.uniform(0, 255, shape).astype(np.float32)


def metrics(reference, actual):
    assert actual.shape == reference.shape == (1, 128)
    assert np.isfinite(actual).all()
    r, a = reference.astype(np.float64).ravel(), actual.astype(np.float64).ravel()
    return {"max_absolute_error": float(np.max(np.abs(r - a))),
            "relative_l2_error": float(np.linalg.norm(r - a) / np.linalg.norm(r)),
            "cosine_drift": float(abs(1 - np.dot(r, a) / (np.linalg.norm(r) * np.linalg.norm(a))))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    source = ROOT / ".model-tools/downloads/face_recognition_sface_2021dec.onnx"
    assert hashlib.sha256(source.read_bytes()).hexdigest() == SHA256, "Untrusted ONNX source hash"
    graph = onnx.load(source)
    onnx.checker.check_model(graph)
    net = SFaceGraph(graph.graph).eval()
    torch.set_num_threads(1)
    package = ROOT / "Resources/SFace.mlpackage"
    if not args.verify_only:
        traced = torch.jit.trace(net, torch.zeros((1, 3, 112, 112)), check_trace=True)
        model = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=(1, 3, 112, 112), dtype=np.float32)],
                           outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
                           minimum_deployment_target=ct.target.macOS13,
                           convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
                           compute_units=ct.ComputeUnit.CPU_ONLY)
        model.short_description = "OpenCV SFace: aligned raw RGB face to 128-value embedding"
        model.author = "Shenzhen Institute of Artificial Intelligence and Robotics for Society; converted for FaceID Unlock"
        model.license = "Apache-2.0; see ThirdParty/SFace-LICENSE"
        model.version = "opencv-sface-2021dec-fp32-v1"
        model.input_description["image"] = "Float32 NCHW [1,3,112,112], RGB values 0..255. Normalization is inside the model."
        model.output_description["embedding"] = "Float32 [1,128]; normalize to unit L2 length before cosine matching."
        model.user_defined_metadata.update({"source_revision": REVISION, "source_sha256": SHA256})
        model.save(str(package))
    options = ort.SessionOptions()
    options.log_severity_level = 3
    session = ort.InferenceSession(str(source), sess_options=options, providers=["CPUExecutionProvider"])
    references = [(name, value, session.run(["fc1"], {"data": value})[0]) for name, value in fixtures()]
    results = []
    for name, value, reference in references:
        with torch.no_grad():
            result = metrics(reference, net(torch.from_numpy(value)).numpy())
        assert result["relative_l2_error"] < 1e-4, (name, result)
        results.append({"backend": "pytorch", "fixture": name, **result})
    for units in [ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.ALL]:
        model = ct.models.MLModel(str(package), compute_units=units)
        inputs = model.get_spec().description.input
        outputs = model.get_spec().description.output
        assert len(inputs) == 1 and inputs[0].name == "image"
        assert list(inputs[0].type.multiArrayType.shape) == [1, 3, 112, 112]
        assert len(outputs) == 1 and outputs[0].name == "embedding"
        assert list(outputs[0].type.multiArrayType.shape) == [1, 128]
        for name, value, reference in references:
            result = metrics(reference, model.predict({"image": value})["embedding"])
            assert result["relative_l2_error"] < 1e-3, (units.name, name, result)
            assert result["cosine_drift"] < 1e-6, (units.name, name, result)
            results.append({"backend": f"coreml_{units.name.lower()}", "fixture": name, **result})
    evidence = {"source_revision": REVISION, "source_sha256": SHA256,
                "platform": platform.platform(), "python": platform.python_version(),
                "dependencies": {d: importlib.metadata.version(d) for d in ["numpy", "torch", "onnx", "onnxruntime", "coremltools"]},
                "operations": dict(Counter(n.op_type for n in graph.graph.node)),
                "package_sha256": {str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest()
                                    for p in sorted(package.rglob("*")) if p.is_file()},
                "thresholds": {"pytorch_relative_l2_error": 1e-4, "coreml_relative_l2_error": 1e-3, "coreml_cosine_drift": 1e-6},
                "results": results}
    evidence_path = ROOT / "Resources/ThirdParty/SFace-verification.json"
    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({"comparisons_passed": len(results), "maximum_cosine_drift": max(r["cosine_drift"] for r in results),
                      "maximum_relative_l2_error": max(r["relative_l2_error"] for r in results)}, indent=2))


if __name__ == "__main__":
    main()
