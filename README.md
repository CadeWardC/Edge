# Edge: Mandarin speaking practice with LFM3-Audio, on device

Speak Mandarin to your iPhone. **LFM3-Audio-2B** (Liquid AI, released 2026-10-27) runs fully on device through
llama.cpp + Metal. It:

1. transcribes what you said (`Perform ASR in Chinese.`),
2. corrects you **in English** and rewrites your sentence as natural Mandarin,
3. replies in Mandarin (with pinyin and an optional English translation),
4. **speaks the reply** with LFM3-Audio's own Chinese voice, streamed as it is generated.

You can also type Chinese instead of speaking. Nothing leaves the phone except the one-time model download.

## Install the unsigned IPA

Every push builds `Edge-unsigned.ipa` on GitHub Actions and attaches it to a release (`build-N`, under *Releases*).
It is unsigned, so sign it while installing with AltStore / SideStore, Sideloadly, or install it with TrollStore.

On first launch, tap **Download model**. That fetches the backbone GGUF (Q4_K_M preferred) and the `mmproj` GGUF
(audio encoder, depthformer and codec) from `LiquidAI/LFM3-Audio-2B-GGUF`. You can change the repo in Settings,
or copy both `.gguf` files into *Files › On My iPhone › Edge*.

A device with 6 GB+ RAM (iPhone 13 Pro / 14 / 15 or newer) is recommended.

## How it works

| Step | Prompt | API |
| --- | --- | --- |
| Hear you | system `Perform ASR in Chinese.`, the recording in the user turn | `mtmd_tokenize` + `mtmd_helper_eval_chunks` |
| Correct + reply | tutor system prompt; it answers in `Feedback / Correct / Reply / Pinyin / English` lines | text generation, `<\|audio_start\|>` / `<\|mixed_start\|>` banned |
| Speak | `Perform TTS in Chinese using a female/male voice.` + `<\|audio_start\|>` | `mtmd_helper_gen_audio_*` (streaming PCM, 24 kHz) |

- `Edge/Engine/LFMEngine.{h,cpp}` is a small C API over llama.cpp/libmtmd that Swift calls through the bridging header.
- `Edge/Tutor/` holds the prompts, the reply parser and the conversation state machine.
- `scripts/build-llama-ios.sh` builds `vendor/llama.xcframework` from a pinned llama.cpp commit (the first one with LFM3-Audio speech output).

## Build locally (macOS)

```sh
brew install xcodegen cmake
./scripts/build-llama-ios.sh
xcodegen generate
open Edge.xcodeproj
```
