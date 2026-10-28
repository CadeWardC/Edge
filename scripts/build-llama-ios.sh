#!/usr/bin/env bash
# Builds vendor/llama.xcframework (llama.cpp + libmtmd, Metal, iOS arm64) from a pinned commit.
# The commit is the first upstream one with LFM3-Audio-2B speech in and out (ggml-org/llama.cpp#31257).
set -euo pipefail

LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_COMMIT="522021325546ea322b0b1e58a50f9dbf03a5f197"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/build/llama.cpp}"
OUT="$ROOT/vendor/llama.xcframework"
STAMP="$ROOT/vendor/llama.commit"

if [[ -d "$OUT" && "$(cat "$STAMP" 2>/dev/null)" == "$LLAMA_COMMIT" ]]; then
    echo "llama.xcframework is up to date ($LLAMA_COMMIT)"
    exit 0
fi

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"
git init -q
git remote add origin "$LLAMA_REPO"
git fetch -q --depth 1 origin "$LLAMA_COMMIT"
git checkout -q FETCH_HEAD

./build-xcframework.sh ios-device

rm -rf "$OUT"
mkdir -p "$ROOT/vendor"
cp -R build-apple/llama.xcframework "$OUT"
echo "$LLAMA_COMMIT" > "$STAMP"
echo "built $OUT"
