import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var ready = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(status ?? "Checking…", systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(ready ? .green : .secondary)
                    Button("Check again") { Task { await refresh() } }
                } header: { Text("Grammar") } footer: {
                    Text("Everything runs on this iPad, offline: words, meanings, transcription and grammar. Only web page links need internet, and the Japanese speech model downloads once the first time you transcribe.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        status = GrammarEngine.unavailableReason ?? "Apple Intelligence is on. Grammar runs on this iPad."
        ready = GrammarEngine.unavailableReason == nil
    }
}
