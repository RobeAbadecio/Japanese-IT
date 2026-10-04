import Foundation

// Saved as JSON on the iPad. Field names match the files the old Mac server wrote, so those import as is.

struct JobSummary: Identifiable, Hashable {
    let id: String
    let title: String?
    let status: String
    let progress: String?
    let source: String?
    let created_at: Double
    let vocab_count: Int
    let grammar_count: Int
}

struct VocabItem: Codable, Identifiable, Hashable {
    var id: String { word }
    var word: String
    var reading: String
    var pos: String
    var proper: Bool?
    var count: Int
    var forms: [String]?
    var example: String?
    var meanings: [String]?
}

struct GrammarExample: Codable, Hashable {
    let japanese: String
    let english: String
}

struct GrammarPoint: Codable, Identifiable, Hashable {
    var id: String { pattern }
    let pattern: String
    let jlpt: String
    let meaning: String
    let explanation: String
    let examples: [GrammarExample]
    let count: Int?
}

struct Job: Codable, Identifiable {
    let id: String
    var title: String?
    var status: String              // running, done, error
    var progress: String?
    var source: String?
    var created_at: Double
    var finished_at: Double?
    var transcript: String?
    var vocab: [VocabItem]?
    var grammar: [GrammarPoint]?    // nil until grammar has been found
    var grammar_truncated: Bool?
    var grammar_skipped: Int?
    var known_hidden: Int?          // filled in when read, not stored
}

struct KnownWord: Codable, Identifiable, Hashable {
    var id: String { word }
    var word: String
    var reading: String
    var meanings: [String]?
    var added_at: Double?
}

struct KnownAdded { let added: [String]; let total: Int }

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
