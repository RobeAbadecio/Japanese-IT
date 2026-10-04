import Foundation
import UIKit

/// Everything lives on this iPad: analyses in Documents/jobs/<id>.json, familiar words in Documents/known.json.
/// No Mac and no internet needed (except to read a web page link).
enum Library {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let store = Store()

    enum Source { case text(String), url(String), file(URL) }

    // MARK: Analyses

    static func jobs() async -> [JobSummary] {
        let known = await store.known()
        return await store.allJobs()
            .sorted { $0.created_at > $1.created_at }
            .map { j in
                JobSummary(id: j.id, title: j.title, status: j.status, progress: j.progress, source: j.source,
                           created_at: j.created_at,
                           vocab_count: (j.vocab ?? []).filter { known[$0.word] == nil }.count,
                           grammar_count: j.grammar?.count ?? 0)
            }
    }

    /// A job with familiar words left out of its word list.
    static func job(_ id: String) async throws -> Job {
        guard var job = await store.job(id) else { throw AppError("This analysis was deleted.") }
        let known = await store.known()
        let all = job.vocab ?? []
        job.vocab = all.filter { known[$0.word] == nil }
        job.known_hidden = all.count - job.vocab!.count
        return job
    }

    static func delete(_ id: String) async { await store.deleteJob(id) }

    /// Starts an analysis in the background; returns its id right away.
    static func submit(_ source: Source, title: String) async throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var job = Job(id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased(),
                      title: title.isEmpty ? nil : title, status: "running", progress: "Starting",
                      created_at: Date().timeIntervalSince1970)
        switch source {
        case .text(let t):
            guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError("Paste some text first.") }
            job.source = "text"
            if job.title == nil { job.title = String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20)) }
        case .url(let u):
            guard !u.trimmingCharacters(in: .whitespaces).isEmpty else { throw AppError("Paste a link first.") }
            job.source = u.trimmingCharacters(in: .whitespaces)
        case .file(let f):
            job.source = f.lastPathComponent
            if job.title == nil { job.title = Extract.cleanFileName(f) }
        }
        await store.save(job)
        let id = job.id
        Task.detached(priority: .userInitiated) { await run(id, source) }
        return id
    }

    private static func run(_ id: String, _ source: Source) async {
        // Ask for a little extra time if the app goes to the background mid-analysis.
        let bg = await UIApplication.shared.beginBackgroundTask(withName: "analysis")
        let progress: @Sendable (String) -> Void = { msg in Task { await store.update(id, persist: false) { $0.progress = msg } } }
        do {
            let (title, raw) = try await Extract.text(from: source, progress: progress)
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AppError("No text could be found in that source.") }
            await store.update(id) { j in
                if j.title == nil { j.title = title }
                j.transcript = text
                j.progress = "Building vocabulary list"
            }
            let vocab = Vocab.build(text, progress: progress)
            guard !vocab.isEmpty else {
                throw AppError("No Japanese words were found. Check the source, or that the video has Japanese audio.")
            }
            // Grammar (grammar == nil) is found next by GrammarEngine when the analysis is opened.
            await store.update(id) { j in
                j.vocab = vocab
                j.status = "done"
                j.progress = "Done"
                j.finished_at = Date().timeIntervalSince1970
            }
        } catch {
            await store.update(id) { j in
                j.status = "error"
                j.progress = error.localizedDescription
                j.finished_at = Date().timeIntervalSince1970
            }
        }
        if case .file(let f) = source { try? FileManager.default.removeItem(at: f) }
        await UIApplication.shared.endBackgroundTask(bg)
    }

    static func saveGrammar(_ id: String, _ points: [GrammarPoint], truncated: Bool, skipped: Int) async throws {
        guard await store.job(id) != nil else { throw AppError("This analysis was deleted.") }
        await store.update(id) { j in
            j.grammar = points
            j.grammar_truncated = truncated
            j.grammar_skipped = skipped
        }
    }

    /// Anki-ready CSV of a job's (unfamiliar) words, then its grammar. Written to a temp file for sharing.
    static func ankiFile(_ job: Job) -> URL {
        func row(_ fields: [String]) -> String {
            fields.map { f in
                f.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: ",")
        }
        var lines = (job.vocab ?? []).map { v in
            row([v.word, v.reading, (v.meanings ?? []).joined(separator: "; "), v.example ?? ""])
        }
        for g in job.grammar ?? [] {
            let ex = g.examples.first
            lines.append(row([g.pattern, g.jlpt, "\(g.meaning) — \(g.explanation)",
                              ex.map { "\($0.japanese) (\($0.english))" } ?? " ()"]))
        }
        let name = (job.title ?? job.id).replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-anki.csv")
        try? (lines.map { $0 + "\r\n" }.joined()).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Familiar words

    static func known() async -> [KnownWord] {
        await store.known().values.sorted { ($0.added_at ?? 0) > ($1.added_at ?? 0) }
    }

    /// Marks words as familiar so they're hidden from word lists. `exact` keeps a word from a list as is;
    /// otherwise typed words (any form, several at once) are turned into dictionary form.
    @discardableResult
    static func addKnown(_ words: String, exact: Bool = false) async -> KnownAdded {
        var seen = Set<String>()
        let raws = words.split(whereSeparator: { " \t\n\r,、，;；/／　".contains($0) }).map(String.init)
            .filter { seen.insert($0).inserted }
        var entries: [KnownWord] = []
        for raw in raws {
            var entry = Vocab.normalize(raw)
            if exact && entry.word != raw {
                entry.word = raw
                if !Vocab.hasKanji(raw) { entry.reading = Vocab.toHiragana(raw) }
            }
            entry.added_at = Date().timeIntervalSince1970
            entries.append(entry)
        }
        return await store.addKnown(entries)
    }

    static func removeKnown(_ word: String) async { await store.removeKnown(word) }
}

