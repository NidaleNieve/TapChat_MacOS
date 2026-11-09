import Foundation

enum Paths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TapChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let chats = dir(support.appendingPathComponent("chats"))
    // The CLIs run here, away from real projects.
    static let work = dir(support.appendingPathComponent("work"))
    // Temporary chats' attachments; emptied at launch.
    static let temporary = dir(FileManager.default.temporaryDirectory.appendingPathComponent("TapChat"))

    private static func dir(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Each chat's folder: chat.json and its attachments.
    static func folder(for chat: Chat) -> URL {
        let base = chat.isTemporary ? temporary : chats
        return dir(base.appendingPathComponent(chat.id.uuidString))
    }
}

enum Settings {
    private static let d = UserDefaults.standard

    static var model: String {
        get { d.string(forKey: "model") ?? "sonnet" }
        set { d.set(newValue, forKey: "model") }
    }
    // One reasoning level for every chat: Medium until changed.
    static var effort: String {
        get { d.string(forKey: "effort") ?? "medium" }
        set { d.set(newValue, forKey: "effort") }
    }
    // Side chats' own model and reasoning level, last used there (nil: the main chat's).
    static var sideModel: String? {
        get { d.string(forKey: "sideModel") }
        set { d.set(newValue, forKey: "sideModel") }
    }
    static var sideEffort: String? {
        get { d.string(forKey: "sideEffort") }
        set { d.set(newValue, forKey: "sideEffort") }
    }
    static var webSearch: Bool {
        get { d.bool(forKey: "webSearch") }
        set { d.set(newValue, forKey: "webSearch") }
    }
    // Used when the other provider is out of its limit.
    static var fallbackClaude: String {
        get { d.string(forKey: "fallbackClaude") ?? "sonnet" }
        set { d.set(newValue, forKey: "fallbackClaude") }
    }
    static var fallbackCodex: String {
        get { d.string(forKey: "fallbackCodex") ?? "codex:default" }
        set { d.set(newValue, forKey: "fallbackCodex") }
    }
    static var autoFallback: Bool {
        get { d.object(forKey: "autoFallback") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoFallback") }
    }
    // Minutes after which ⌥Space opens a new chat instead of the last one; 0 = never.
    static var newChatAfter: Int {
        get { d.object(forKey: "newChatAfter") as? Int ?? 0 }
        set { d.set(newValue, forKey: "newChatAfter") }
    }
    // The open new chat's id until it's sent (see ChatModel.blankChat).
    static var newChatId: UUID {
        get {
            if let id = d.string(forKey: "newChatId").flatMap(UUID.init) { return id }
            let id = UUID()
            d.set(id.uuidString, forKey: "newChatId")
            return id
        }
        set { d.set(newValue.uuidString, forKey: "newChatId") }
    }
    // Updates (Settings → Updates): on, weekly, until changed.
    static var automaticUpdates: Bool {
        get { d.object(forKey: "automaticUpdates") as? Bool ?? true }
        set { d.set(newValue, forKey: "automaticUpdates") }
    }
    static var updateFrequency: UpdateFrequency {
        get { d.string(forKey: "updateFrequency").flatMap(UpdateFrequency.init) ?? .weekly }
        set { d.set(newValue.rawValue, forKey: "updateFrequency") }
    }
    static var haptics: Bool {
        get { d.object(forKey: "haptics") as? Bool ?? true }
        set { d.set(newValue, forKey: "haptics") }
    }
    static var showMenuBarIcon: Bool {
        get { d.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { d.set(newValue, forKey: "showMenuBarIcon") }
    }
    static var showInDock: Bool {
        get { d.bool(forKey: "showInDock") }
        set { d.set(newValue, forKey: "showInDock") }
    }
    // Set once Open at Login has been turned on for the first time, so turning it off sticks.
    static var loginItemConfigured: Bool {
        get { d.bool(forKey: "loginItemConfigured") }
        set { d.set(newValue, forKey: "loginItemConfigured") }
    }
    static var claudePath: String {
        get { d.string(forKey: "claudePath") ?? "" }
        set { d.set(newValue, forKey: "claudePath") }
    }
    static var codexPath: String {
        get { d.string(forKey: "codexPath") ?? "" }
        set { d.set(newValue, forKey: "codexPath") }
    }
    static var lastChatId: UUID? {
        get { d.string(forKey: "lastChatId").flatMap(UUID.init) }
        set { d.set(newValue?.uuidString, forKey: "lastChatId") }
    }
    // One width for the bar, History and the chat, so nothing jumps sideways.
    static let widthRange: ClosedRange<Double> = 340...900
    // nil until resized: then a quarter of the screen.
    static var storedWidth: Double? {
        get { d.object(forKey: "width2") as? Double }
        set { d.set(newValue, forKey: "width2") }
    }
    static var historyHeight: Double {
        get { max(d.object(forKey: "historyHeight") as? Double ?? 330, 200) }
        set { d.set(newValue, forKey: "historyHeight") }
    }
    static var expandedHeight: Double {
        get { d.object(forKey: "expandedHeight") as? Double ?? 560 }
        set { d.set(newValue, forKey: "expandedHeight") }
    }
    // Bottom-centre of the window; it grows upwards (and sideways) from here.
    static var anchor: CGPoint? {
        get {
            guard let a = d.array(forKey: "anchorCenter") as? [Double], a.count == 2 else { return nil }
            return CGPoint(x: a[0], y: a[1])
        }
        set { d.set(newValue.map { [$0.x, $0.y] }, forKey: "anchorCenter") }
    }
    static func usage(_ p: Provider) -> Usage? {
        d.data(forKey: "usage.\(p.rawValue)").flatMap { try? JSONDecoder().decode(Usage.self, from: $0) }
    }
    static func setUsage(_ u: Usage) {
        d.set(try? JSONEncoder().encode(u), forKey: "usage.\(u.provider.rawValue)")
    }
}

// Saved chats: one folder each, plus an index for the history list.
final class ChatStore {
    static let shared = ChatStore()
    private let indexURL = Paths.support.appendingPathComponent("index.json")
    private(set) var index: [ChatSummary] = []

    private init() {
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([ChatSummary].self, from: data) {
            index = list
        }
        cleanUp()
    }

    // The last few chats opened or saved, decoded: going back to one skips
    // reading and decoding its file.
    private var recent: [(id: UUID, chat: Chat)] = []

    private func remember(_ chat: Chat) {
        recent.removeAll { $0.id == chat.id }
        recent.insert((chat.id, chat), at: 0)
        if recent.count > 4 { recent.removeLast() }
    }

    // `keep: false` for one-off reads (search), which shouldn't push out the
    // chats actually being opened.
    func load(_ id: UUID, keep: Bool = true) -> Chat? {
        if let hit = recent.first(where: { $0.id == id }) { return hit.chat }
        let url = Paths.chats.appendingPathComponent(id.uuidString).appendingPathComponent("chat.json")
        guard let data = try? Data(contentsOf: url), let chat = try? JSONDecoder().decode(Chat.self, from: data) else { return nil }
        if keep { remember(chat) }
        return chat
    }

    func save(_ chat: Chat) {
        guard !chat.isTemporary, !chat.messages.isEmpty else { return }
        let url = Paths.folder(for: chat).appendingPathComponent("chat.json")
        if let data = try? JSONEncoder().encode(chat) { try? data.write(to: url, options: .atomic) }
        remember(chat)
        contents[chat.id] = nil
        index.removeAll { $0.id == chat.id }
        index.append(ChatSummary(id: chat.id, title: chat.title, updatedAt: chat.updatedAt, parentId: chat.parentId))
        index.sort { $0.updatedAt > $1.updatedAt }
        writeIndex()
    }

    // History search: every term (or "quoted phrase") must appear in the
    // title or the messages, ignoring case and accents. Title hits first.
    struct Hit: Identifiable, Hashable {
        var summary: ChatSummary
        var snippet: String?
        var terms: [String] = []
        var id: UUID { summary.id }
    }
    // Each chat's text, as written and folded for matching (folding all of
    // it again on every keystroke of a search was the slow part).
    private var contents: [UUID: (raw: String, folded: String)] = [:]

    func search(_ query: String) -> [Hit] {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        var terms: [String] = []
        for (i, part) in query.components(separatedBy: "\"").enumerated() {
            if i % 2 == 1 { if !part.isEmpty { terms.append(fold(part)) } }
            else { terms += part.split(whereSeparator: \.isWhitespace).map { fold(String($0)) } }
        }
        guard !terms.isEmpty else { return index.map { Hit(summary: $0) } }
        var titleHits: [Hit] = [], bodyHits: [Hit] = []
        for s in index {
            let title = fold(s.title)
            if contents[s.id] == nil {
                let raw = load(s.id, keep: false).map { $0.messages.map(\.text).joined(separator: "\n") } ?? ""
                contents[s.id] = (raw, fold(raw))
            }
            let (raw, body) = contents[s.id] ?? ("", "")
            guard terms.allSatisfy({ title.contains($0) || body.contains($0) }) else { continue }
            // The passage that matched, even when the title matched too.
            let inBody = terms.first { !title.contains($0) && body.contains($0) } ?? terms.first { body.contains($0) }
            let hit = Hit(summary: s, snippet: inBody.flatMap { snippet(raw, folded: body, term: $0) }, terms: terms)
            if terms.allSatisfy({ title.contains($0) }) { titleHits.append(hit) } else { bodyHits.append(hit) }
        }
        return titleHits + bodyHits
    }

    private func snippet(_ raw: String, folded: String, term: String) -> String? {
        guard let r = folded.range(of: term), raw.count == folded.count else { return nil }
        let at = folded.distance(from: folded.startIndex, to: r.lowerBound)
        let start = raw.index(raw.startIndex, offsetBy: max(0, at - 30))
        let end = raw.index(raw.startIndex, offsetBy: min(raw.count, at + term.count + 50))
        let s = raw[start..<end].replacingOccurrences(of: "\n", with: " ")
        return (start > raw.startIndex ? "…" : "") + s + (end < raw.endIndex ? "…" : "")
    }

    func delete(_ id: UUID) {
        contents[id] = nil
        recent.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Paths.chats.appendingPathComponent(id.uuidString))
        index.removeAll { $0.id == id }
        writeIndex()
    }

    private func writeIndex() {
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }

    // Folders of chats never sent (attachments added, then left), entries
    // whose folder is gone, and last session's temporary chats.
    private func cleanUp() {
        let fm = FileManager.default
        // Saved chats, and the new chat's draft attachments.
        let known = Set(index.map(\.id.uuidString) + [Settings.newChatId.uuidString])
        for name in (try? fm.contentsOfDirectory(atPath: Paths.chats.path)) ?? [] where !known.contains(name) {
            let folder = Paths.chats.appendingPathComponent(name)
            if !fm.fileExists(atPath: folder.appendingPathComponent("chat.json").path) {
                try? fm.removeItem(at: folder)
            }
        }
        let before = index.count
        index.removeAll { !fm.fileExists(atPath: Paths.chats.appendingPathComponent($0.id.uuidString).appendingPathComponent("chat.json").path) }
        if index.count != before { writeIndex() }
        for name in (try? fm.contentsOfDirectory(atPath: Paths.temporary.path)) ?? [] {
            try? fm.removeItem(at: Paths.temporary.appendingPathComponent(name))
        }
    }
}

// The models each CLI offers, refreshed at most daily.
final class ModelCatalog {
    static let shared = ModelCatalog()
    private let url = Paths.support.appendingPathComponent("models.json")
    private(set) var models: [ModelOption]
    private var fetchedAt: Date = .distantPast
    var onChange: (() -> Void)?

