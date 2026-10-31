# Edge: listen to scientific papers in any voice

An iPhone app that turns research papers into audio read by a cloned voice:

- **Papers:** import a PDF. DeepSeek writes an audio script in as many parts as you choose, each about as long as you
  choose, following a prompt you can edit, and a cloned voice reads every part on the phone. Listen in the app (Lock
  Screen controls, speed, auto-next) or share the `.m4a` files.
- **Speak:** type anything and hear it in a cloned voice.
- **Voices:** clone a voice from a recording (import an audio or video file, or record 5 to 15 seconds in the app).
  The app writes down what is said with Apple's on-device speech recognition; you can correct it.
- **Settings:** your DeepSeek API key (kept in the Keychain), the DeepSeek model (loaded from your account), the
  default prompt, parts and length, and the voice models.

## Voice cloning on the iPhone

Both models run on the CPU through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) and clone from a short sample
with no training:

| | Model | Download | Notes |
| --- | --- | --- | --- |
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
2. Settings › Voice models: download Best, Fast or both.
3. Voices: add a voice.
4. Papers: import a PDF and tap **Make audio**.

## Build locally (macOS)

```sh
brew install xcodegen
./scripts/fetch-sherpa-ios.sh
xcodegen generate
open Edge.xcodeproj
```
