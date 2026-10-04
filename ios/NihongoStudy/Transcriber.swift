import AVFoundation
import Foundation
import Speech

/// Turns Japanese speech in a video or audio file into text with Apple's on-device speech recognition.
/// The Japanese speech model is downloaded once (needs internet that one time); after that it works offline.
enum Transcriber {
    static func transcribe(_ url: URL, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
            throw AppError("Japanese speech recognition isn't available on this iPad.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress("Downloading the Japanese speech model (one time, needs internet)")
            do { try await request.downloadAndInstall() }
            catch { throw AppError("Couldn't download the Japanese speech model. Connect to the internet once and try again.") }
        }

        progress("Preparing the audio")
        let audioURL = try await audioOnly(url)
        defer { if audioURL != url { try? FileManager.default.removeItem(at: audioURL) } }
        let file = try AVAudioFile(forReading: audioURL)
        let minutes = Int(Double(file.length) / file.fileFormat.sampleRate / 60)
        progress("Transcribing \(minutes > 0 ? "\(minutes) min of " : "")audio on this iPad")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let lines: [String] = transcriber.results.reduce(into: []) { out, result in
            let line = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { out.append(line) }
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let text = try await lines.joined(separator: "\n")
        guard !text.isEmpty else { throw AppError("No speech was found in that file.") }
        return text
    }

    /// Video files are converted to an audio-only M4A first; audio files are used as they are.
    private static func audioOnly(_ url: URL) async throws -> URL {
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return url }
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw AppError("That video has no sound.") }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AppError("Couldn't read the sound from that video.")
        }
        let out = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        try await export.export(to: out, as: .m4a)
        return out
    }
}
