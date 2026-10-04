import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum SourceMode: String, CaseIterable { case link = "Link", upload = "Upload", text = "Text" }

/// A video picked from Photos, copied to a temp file so it can be analyzed.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(received.file.lastPathComponent)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}

struct HomeView: View {
    @State private var mode: SourceMode = .link
    @State private var link = ""
    @State private var text = ""
    @State private var title = ""
    @State private var file: URL?
    @State private var showImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var submitting = false
    @State private var error: String?
    @State private var jobs: [JobSummary] = []
    @State private var path: [String] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { addForm }
                Section("Library") {
                    if jobs.isEmpty {
                        Text("Nothing yet. Add text, a file or a link above to start.").foregroundStyle(.secondary)
                    }
                    ForEach(jobs) { job in
                        NavigationLink(value: job.id) { LibraryRow(job: job) }
                    }
                    .onDelete { idx in
                        let ids = idx.map { jobs[$0].id }
                        jobs.remove(atOffsets: idx)
                        Task { for id in ids { await Library.delete(id) } }
                    }
                }
            }
            .navigationTitle("日本語 Study")
            .navigationDestination(for: String.self) { DetailView(jobID: $0) }
            .toolbar {
                NavigationLink { KnownWordsView() } label: { Image(systemName: "checkmark.seal") }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .refreshable { await load() }
            .task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(jobs.contains { $0.status == "running" } ? 3 : 15))
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.movie, .audio, .pdf, .epub, .plainText, .html, .item]) { result in
                if case .success(let url) = result { file = copyIn(url) }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { file = try? await item.loadTransferable(type: PickedMovie.self)?.url }
            }
        }
    }

    @ViewBuilder private var addForm: some View {
        Picker("Source", selection: $mode) {
            ForEach(SourceMode.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .listRowSeparator(.hidden)

        switch mode {
        case .link:
            TextField("Web page link (needs internet)", text: $link)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        case .upload:
            HStack {
                PhotosPicker(selection: $photoItem, matching: .videos) {
                    Label("Video", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                Button { showImporter = true } label: { Label("Files", systemImage: "folder") }
                    .buttonStyle(.bordered)
            }
            if let file {
                Label(file.lastPathComponent, systemImage: "doc").font(.footnote).lineLimit(1)
            } else {
                Text("Video, audio, PDF, EPUB or text file").font(.footnote).foregroundStyle(.secondary)
            }
        case .text:
            TextField("Paste Japanese text", text: $text, axis: .vertical).lineLimit(4...10)
        }

        TextField("Title (optional)", text: $title)

        Button(action: submit) {
            HStack {
                Spacer()
                if submitting { ProgressView().tint(.white) }
                Text(submitting ? "Starting…" : "Analyze").bold()
                Spacer()
            }
        }
        .listRowBackground(Color.accentColor)
        .foregroundStyle(.white)
        .disabled(submitting)

        if let error { Text(error).foregroundStyle(.red).font(.footnote) }
    }

    private func submit() {
        error = nil
        submitting = true
        Task {
            defer { submitting = false }
            do {
                let id: String
                switch mode {
                case .link: id = try await Library.submit(.url(link), title: title)
                case .text: id = try await Library.submit(.text(text), title: title)
                case .upload:
                    guard let file else { error = "Choose a file first."; return }
                    id = try await Library.submit(.file(file), title: title)  // the copy is deleted once read
                }
                link = ""; text = ""; title = ""; file = nil; photoItem = nil
                await load()
                path.append(id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        jobs = await Library.jobs()
    }

    /// Files from the Files app are security-scoped; copy them somewhere we can read later.
    private func copyIn(_ url: URL) -> URL? {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil
    }
}

struct LibraryRow: View {
    let job: JobSummary
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title ?? job.source ?? "Untitled").font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch job.status {
            case "running": ProgressView()
            case "error": Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            default: EmptyView()
            }
        }
    }
    private var subtitle: String {
        if job.status == "running" { return job.progress ?? "Working" }
        if job.status == "error" { return "Failed" }
        let date = Date(timeIntervalSince1970: job.created_at).formatted(date: .abbreviated, time: .omitted)
        return "\(job.vocab_count) words · \(job.grammar_count) grammar · \(date)"
    }
}
