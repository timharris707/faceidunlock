# SFace model attribution

The bundled `SFace.mlpackage` is a converted form of `face_recognition_sface_2021dec.onnx` from OpenCV Zoo, licensed under Apache License 2.0. The complete license is bundled in `SFace-LICENSE`.

Copyright (C) 2021, Shenzhen Institute of Artificial Intelligence and Robotics for Society, all rights reserved. Third party copyrights are property of their respective owners.

Source repository: https://github.com/opencv/opencv_zoo

Pinned source revision: `47534e27c9851bb1128ccc0102f1145e27f23f98`

Model path: `models/face_recognition_sface/face_recognition_sface_2021dec.onnx`

Original model SHA-256: `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79`

License file SHA-256: `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`

Modification: converted the inference graph from ONNX to native Core ML ML Program using float32 weights/computation; renamed `data` to `image` and `fc1` to `embedding`; added descriptive metadata. No training, weight quantization, or embedding normalization was applied. Core ML's standard conversion passes fold equivalent inference operations, including batch normalization. The conversion tools are development-only and are not bundled into the app.

The source model and wrapper license are available at:
https://github.com/opencv/opencv_zoo/blob/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_recognition_sface/LICENSE

Reference: Zhong et al., *SFace: Sigmoid-Constrained Hypersphere Loss for Robust Face Recognition*, IEEE Transactions on Image Processing (2021).
