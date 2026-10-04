import Foundation

/// The word list: split with MeCab (UniDic), group by dictionary form, look up meanings in JMdict.
enum Vocab {
    static let keepPOS: Set<String> = ["名詞", "動詞", "形容詞", "形状詞", "副詞", "連体詞", "接続詞", "感動詞", "代名詞"]
    static let skipPOS2: Set<String> = ["数詞"]

    static func hasKanji(_ s: String) -> Bool { s.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } }
    static func hasJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
    }
    static func toHiragana(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { (0x30A1...0x30F6).contains($0.value) ? Unicode.Scalar($0.value - 0x60)! : $0 }))
    }

    /// Splits after 。！？!? and at line breaks.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for c in text {
            if c == "\n" { out.append(cur); cur = ""; continue }
            cur.append(c)
            if "。！？!?".contains(c) { out.append(cur); cur = "" }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func build(_ text: String, progress: (String) -> Void) -> [VocabItem] {
        struct Entry { var item: VocabItem; var lemma: String; var order: Int }
        var words: [String: Entry] = [:]
        let all = sentences(text)
        for (i, sentence) in all.enumerated() {
            if i % 500 == 0 && all.count > 1000 { progress("Splitting words (\(i * 100 / all.count)%)") }
            for tok in Tokenizer.shared.tokenize(sentence) {
                guard keepPOS.contains(tok.pos1), !skipPOS2.contains(tok.pos2) else { continue }
                let base = tok.orthBase != "*" && !tok.orthBase.isEmpty ? tok.orthBase : tok.surface
                guard hasJapanese(base) else { continue }
                if words[base] == nil {
                    let kana = tok.kanaBase != "*" && !tok.kanaBase.isEmpty ? tok.kanaBase : tok.surface
                    words[base] = Entry(item: VocabItem(word: base, reading: toHiragana(kana), pos: tok.pos1,
                                                        proper: tok.pos2 == "固有名詞", count: 0, forms: [],
                                                        example: String(sentence.prefix(200)), meanings: nil),
                                        lemma: String(tok.lemma.split(separator: "-").first ?? ""), order: words.count)
                }
                words[base]!.item.count += 1
                if tok.surface != base, !(words[base]!.item.forms ?? []).contains(tok.surface), (words[base]!.item.forms ?? []).count < 5 {
                    words[base]!.item.forms!.append(tok.surface)
                }
            }
        }

        progress("Looking up \(words.count) words in the dictionary")
        var items: [(Int, VocabItem)] = []
        for e in words.values {
            var item = e.item
            item.meanings = JMdict.shared.meanings(lemma: e.lemma, word: item.word, reading: item.reading)
            if !hasKanji(item.word) { item.reading = item.word }
            items.append((e.order, item))
        }
        // Most frequent first; ties keep the order the words first appeared in.
        return items.sorted { $0.1.count != $1.1.count ? $0.1.count > $1.1.count : $0.0 < $1.0 }.map(\.1)
    }

    /// Turns a typed word (any inflection) into the same dictionary-form entry `build` would produce.
    static func normalize(_ raw: String) -> KnownWord {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = Tokenizer.shared.tokenize(text).filter { keepPOS.contains($0.pos1) && !skipPOS2.contains($0.pos2) }
        var word = text, reading = toHiragana(text), lemma = ""
        if kept.count == 1, let tok = kept.first {
            word = tok.orthBase != "*" && !tok.orthBase.isEmpty ? tok.orthBase : tok.surface
            reading = toHiragana(tok.kanaBase != "*" && !tok.kanaBase.isEmpty ? tok.kanaBase : tok.surface)
            lemma = String(tok.lemma.split(separator: "-").first ?? "")
        }  // otherwise a phrase UniDic keeps together, or something it can't split cleanly: keep as typed
        if !hasKanji(word) { reading = word }
        return KnownWord(word: word, reading: reading,
                         meanings: JMdict.shared.meanings(lemma: lemma, word: word, reading: reading), added_at: nil)
    }
}
