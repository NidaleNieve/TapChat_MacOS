import Foundation

enum Provider: String, Codable {
    case claude, codex

    var name: String { self == .claude ? "Claude" : "Codex" }
    var other: Provider { self == .claude ? .codex : .claude }
}

// Codex models carry this prefix; Claude models are what `claude --model` takes.
let codexPrefix = "codex:"

func providerOf(_ model: String) -> Provider {
    model.hasPrefix(codexPrefix) ? .codex : .claude
}

struct Attachment: Codable, Identifiable, Hashable {
    // A folder isn't copied: it's attached as its path.
    enum Kind: String, Codable { case image, file, folder }
    var id = UUID()
    var name: String
    var kind: Kind
    // Absolute path of the app's own copy (a folder: the folder itself).
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
}

struct Message: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var attachments: [Attachment] = []
    // Assistant: the model that answered.
    var model: String?
    var error: String?
    // E.g. "Switched to Sonnet: Codex usage limit reached".
    var note: String?
    var durationMs: Int?
    // Replies to parts of earlier messages, sent with this one.
    var replies: [ReplyNote]?
    // Messages from before replies had notes: one quoted part.
    var quote: String?
    // Parts marked with Highlight (shown with a background), as text.
    var highlights: [String]?
    // A question you edited: its other versions, each with what followed it
    // (answers, later questions, their own versions). The one shown is in
    // the chat itself, at `versionIndex` among them all.
    var versions: [[Message]]?
    var versionIndex: Int?

    var versionCount: Int { (versions?.count ?? 0) + 1 }
}

// A reply to part of a message: the part, and what you say about it.
struct ReplyNote: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var quote: String
    var note: String
    // The message quoted from: clicking the reply goes there.
    var source: UUID? = nil
}

struct Chat: Codable, Identifiable {
    var id = UUID()
    var title = ""
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [Message] = []
    var isTemporary = false
    // A fork: the chat it was forked from (the original, for forks of forks).
    var parentId: UUID?
    // You named it (Rename): the app no longer retitles it.
    var titleByUser: Bool?

    enum CodingKeys: String, CodingKey { case id, title, createdAt, updatedAt, messages, parentId, titleByUser }
}

struct ChatSummary: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var parentId: UUID?
}

struct ModelOption: Codable, Hashable, Identifiable {
    var value: String
    var title: String
    var efforts: [String]
    var defaultEffort: String?
    // Its faster speed, when it has one: Claude's fast mode ("fast"), or the
    // Codex service tier to ask for ("priority").
    var fastTier: String?
    var id: String { value }
    var provider: Provider { providerOf(value) }
    // Codex's names without hyphens: "GPT 6 Sol".
    var name: String { provider == .codex ? title.replacingOccurrences(of: "-", with: " ") : title }
}

let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]

// Beyond High: shown when turned on in Settings, where the model has them.
let extraEfforts = ["xhigh", "max", "ultra"]

func effortTitle(_ e: String) -> String {
    e == "xhigh" ? "Extra High" : e.prefix(1).uppercased() + e.dropFirst()
}

func titleFrom(_ text: String) -> String {
    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .newlines).first ?? ""
    return line.count > 60 ? String(line.prefix(57)) + "…" : line
}
