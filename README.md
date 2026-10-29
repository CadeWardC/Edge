# Edge: Mandarin speaking practice with LFM3-Audio, on device

Speak Mandarin to your iPhone. **LFM3-Audio-2B** (Liquid AI, released 2026-10-27) runs fully on device through
llama.cpp + Metal. It:

1. transcribes what you said (`Perform ASR in Chinese.`),
2. corrects you **in English** and rewrites your sentence as natural Mandarin,
3. replies in Mandarin (with pinyin and an optional English translation),
4. **speaks the reply** with LFM3-Audio's own Chinese voice, streamed as it is generated.

Tap the mic once and talk; your turn is sent when you pause (1.6 s by default), and hands-free mode reopens the mic
after each reply, like a voice chat. You can also type Chinese instead of speaking. Nothing leaves the phone except the one-time model download.

## Install the unsigned IPA

Every push builds `Edge-unsigned.ipa` on GitHub Actions and attaches it to a release (`build-N`, under *Releases*).
It is unsigned, so sign it while installing with AltStore / SideStore, Sideloadly, or install it with TrollStore.

On first launch, tap **Download model**. That fetches the backbone GGUF (Q8_0) and the `mmproj` GGUF
(audio encoder, depthformer and codec) from `LiquidAI/LFM3-Audio-2B-GGUF`. You can change the repo in Settings,
or copy both `.gguf` files into *Files › On My iPhone › Edge*.

Use the Q8_0 backbone, not a 4-bit one: speech is generated from the backbone's hidden states, and the 4-bit
backbones are ~45x further off the reference ([audio.cpp's LFM3-Audio validation](https://github.com/0xShug0/audio.cpp/blob/main/docs/models/lfm3_audio.md)),
which comes out as babble while text still looks fine. The Q8_0 model takes about 3 GB of memory while running,
so an iPhone with 8 GB (15 Pro or newer) is the safe choice; 6 GB models may be closed by iOS.

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
| Hear you | system `Perform ASR in Chinese.`, the recording in the user turn | `mtmd_tokenize` + `mtmd_helper_eval_chunks` |
| Reply + correct | tutor system prompt; it answers in `Reply / English / Feedback / Correct` lines | text generation, `<\|audio_start\|>` / `<\|mixed_start\|>` banned |
| Speak | `Perform TTS in Chinese using a female/male voice.` + `<\|audio_start\|>` | `mtmd_helper_gen_audio_*` (streaming PCM, 24 kHz) |

The conversation lives in its own sequence of the model's memory (seq 0) and is never cleared between turns:
each turn's prompt extends the last one, so only the new sentence is evaluated. Speech recognition and the voice
run on a scratch sequence (seq 1). The reply is written first; generation pauses once it is complete, the voice
speaks it, and the translation and feedback are written while it plays. Pinyin comes from the bundled dictionary.

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
