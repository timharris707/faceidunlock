# MiniFASNet model attribution

The bundled `MiniFASNet.mlpackage` is a converted form of two face anti-spoofing models from Silent-Face-Anti-Spoofing by Minivision, licensed under Apache License 2.0. The complete license is bundled in `MiniFASNet-LICENSE`.

Copyright 2020 Minivision.

Source repository: https://github.com/minivision-ai/Silent-Face-Anti-Spoofing

Pinned source revision: `b6d5f04ad78778917853b25c778acef6d5626d15` (master, 2020-08-05)

| Model path | Role in the package | SHA-256 |
|---|---|---|
| `resources/anti_spoof_models/2.7_80x80_MiniFASNetV2.pth` | input `crop27`, output `probs27` | `a5eb02e1843f19b5386b953cc4c9f011c3f985d0ee2bb9819eea9a142099bec0` |
| `resources/anti_spoof_models/4_0_0_80x80_MiniFASNetV1SE.pth` | input `crop40`, output `probs40` | `84ee1d37d96894d5e82de5a57df044ef80a58be2b218b5ed7cdfd875ec2f5990` |

Network definition: `src/model_lib/MiniFASNet.py`, SHA-256 `e498c4ec5e1ddfaba62b941a126c19d65aa564999f3309661fe43ee8bf38acd7`.

License file SHA-256: `daf94bf1dc9cc5700fe5af2c7c0cbd1836e70d509ed78fd0bebef7432edee6fb`

Modification: the MiniFASNetV2 and MiniFASNetV1SE network definitions were transcribed into `scripts/convert-minifasnet.py` (condensed, same layer names, shapes and arithmetic). The original weights were loaded unchanged and both networks were combined, each followed by its softmax, into one float32 Core ML ML Program. The program also outputs the mean of the two class-1 (real face) probabilities, as the upstream `test.py` averages them. Inputs were named `crop27` and `crop40`; outputs `real`, `probs27` and `probs40`. Descriptive metadata was added. No training, fine-tuning, weight quantization or pruning was applied. Core ML's standard conversion passes fold equivalent inference operations, including batch normalization. The conversion tools and the upstream RetinaFace detector (used only to box the upstream sample images during verification) are development-only and are not bundled into the app.

The source license is available at:
https://github.com/minivision-ai/Silent-Face-Anti-Spoofing/blob/b6d5f04ad78778917853b25c778acef6d5626d15/LICENSE

The upstream repository has no NOTICE file.
