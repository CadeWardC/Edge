# Papers: listen to research papers and recordings, on device

Give Papers a PDF and, entirely on your iPhone, it makes three things to listen to:

1. **Overview (5–6 min):** the question the researchers ask, why it matters, what they did, what they found. A
   framework for your brain before you read the paper.
2. **In depth (10–15 min):** the main findings, what each experiment demonstrates, how each figure supports the
   conclusions, limitations and weaknesses, and what the researchers have not established.
3. **Questions:** 5–10 study questions with in-depth answers. In the audio, each question is followed by a pause
   to think before the answer; in the app, answers are hidden until you tap.

The in-depth audio and the questions use two voices: a second voice asks the question that leads into each part
and the main voice explains, so it sounds like a conversation and not a lecture.

The **Audio** tab takes a recording (lecture, meeting, interview, voice memo or video), transcribes it with
timestamps and summarizes it into an overview, key points and action items. Tap a line of the transcript to hear it.

## Install the unsigned IPA

Every push that touches `Papers/` builds `Papers-unsigned.ipa` on GitHub Actions and attaches it to a release
(`papers-build-N`, under *Releases*). Sign it while installing with AltStore / SideStore or Sideloadly, or install it
with TrollStore.

On first launch, tap **Download models** (about 1.7 GB): Qwen3.5-2B Q4_K_M (1.3 GB) and Kokoro-82M v1.0 (about
360 MB). The Audio tab asks for speech recognition separately (about 670 MB): NVIDIA Parakeet TDT 0.6B v3 int8 and
Silero VAD, from the `models-parakeet-v3` release made by `.github/workflows/mirror-parakeet.yml`. The Kokoro files come from this repo's `models-kokoro-v1_0` release, unpacked from sherpa-onnx's
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

| Step | What runs |
| --- | --- |
| Read the PDF | PDFKit text; Vision OCR for scanned pages; running headers, page numbers and the reference list removed; figure and table captions found |
| Take notes | Qwen3.5-2B (llama.cpp, thinking off, temperature 0) reads the paper in up to 10 parts of about 2,300 tokens, noting under fixed headings: question, motivation, methods, experiments, figures, findings, limitations |
| Write | each part of each script is written from the notes that matter for it **plus passages retrieved from the paper itself** (BM25), so the model works from the paper's own words |
| Check | any sentence that cites a number the paper does not contain is removed |
| Speak | Kokoro-82M v1.0 (sherpa-onnx, full precision, CPU) with two voices, sentence and paragraph pauses, into AAC `.m4a` files with chapters |
| Transcribe | AVFoundation decodes any audio or video to 16 kHz; Silero VAD finds the speech; Parakeet TDT 0.6B v3 writes it with punctuation |
| Summarize | transcripts are read in parts into bullet notes, then merged into an overview, key points and action items (numbers checked against the transcript) |

The overview is recorded as soon as it is written, so it can be heard while the rest is made.

### Checked on real inputs

`Papers/Package.swift` builds the app's own pipeline code (`Papers/Papers/Core`) for macOS, and
`.github/workflows/papers-eval.yml` runs it with the same models on real papers and a synthetic meeting recording,
printing every note, script, question, answer, transcript and summary and uploading the recordings. Use
*Run workflow* to try your own PDF URLs or another summary model.

### Pronunciation

sherpa-onnx 2.x dropped espeak-ng and silently skips any word missing from Kokoro's lexicon, which would drop most
of a paper's jargon. So Papers phonemizes the text itself (`Core/EnglishPhonemizer.swift`): misaki's US lexicon,
then regular inflections (-s, -ed, -ing), compounds of known words and common prefixes/suffixes (nano + particles),
CamelCase parts (PubMed), acronyms letter by letter (DNA), and spelling rules as a last resort. Numbers, years,
percentages, symbols and abbreviations are spelled out first (`Core/SpokenText.swift`).

Settings: the main and second voices (eight Kokoro voices), reading pace, and the summary model. Standard is
Qwen3.5-2B. Larger is Qwen3.5-4B (2.7 GB, about 3.4 GB of memory while running); Settings shows how much memory
iOS gives Papers and only offers the larger model when it fits, since a 6 GB iPhone 15 usually does not have room.

Files are in Documents (visible in the Files app): `Models/`, `Papers/<id>/` (`paper.pdf`, `text.txt`,
`state.json`, `overview.m4a`, `deep.m4a`, `questions.m4a`) and `Recordings/<id>/`.

## Build locally (macOS)

```sh
brew install xcodegen cmake
./scripts/build-llama-ios.sh   # from the repo root
cd Papers
xcodegen generate
open Papers.xcodeproj
```

`scripts/make-icon.py` renders the app icon.
