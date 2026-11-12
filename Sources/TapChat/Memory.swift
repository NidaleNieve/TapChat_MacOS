import Foundation
import Observation

// What TapChat has learned about how you like answers ("writes open
// intervals as ]a,b["): a few short lines, added to every chat's
// instructions. Learned in the background from finished chats (never
// temporary ones), only while the window is closed; nothing to approve.
// Kept on this Mac, in memory.json; Settings lists it.
@Observable
final class MemoryStore {
    static let shared = MemoryStore()

    private(set) var items: [String] = []
    // Bumped on every change: a note-taking run that started before a
    // change (say, you deleted a line meanwhile) is dropped, not merged.
    @ObservationIgnored private(set) var version = 0
    // Per chat, how many of its messages have been read already.
    @ObservationIgnored private var seen: [UUID: Int] = [:]
    @ObservationIgnored var onChange: (() -> Void)?

    private let url = Paths.support.appendingPathComponent("memory.json")
    private struct Saved: Codable { var items: [String]; var seen: [UUID: Int] }

    // Only a safeguard against a runaway reply, not a limit in practice.
    static let maxItems = 50

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            items = saved.items
            seen = saved.seen
        }
    }

    var enabled: Bool { Settings.memory }

    // The part added to the instructions; empty when off or when nothing's learned.
    var promptSection: String {
        guard enabled, !items.isEmpty else { return "" }
        return "\n\nWhat you know about this user from earlier chats (follow it without mentioning it):\n"
            + items.map { "- " + $0 }.joined(separator: "\n")
    }

    func remove(_ item: String) {
        items.removeAll { $0 == item }
        changed()
    }

    func clear() {
        items = []
        changed()
    }

    func seenCount(_ chat: UUID) -> Int { seen[chat] ?? 0 }

    func markSeen(_ chat: UUID, count: Int) {
        seen[chat] = count
        write()
    }

    // A learning run's result, if nothing changed since it started.
    func apply(_ new: [String], from startVersion: Int) {
        guard startVersion == version, new != items else { return }
        items = Array(new.prefix(Self.maxItems))
        changed()
    }

    private func changed() {
        version += 1
        write()
        onChange?()
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(Saved(items: items, seen: seen)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // The request for the small model: the current memory, the new part of
    // a chat, and what's worth keeping.
    static func prompt(current: [String], transcript: String) -> String {
        """
        You keep a very small memory of standing conventions for answering this user. It's added to every future chat, so it must stay tiny: most conversations add nothing.

        Add a fact only when one of these is true:
        - the user explicitly states a standing preference ("I always write open intervals as ]a,b[", "use SI units", "never use bullet points")
        - the user writes in a notation or convention that differs from the usual one (for example ]a,b[ for open intervals, a decimal comma). This is the main thing to look for: one use in the user's own messages is enough.

        Never add:
        - what they're studying, working on or preparing for, or the topics of the conversation
        - guesses from one conversation's tone, length or style ("prefers short answers" unless they said so)
        - the language they write in (answers already follow it)
        - anything sensitive (health, money, passwords, addresses, other people)

        Write each fact as one short line, like "Writes open intervals as ]a,b[".

        Current memory:
        \(current.isEmpty ? "(empty)" : current.map { "- " + $0 }.joined(separator: "\n"))

        Conversation:
        \(transcript)

        If nothing qualifies, which is the usual case, reply with exactly: NO_CHANGE
        Otherwise reply with the complete updated memory and nothing else: one fact per line, each starting with "- ". Keep existing facts unless the user contradicts them; merge duplicates.
        """
    }

    // The reply as a list; nil for no change (or a reply that isn't one).
    static func parse(_ reply: String) -> [String]? {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("NO_CHANGE") else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 300 }
        return lines.isEmpty ? nil : lines
    }

    // The part of a chat not read yet (with a little before it for
    // context): your messages in full, answers shortened. At most ~12,000
    // characters, the latest kept.
    static func transcript(_ messages: [Message], from start: Int) -> String? {
        let from = max(0, min(start, messages.count) - 2)
        let part = messages[from...].filter { $0.error == nil && !$0.text.isEmpty }
        guard part.contains(where: { $0.role == .user }) else { return nil }
        var text = part.map { m in
            m.role == .user ? "User: " + String(m.text.prefix(3000)) : "Assistant: " + String(m.text.prefix(800))
        }.joined(separator: "\n\n")
        if text.count > 12_000 { text = "…" + String(text.suffix(12_000)) }
        return text
    }
}
