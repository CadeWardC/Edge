# Edge: Mandarin speaking practice, on device

Speak Mandarin to your iPhone. Everything runs on the phone:

1. [SenseVoice-Small](https://github.com/FunAudioLLM/SenseVoice) transcribes what you said,
2. [Qwen3.5-2B](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF) corrects you **in English**, rewrites your sentence as
   natural Mandarin, and replies in Mandarin (with pinyin and an optional English translation),
3. [Kokoro-82M v1.1-zh](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh) **speaks the reply**, sentence by sentence.

Tap the mic once and talk; your turn is sent when you pause (1.6 s by default), and hands-free mode reopens the mic
after each reply, like a voice chat. You can also type Chinese instead of speaking. Nothing leaves the phone except the one-time model download.

## Install the unsigned IPA

Every push builds `Edge-unsigned.ipa` on GitHub Actions and attaches it to a release (`build-N`, under *Releases*).
It is unsigned, so sign it while installing with AltStore / SideStore, Sideloadly, or install it with TrollStore.

On first launch, tap **Download models** (about 1.9 GB: SenseVoice int8 230 MB, Qwen3.5 Q4_K_M 1.3 GB, Kokoro
390 MB). Kokoro's files come from this repo's `models-kokoro-v1_1` release, unpacked from sherpa-onnx's
`kokoro-multi-lang-v1_1.tar.bz2` by `.github/workflows/mirror-kokoro.yml` (Apache-2.0). The full-precision model is
used because the int8 one is audibly noisy (and, on CPU, slower).

It needs about 2 GB of memory while running, so any recent iPhone (6 GB or more) is fine. Earlier builds used
LFM3-Audio; this version deletes its GGUFs (about 2.5 GB) on first launch.

## Tone check

Speech recognition writes the character you *meant*, so it can't tell you got a tone wrong. Edge checks tones separately,
on device, from the pitch of your recording:

1. YIN pitch tracking every 10 ms (`Edge/Tones/ToneAnalyzer.swift`, Accelerate).
2. The voiced audio is split into as many syllables as the transcript has characters.
3. Pitch is normalized to your own range and each syllable is matched against the four tone shapes.
4. Expected tones come from a bundled dictionary (`Edge/Resources/pinyin.tsv`, built by `scripts/build-pinyin-dict.py`
   from the MIT-licensed [pinyin-data](https://github.com/mozillazg/pinyin-data) and
   [phrase-pinyin-data](https://github.com/mozillazg/phrase-pinyin-data)), with 3-3, 不 and 一 tone sandhi applied.

A syllable is only marked wrong when the match is clear; otherwise it shows as unclear. It is a rough guide.
`scripts/tones/` has the Python prototype and a synthetic-speech test (`python3 scripts/tones/test_synthetic.py`).

## How it works

| Step | Prompt | API |
| --- | --- | --- |
| Hear you | [SenseVoice-Small](https://github.com/FunAudioLLM/SenseVoice) via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (int8, Mandarin) | `SherpaOnnxOfflineRecognizer` |
| Reply | plain chat: answer in one or two short Chinese sentences (retried once if it has no Chinese), written by [Qwen3.5-2B](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF) (Q4_K_M, its own chat template, thinking off) | `chat_engine_generate` |
| Correct | the learner's sentence alone, answer prefilled with `Correct:` then `Feedback:` | text generation |
| Translate | right after the reply, when English is switched on | text generation |
| Speak | Kokoro v1.1-zh (full precision, speaker 3 female / 58 male, its own speed control) | `SherpaOnnxOfflineTtsWrapper`, one sentence at a time (24 kHz) |

- `Edge/Engine/ChatEngine.{h,cpp}` is a small C API over llama.cpp that Swift calls through the bridging header.
- `Edge/Tutor/` holds the prompts, the reply parser and the conversation state machine.
- `scripts/build-llama-ios.sh` builds `vendor/llama.xcframework` from a pinned llama.cpp commit (it has Qwen3.5 support).

## Build locally (macOS)

```sh
brew install xcodegen cmake
./scripts/build-llama-ios.sh
xcodegen generate
open Edge.xcodeproj
```
