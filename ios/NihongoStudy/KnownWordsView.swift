import SwiftUI

/// Words you already know. They're hidden from every word list and Anki export.
struct KnownWordsView: View {
    @State private var words: [KnownWord] = []
    @State private var input = ""
    @State private var search = ""
    @State private var adding = false
    @State private var note: String?

    var body: some View {
        List {
            Section {
                TextField("食べる, 学校, きれい…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(add)
                Button(adding ? "Adding…" : "Add") { add() }
                    .disabled(adding || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("Add words you know") } footer: {
                Text(note ?? "Type one or several words separated by spaces, commas or new lines. Any form works: 食べた is saved as 食べる.")
            }

            Section(words.isEmpty ? "" : "\(words.count) familiar words") {
                if words.isEmpty {
                    Text("None yet. Add words here, or swipe right on a word in any word list.").foregroundStyle(.secondary)
                }
                ForEach(filtered) { KnownRow(k: $0) }
                    .onDelete { idx in
                        let gone = idx.map { filtered[$0].word }
                        words.removeAll { gone.contains($0.word) }
                        Task { for w in gone { await Library.removeKnown(w) } }
                    }
            }
        }
        .navigationTitle("Familiar Words")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search familiar words")
        .refreshable { await load() }
        .task { await load() }
    }

    private var filtered: [KnownWord] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return words }
        return words.filter { $0.word.contains(q) || $0.reading.contains(q) || ($0.meanings ?? []).joined(separator: " ").lowercased().contains(q) }
    }

    private func add() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            let r = await Library.addKnown(text)
            input = ""
            note = r.added.isEmpty ? "Already in your list." : "Added \(r.added.joined(separator: "、"))."
            await load()
        }
    }

    private func load() async {
        words = await Library.known()
    }
}

struct KnownRow: View {
    let k: KnownWord
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(k.word).font(.title3.bold())
                if k.reading != k.word { Text(k.reading).foregroundStyle(.secondary) }
            }
            if let m = k.meanings, !m.isEmpty {
                Text(m.joined(separator: "; ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
