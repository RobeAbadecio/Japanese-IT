import Foundation
import FoundationModels

// Finds the grammar patterns used in a text with Apple Intelligence on this iPad, then saves them with the
// analysis so they show up in the library and the Anki export.

@Generable
struct FoundExample {
    @Guide(description: "A sentence copied exactly from the text")
    var japanese: String
    @Guide(description: "English translation of that sentence")
    var english: String
}

@Generable
struct FoundPoint {
    @Guide(description: "The pattern in textbook form, e.g. 〜てしまう")
    var pattern: String
    @Guide(description: "JLPT level", .anyOf(["N5", "N4", "N3", "N2", "N1", "—"]))
    var jlpt: String
    @Guide(description: "One-line meaning in English")
    var meaning: String
    @Guide(description: "One or two plain-English sentences on how it works")
    var explanation: String
    @Guide(description: "Examples from the text", .count(1...2))
    var examples: [FoundExample]
}

@Generable
struct FoundGrammar {
    @Guide(description: "Distinct grammar patterns used in the text", .maximumCount(8))
    var points: [FoundPoint]
}

@MainActor
final class GrammarEngine: ObservableObject {
    static let shared = GrammarEngine()

    static let chunkChars = 1500  // the on-device model has a 4,096-token window shared by prompt and answer
    static let minChars = 300     // a part still too long at this size is skipped
    static let maxChars = 30000   // caps run time on whole books; vocabulary still covers everything

    static let instructions = """
    You are a Japanese teacher helping an English-speaking learner study real material. \
    List the distinct grammar patterns that appear in the Japanese text: verb and adjective \
    conjugations (te-form, passive, causative, potential, volitional, conditionals), particles used \
    in notable ways, sentence-ending expressions, and set patterns such as 〜ようにする or 〜わけではない. \
    Skip plain は, が and を. Write every meaning and explanation in English. \
    Only list a pattern that is really used in the text, and quote the exact sentence that uses it.
    """

    /// Job id → "Finding grammar (3 of 20)" while it runs.
    @Published private(set) var progress: [String: String] = [:]
    /// Job id → why grammar couldn't be found.
    @Published private(set) var errors: [String: String] = [:]
    /// Job id → when grammar was last saved, so open screens know to reload.
    @Published private(set) var saved: [String: Date] = [:]
    private var lastError: String?

