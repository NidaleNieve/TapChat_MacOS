import AppKit
import Observation
import SwiftUI

enum Layout { case bar, history, expanded }

// What's typed but not sent in a chat, including a half-finished edit.
struct Draft: Codable {
    var text = ""
    var attachments: [Attachment] = []
    var editingId: UUID?
    var editText = ""
    var editAttachments: [Attachment] = []

    var isEmpty: Bool { text.isEmpty && attachments.isEmpty && editingId == nil }
}

@Observable
final class ChatModel {
    var chat = Chat()
    var draft = "" { didSet { draftChanged() } }
    var draftAttachments: [Attachment] = [] { didSet { draftChanged() } }
    var editingId: UUID? { didSet { draftChanged() } }
    var editText = "" { didSet { draftChanged() } }
    var editAttachments: [Attachment] = [] { didSet { draftChanged() } }
    var model = Settings.model
    // Always on: the model searches when it thinks it should.
    let webSearch = true
    // Files are being dragged somewhere: the bar shows a drop area.
    var dropZone = false
    // A brief confirmation in the header ("Forked").
    var banner: String?
    // The assistant message being written, and what the model is doing.
    var runningId: UUID?
    var status: String?
    // The answer shown so far: it catches up with the CLI's text at an even pace.
    var revealId: UUID?
    var revealed = ""
    var fadeTail = 0
    var showingHistory = false
    // The window is on screen (animations pause while it isn't).
    var shown = false
    // The chat was opened from History; the header shows a back button.
    var openedFromHistory = false
    var history: [ChatSummary] = ChatStore.shared.index
    var models: [ModelOption] = ModelCatalog.shared.models
    var usage: [Provider: Usage] = [:]
    var hotkeyProblem: String?
    // Heights as laid out: the composer, the glass, and the canvas it lives in.
    var barHeight: CGFloat = 44
    var glassHeight: CGFloat = 44
    var canvasHeight: CGFloat = 560
    // Bumped to put the cursor in the composer.
    var focusToken = 0

    @ObservationIgnored var onLayoutChange: (() -> Void)?
    @ObservationIgnored var onHide: (() -> Void)?
    @ObservationIgnored var openSettings: (() -> Void)?
    @ObservationIgnored var onDropped: (() -> Void)?
    @ObservationIgnored private var bannerClear: DispatchWorkItem?
    @ObservationIgnored private var handle: RunHandle?
    // New text wakes the reveal (see wakeReveal).
    @ObservationIgnored private var latestText = "" { didSet { wakeReveal() } }
    @ObservationIgnored private var revealTimer: Timer?
    @ObservationIgnored private var cursor = RevealCursor()
    @ObservationIgnored private var lastHaptic = Date.distantPast
    @ObservationIgnored private var hapticGap: TimeInterval = 0.12
    @ObservationIgnored private var hiddenAt: Date?
    @ObservationIgnored private var drafts: [UUID: Draft] = [:]
    @ObservationIgnored private var loadingDraft = false
    @ObservationIgnored private var draftSave: DispatchWorkItem?
    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var spareDiscard: DispatchWorkItem?
    @ObservationIgnored private var wasWriting = false
    @ObservationIgnored private var purge: DispatchWorkItem?
    private static let draftsURL = Paths.support.appendingPathComponent("drafts.json")

    init() {
        for p in [Provider.claude, .codex] { usage[p] = Settings.usage(p) }
        if let data = try? Data(contentsOf: Self.draftsURL),
           let saved = try? JSONDecoder().decode([UUID: Draft].self, from: data) {
            drafts = saved
        }
        if let id = Settings.lastChatId, let saved = ChatStore.shared.load(id) {
            chat = saved
        } else {
            chat = Self.blankChat()
        }
        loadDraft()
        ModelCatalog.shared.onChange = { [weak self] in self?.models = ModelCatalog.shared.models }
    }

