"""Vocabulary list: tokenize with MeCab (UniDic), group by dictionary form, look up meanings in JMdict."""
import re
from collections import OrderedDict

import fugashi
from jamdict import Jamdict

KEEP_POS = {"名詞", "動詞", "形容詞", "形状詞", "副詞", "連体詞", "接続詞", "感動詞", "代名詞"}
SKIP_POS2 = {"数詞"}
KANJI = re.compile(r"[\u3400-\u9fff]")
JP_CHAR = re.compile(r"[぀-ヿ㐀-鿿]")
SENTENCE_SPLIT = re.compile(r"(?<=[。！？!?])|\n")

_tagger = None


def tagger():
    global _tagger
    if _tagger is None:
        _tagger = fugashi.Tagger()
    return _tagger


def to_hiragana(s: str) -> str:
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s or "")


def build(text: str, progress=lambda *_: None) -> list[dict]:
    t = tagger()
    words: "OrderedDict[str, dict]" = OrderedDict()
    sentences = [s.strip() for s in SENTENCE_SPLIT.split(text) if s and s.strip()]

    for sentence in sentences:
        for tok in t(sentence):
            f = tok.feature
            if f.pos1 not in KEEP_POS or f.pos2 in SKIP_POS2:
                continue
            base = f.orthBase if f.orthBase and f.orthBase != "*" else tok.surface
            if not JP_CHAR.search(base):
                continue
            entry = words.get(base)
            if entry is None:
                entry = words[base] = {
                    "word": base,
                    "reading": to_hiragana(f.kanaBase if f.kanaBase and f.kanaBase != "*" else tok.surface),
                    "pos": f.pos1,
                    "proper": f.pos2 == "固有名詞",
                    "count": 0,
                    "forms": [],
                    "example": sentence[:200],
                    "lemma": (f.lemma or "").split("-")[0],
                }
            entry["count"] += 1
            if tok.surface != base and tok.surface not in entry["forms"] and len(entry["forms"]) < 5:
                entry["forms"].append(tok.surface)

    progress(f"Looking up {len(words)} words in the dictionary")
    jmd = Jamdict()
    for entry in words.values():
        entry["meanings"] = lookup(jmd, entry.pop("lemma"), entry["word"], entry["reading"])
        if not KANJI.search(entry["word"]):
            entry["reading"] = entry["word"]

    return sorted(words.values(), key=lambda w: -w["count"])


def lookup(jmd: Jamdict, lemma: str, word: str, reading: str) -> list[str]:
    # UniDic's lemma carries the kanji spelling (いる -> 居る), which picks the right homonym.
    entries = []
    for key in dict.fromkeys(k for k in (lemma, word, reading) if k and k != "*"):
        try:
            entries = jmd.lookup(key, strict_lookup=True, lookup_chars=False, lookup_ne=False).entries
        except Exception:
            entries = []
        if entries:
            break
    if not entries:
        return []
    best = next((e for e in entries if any(to_hiragana(k.text) == reading for k in e.kana_forms)), entries[0])
    return [s.text().replace("/", ", ") for s in best.senses[:3]]


def normalize(text: str) -> dict:
    """Turn a typed word (any inflection) into the same dictionary-form entry build() would produce."""
    text = text.strip()
    kept = []
    for tok in tagger()(text):
        f = tok.feature
        if f.pos1 in KEEP_POS and f.pos2 not in SKIP_POS2:
            kept.append(tok)
    if len(kept) == 1:
        tok, f = kept[0], kept[0].feature
        word = f.orthBase if f.orthBase and f.orthBase != "*" else tok.surface
        reading = to_hiragana(f.kanaBase if f.kanaBase and f.kanaBase != "*" else tok.surface)
        lemma = (f.lemma or "").split("-")[0]
    else:  # a phrase UniDic keeps together, or something it can't split cleanly: keep as typed
        word, reading, lemma = text, to_hiragana(text), ""
    if not KANJI.search(word):
        reading = word
    return {"word": word, "reading": reading, "meanings": lookup(Jamdict(), lemma, word, reading)}
