#!/usr/bin/env python3
"""Builds Edge/Resources/pinyin.tsv from mozillazg/pinyin-data and phrase-pinyin-data (MIT).

Lines are "<text>\t<numbered pinyin>", e.g. "好\thao3" or "银行\tyin2 hang2".
Single characters keep their most common reading; a phrase is kept only when its
reading differs from those defaults, which is what resolves polyphones and neutral tones.
"""
import os
import re
import sys
import unicodedata

src, out = sys.argv[1], sys.argv[2]

TONE_MARKS = {"̄": 1, "́": 2, "̌": 3, "̀": 4}


def numbered(syllable):
    """'hǎo' -> 'hao3', 'ba' -> 'ba5', 'lǜ' -> 'lv4'"""
    tone = 5
    base = []
    for ch in unicodedata.normalize("NFD", syllable.strip().lower()):
        if ch in TONE_MARKS:
            tone = TONE_MARKS[ch]
        elif ch == "̈":  # ü
            base.append("v")
            base.pop(-2)
        else:
            base.append(ch)
    s = "".join(base)
    return s + str(tone) if re.fullmatch(r"[a-zv]+", s) else None


def is_hanzi(ch):
    return 0x4E00 <= ord(ch) <= 0x9FFF or 0x3400 <= ord(ch) <= 0x4DBF


chars = {}
with open(os.path.join(src, "pinyin.txt"), encoding="utf-8") as f:
    for line in f:
        m = re.match(r"U\+([0-9A-F]+):\s*([^#]+)", line)
        if not m:
            continue
        ch = chr(int(m.group(1), 16))
        if not is_hanzi(ch):
            continue
        first = numbered(m.group(2).split(",")[0])
        if first:
            chars[ch] = first

phrases = {}
with open(os.path.join(src, "large_pinyin.txt"), encoding="utf-8") as f:
    for line in f:
        if line.startswith("#") or ":" not in line:
            continue
        text, py = line.split(":", 1)
        text = text.strip()
        sylls = py.split("#")[0].split()
        if not 2 <= len(text) <= 4 or len(sylls) != len(text) or not all(c in chars for c in text):
            continue
        nums = [numbered(s) for s in sylls]
        if None in nums:
            continue
        if nums != [chars[c] for c in text]:
            phrases[text] = " ".join(nums)

os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    for k in sorted(chars):
        f.write(f"{k}\t{chars[k]}\n")
    for k in sorted(phrases):
        f.write(f"{k}\t{phrases[k]}\n")
print(f"{len(chars)} characters, {len(phrases)} phrases -> {out} ({os.path.getsize(out) // 1024} KB)")
