# CoreML Export Guide

Anleitung zum Export von Omni-ASR CTC Modellen (wav2vec2 300M, fairseq2) nach CoreML fuer die iOS App.

## Voraussetzungen

```bash
pip install coremltools torch torchaudio sentencepiece
```

Das fairseq2-Paket muss installiert sein (wird aus `omni-asr-ft/.venv` referenziert).

## Schnellstart

### 1. Pre-trained Modell exportieren

```bash
python scripts/export_coreml.py \
    --checkpoint /path/to/checkpoint.pt \
    --arch 300m \
    --spm-model /path/to/tokenizer.model \
    --output OmniASR_CTC_300M.mlpackage \
    --vocab-output vocabulary.json \
    --validate
```

### 2. Custom Fine-tuned Modell exportieren

```bash
# German BPE 1024
python scripts/export_coreml.py \
    --checkpoint /path/to/finetuned_bpe1024.pt \
    --arch 300m_1024 \
    --spm-model /path/to/bpe_1024.model \
    --output OmniASR_BPE1024.mlpackage \
    --vocab-output vocabulary_bpe1024.json

# Syllable 1024
python scripts/export_coreml.py \
    --checkpoint /path/to/finetuned_syl1024.pt \
    --arch 300m_1024 \
    --spm-model /path/to/syllable_1024.model \
    --output OmniASR_Syllable1024.mlpackage \
    --vocab-output vocabulary_syl1024.json
```

## CLI-Optionen

| Option | Default | Beschreibung |
|--------|---------|-------------|
| `--checkpoint` | (pflicht) | Pfad zum fairseq2 Checkpoint (.pt) |
| `--arch` | `300m` | Modell-Architektur (`300m`, `300m_512`, `300m_1024`, `300m_2048`, `300m_v2`, `1b`, `3b`, `7b`, etc.) |
| `--output` | `OmniASR_CTC.mlpackage` | Ausgabepfad fuer CoreML-Paket |
| `--spm-model` | - | SentencePiece `.model` Datei fuer Vocabulary-Extraktion |
| `--tokenizer-name` | - | Alternativ: fairseq2 Tokenizer-Name |
| `--vocab-output` | `vocabulary.json` | Ausgabepfad fuer Vocabulary JSON |
| `--via-onnx` | `false` | ONNX als Zwischenformat verwenden (Fallback) |
| `--validate` | `false` | CoreML-Ausgabe gegen PyTorch validieren |
| `--test-audio` | - | WAV-Datei fuer Validierung |
| `--min-audio-secs` | `1.0` | Minimale Audio-Dauer (Sekunden) |
| `--max-audio-secs` | `40.0` | Maximale Audio-Dauer (Sekunden) |
| `--device` | `cpu` | Device fuer Model-Loading |

## Export-Pipeline im Detail

### Schritt 1: Wrapper-Klasse

Das fairseq2 `Wav2Vec2AsrModel` verwendet `BatchLayout`, das nicht mit `torch.jit.trace` kompatibel ist. Der Export-Wrapper `Wav2Vec2ForExport` konstruiert `BatchLayout` intern aus der Tensor-Shape:

```
waveform [1, T] → BatchLayout(shape=(1,T), seq_lens=[T]) → model.forward() → logits [1, T', V]
```

### Schritt 2: Weight Norm entfernen

Die Conv1d-Layers im Feature Extractor verwenden Weight Normalization (`weight_g`, `weight_v`). Diese wird vor dem Tracing entfernt, da `torch.jit.trace` sie nicht unterstuetzt.

### Schritt 3: Torch Tracing

- Batch-Size fixiert auf 1 (iOS = Einzelinferenz)
- Dummy-Input: `torch.randn(1, 160000)` (10s @ 16kHz)
- dtype: `float32` (CoreML unterstuetzt kein bfloat16)

### Schritt 4: CoreML-Konvertierung

- Variable Audio-Laenge via `ct.EnumeratedShapes` (1s bis 40s in 1s-Schritten)
- `compute_precision=FLOAT16` fuer Neural Engine Optimierung
- `minimum_deployment_target=iOS17`

### Schritt 5: Validierung

Vergleicht CoreML- und PyTorch-Logits:
- Max/Mean absolute Differenz
- Argmax-Uebereinstimmung (>99% erwartet bei float16)