    // The unsent new chat keeps one id until it's sent, so its draft (and
    // the attachments in its folder) survive switching away and quitting.
    private static func blankChat() -> Chat {
        var c = Chat()
        c.id = Settings.newChatId
        return c
    }

    var layout: Layout {
        if !chat.messages.isEmpty { return .expanded }
        return showingHistory ? .history : .bar
    }

    var isRunning: Bool { runningId != nil }
    var modelTitle: String { ModelCatalog.shared.title(model) }
    var option: ModelOption? { models.first { $0.value == model } }

    // Codex has no level without reasoning: Instant runs as Low there.
    var effectiveEffort: String { providerOf(model) == .codex && effort == "instant" ? "low" : effort }

    // Kept across chats and restarts.
    var effort = Settings.effort == "max" ? "high" : Settings.effort {
        didSet { Settings.effort = effort; warmUp() }
    }

    // Usage worth a quiet note: 90% of a 5-hour window, or a reached limit.
    // Only for the selected model's provider.
    var usageNotes: [Usage] {
        [providerOf(model)].compactMap { usage[$0] }.filter(\.isHigh)
    }

    // MARK: Drafts

    private func draftChanged() {
        guard !loadingDraft else { return }
        updateSpare()
        let d = Draft(text: draft, attachments: draftAttachments, editingId: editingId,
                      editText: editText, editAttachments: editAttachments)
        drafts[chat.id] = d.isEmpty ? nil : d
        draftSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeDrafts() }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func writeDrafts() {
        draftSave?.cancel()
        draftSave = nil
        let kept = drafts.filter { !$0.value.isEmpty }
        if let data = try? JSONEncoder().encode(kept) { try? data.write(to: Self.draftsURL, options: .atomic) }
    }

    private func loadDraft() {
        loadingDraft = true
        let d = drafts[chat.id] ?? Draft()
        draft = d.text
        draftAttachments = d.attachments.filter { FileManager.default.fileExists(atPath: $0.path) }
        let editable = d.editingId.flatMap { id in chat.messages.first { $0.id == id } } != nil
        editingId = editable ? d.editingId : nil
        editText = editable ? d.editText : ""
        editAttachments = editable ? d.editAttachments : []
        loadingDraft = false
    }

    // Every change of chat goes through here: the old chat's draft stays saved.
    private func switchTo(_ next: Chat) {
        stop()
        writeDrafts()
        discardTemporary()
        chat = next
        // Its answers get parsed in the background, ready before they scroll into view.
        MarkdownCache.shared.prepare(next.messages)
        loadDraft()
        updateSpare()
        focusToken += 1
        onLayoutChange?()
    }

    // MARK: Window

    func didShow() {
        if let hiddenAt, Settings.newChatAfter > 0, !isRunning,
           Date().timeIntervalSince(hiddenAt) > Double(Settings.newChatAfter * 60), !chat.messages.isEmpty {
            newChat()
        }
        windowVisible = true
        shown = true
        // Answered while hidden: shown whole, no catching up.
        if revealId != nil, !isRunning { endReveal() } else { wakeReveal() }
        purge?.cancel()
        purge = nil
        focusToken += 1
        warmUp()
        ModelCatalog.shared.refreshIfStale()
        // Codex's usage costs nothing to ask for: rechecked each time, at most once a minute.
        if (usage[.codex]?.checkedAt ?? .distantPast).timeIntervalSinceNow < -60, CodexRunner.shared.binary != nil {
            CodexRunner.shared.fetchUsage { [weak self] u in if let u { self?.record(u) } }
        }
    }

