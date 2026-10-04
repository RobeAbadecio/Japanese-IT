"""Builds the dictionaries the iPad app bundles, into ios/Resources/ (gitignored, ~280 MB):
- unidic/: the UniDic-lite files MeCab needs to split words (copied from the unidic_lite package)
- jmdict.sqlite: a small JMdict with meanings, in jamdict's order so the app picks the same entry

Run once before building the app, with a Python that has unidic-lite and jamdict-data installed:
    .venv/bin/python tools/build_resources.py
"""
import shutil
import sqlite3
from pathlib import Path

import jamdict_data
import unidic_lite

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios" / "Resources" / "jmdict.sqlite"
UNIDIC = ROOT / "ios" / "Resources" / "unidic"

UNIDIC.mkdir(parents=True, exist_ok=True)
for name in ("dicrc", "sys.dic", "matrix.bin", "char.bin", "unk.dic", "BSD", "COPYING", "version"):
    shutil.copy2(Path(unidic_lite.DICDIR) / name, UNIDIC / name)


def to_hiragana(s: str) -> str:
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s or "")


src = sqlite3.connect(jamdict_data.JAMDICT_DB_PATH)
OUT.unlink(missing_ok=True)
out = sqlite3.connect(OUT)
out.executescript("""
CREATE TABLE entries (id INTEGER PRIMARY KEY, kana TEXT NOT NULL, senses TEXT NOT NULL);
CREATE TABLE keys (text TEXT NOT NULL, id INTEGER NOT NULL);
""")

kana, keys, senses = {}, [], {}
for idseq, text in src.execute("SELECT idseq, text FROM Kana ORDER BY ID"):
    kana.setdefault(idseq, []).append(to_hiragana(text))
    keys.append((text, idseq))
for idseq, text in src.execute("SELECT idseq, text FROM Kanji ORDER BY ID"):
    keys.append((text, idseq))
glosses = {}
for sid, text in src.execute("SELECT sid, text FROM SenseGloss WHERE lang = 'eng' ORDER BY rowid"):
    glosses.setdefault(sid, []).append(text)
for sid, idseq in src.execute("SELECT ID, idseq FROM Sense ORDER BY ID"):
    s = senses.setdefault(idseq, [])
    if len(s) < 3:  # the app shows up to 3 senses, like the Mac version did
        s.append("/".join(glosses.get(sid, [])).replace("/", ", "))

# Entry rowid order is the order jamdict returns matches in.
order = {idseq: i for i, (idseq,) in enumerate(src.execute("SELECT idseq FROM Entry ORDER BY rowid"))}
out.executemany("INSERT INTO entries VALUES (?, ?, ?)",
                ((order[i], "\t".join(kana.get(i, [])), "\x1f".join(senses.get(i, []))) for i in order))
out.executemany("INSERT INTO keys VALUES (?, ?)", ((t, order[i]) for t, i in keys if i in order))
out.execute("CREATE INDEX keys_text ON keys(text)")
out.commit()
out.execute("VACUUM")
print(f"{len(order)} entries, {len(keys)} keys -> {OUT} ({OUT.stat().st_size / 1e6:.1f} MB); UniDic copied to {UNIDIC}")
