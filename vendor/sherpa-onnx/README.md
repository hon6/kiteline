# sherpa-onnx（本机离线语音识别）

- 版本：1.13.8（来自 PyPI 包 sherpa-onnx-core 的 macOS arm64 wheel：lib/ 下两个 dylib，include/ 下 C 头文件）
- 用途：Mac 端「按住说话」转写，模型 Fun-ASR-Nano（运行时下载到 ~/Library/Application Support/TARS/asr/），见 Sources/LocalASR.swift
- build.sh 把 lib/*.dylib 拷进 App 的 Contents/Frameworks，Swift 用 include/module.modulemap 认 C 类型，运行时 dlopen
- 许可：sherpa-onnx Apache-2.0（https://github.com/k2-fsa/sherpa-onnx），ONNX Runtime MIT（https://github.com/microsoft/onnxruntime）
- 只有 arm64：通用版里 Intel 那一半加载不到库，自动退回系统语音识别