    func didHide() {
        windowVisible = false
        shown = false
        sleepReveal()
        spareDiscard?.cancel()
        spareDiscard = nil
        // Hidden a while: caches go and freed memory goes back to the system.
        // (Not at once: reopening right away stays instant.)
        let work = DispatchWorkItem {
            MarkdownCache.shared.removeAll()
            Thumbnails.removeAll()
            malloc_zone_pressure_relief(nil, 0)
        }
        purge = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
        hiddenAt = Date()
        showingHistory = false
        writeDrafts()
        // Nothing runs in the background while the window is closed.
        if !isRunning {
            ClaudeRunner.shared.discardSpare()
            CodexRunner.shared.discardSpare()
        }
    }

    // A CLI started ahead (a "spare") answers sooner: it's started when the
    // window opens and after each answer, as before. It's a process of
    // 100 MB or more, so while the window sits open with nothing being
    // written for 3 minutes it's stopped, and started again on the first
    // keystroke. Hidden: stopped (didHide).
    private func warmUp() {
        guard windowVisible, !isRunning else { return }
        prewarm()
        scheduleSpareDiscard()
    }

    private var writing: Bool { !draft.isEmpty || !draftAttachments.isEmpty || editingId != nil }

    // Only when writing starts or stops, not on every keystroke (a spare
    // that failed would otherwise be started again on each one).
    private func updateSpare() {
        guard writing != wasWriting else { return }
        wasWriting = writing
        guard windowVisible, !isRunning else { return }
        if writing {
            spareDiscard?.cancel()
            spareDiscard = nil
            prewarm()
        } else {
            scheduleSpareDiscard()
        }
    }

