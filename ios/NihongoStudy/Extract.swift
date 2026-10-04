import Compression
import Foundation
import PDFKit

/// Turns a link, a file or pasted text into plain Japanese text, all on the iPad.
enum Extract {
    static let mediaExt: Set<String> = ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "aif", "aiff", "caf", "flac"]

    /// Returns (title, text).
    static func text(from source: Library.Source, progress: @escaping @Sendable (String) -> Void) async throws -> (String, String) {
        switch source {
        case .text(let t): return ("Pasted text", t)
        case .url(let u): return try await fromURL(u, progress: progress)
        case .file(let f): return try await fromFile(f, progress: progress)
        }
    }

    /// Picked files are copied in as "<uuid>-name.ext"; this gives back "name".
    static func cleanFileName(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.count > 37 && stem.dropFirst(36).first == "-" ? String(stem.dropFirst(37)) : stem
    }

    static func fromFile(_ url: URL, progress: @escaping @Sendable (String) -> Void) async throws -> (String, String) {
        let ext = url.pathExtension.lowercased()
        let title = cleanFileName(url)
        if mediaExt.contains(ext) { return (title, try await Transcriber.transcribe(url, progress: progress)) }
        switch ext {
        case "mkv", "webm", "avi", "ogg", "opus":
            throw AppError("The iPad can't read .\(ext) files. Use MP4, MOV, M4A, MP3 or WAV.")
        case "pdf":
            progress("Reading PDF")
            guard let doc = PDFDocument(url: url) else { throw AppError("Couldn't open that PDF.") }
            let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AppError("This PDF has no text layer (it's scanned images), so it can't be read.")
            }
            return (title, text)
        case "epub":
            progress("Reading EPUB")
            return (title, try epubText(url))
        case "srt", "vtt", "ass":
            return (title, cleanSubtitles(try readText(url)))
        case "html", "htm", "xhtml":
            return (title, htmlText(try readText(url)))
        default:
            return (title, try readText(url))
        }
    }

    static func fromURL(_ raw: String, progress: @escaping @Sendable (String) -> Void) async throws -> (String, String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host()?.lowercased() else { throw AppError("That doesn't look like a link.") }
        if ["youtube.com", "youtu.be", "nicovideo.jp", "tiktok.com", "vimeo.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            throw AppError("Video links can't be read on the iPad. Save the video to Photos or Files and use Upload instead.")
        }
        progress("Reading the web page")
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) }
        catch { throw AppError("Couldn't open that link. Web page links need an internet connection.") }
        let html = decode(data)
        let title = firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html).map { entities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (title?.isEmpty == false ? title! : s, htmlText(html))
    }

    // MARK: Text helpers

    static func readText(_ url: URL) throws -> String { decode(try Data(contentsOf: url)) }

    /// UTF-8 first, then Shift JIS (common in older Japanese files).
    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .shiftJIS) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func cleanSubtitles(_ raw: String) -> String {
        var lines: [String] = []
        var last: String?
        for var line in raw.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.isEmpty || line == "WEBVTT" || line.contains("-->") || line.allSatisfy(\.isNumber) { continue }
            if line.hasPrefix("Dialogue:") {
                line = line.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).last.map(String.init) ?? ""
                line = line.replacingOccurrences(of: "\\N", with: " ")
            } else if ["Kind:", "Language:", "NOTE", "STYLE", "[", "Format:", "Style:"].contains(where: line.hasPrefix)
                        || (line.prefix(12).contains(":") && line.allSatisfy(\.isASCII)) {
                continue
            }
            line = line.replacingOccurrences(of: #"<[^>]+>|\{[^}]*\}"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty && line != last { lines.append(line); last = line }
        }
        return lines.joined(separator: "\n")
    }

    /// Visible text of a page: the <article>, else <main>, else <body>, without scripts, menus or furigana.
    static func htmlText(_ html: String) -> String {
        var h = html
        for tag in ["script", "style", "nav", "header", "footer", "rt", "rp", "noscript"] {
            h = h.replacingOccurrences(of: "<\(tag)\\b[^>]*>.*?</\(tag)>", with: "\n",
                                       options: [.regularExpression, .caseInsensitive])
        }
        for tag in ["article", "main", "body"] {
            if let inner = firstMatch("<\(tag)\\b[^>]*>(.*)</\(tag)>", in: h) { h = inner; break }
        }
        h = h.replacingOccurrences(of: "<!--.*?-->", with: "", options: .regularExpression)
        h = h.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        return entities(h).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r])
    }

    static func entities(_ s: String) -> String {
        var out = s
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let r = Range(m.range, in: out), let hexR = Range(m.range(at: 1), in: out), let numR = Range(m.range(at: 2), in: out),
                      let code = UInt32(out[numR], radix: out[hexR].isEmpty ? 10 : 16), let scalar = Unicode.Scalar(code) else { continue }
                out.replaceSubrange(r, with: String(Character(scalar)))
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: EPUB

    /// Chapters in reading order (the OPF spine), falling back to every HTML file in name order.
    static func epubText(_ url: URL) throws -> String {
        let zip = try ZipReader(url)
        var order: [String] = []
        if let container = zip.text("META-INF/container.xml"),
           let opfPath = firstMatch(#"full-path="([^"]+)""#, in: container), let opf = zip.text(opfPath) {
            let base = (opfPath as NSString).deletingLastPathComponent
            var hrefs: [String: String] = [:]
            if let re = try? NSRegularExpression(pattern: "<item\\b[^>]*>", options: .caseInsensitive) {
                for m in re.matches(in: opf, range: NSRange(opf.startIndex..., in: opf)) {
                    let tag = String(opf[Range(m.range, in: opf)!])
                    if let id = firstMatch(#"\bid="([^"]+)""#, in: tag), let href = firstMatch(#"\bhref="([^"]+)""#, in: tag) {
                        let path = base.isEmpty ? href : base + "/" + href
                        hrefs[id] = path.removingPercentEncoding ?? path
                    }
                }
            }
            if let re = try? NSRegularExpression(pattern: #"<itemref\b[^>]*idref="([^"]+)""#, options: .caseInsensitive) {
                for m in re.matches(in: opf, range: NSRange(opf.startIndex..., in: opf)) {
                    if let r = Range(m.range(at: 1), in: opf), let path = hrefs[String(opf[r])] { order.append(path) }
                }
            }
        }
        if order.isEmpty {
            order = zip.names.filter { ["html", "htm", "xhtml"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        }
        let parts = order.compactMap { zip.text($0) }.map(htmlText).filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw AppError("Couldn't find any text in that EPUB.") }
        return parts.joined(separator: "\n")
    }
}

/// Just enough of a ZIP reader for EPUB files (stored and deflated entries).
struct ZipReader {
    private let data: Data
    private var entries: [String: (offset: Int, method: UInt16, compressed: Int, size: Int)] = [:]
    var names: [String] { Array(entries.keys) }

    init(_ url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // Find the end-of-central-directory record from the back.
        guard data.count >= 22, let eocd = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
            .first(where: { u32($0) == 0x0605_4b50 }) else { throw AppError("That EPUB file is damaged.") }
        var p = u32(eocd + 16)
        for _ in 0..<u16(eocd + 10) {
            guard p + 46 <= data.count, u32(p) == 0x0201_4b50 else { break }
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let name = String(decoding: data[(data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen)], as: UTF8.self)
            entries[name] = (u32(p + 42), UInt16(u16(p + 10)), u32(p + 20), u32(p + 24))
            p += 46 + nameLen + extraLen + commentLen
        }
        func localDataStart(_ header: Int) -> Int { header + 30 + u16(header + 26) + u16(header + 28) }
        for (k, e) in entries { entries[k]!.offset = localDataStart(e.offset) }
    }

    func data(_ name: String) -> Data? {
        guard let e = entries[name], e.offset + e.compressed <= data.count else { return nil }
        let raw = data[(data.startIndex + e.offset)..<(data.startIndex + e.offset + e.compressed)]
        if e.method == 0 { return Data(raw) }
        guard e.method == 8, e.size > 0 else { return e.size == 0 ? Data() : nil }
        var out = Data(count: e.size)
        let n = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, e.compressed, nil, COMPRESSION_ZLIB)
            }
        }
        return n == e.size ? out : nil
    }

    func text(_ name: String) -> String? { data(name).map(Extract.decode) }
}
