# OmniASR Playground

On-device automatic speech recognition for iOS, powered by [Meta's Omni-ASR](https://github.com/facebookresearch/omniasr) CTC models running on CoreML. All processing happens locally on your device — no cloud, no data leaves your phone.

## Features

- **Live Transcription** — real-time speech-to-text as you speak
- **Record & Transcribe** — record audio, then transcribe with progress feedback
- **Audio File Import** — import audio files from your device and transcribe them
- **Model Management** — download, switch, and delete models on-demand from HuggingFace
- **Compute Unit Selection** — choose between CPU, GPU, or Apple Neural Engine (ANE)
- **Privacy First** — fully offline, no network required after model download

## Available Models

All models are downloaded on-demand from [HuggingFace](https://huggingface.co/ChipCracker/omni-asr-coreml).

| Model | Quantization | Download Size |
|-------|-------------|---------------|
| Omni ASR 300M | INT8 | ~326 MB |
| Omni ASR 300M | FP16 | ~651 MB |
| Omni ASR 1B | INT8 | ~977 MB |
| Omni ASR 1B | FP16 | ~1.95 GB |

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+
- A physical device is recommended (Neural Engine is not available in the Simulator)

## Getting Started

```bash
git clone git@github.com:ChipCracker/OmniASRPlayground.git
cd OmniASRPlayground
open omni-asr.xcodeproj
```

1. Select your target device in Xcode
2. Build and run
3. On first launch, open the model manager and download a model
4. Start transcribing

## Architecture

The app follows a **SwiftUI + MVVM** pattern:

```
omni-asr/
├── ViewModels/
│   └── TranscriptionViewModel    # Central state machine & business logic
├── Views/
│   ├── ContentView               # Main UI with state-driven layout
│   ├── ModelManagerSheet         # Model download & selection
│   ├── TranscriptionCardView    # Live + confirmed transcription display
│   ├── RecordButton             # Animated recording button
│   ├── AudioWaveformView        # Real-time audio visualization
│   └── Theme                    # Global styling
├── Services/
│   ├── AudioCaptureService      # 16kHz mono microphone input
│   ├── AudioFileService         # File import & format conversion
│   └── ModelDownloadService     # HuggingFace download manager
└── Resources/
    ├── model_info.json          # Model registry
    └── vocabulary.json          # Multilingual character vocabulary
```

**OmniASRKit** is a local Swift Package that handles CoreML model loading, inference, and CTC decoding.

## License

MIT