/// Reads and writes the JSON files; one at a time so saves can't interleave.
actor Store {
    private let jobsDir = Library.docs.appending(path: "jobs")
    private let knownFile = Library.docs.appending(path: "known.json")
    private var jobs: [String: Job] = [:]
    private var knownWords: [String: KnownWord] = [:]

    init() {
        try? FileManager.default.createDirectory(at: jobsDir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: jobsDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), var job = try? JSONDecoder().decode(Job.self, from: data) else { continue }
            if job.status == "running" {  // the app was closed mid-analysis; it will never finish
                job.status = "error"
                job.progress = "Interrupted because the app was closed. Try again."
                try? JSONEncoder().encode(job).write(to: f, options: .atomic)
            }
            jobs[job.id] = job
        }
        if let data = try? Data(contentsOf: knownFile) {
            knownWords = (try? JSONDecoder().decode([String: KnownWord].self, from: data)) ?? [:]
        }
    }

    func allJobs() -> [Job] { Array(jobs.values) }
    func job(_ id: String) -> Job? { jobs[id] }

    func save(_ job: Job) {
        jobs[job.id] = job
        try? JSONEncoder().encode(job).write(to: jobsDir.appending(path: "\(job.id).json"), options: .atomic)
    }

    func update(_ id: String, persist: Bool = true, _ change: (inout Job) -> Void) {
        guard var job = jobs[id] else { return }
        change(&job)
        if persist { save(job) } else { jobs[id] = job }
    }

    func deleteJob(_ id: String) {
        jobs[id] = nil
        try? FileManager.default.removeItem(at: jobsDir.appending(path: "\(id).json"))
    }

    func known() -> [String: KnownWord] { knownWords }

    func addKnown(_ entries: [KnownWord]) -> KnownAdded {
        var added: [String] = []
        for e in entries where knownWords[e.word] == nil {
            knownWords[e.word] = e
            added.append(e.word)
        }
        saveKnown()
        return KnownAdded(added: added, total: knownWords.count)
    }

    func removeKnown(_ word: String) {
        knownWords[word] = nil
        saveKnown()
    }

    private func saveKnown() {
        try? JSONEncoder().encode(knownWords).write(to: knownFile, options: .atomic)
    }
}
