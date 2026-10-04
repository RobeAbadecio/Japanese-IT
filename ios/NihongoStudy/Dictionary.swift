import Foundation
import SQLite3

/// English meanings from the bundled JMdict (built by tools/build_resources.py).
final class JMdict: @unchecked Sendable {
    static let shared = JMdict()

    private var db: OpaquePointer?
    private var stmt: OpaquePointer?
    private let lock = NSLock()

    private init() {
        let path = resources.appending(path: "jmdict.sqlite").path
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        sqlite3_prepare_v2(db, "SELECT DISTINCT e.id, e.kana, e.senses FROM keys k JOIN entries e ON e.id = k.id WHERE k.text = ? ORDER BY e.id",
                           -1, &stmt, nil)
    }

    /// Up to 3 senses. UniDic's lemma carries the kanji spelling (いる → 居る), which picks the right homonym,
    /// so it's tried first, then the word, then the reading. Prefers the entry whose kana matches the reading.
    func meanings(lemma: String, word: String, reading: String) -> [String] {
        var seen = Set<String>()
        for key in [lemma, word, reading] where !key.isEmpty && key != "*" && seen.insert(key).inserted {
            let entries = lookup(key)
            guard !entries.isEmpty else { continue }
            let best = entries.first { $0.kana.contains(reading) } ?? entries[0]
            return best.senses
        }
        return []
    }

    private func lookup(_ key: String) -> [(kana: [String], senses: [String])] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt else { return [] }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out: [(kana: [String], senses: [String])] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kana = String(cString: sqlite3_column_text(stmt, 1)).split(separator: "\t").map(String.init)
            let senses = String(cString: sqlite3_column_text(stmt, 2)).split(separator: "\u{1f}").map(String.init)
            out.append((kana, senses))
        }
        return out
    }
}