    private func scheduleSpareDiscard() {
        spareDiscard?.cancel()
        spareDiscard = nil
        guard !writing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.spareDiscard = nil
            guard !self.isRunning, !self.writing else { return }
            ClaudeRunner.shared.discardSpare()
            CodexRunner.shared.discardSpare()
        }
        spareDiscard = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: work)
    }

    private func prewarm() {
        guard !isRunning else { return }
        if providerOf(model) == .claude {
            CodexRunner.shared.discardSpare()
            ClaudeRunner.shared.prewarm(model: model, effort: effort, webSearch: webSearch)
        } else {
            ClaudeRunner.shared.discardSpare()
            CodexRunner.shared.prewarm(webSearch: webSearch)
        }
    }

    // MARK: Chats

    func newChat(temporary: Bool = false) {
        var next = Self.blankChat()
        if temporary {
            next = Chat()
            next.isTemporary = true
        }
        openedFromHistory = false
        showingHistory = false
        Settings.lastChatId = nil
        switchTo(next)
    }

    // Typed text comes along when an empty chat turns temporary or back.
    func toggleTemporary() {
        let next: Chat = {
            if chat.isTemporary { return Self.blankChat() }
            var c = Chat()
            c.isTemporary = true
            return c
        }()
        let empty = chat.messages.isEmpty
        let carryText = empty ? draft : ""
        let carryFiles = empty ? adopt(draftAttachments, into: next) : []
        if empty { draft = ""; draftAttachments = [] }
        openedFromHistory = false
        showingHistory = false
        Settings.lastChatId = nil
        switchTo(next)
        if draft.isEmpty, !carryText.isEmpty { draft = carryText }
        if !carryFiles.isEmpty { draftAttachments += carryFiles }
    }

    func open(_ id: UUID) {
        guard let saved = ChatStore.shared.load(id) else {
            ChatStore.shared.delete(id)
            history = ChatStore.shared.index
            return
        }
        Settings.lastChatId = id
        openedFromHistory = true
        showingHistory = false
        switchTo(saved)
    }

    func delete(_ id: UUID) {
        ChatStore.shared.delete(id)
        drafts[id] = nil
        writeDrafts()
        history = ChatStore.shared.index
        if chat.id == id {
            openedFromHistory = false
            Settings.lastChatId = nil
            chat = Self.blankChat()
            loadDraft()
            onLayoutChange?()
        }
    }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if chat.id == id {
            chat.title = t
            chat.titleByUser = true
            save()
        } else if var saved = ChatStore.shared.load(id) {
            saved.title = t
            saved.titleByUser = true
            ChatStore.shared.save(saved)
        }
        history = ChatStore.shared.index
    }

    func backToHistory() {
        history = ChatStore.shared.index
        showingHistory = true
        onLayoutChange?()
    }

    func toggleHistory() {
        history = ChatStore.shared.index
        showingHistory.toggle()
        if !showingHistory { focusToken += 1 }
        onLayoutChange?()
    }

    private func discardTemporary() {
        if chat.isTemporary {
            drafts[chat.id] = nil
            try? FileManager.default.removeItem(at: Paths.folder(for: chat))
        }
    }

    func select(model value: String) {
        model = value
        Settings.model = value
        warmUp()
    }

    func flash(_ text: String) {
        banner = text
        bannerClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.banner = nil }
        bannerClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
        Haptics.confirm()
    }

    // MARK: Attachments

    func attach(urls: [URL], toEdit: Bool = false) {
        let folder = Paths.folder(for: chat)
        let added = Attachments.importFiles(urls, into: folder)
        if toEdit { editAttachments += added } else { draftAttachments += added }
        onDropped?()
    }

    func attach(_ list: [Attachment], toEdit: Bool = false) {
        if toEdit { editAttachments += list } else { draftAttachments += list }
        if !list.isEmpty { onDropped?() }
    }

    // A photo, scan or sketch from the iPhone (Continuity Camera).
    func importFromDevice(_ pb: NSPasteboard) -> Bool {
        let list = Attachments.fromDevice(pb, into: Paths.folder(for: chat))
        attach(list, toEdit: editingId != nil)
        return !list.isEmpty
    }

    func chooseFiles(toEdit: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.level = .floating + 1
        if panel.runModal() == .OK { attach(urls: panel.urls, toEdit: toEdit) }
        focusToken += 1
    }

    // Attachments kept in another chat's folder (a fork, a draft carried
    // over) are copied into this one's, so deleting that chat can't break them.
    private func adopt(_ list: [Attachment], into target: Chat) -> [Attachment] {
        let folder = Paths.folder(for: target)
        return list.map { a in
            guard a.kind != .folder, !a.path.hasPrefix(folder.path) else { return a }
            let dest = folder.appendingPathComponent(a.url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: a.url, to: dest)
            }
            var copy = a
            copy.path = dest.path
            return copy
        }
    }

    // MARK: Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty || !draftAttachments.isEmpty else { return }
        let user = Message(role: .user, text: text, attachments: adopt(draftAttachments, into: chat))
        draft = ""
        draftAttachments = []
        if chat.title.isEmpty { chat.title = titleFrom(text.isEmpty ? (user.attachments.first?.name ?? "Attachment") : text) }
        withAnimation(.spring(duration: 0.38, bounce: 0.1)) {
            chat.messages.append(user)
            showingHistory = false
        }
        // Outside the spring: Stop and the status fade in on their own.
        generate()
        onLayoutChange?()
    }

    // Answers the last message (a user message).
    private func generate(fellBackFrom: Provider? = nil) {
        guard let question = chat.messages.last, question.role == .user else { return }
        var runModel = model
        var note: String?
        if let from = fellBackFrom {
            note = fallbackNote(from: from, to: runModel)
        } else if Settings.autoFallback, usage[providerOf(model)]?.isExhausted == true,
                  let fb = fallback(for: providerOf(model)) {
            note = fallbackNote(from: providerOf(model), to: fb)
            runModel = fb
            select(model: fb)
        }
        let answer = Message(role: .assistant, text: "", model: runModel, note: note)
        chat.messages.append(answer)
        runningId = answer.id
        status = nil
        startReveal(answer.id)
        let req = RunRequest(model: runModel, effort: effort, webSearch: webSearch,
                             history: Array(chat.messages.dropLast(2)), question: question)
        let onEvent: (RunEvent) -> Void = { [weak self] event in
            guard let self, self.runningId == answer.id else { return }
            switch event {
            case .text(let t): self.latestText = t
            case .status(let s): if self.status != s { self.status = s }
            case .usage(let u): self.record(u)
            }
        }
        let completion: (RunResult) -> Void = { [weak self] result in
            self?.finish(answer.id, runModel, result, fellBack: fellBackFrom != nil)
        }
        handle = providerOf(runModel) == .claude
            ? ClaudeRunner.shared.run(req, onEvent: onEvent, completion: completion)
            : CodexRunner.shared.run(req, onEvent: onEvent, completion: completion)
    }

    // MARK: Smooth text

    private func startReveal(_ id: UUID) {
        Haptics.cancelDone()
        revealId = id
        revealed = ""
        cursor = RevealCursor()
        latestText = ""
        wakeReveal()
    }

    // The reveal timer runs only while there's something to show: it sleeps
    // while waiting for the model (thinking can take a while) and while the
    // window is hidden, and wakes on new text, the end of the answer, or showing.
    private func wakeReveal() {
        guard revealTimer == nil, revealId != nil, shown else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.revealTick() }
        RunLoop.main.add(t, forMode: .common)
        revealTimer = t
    }

    private func sleepReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
    }

    private func endReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
        revealId = nil
        revealed = ""
        cursor = RevealCursor()
        fadeTail = 0
    }

    // Shows a few more characters per frame: more when it's far behind, so
    // it never lags much, and evenly instead of in network-sized jumps.
    private func revealTick() {
        guard let id = revealId else { return endReveal() }
        let target: String
        if runningId == id {
            target = latestText
        } else if let m = chat.messages.first(where: { $0.id == id }) {
            target = m.text
        } else {
            return endReveal()
        }
        cursor.update(target)
        // Once the answer is complete, the rest appears quickly instead of
        // easing in over a second.
        if cursor.advance(fast: runningId != id) {
            revealed = cursor.shown
            fadeTail = 30
            // Light ticks at uneven gaps while text appears, some skipped.
            if Date().timeIntervalSince(lastHaptic) >= hapticGap {
                lastHaptic = Date()
                hapticGap = Haptics.nextGap()
                if !Haptics.shouldSkip() { Haptics.tick() }
            }
        } else if fadeTail > 0 {
            // Caught up: the last characters finish fading in.
            fadeTail = max(0, fadeTail - (runningId == id ? 2 : 6))
        } else if runningId == id {
            // Caught up, waiting for more: sleep until it comes.
            sleepReveal()
        } else if runningId != id {
            let finished = chat.messages.first { $0.id == id }
            endReveal()
            if finished?.error == nil, !(finished?.text.isEmpty ?? true) { Haptics.done(after: lastHaptic) }
        }
    }

    private func finish(_ id: UUID, _ runModel: String, _ result: RunResult, fellBack: Bool) {
        guard runningId == id, let i = chat.messages.firstIndex(where: { $0.id == id }) else { return }
        handle = nil
        let provider = providerOf(runModel)
        if result.error?.kind == .usageLimit, result.text.isEmpty, !fellBack, Settings.autoFallback,
           let fb = fallback(for: provider) {
            if var u = usage[provider] { u.limitReached = true; record(u) }
            chat.messages.remove(at: i)
            runningId = nil
            select(model: fb)
            generate(fellBackFrom: provider)
            return
        }
        chat.messages[i].text = result.text
        chat.messages[i].durationMs = result.durationMs
        if let e = result.error, e.kind != .cancelled || result.text.isEmpty {
            chat.messages[i].error = errorText(e, provider)
        }
        // The reveal finishes on its own, then shows the message as saved.
        runningId = nil
        status = nil
        chat.updatedAt = Date()
        save()
        wakeReveal()
        if NSApp.isActive { warmUp() }
        if result.error == nil, !result.text.isEmpty { nameFromContent() }
    }

    // A title for what the chat is about, written by a small fast model
    // after the first answer and again every 3rd one, as the topic drifts.
    // Cheap: the selected provider's smallest model (Claude Haiku, Codex
    // Luna; the other provider when it's out of usage), without reasoning, tools or web
    // search, given only the current title, up to 8 questions spread over
    // the whole chat (100 characters each) and the start of the latest
    // answer: ~1,200 characters in, a few words back. Not for chats you renamed, forks or temporary chats.
    static let retitleEvery = 3

    private func nameFromContent(force: Bool = false) {
        guard !chat.isTemporary, chat.parentId == nil, chat.titleByUser != true else { return }
        let answers = chat.messages.filter { $0.role == .assistant && $0.error == nil && !$0.text.isEmpty }
        guard let latest = answers.last, force || answers.count % Self.retitleEvery == 1 else { return }
        // Spread over the chat, first and latest included: the title is about
        // the whole conversation, not only where it is now.
        let all = chat.messages.filter { $0.role == .user }
        let picks = all.count <= 8 ? Array(all.indices) : (0..<8).map { $0 * (all.count - 1) / 7 }
        let questions = picks.map { all[$0] }
            .map { "- " + ($0.text.isEmpty ? ($0.attachments.first?.name ?? "Attachment") : String($0.text.prefix(100))) }
        let before = chat.title
        let id = chat.id
        let prompt = """
            Title this conversation: 2 to 6 words naming its overall theme or purpose, \
            across all of it, not just its latest part (keep the current title if it still fits). \
            Same language as the questions; no quotes, no final full stop. Reply with the title only.

            Current title: \(before)
            Questions, first to latest:
            \(questions.joined(separator: "\n"))
            Start of the latest answer: \(latest.text.prefix(200))
            """
        // The selected model's provider, or the other one when it's out of
        // usage (or not installed): its smallest model, without reasoning.
        let installed = { (p: Provider) in (p == .claude ? ClaudeRunner.shared.binary : CodexRunner.shared.binary) != nil }
        let usable = { (p: Provider) in installed(p) && self.usage[p]?.isExhausted != true }
        let selected = providerOf(model)
        guard let provider = usable(selected) ? selected : usable(selected.other) ? selected.other : nil else { return }
        let useClaude = provider == .claude
        let codexSmall = models.first { $0.provider == .codex && $0.value.contains("luna") && $0.value.contains("gpt-6") }?.value
            ?? models.first { $0.provider == .codex && $0.value.contains("luna") }?.value ?? codexPrefix + "default"
        let req = RunRequest(model: useClaude ? "haiku" : codexSmall, effort: useClaude ? "instant" : "low",
                             webSearch: false, history: [], question: Message(role: .user, text: prompt))
        let done: (RunResult) -> Void = { [weak self] result in
            guard let self, result.error == nil, let title = Self.cleanTitle(result.text), title != before else { return }
            // Only if nobody renamed it meanwhile.
            if self.chat.id == id {
                guard self.chat.title == before, self.chat.titleByUser != true else { return }
                self.chat.title = title
                // Mid-answer, that answer's own save stores it (saving now would
                // write the unfinished answer).
                if !self.isRunning { self.save() } else { self.history = ChatStore.shared.index }
            } else if var saved = ChatStore.shared.load(id), saved.title == before, saved.titleByUser != true {
                saved.title = title
                ChatStore.shared.save(saved)
                self.history = ChatStore.shared.index
            }
        }
        _ = useClaude
            ? ClaudeRunner.shared.run(req, onEvent: { _ in }, completion: done)
            : CodexRunner.shared.run(req, onEvent: { _ in }, completion: done)
    }

    // Retitles the open chat now (debug hook "retitle").
    func retitleNow() { nameFromContent(force: true) }

    // The model's reply as a title: its first line, without quotes, Markdown
    // or a full stop; nil if that leaves nothing sensible.
    static func cleanTitle(_ reply: String) -> String? {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’*#`.").union(.whitespaces))
        guard !t.isEmpty, t.count <= 80 else { return nil }
        return titleFrom(t)
    }

    private func fallbackNote(from: Provider, to model: String) -> String {
        "\(from.name) usage limit reached: switched to \(ModelCatalog.shared.fullTitle(model))"
    }

    private func save() {
        guard !chat.isTemporary else { return }
        ChatStore.shared.save(chat)
        Settings.lastChatId = chat.id
        // Sent: the next new chat gets its own id.
        if chat.id == Settings.newChatId { Settings.newChatId = UUID() }
        history = ChatStore.shared.index
    }

    private func errorText(_ e: RunError, _ p: Provider) -> String {
        switch e.kind {
        case .cancelled: return "Stopped."
        case .notInstalled: return e.message
        case .notLoggedIn:
            return p == .claude ? "Claude Code isn't signed in. In Terminal run `claude`, then `/login`.\n\n\(e.message)"
                : "Codex isn't signed in. In Terminal run `codex login`.\n\n\(e.message)"
        case .usageLimit: return "\(p.name) usage limit reached.\n\n\(e.message)"
        case .other: return e.message
        }
    }

    // The fallback model on the other provider, unless it's out too.
    private func fallback(for provider: Provider) -> String? {
        let other = provider.other
        guard usage[other]?.isExhausted != true else { return nil }
        let value = other == .claude ? Settings.fallbackClaude : Settings.fallbackCodex
        let available = other == .claude ? ClaudeRunner.shared.binary : CodexRunner.shared.binary
        return available == nil ? nil : value
    }

    func record(_ u: Usage) {
        usage[u.provider] = u
        Settings.setUsage(u)
    }

    // Frees the window at once, whatever the CLI does next; a late answer is ignored.
    func stop() {
        guard let id = runningId else { return }
        handle?.cancel()
        handle = nil
        let text = latestText
        if let i = chat.messages.firstIndex(where: { $0.id == id }) {
            chat.messages[i].text = text
            if text.isEmpty { chat.messages[i].error = "Stopped." }
            chat.updatedAt = Date()
        }
        runningId = nil
        status = nil
        endReveal()
        save()
    }

    // MARK: Editing, retrying and forking

    func startEdit(_ id: UUID) {
        guard !isRunning, let m = chat.messages.first(where: { $0.id == id }), m.role == .user else { return }
        editText = m.text
        editAttachments = m.attachments
        editingId = id
    }

    func editLast() {
        if let last = chat.messages.last(where: { $0.role == .user }) { startEdit(last.id) }
    }

    func cancelEdit() {
        editingId = nil
        editText = ""
        editAttachments = []
        focusToken += 1
    }

    // The edited message replaces the original; what came after is answered again.
    func saveEdit() {
        guard !isRunning, let id = editingId, let i = chat.messages.firstIndex(where: { $0.id == id }) else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !editAttachments.isEmpty else { return }
        // The version being replaced is kept, with everything after it.
        let old = chat.messages[i]
        var all = old.versions ?? []
        all.insert(Self.detached(Array(chat.messages[i...])), at: min(old.versionIndex ?? all.count, all.count))
        var edited = old
        edited.text = text
        edited.attachments = adopt(editAttachments, into: chat)
        edited.versions = all
        edited.versionIndex = all.count
        chat.messages.replaceSubrange(i..., with: [edited])
        if i == 0, chat.titleByUser != true { chat.title = titleFrom(text) }
        editingId = nil
        editText = ""
        editAttachments = []
        focusToken += 1
        generate()
    }

    // Shows version `k` of an edited question, with what followed it then.
    func showVersion(_ k: Int, of id: UUID) {
        guard !isRunning, let i = chat.messages.firstIndex(where: { $0.id == id }), let versions = chat.messages[i].versions else { return }
        if editingId != nil { cancelEdit() }
        var all = versions
        all.insert(Self.detached(Array(chat.messages[i...])), at: min(chat.messages[i].versionIndex ?? all.count, all.count))
        guard all.indices.contains(k) else { return }
        var chosen = all.remove(at: k)
        chosen[0].versions = all
        chosen[0].versionIndex = k
        chat.messages.replaceSubrange(i..., with: chosen)
        save()
    }

    // A version as stored: its first message without the version list.
    private static func detached(_ tail: [Message]) -> [Message] {
        var t = tail
        t[0].versions = nil
        t[0].versionIndex = nil
        return t
    }

    func retry(_ id: UUID) {
        guard !isRunning, let i = chat.messages.firstIndex(where: { $0.id == id }), chat.messages[i].role == .assistant else { return }
        chat.messages.removeSubrange(i...)
        generate()
    }

    // A new chat with everything up to this message. From a question, the
    // question goes into the composer to change before sending; from an
    // answer, what's in the composer comes along.
    func fork(at id: UUID) {
        guard !isRunning, let i = chat.messages.firstIndex(where: { $0.id == id }) else { return }
        var forked = Chat()
        forked.isTemporary = chat.isTemporary
        // Forks hang under the original chat in History: "Title (Fork 2)".
        let root = chat.parentId ?? chat.id
        forked.parentId = chat.isTemporary ? nil : root
        let m = chat.messages[i]
        let kept = m.role == .user ? Array(chat.messages[..<i]) : Array(chat.messages[...i])
        forked.messages = kept.map { msg in
            var copy = msg
            copy.attachments = adopt(msg.attachments, into: forked)
            return copy
        }
        let rootTitle = (chat.parentId.flatMap { id in ChatStore.shared.index.first { $0.id == id }?.title } ?? chat.title)
            .replacingOccurrences(of: #" \(Fork \d+\)$"#, with: "", options: .regularExpression)
        let base = rootTitle.isEmpty ? titleFrom(m.text) : rootTitle
        let n = ChatStore.shared.index.filter { $0.parentId == root }.count + 1
        forked.title = "\(base) (Fork \(n))"
        let carried = m.role == .user
            ? (m.text, adopt(m.attachments, into: forked))
            : (draft, adopt(draftAttachments, into: forked))
        openedFromHistory = false
        switchTo(forked)
        if !forked.messages.isEmpty { save() }
        draft = carried.0
        draftAttachments = carried.1
        flash("Forked as Fork \(n)")
    }

    // MARK: Benchmark

    // An answer streamed by a timer instead of a CLI (DebugHooks / Bench only):
    // the same reveal, rendering and saving path as a real answer.
    // `likeSend`: the question goes in the way send() puts it (animated).
    func simulateAnswer(_ full: String, chunk: Int, every: TimeInterval, likeSend: Bool = false, done: @escaping () -> Void) {
        if likeSend {
            if chat.title.isEmpty { chat.title = "Fake question" }
            withAnimation(.spring(duration: 0.38, bounce: 0.1)) {
                chat.messages.append(Message(role: .user, text: "Fake question"))
                showingHistory = false
            }
        } else {
            chat.messages.append(Message(role: .user, text: "Benchmark question"))
        }
        let answer = Message(role: .assistant, text: "", model: model)
        chat.messages.append(answer)
        runningId = answer.id
        status = nil
        startReveal(answer.id)
        let chars = Array(full)
        var sent = 0
        Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            sent = min(chars.count, sent + chunk)
            self.latestText = String(chars[0..<sent])
            guard sent >= chars.count else { return }
            t.invalidate()
            self.finish(answer.id, self.model, RunResult(text: full, error: nil, durationMs: 0), fellBack: true)
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t2 in
                if self.revealId == nil { t2.invalidate(); done() }
            }
        }
    }
}