    /// Nil when Apple Intelligence is ready on this iPad; otherwise what to do about it.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence on this iPad (Settings > Apple Intelligence & Siri) to get grammar concepts."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model on this iPad. Try again later."
        case .unavailable(.deviceNotEligible):
            return "This device can't run Apple Intelligence, so grammar concepts are unavailable."
        case .unavailable(let other):
            return "Apple Intelligence is unavailable on this iPad (\(other))."
        }
    }

    /// Starts finding grammar for a job unless it's already running. Keeps going if the screen is closed,
    /// as long as the app stays open.
    func start(jobID: String, text: String) {
        guard progress[jobID] == nil else { return }
        errors[jobID] = nil
        if let reason = Self.unavailableReason { errors[jobID] = reason; return }
        let parts = Self.chunks(String(text.prefix(Self.maxChars)), size: Self.chunkChars)
        progress[jobID] = "Finding grammar on this iPad (0 of \(parts.count))"
        Task {
            defer { progress[jobID] = nil }
            var found: [GrammarPoint] = []
            var skipped = 0
            for (i, part) in parts.enumerated() {
                let (points, s) = await analyze(part)
                found += points
                skipped += s
                progress[jobID] = "Finding grammar on this iPad (\(i + 1) of \(parts.count))"
            }
            if found.isEmpty && skipped > 0 {  // nothing worked; don't save an empty list as if it were the answer
                errors[jobID] = "Apple Intelligence couldn't read this text (\(lastError ?? "unknown error")). Try again later."
                return
            }
            do {
                try await Library.saveGrammar(jobID, Self.merge(found), truncated: text.count > Self.maxChars, skipped: skipped)
                saved[jobID] = Date()
            } catch {
                errors[jobID] = "Grammar was found but couldn't be saved: \(error.localizedDescription)"
            }
        }
    }

    /// Returns (grammar points, parts skipped). Halves a part the model says is too long.
    private func analyze(_ text: String) async -> ([GrammarPoint], Int) {
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: "<text>\n\(text)\n</text>", generating: FoundGrammar.self,
                                                      options: GenerationOptions(temperature: 0.2))
            let points = response.content.points.compactMap { p -> GrammarPoint? in
                // The small model sometimes invents patterns or quotes sentences that don't show them. Keep a
                // pattern only if its start (e.g. てし for 〜てしまう) is in the text, and only examples that are
                // really in the text and contain it.
                let stem = Self.stem(p.pattern)
                if !stem.isEmpty && !text.contains(stem) { return nil }
                let examples = p.examples
                    .filter { text.contains($0.japanese.trimmingCharacters(in: CharacterSet(charactersIn: " 「」『』。."))) }
                    .filter { stem.isEmpty || $0.japanese.contains(stem) }
                    .map { GrammarExample(japanese: $0.japanese, english: $0.english) }
                return GrammarPoint(pattern: p.pattern, jlpt: p.jlpt, meaning: p.meaning,
                                    explanation: p.explanation, examples: examples, count: nil)
            }
            return (points, 0)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            guard text.count > Self.minChars else { return ([], 1) }
            var points: [GrammarPoint] = []
            var skipped = 0
            for part in Self.chunks(text, size: text.count / 2 + 1) {
                let (p, s) = await analyze(part)
                points += p
                skipped += s
            }
            return (points, skipped)
        } catch {
            lastError = error.localizedDescription
            return ([], 1)  // e.g. Apple's safety filter blocked this part
        }
    }

    /// The first two Japanese characters of a pattern (〜てしまう → てし), enough to tell whether it's in a sentence
    /// even when conjugated. Empty when the pattern has no Japanese in it.
    static func stem(_ pattern: String) -> String {
        let jp = pattern.unicodeScalars.filter { (0x3041...0x30FF).contains($0.value) && $0 != "〜" && $0 != "ー" || (0x3400...0x9FFF).contains($0.value) }
        return String(String.UnicodeScalarView(jp.prefix(2)))
    }

    /// Splits text into parts of at most `size` characters on line boundaries.
    static func chunks(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var buf = ""
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(piece) + "\n"
            while line.count > size {  // a very long line (no line breaks in a book) is split on its own
                if !buf.isEmpty { out.append(buf); buf = "" }
                out.append(String(line.prefix(size)))
                line = String(line.dropFirst(size))
            }
            if buf.count + line.count > size && !buf.isEmpty { out.append(buf); buf = "" }
            buf += line
        }
        if !buf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(buf) }
        return out
    }

    /// Merges points by pattern (〜 ignored), keeping up to 3 examples, sorted N5 first then by frequency.
    static func merge(_ points: [GrammarPoint]) -> [GrammarPoint] {
        var order: [String] = []
        var merged: [String: (point: GrammarPoint, examples: [GrammarExample], count: Int)] = [:]
        for p in points {
            let key = p.pattern.replacingOccurrences(of: "〜", with: "").replacingOccurrences(of: "~", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if merged[key] == nil { merged[key] = (p, [], 0); order.append(key) }
            merged[key]!.count += 1
            for ex in p.examples where merged[key]!.examples.count < 3
                && !merged[key]!.examples.contains(where: { $0.japanese == ex.japanese }) {
                merged[key]!.examples.append(ex)
            }
        }
        let levels = ["N5": 0, "N4": 1, "N3": 2, "N2": 3, "N1": 4]
        return order.compactMap { merged[$0] }
            .map { m in GrammarPoint(pattern: m.point.pattern, jlpt: m.point.jlpt, meaning: m.point.meaning,
                                     explanation: m.point.explanation, examples: m.examples, count: m.count) }
            .sorted {
                let a = levels[$0.jlpt.uppercased().trimmingCharacters(in: .whitespaces)] ?? 5
                let b = levels[$1.jlpt.uppercased().trimmingCharacters(in: .whitespaces)] ?? 5
                return a != b ? a < b : ($0.count ?? 0) > ($1.count ?? 0)
            }
    }
}
