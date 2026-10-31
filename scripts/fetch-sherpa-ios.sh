#!/usr/bin/env bash
# Downloads sherpa-onnx's prebuilt static iOS libraries (sherpa-onnx + onnxruntime) into vendor/.
# Pinned to 1.12.40: the 2.x releases dropped espeak-ng, which ZipVoice needs to read English.
set -euo pipefail

VERSION="1.12.40"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$ROOT/vendor/sherpa.version"

if [[ -d "$ROOT/vendor/sherpa-onnx.xcframework" && "$(cat "$STAMP" 2>/dev/null)" == "$VERSION" ]]; then
    echo "sherpa-onnx $VERSION is already in vendor/"
    exit 0
fi

WORK="$(mktemp -d)"
curl -sSfL -o "$WORK/ios.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$VERSION/sherpa-onnx-v$VERSION-ios.tar.bz2"
tar xjf "$WORK/ios.tar.bz2" -C "$WORK"

rm -rf "$ROOT/vendor/sherpa-onnx.xcframework" "$ROOT/vendor/onnxruntime.xcframework"
mkdir -p "$ROOT/vendor"
cp -R "$WORK/build-ios/sherpa-onnx.xcframework" "$ROOT/vendor/"
cp -R "$WORK"/build-ios/ios-onnxruntime/*/onnxruntime.xcframework "$ROOT/vendor/"
echo "$VERSION" > "$STAMP"
rm -rf "$WORK"
ls "$ROOT/vendor"
