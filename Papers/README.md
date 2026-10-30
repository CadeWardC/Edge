# Papers: listen to research papers, on device

Give Papers a PDF and it makes a **5–6 minute audio overview** of the paper, entirely on your iPhone:

1. **The question**: what the researchers are asking.
2. **Why it matters**: the background and what was not known.
3. **What they did**: the approach, data and experiments.
4. **What they found**: the main results, what they mean and their limits.

That gives your brain a framework before you read the paper itself. Each section is a chapter in the player, with
its script shown underneath.

## Install the unsigned IPA

Every push that touches `Papers/` builds `Papers-unsigned.ipa` on GitHub Actions and attaches it to a release
(`papers-build-N`, under *Releases*). Sign it while installing with AltStore / SideStore or Sideloadly, or install it
with TrollStore.

On first launch, tap **Download models** (about 1.7 GB): Qwen3.5-2B Q4_K_M (1.3 GB) and Kokoro-82M v1.0 (about
360 MB). The Kokoro files come from this repo's `models-kokoro-v1_0` release, unpacked from sherpa-onnx's
`kokoro-multi-lang-v1_0.tar.bz2` by `.github/workflows/mirror-kokoro-en.yml`. The download continues in the
background.

## Adding papers

- Tap **+** and pick one or more PDFs from Files, or
- share a PDF to **Papers** from Safari, Mail or Files ("Open in Papers").

Papers are queued and summarized one at a time. A paper takes several minutes (it can be slow; that's fine).

## Background work

- Model downloads use a background `URLSession`, so they continue while the app is closed.
- Summaries run in an iOS 26 **continued processing task** (`BGContinuedProcessingTask`): leave the app and the
  progress shows on the Lock Screen / Dynamic Island while the summary is written and recorded. iOS refuses GPU work
  from a backgrounded app (unless the phone grants background GPU), so the summary model moves to the CPU while
  Papers is in the background and back to the GPU when you return. Every step is saved, so if iOS stops the work
  anyway, it picks up where it left off the next time you open the app.
- Playback continues in the background with Lock Screen controls (play/pause, ±15 s, scrubbing) and adjustable speed.

## How it works

| Step | What runs | Where |
| --- | --- | --- |
| Read the PDF | PDFKit text; Vision OCR for scanned pages; running headers, page numbers and the reference list removed | `Library/PDFText.swift` |
| Take notes | Qwen3.5-2B (llama.cpp, thinking off) reads the paper in up to 10 parts of about 2,300 tokens and notes the question, motivation, methods and results of each | `Summary/` |
| Write the script | four requests, one per section, each given the notes, the paper's opening and the sections written so far, about 210 words each | `Summary/SummaryPrompts.swift` |
| Speak | Kokoro-82M v1.0 (sherpa-onnx, full precision, CPU), one sentence at a time, into an AAC `.m4a` | `Speech/` |

sherpa-onnx 2.x dropped espeak-ng and silently skips any word missing from Kokoro's lexicon, which would drop most
of a paper's jargon. So Papers phonemizes the text itself (`Speech/EnglishPhonemizer.swift`): misaki's US lexicon,
then regular inflections (-s, -ed, -ing), compounds of known words and common prefixes/suffixes (nano + particles),
CamelCase parts (PubMed), acronyms letter by letter (DNA), and spelling rules as a last resort. Numbers, years,
percentages, symbols and abbreviations are spelled out first (`Speech/SpokenText.swift`).

Settings: six voices (Heart, Bella, Michael, Fenrir, Emma, George), reading pace, and the summary model repo (any
Hugging Face GGUF repo; a bigger model writes better summaries but is slower and needs more memory).

Files are in Documents (visible in the Files app): `Models/` and `Papers/<id>/` with `paper.pdf`, `text.txt`,
`state.json` and `summary.m4a`.

## Build locally (macOS)

```sh
brew install xcodegen cmake
./scripts/build-llama-ios.sh   # from the repo root
cd Papers
xcodegen generate
open Papers.xcodeproj
```

`scripts/make-icon.py` renders the app icon.
