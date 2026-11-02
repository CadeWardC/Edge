# Shuō 说: speak Mandarin, hear it back, check your tones

A separate iPhone app from Edge. Speak Mandarin; Shuō understands you on the phone, a DeepSeek or Kimi model replies in
Mandarin (with pinyin and English), the reply is spoken, and every syllable you said gets a tone check.

- **Recognition:** [SenseVoice-Small](https://github.com/FunAudioLLM/SenseVoice) (int8, 2025-09-09) on device via
  sherpa-onnx; the iPhone's Mandarin recognizer until it is downloaded.
- **Replies:** DeepSeek (`api.deepseek.com`) or Kimi (`api.moonshot.ai`, or `.cn`) with your own API key, any model on
  your account. The prompt and level are adjustable.
- **Voice:** [Kokoro v1.1-zh](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh) on device (20 voices to pick from);
  the iPhone's Chinese voice until it is downloaded.
- **Tone check:** pitch tracking (YIN) of your recording, split into syllables and matched against the four tone
  shapes, compared with the dictionary tones (`Resources/pinyin.tsv`, from mozillazg's pinyin data) after tone sandhi.
- **Hands-free:** the mic reopens after every reply; it pauses itself after 20 seconds of silence.

Every push to `Shuo/` builds `Shuo-unsigned.ipa` into a `shuo-build-N` release. The speech models come from the
`models-shuo-v1` release (`.github/workflows/mirror-shuo-models.yml`).

Build locally: `./scripts/fetch-sherpa-ios.sh && cd Shuo && xcodegen generate && open Shuo.xcodeproj`.
