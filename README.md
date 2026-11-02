# Edge: listen to scientific papers in any voice

An iPhone app (English) that turns research papers into audio read by a natural voice: one of 27 built-in voices,
or any voice cloned from a short recording.

This repo also holds **[Shuō 说](Shuo/README.md)**, a separate app for speaking Mandarin with tone checks
(`shuo-build-N` releases).

- **Papers:** import a PDF (or share one to Edge). DeepSeek writes two audios from two prompts you can edit: a light
  **introduction** (5–6 minutes) and an **in-depth recap** (15–16 minutes). Add, remove or change the audios in
  Settings or per paper. The voice you pick reads them on the phone; listen in the app (Lock Screen controls, speed,
  auto-next) or share the `.m4a` files.
- **Speak:** type anything and hear it in any of your voices.
- **Voices:** Kokoro's 27 built-in English voices, and your own: clone a voice from a recording (import an .m4a or other audio file, share a recording from Voice Memos to Edge, or record 5 to 15 seconds in the app).
  The app writes down what is said with Apple's on-device speech recognition; you can correct it.
- **Settings:** your DeepSeek API key (kept in the Keychain), the DeepSeek model (loaded from your account), the
  audios made for each paper (prompt and length of each), and the voice models.

## Voices on the iPhone

All three models run on the CPU through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). The two cloning models
copy a voice from a short sample with no training:

| | Model | Download | Notes |
| --- | --- | --- | --- |
| **Built-in voices** | [Kokoro-82M v1.0](https://huggingface.co/hexgrad/Kokoro-82M) (full precision) | ~380 MB | 27 English voices (American and British). About 0.65× real time. Apache-2.0. |
| **Best** | [ZipVoice-Distill](https://github.com/k2-fsa/ZipVoice) (flow matching, full precision) + Vocos vocoder | ~575 MB | Closest, most natural clone. Uses the sample's transcript. English and Chinese. Apache-2.0. |
| **Fast** | [Kyutai Pocket TTS](https://github.com/kyutai-labs/pocket-tts) (int8) | ~125 MB | Clones from the sound alone, about twice as fast. English. Non-commercial licence. |

On a desktop CPU (2 threads) Best runs at about 1.4× real time with 8 steps and Fast at about 0.6×; an iPhone is in the
same range. Long papers keep rendering in the background on iOS 26 (continued processing task).

The models are downloaded in the app from this repo's `models-voice-v1` release, which
`.github/workflows/mirror-voice-models.yml` repacks from sherpa-onnx's archives.

sherpa-onnx is pinned to **1.12.40** (`scripts/fetch-sherpa-ios.sh`): the 2.x releases dropped espeak-ng, which
ZipVoice needs to read English.

## Install

Every push builds `Edge-unsigned.ipa` on GitHub Actions and attaches it to a release (`build-N`). Sign it while
installing with AltStore / SideStore or Sideloadly, or install it with TrollStore. Then in the app:

1. Settings › DeepSeek: paste your API key and tap **Save and check**.
2. Settings › Voice models: download Kokoro for the built-in voices, and Best and/or Fast to clone voices.
3. Voices: pick a built-in voice, or add a recording to clone one.
4. Papers: import a PDF and tap **Make audio**.

## Build locally (macOS)

```sh
brew install xcodegen
./scripts/fetch-sherpa-ios.sh
xcodegen generate
open Edge.xcodeproj
```