    static let fallback: [ModelOption] = [
        ModelOption(value: "haiku", title: "Haiku", efforts: claudeEfforts),
        ModelOption(value: "sonnet", title: "Sonnet", efforts: claudeEfforts),
        ModelOption(value: "opus", title: "Opus", efforts: claudeEfforts),
        ModelOption(value: "codex:default", title: "Codex Default", efforts: ["low", "medium", "high", "xhigh"]),
    ]

    private struct Saved: Codable { var fetchedAt: Date; var models: [ModelOption] }

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            models = saved.models
            fetchedAt = saved.fetchedAt
        } else {
            models = Self.fallback
        }
    }

    func option(_ value: String) -> ModelOption? { models.first { $0.value == value } }

    // With the provider when the title alone doesn't say it ("Codex (default model)").
    func fullTitle(_ value: String) -> String {
        if value == codexPrefix + "default" { return "Codex (default model)" }
        let t = title(value)
        let p = providerOf(value)
        return t.localizedCaseInsensitiveContains(p.name) || (p == .codex && t.lowercased().hasPrefix("gpt")) ? t : "\(p.name) \(t)"
    }

    func title(_ value: String) -> String {
        if value == codexPrefix + "default", option(value) == nil { return "Codex Default" }
        return option(value)?.name ?? (value.hasPrefix(codexPrefix) ? String(value.dropFirst(codexPrefix.count)).replacingOccurrences(of: "-", with: " ") : value.capitalized)
    }

    func refreshIfStale() {
        guard Date().timeIntervalSince(fetchedAt) > 24 * 3600 else { return }
        refresh()
    }

    func refresh() {
        var claude: [ModelOption]?
        var codex: [ModelOption]?
        let group = DispatchGroup()
        group.enter()
        fetchClaudeModels { claude = $0; group.leave() }
        group.enter()
        fetchCodexModels { codex = $0; group.leave() }
        group.notify(queue: .main) { [self] in
            guard claude != nil || codex != nil else { return }
            let keepClaude = models.filter { $0.provider == .claude }
            let keepCodex = models.filter { $0.provider == .codex }
            models = (claude ?? keepClaude) + (codex ?? keepCodex)
            fetchedAt = Date()
            if let data = try? JSONEncoder().encode(Saved(fetchedAt: fetchedAt, models: models)) {
                try? data.write(to: url, options: .atomic)
            }
            onChange?()
        }
    }

    // The model list Claude Code returns to `initialize`, as in the Agent SDK.
    private func fetchClaudeModels(_ done: @escaping ([ModelOption]?) -> Void) {
        guard let bin = ClaudeRunner.shared.binary else { return done(nil) }
        let p = LineProcess(executable: bin, arguments: [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
        ], directory: Paths.work)
        var finished = false
        let finish = { (m: [ModelOption]?) in
            guard !finished else { return }
            finished = true
            p.kill()
            done(m)
        }
        p.onLine = { line in
            guard let e = jsonObject(line), e["type"] as? String == "control_response" else { return }
            let list = ((e["response"] as? [String: Any])?["response"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            let models: [ModelOption] = list.compactMap { m in
                guard let value = m["value"] as? String, value != "default" else { return nil }
                let resolved = (m["resolvedModel"] as? String) ?? value
                guard seen.insert(resolved).inserted else { return nil }
                return ModelOption(value: value, title: (m["displayName"] as? String) ?? value, efforts: claudeEfforts)
            }
            finish(models.isEmpty ? nil : models)
        }
        p.onExit = { _, _ in finish(nil) }
        do { try p.start() } catch { return finish(nil) }
        p.writeJSON(["type": "control_request", "request_id": "models", "request": ["subtype": "initialize"]])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish(nil) }
    }

    private func fetchCodexModels(_ done: @escaping ([ModelOption]?) -> Void) {
        guard let bin = CodexRunner.shared.binary else { return done(nil) }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["debug", "models"]
            p.environment = childEnvironment()
            p.currentDirectoryURL = Paths.work
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var models: [ModelOption]?
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
                models = list.compactMap { m in
                    guard let slug = m["slug"] as? String, m["visibility"] as? String == "list" else { return nil }
                    let efforts = (m["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
                    return ModelOption(value: codexPrefix + slug, title: (m["display_name"] as? String) ?? slug,
                                       efforts: efforts, defaultEffort: m["default_reasoning_level"] as? String)
                }
                if models?.isEmpty == true { models = nil }
            }
            DispatchQueue.main.async { done(models) }
        }
    }
}
