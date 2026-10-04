import Foundation

/// Where the bundled dictionaries are. Only changed by tools/check_vocab.sh, which runs this code on the Mac.
nonisolated(unsafe) var resources = Bundle.main.resourceURL!

/// Splits Japanese into words with MeCab and the bundled UniDic-lite dictionary (the same setup the Mac used).
final class Tokenizer: @unchecked Sendable {
    static let shared = Tokenizer()

    struct Token {
        let surface: String
        let features: [String]
        func feature(_ i: Int) -> String { i < features.count ? features[i] : "*" }
        // UniDic field positions (see the dictionary's dicrc).
        var pos1: String { feature(0) }
        var pos2: String { feature(1) }
        var lemma: String { feature(7) }
        var orthBase: String { feature(10) }
        var kanaBase: String { feature(18) }
    }

    private let tagger: OpaquePointer
    private let lock = NSLock()  // a MeCab tagger can't be used from two threads at once

    private init() {
        let dic = resources.appending(path: "unidic").path
        var args = ["mecab", "-r", "/dev/null", "-d", dic].map { strdup($0) }
        defer { args.forEach { free($0) } }
        guard let t = mecab_new(Int32(args.count), &args) else {
            fatalError("MeCab couldn't open the dictionary: \(String(cString: mecab_strerror(nil)))")
        }
        tagger = t
    }

    func tokenize(_ text: String) -> [Token] {
        lock.lock()
        defer { lock.unlock() }
        var out: [Token] = []
        text.withCString { cstr in
            var node = mecab_sparse_tonode(tagger, cstr)
            while let n = node {
                let stat = Int32(n.pointee.stat)
                if stat != MECAB_BOS_NODE && stat != MECAB_EOS_NODE {
                    let bytes = UnsafeRawBufferPointer(start: n.pointee.surface, count: Int(n.pointee.length))
                    out.append(Token(surface: String(decoding: bytes, as: UTF8.self),
                                     features: Self.splitCSV(String(cString: n.pointee.feature))))
                }
                node = UnsafePointer(n.pointee.next)
            }
        }
        return out
    }

    /// MeCab features are CSV; a few fields are quoted because they contain commas.
    static func splitCSV(_ s: String) -> [String] {
        var fields: [String] = []
        var cur = ""
        var quoted = false
        for c in s {
            if c == "\"" { quoted.toggle() }
            else if c == "," && !quoted { fields.append(cur); cur = "" }
            else { cur.append(c) }
        }
        fields.append(cur)
        return fields
    }
}