## ONNX-Fallback

Falls `torch.jit.trace` an dynamischen Ops scheitert (z.B. Positional Encoding, Relative Attention):

```bash
python scripts/export_coreml.py \
    --checkpoint /path/to/checkpoint.pt \
    --arch 300m \
    --output OmniASR_CTC_300M.mlpackage \
    --via-onnx
```

Pipeline: `fairseq2 → torch.onnx.export() → ONNX → coremltools → CoreML`

Der ONNX-Zwischenschritt hat bessere Op-Coverage fuer komplexe Operationen.

## Modell-Varianten

| Variante | vocab_size | PostProcessor | Beschreibung |
|----------|-----------|---------------|-------------|
| Omni v1 (`300m`) | 9812 | Identity | Pre-trained Basis |
| Omni v2 (`300m_v2`) | 10288 | Identity | Aktualisiertes Vocabulary |
| German BPE 512 (`300m_512`) | 512 | Identity | Fine-tuned BPE |
| German BPE 1024 (`300m_1024`) | 1024 | Identity | Fine-tuned BPE |
| German BPE 2048 (`300m_2048`) | 2048 | Identity | Fine-tuned BPE |
| Syllable 512 (`300m_512`) | 512 | Syllable | Fine-tuned Silben |
| Syllable 1024 (`300m_1024`) | 1024 | Syllable | Fine-tuned Silben |
| Syllable 2048 (`300m_2048`) | 2048 | Syllable | Fine-tuned Silben |

## Vocabulary-Datei

Die `vocabulary.json` ist ein JSON-Array das Token-Index auf Token-String mappt:

```json
["<blank>", "<unk>", "▁", "e", "n", "▁d", "i", ...]
```

- Index 0 = CTC Blank Token
- `▁` (U+2581) = SentencePiece Word Boundary (wird in der App zu Leerzeichen)
- Bei Syllable-Tokenizer: `-` wird in der App entfernt

## Integration in die iOS App

### Bundled (Entwicklung)

1. `.mlpackage` in Xcode-Projekt ziehen → wird automatisch zu `.mlmodelc` kompiliert
2. `vocabulary.json` als Resource hinzufuegen

### On-demand Download (Produktion)

1. `.mlmodelc` (kompiliert) + `vocabulary.json` auf Server bereitstellen
2. In `~/Library/Application Support/Models/` ablegen
3. Optional: `model_info.json` mit Modell-Metadaten:

```json
[
  {
    "id": "OmniASR_CTC_300M",
    "name": "Omni ASR 300M",
    "vocabFile": "vocabulary.json",
    "postProcessorType": "identity"
  }
]
```

## Bekannte Probleme

| Problem | Status | Loesung |
|---------|--------|---------|
| `BatchLayout` nicht trace-bar | Geloest | Wrapper-Klasse |
| GroupNorm castet zu float32 | Kein Problem | coremltools handhabt float32↔float16 Casts |
| bfloat16 nicht CoreML-kompatibel | Geloest | Konvertierung zu float32 vor Export |
| Positional Encoding (Conv1d, k=128, groups=16) | Testen | Standard Op, sollte konvertieren |
| Relative Attention Biases | Risiko | Ggf. fest vorberechnen fuer max Laenge |
| Modell zu gross fuer iPhone RAM | Mitigation | float16 + `computeUnits = .all` |

## Modell-Architektur (Referenz)

```
Audio [1, T] @ 16kHz float32
  → layer_norm (zero mean, unit variance)
  → Wav2Vec2FeatureExtractor (7x Conv1d, Faktor ~320 Reduktion)
      Layer 1: Conv1d(1→512, k=10, s=5) + GroupNorm + GELU
      Layer 2-5: Conv1d(512→512, k=3, s=2) x4 + GELU
      Layer 6-7: Conv1d(512→512, k=2, s=2) x2 + GELU
  → Feature Projection: Linear(512→1024)
  → Positional Encoding: Conv1d(1024, k=128, groups=16)
  → Transformer Encoder: 24 Layers (1024 dim, 16 heads, FFN 4096)
  → Final Projection: Linear(1024→vocab_size)
  → CTC Decoding: argmax → consecutive dedup → blank removal
```

Output-Shape: `[1, T/320, vocab_size]` (z.B. 10s Audio → ~50 Frames)
