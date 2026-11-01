#!/bin/bash
# Fetch pinned, Apache-licensed SFace weights, convert, and check native inference.
set -euo pipefail
cd "$(dirname "$0")/.."
revision=47534e27c9851bb1128ccc0102f1145e27f23f98
expected_sha=0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
model=.model-tools/downloads/face_recognition_sface_2021dec.onnx
if [[ ! -x .model-tools/bin/python ]]; then
    python3.12 -m venv .model-tools
fi
.model-tools/bin/python -m pip install -r Resources/ThirdParty/SFace-conversion-requirements.txt
mkdir -p .model-tools/downloads
if [[ ! -f "$model" ]]; then
    curl --fail --location --retry 2 \
        "https://media.githubusercontent.com/media/opencv/opencv_zoo/$revision/models/face_recognition_sface/face_recognition_sface_2021dec.onnx" \
        --output "$model.download"
    actual_sha=$(shasum -a 256 "$model.download" | cut -d ' ' -f 1)
    [[ "$actual_sha" == "$expected_sha" ]] || { echo "Downloaded model failed its SHA-256 check" >&2; exit 1; }
    mv "$model.download" "$model"
fi
actual_sha=$(shasum -a 256 "$model" | cut -d ' ' -f 1)
[[ "$actual_sha" == "$expected_sha" ]] || { echo "Cached model failed its SHA-256 check" >&2; exit 1; }
.model-tools/bin/python scripts/convert-sface.py "$@"
