import SwiftUI

enum DetailTab: String, CaseIterable { case vocab = "Vocabulary", grammar = "Grammar", text = "Text" }
enum VocabFilter: String, CaseIterable { case all = "All", kanji = "With kanji", verbs = "Verbs", nouns = "Nouns", adjectives = "Adjectives", noNames = "Hide names" }

let posEnglish = ["動詞": "verb", "名詞": "noun", "代名詞": "pronoun", "形容詞": "i-adj", "形状詞": "na-adj",
                  "副詞": "adverb", "連体詞": "adnominal", "接続詞": "conjunction", "感動詞": "interjection"]

struct DetailView: View {
    let jobID: String
    @State private var job: Job?
    @State private var tab: DetailTab = .vocab
    @State private var search = ""
    @State private var filter: VocabFilter = .all
    @State private var markedFamiliar: Set<String> = []
    @State private var undoWord: String?
    @State private var pendingAdd: Task<Void, Never>?
    @ObservedObject private var grammarEngine = GrammarEngine.shared
    @State private var ankiURL: URL?

    var body: some View {
        List {
            if let job, job.status != "done" {
                Section {
                    HStack(spacing: 12) {
                        if job.status == "running" { ProgressView() } else {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        Text(job.status == "error" ? "Failed: \(job.progress ?? "")" : (job.progress ?? "Working"))
                    }
                }
            }
            Section {
                Picker("View", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { t in Text(label(t)) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            switch tab {
            case .vocab: vocabSection
            case .grammar: grammarSection
            case .text:
                Section { Text(job?.transcript ?? "").font(.system(size: 18)).lineSpacing(8).textSelection(.enabled) }
            }
        }
        .safeAreaInset(edge: .bottom) { if undoWord != nil { undoBar } }
        .navigationTitle(job?.title ?? (job?.status == "error" ? "Failed" : "Analyzing…"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search words or meanings")
        .toolbar {
            if let job, job.status == "done", let ankiURL {
                ShareLink(item: ankiURL) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task { await poll() }
        .onChange(of: grammarEngine.saved[jobID]) { Task { await reload() } }
    }

    private func poll() async {
        while !Task.isCancelled {
            await reload()
            if job?.status != "running" { break }
            try? await Task.sleep(for: .seconds(2))
        }
        // Grammar is found next, once the text and words are ready.
        if let job, job.status == "done", job.grammar == nil, grammarEngine.errors[jobID] == nil { findGrammar() }
    }

    private func reload() async {
        job = try? await Library.job(jobID)
        if let job, job.status == "done" { ankiURL = Library.ankiFile(job) }
    }

    private func findGrammar() {
        guard let text = job?.transcript else { return }
        grammarEngine.start(jobID: jobID, text: text)
    }

    private func label(_ t: DetailTab) -> String {
        switch t {
        case .vocab:
            let n = (job?.vocab ?? []).filter { !markedFamiliar.contains($0.word) }.count
            return n > 0 ? "Words \(n)" : "Words"
        case .grammar: return job?.grammar?.isEmpty == false ? "Grammar \(job!.grammar!.count)" : "Grammar"
        case .text: return "Text"
        }
    }

    private var filteredVocab: [VocabItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (job?.vocab ?? []).filter { v in
            if markedFamiliar.contains(v.word) { return false }
            switch filter {
            case .kanji: if !v.word.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) { return false }
            case .verbs: if v.pos != "動詞" { return false }
            case .nouns: if !["名詞", "代名詞"].contains(v.pos) { return false }
            case .adjectives: if !["形容詞", "形状詞", "連体詞"].contains(v.pos) { return false }
            case .noNames: if v.proper == true { return false }
            case .all: break
            }
            guard !q.isEmpty else { return true }
            return v.word.contains(q) || v.reading.contains(q) || (v.meanings ?? []).joined(separator: " ").lowercased().contains(q)
        }
    }

    @ViewBuilder private var vocabSection: some View {
        let items = filteredVocab
        Section {
            Picker("Filter", selection: $filter) {
                ForEach(VocabFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            ForEach(items.prefix(500)) { v in
                ShortSwipe(onSwipe: { markFamiliar(v) }) { VocabRow(v: v) }
                    .listRowInsets(EdgeInsets())
                    .contextMenu {
                        Button { markFamiliar(v) } label: { Label("I know this word", systemImage: "checkmark.circle") }
                    }
            }
            if items.count > 500 {
                Text("Showing 500 of \(items.count). Search to narrow down.").foregroundStyle(.secondary)
            }
        } footer: {
            let hidden = (job?.known_hidden ?? 0) + (job?.vocab ?? []).filter { markedFamiliar.contains($0.word) }.count
            if hidden > 0 { Text("\(hidden) familiar word\(hidden == 1 ? "" : "s") hidden. Swipe right on a word you know to hide it.") }
            else if job?.vocab?.isEmpty == false { Text("Swipe right on a word you already know to hide it from now on.") }
        }
    }

    private func markFamiliar(_ v: VocabItem) {
        withAnimation {
            _ = markedFamiliar.insert(v.word)
            undoWord = v.word
        }
        pendingAdd = Task {
            await Library.addKnown(v.word, exact: true)
        }
        // Hide the undo bar after a few seconds unless another word was marked since.
        Task {
            try? await Task.sleep(for: .seconds(6))
            if undoWord == v.word { withAnimation { undoWord = nil } }
        }
    }

    private func undoFamiliar() {
        guard let word = undoWord else { return }
        withAnimation {
            _ = markedFamiliar.remove(word)
            undoWord = nil
        }
        let add = pendingAdd
        Task {
            await add?.value  // make sure the add reached the server before removing it
            await Library.removeKnown(word)
        }
    }

    private var undoBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("\(undoWord ?? "") marked familiar").lineLimit(1)
            Spacer()
            Button("Undo", action: undoFamiliar).bold()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 2)
        .padding(.horizontal).padding(.bottom, 8)
        .frame(maxWidth: 520)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder private var grammarSection: some View {
        Section {
            if let p = grammarEngine.progress[jobID] {
                HStack(spacing: 12) { ProgressView(); Text(p) }
                Text("Keep the app open until this finishes.").font(.footnote).foregroundStyle(.secondary)
            } else {
                if let note = grammarNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
                if let job, job.status == "done", grammarEngine.errors[jobID] != nil || (job.grammar ?? []).isEmpty {
                    Button(job.grammar == nil ? "Find grammar" : "Find grammar again", systemImage: "sparkles") { findGrammar() }
                }
            }
            ForEach(job?.grammar ?? []) { GrammarRow(g: $0) }
            if let job, job.status == "done", job.grammar?.isEmpty == false, grammarEngine.progress[jobID] == nil {
                Button("Find grammar again", systemImage: "arrow.clockwise") { findGrammar() }.font(.footnote)
            }
        }
    }

    private var grammarNote: String? {
        guard let job else { return nil }
        if let e = grammarEngine.errors[jobID] { return e }
        if job.status == "running" { return "Grammar is found on this iPad once the words are ready." }
        if job.grammar?.isEmpty == true { return "No grammar patterns were found." }
        var notes: [String] = []
        if job.grammar_truncated == true { notes.append("Long text: grammar covers the first 30,000 characters. Vocabulary covers everything.") }
        if let n = job.grammar_skipped { notes.append("Apple Intelligence skipped \(n) part\(n == 1 ? "" : "s") of the text.") }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

/// Swipe right a short way (not the full row width, which is long on iPad) to trigger the action.
/// It fires as soon as the drag passes the threshold, so there's no need to let go at the right spot.
struct ShortSwipe<Content: View>: View {
    var threshold: CGFloat = 80
    let onSwipe: () -> Void
    @ViewBuilder let content: Content

    private struct Drag { var offset: CGFloat = 0; var horizontal: Bool? }
    @GestureState private var drag = Drag()  // resets by itself, even if the list steals the touch
    @State private var fired = false

    var body: some View {
        let offset = fired ? 0 : drag.offset
        ZStack(alignment: .leading) {
            Color.green.opacity(offset >= threshold * 0.6 ? 1 : 0.4)
                .overlay(alignment: .leading) {
                    Label("Familiar", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.white).padding(.leading, 20)
                        .opacity(min(1, offset / 40))
                }
                .opacity(offset > 0 ? 1 : 0)
            content
                .padding(.horizontal, 20).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .offset(x: offset)
        }
        .contentShape(Rectangle())
        .animation(.spring(duration: 0.2), value: offset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .updating($drag) { g, state, _ in
                    if state.horizontal == nil { state.horizontal = g.translation.width > abs(g.translation.height) * 1.5 }
                    state.offset = state.horizontal == true ? max(0, min(g.translation.width, threshold + 20)) : 0
                }
        )
        .onChange(of: drag.offset) { _, x in
            if x >= threshold && !fired {
                fired = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onSwipe()
            } else if x == 0 {
                fired = false
            }
        }
    }
}

struct VocabRow: View {
    let v: VocabItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(v.word).font(.title2.bold())
                if v.reading != v.word { Text(v.reading).foregroundStyle(.secondary) }
                Text(posEnglish[v.pos] ?? v.pos)
                    .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.4)))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("×\(v.count)").font(.caption).foregroundStyle(.secondary)
            }
            if let m = v.meanings, !m.isEmpty {
                Text(m.joined(separator: "; "))
            } else {
                Text("No dictionary entry").foregroundStyle(.secondary)
            }
            if let ex = v.example { highlighted(ex).font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }

    private func highlighted(_ sentence: String) -> Text {
        var s = AttributedString(sentence)
        for w in [v.word] + (v.forms ?? []) {
            if let r = s.range(of: w) {
                s[r].foregroundColor = .accentColor
                s[r].font = .subheadline.bold()
            }
        }
        return Text(s)
    }
}

struct GrammarRow: View {
    let g: GrammarPoint
    @State private var expanded = false

    var level: String { g.jlpt.uppercased().trimmingCharacters(in: .whitespaces) }
    var levelColor: Color {
        ["N5": .green, "N4": .blue, "N3": .purple, "N2": .orange, "N1": .red][level] ?? .gray
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(g.pattern).font(.title3.bold())
                if level.range(of: "^N[1-5]$", options: .regularExpression) != nil {
                    Text(level).font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(levelColor, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            Text(g.meaning).fontWeight(.medium)
            Text(g.explanation).font(.subheadline).foregroundStyle(.secondary)
            if !g.examples.isEmpty {
                DisclosureGroup("Examples from the text", isExpanded: $expanded) {
                    ForEach(g.examples, id: \.self) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.japanese)
                            Text(e.english).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}
