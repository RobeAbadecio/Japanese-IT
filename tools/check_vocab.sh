#!/bin/zsh
# Checks that the iPad's word list (ios/NihongoStudy/Vocab.swift + MeCab + JMdict) gives exactly the same
# result as the old Python version (app/vocab.py) on the saved transcripts in data/jobs.
# Needs: tools/build_resources.py run once, and the project's .venv. Usage: tools/check_vocab.sh
set -e
cd "${0:A:h}/.."
TMP=$(mktemp -d)
for f in ios/MeCab/*.cpp; do clang++ -std=gnu++14 -O1 -DHAVE_CONFIG_H -Iios/MeCab -w -c $f -o $TMP/${f:t:r}.o; done
cat > $TMP/main.swift <<'SWIFT'
import Foundation
resources = URL(fileURLWithPath: CommandLine.arguments[1])
let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
FileHandle.standardOutput.write(try! JSONEncoder().encode(Vocab.build(text, progress: { _ in })))
SWIFT
swiftc -O -import-objc-header ios/NihongoStudy/Bridging.h -Iios/MeCab ios/NihongoStudy/{Tokenizer,Dictionary,Vocab,Models}.swift \
  $TMP/main.swift $TMP/*.o -lc++ -lsqlite3 -o $TMP/vocab
.venv/bin/python - "$TMP/vocab" <<'PY'
import glob, json, subprocess, sys
sys.path.insert(0, ".")
from app import vocab
for f in sorted(glob.glob("data/jobs/*.json")):
    t = json.load(open(f)).get("transcript") or ""
    py = vocab.build(t)
    sw = json.loads(subprocess.run([sys.argv[1], "ios/Resources"], input=t.encode(), capture_output=True).stdout)
    print(f"{f}: {'same' if py == sw else 'DIFFERENT'} ({len(py)} words)")
PY
rm -rf $TMP
