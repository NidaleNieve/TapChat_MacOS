import AppKit
import Foundation

struct RunRequest {
    var model: String
    var effort: String?
    var webSearch: Bool
    // Earlier turns, then the question (a user message).
    var history: [Message]
    var question: Message
    // A check nobody waits for (usage): at a lower priority, no spare used.
    var background = false
    // The faster speed asked for (ModelOption.fastTier), or nil.
    var fastTier: String? = nil
    // File editing (Settings.fileEditing): it may change files and run
    // commands, each after the user allows it (RunEvent.approval).
    var canEdit = false
}

struct RunError: Error {
    enum Kind { case usageLimit, notLoggedIn, notInstalled, cancelled, other }
    var kind: Kind
    var message: String
}

struct RunResult {
    var text: String
    var error: RunError?
    var durationMs: Int?
}

enum RunEvent {
    // The whole answer so far.
    case text(String)
    // What the model is doing ("Searching the web…"), or nil.
    case status(String?)
    case usage(Usage)
    // It wants to do something the user must allow first.
    case approval(Approval)
}

// A request to change a file, run a command or read outside what was
// attached, waiting for the user. `respond` is called once.
final class Approval: Identifiable {
    enum Kind: String { case edit, command, read }
    enum Decision { case allow, allowForChat, allowEverything, deny }
    let id = UUID()
    let kind: Kind
    // "Edit report.docx", "Run a command".
    let title: String
    // The path(s) or the command.
    let detail: String
    // What "Allow for this chat" covers: the kind, or for a command its program.
    let scope: String
    // It deletes something: never covered by "Allow Everything", only by
    // allowing it (or its program) itself.
    let deletes: Bool
    private var respondOnce: ((Decision) -> Void)?

    init(kind: Kind, title: String, detail: String, scope: String? = nil, deletes: Bool? = nil, respond: @escaping (Decision) -> Void) {
        self.kind = kind
        self.title = title
        self.detail = detail
        let deleting = deletes ?? (kind == .command && Approval.deletes(detail))
        self.deletes = deleting
        // Deleting is allowed for a chat only as itself, never by program.
        self.scope = deleting ? "delete" : scope ?? kind.rawValue
        respondOnce = respond
    }

    func respond(_ d: Decision) {
        respondOnce?(d)
        respondOnce = nil
    }

    // Whether a command looks like it deletes files: rm, rmdir, unlink,
    // shred, trash, find -delete, git rm/clean, and Python's or Node's
    // remove calls. Erring towards asking.
    static func deletes(_ command: String) -> Bool { !deletions(command).isEmpty }

    private static let deletePatterns = [
        #"(^|[\s;&|(`$])(sudo\s+)?(rm|rmdir|unlink|srm|shred|trash)(\s|$)"#, #"\bfind\b.*\s-delete\b"#,
        #"\bgit\s+(rm|clean)\b"#, #"\b(os\.(remove|unlink|rmdir|removedirs)|shutil\.rmtree|send2trash|\.unlink\(|\.rmdir\(|unlinkSync|rmSync|fs\.rm)\b"#,
        #"removeItem"#,
    ]

    // The parts of a command that delete (shown on the card): its lines and
    // `&&`/`;` steps that match, leaving out text a heredoc writes into a
    // file (`cat > f <<EOF … EOF`), which is data, not run. A heredoc fed
    // to python3 or node is run, so it's checked.
    static func deletions(_ command: String) -> [String] {
        var lines: [String] = []
        var skipUntil: String?
        for line in command.components(separatedBy: "\n") {
            if let end = skipUntil {
                if line.trimmingCharacters(in: .whitespaces) == end { skipUntil = nil }
                continue
            }
            lines.append(line)
            if let m = line.firstMatch(of: #/<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/#),
               line.range(of: #"\b(cat|tee)\b"#, options: .regularExpression) != nil {
                skipUntil = String(m.1)
            }
        }
        var found: [String] = []
        for line in lines {
            for part in line.components(separatedBy: "&&").flatMap({ $0.components(separatedBy: ";") }) {
                let p = part.trimmingCharacters(in: .whitespaces)
                guard !p.isEmpty, deletePatterns.contains(where: { p.range(of: $0, options: .regularExpression) != nil }) else { continue }
                found.append(p.count > 90 ? String(p.prefix(88)) + "…" : p)
            }
        }
        return Array(found.prefix(3))
    }

    // A command's program ("python3", "zip"), for "Allow for this chat":
    // the first real command, past `cd …`, `export …`, variable settings and
    // sudo, with quoted paths kept whole.
    // Every program in it, so "Always allow" covers that same set only
    // (allowing `ls` never lets `ls; python3 …` through).
    static func program(_ command: String) -> String {
        var programs: [String] = []
        for segment in segments(command) {
            var words = shellWords(segment)
            while let w = words.first, w == "sudo" || w == "env" || w == "command" || w == "exec" || (w.contains("=") && !w.hasPrefix("=")) {
                words.removeFirst()
            }
            guard let first = words.first, !["cd", "pushd", "popd", "export", "set", "source", ".", "true"].contains(first) else { continue }
            let name = (first as NSString).lastPathComponent
            if !programs.contains(name) { programs.append(name) }
        }
        return "command:" + (programs.isEmpty ? command : programs.joined(separator: ", "))
    }

    // The commands in a line: split at ; | & and newlines outside quotes
    // (a heredoc's body counts as one, the rest of the text).
    private static func segments(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for c in s {
            if let q = quote {
                if c == q { quote = nil }
                cur.append(c)
            } else if c == "'" || c == "\"" {
                quote = c
                cur.append(c)
            } else if ";|&\n".contains(c) {
                out.append(cur); cur = ""
                if c == "\n", s.contains("<<") { break }
            } else {
                cur.append(c)
            }
        }
        out.append(cur)
        return out
    }

    // Words as a shell splits them: spaces, with '…' and "…" kept together.
    private static func shellWords(_ s: String) -> [String] {
        var words: [String] = [], word = "", quote: Character?, any = false
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c; any = true
            } else if c == " " || c == "\t" {
                if any || !word.isEmpty { words.append(word); word = ""; any = false }
            } else {
                word.append(c)
            }
        }
        if any || !word.isEmpty { words.append(word) }
        return words
    }
}

func tildePath(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
}

final class RunHandle {
    var cancelAction: (() -> Void)?
    func cancel() { cancelAction?() }
}

// With what TapChat remembers about the user (MemoryStore), when on.
var systemPrompt: String { baseSystemPrompt + MemoryStore.shared.promptSection }

// The instructions for a run: with file editing, how to go about it.
func instructions(edit: Bool) -> String { systemPrompt + (edit ? editingPrompt : "") }

// With file editing on (Settings.fileEditing).
var editingPrompt: String { editingPromptText.replacingOccurrences(of: "{work}", with: Paths.work.path) }

private let editingPromptText = """

File editing is on. When the user asks you to change, create, convert or organise files on their Mac, you can read and edit files and \
run commands to do it, anywhere they point you to (they may just name a folder or file). Each change and command is shown to the user \
to allow first, so do the work in a few clear steps rather than many small ones, and only touch what they asked about. \
Save a changed document as a new file next to the original (like "report (edited).docx") unless they ask you to replace it. \
Never delete files unless asked. Office files (.docx, .xlsx, .pptx) are zip archives of XML: python3 with zipfile works for them \
(python-docx and openpyxl may not be installed). Don't delete a file to replace it: overwrite it (each deletion asks \
the user separately). Your working folder, {work}, is TapChat's own: there you can create files and run commands without asking the user, \
so do the work there (in a subfolder per task) and put new files there unless the user names another place. \
Anything outside it (reading, changing, or a command reaching outside) asks the user first. \
When you're done, say briefly what you changed, and give the full path of each file you made or changed in backticks \
(like `/Users/name/Downloads/report.docx`): TapChat shows them as files to open.
"""

let baseSystemPrompt = """
You are a helpful, concise assistant in a quick-access chat window on the user's Mac, used for quick lookups and help with writing. \
Reply in the language the user writes in. Skip filler and preambles. Use Markdown when it helps; use fenced code blocks with a language tag for code; write math in LaTeX, \\( … \\) inline and \\[ … \\] on its own lines. \
Earlier turns of the conversation, if any, come first inside <conversation_history>; continue the conversation and answer the user's latest message. \
A message may start with <reply> elements: each quotes part of an earlier message (<quote>) with the user's note on it (<note>). \
When the user has attached a folder or a PDF, you can list, search and read the files in it (read-only) with your tools; \
open them when the question needs them. You can't reach anything else on the Mac. \
The latest message may start with <context>: the current local time and the user's rough location, taken from their Mac's time zone and region \
settings (not GPS). Use it when the answer depends on the date, time or place, and don't mention it otherwise. \
When the user asks for a file they can download (a document, spreadsheet, script, calendar event…), put the whole file in a fenced code block \
whose info string is `file:` and the file name, like ```file:packing-list.md; TapChat shows it as a file to open or save. \
For .docx, .pdf or .rtf write the content as simple HTML (TapChat converts it); for spreadsheets use .csv.
"""

// The time and rough location, sent with the question (not in the
// instructions, which the CLIs started ahead already hold). From the time
// zone and the Mac's region: no location permission, nothing looked up.
func localContext(_ now: Date = Date()) -> String? {
    guard Settings.shareContext else { return nil }
    let tz = TimeZone.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz
    f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
    let offset = DateFormatter()
    offset.locale = f.locale
    offset.timeZone = tz
    offset.dateFormat = "xxx"
    var abbr = tz.abbreviation(for: now) ?? ""
    if abbr.hasPrefix("GMT") && abbr != "GMT" { abbr = "" }
    var lines = ["Local time: \(f.string(from: now)) (UTC\(offset.string(from: now))\(abbr.isEmpty ? "" : ", \(abbr)"), time zone \(tz.identifier))"]
    var place: [String] = []
    let parts = tz.identifier.split(separator: "/")
    if parts.count >= 2, parts[0] != "Etc" {
        place.append("near " + parts[parts.count - 1].replacingOccurrences(of: "_", with: " "))
    }
    if let code = Locale.current.region?.identifier,
       let country = Locale(identifier: "en_US").localizedString(forRegionCode: code) {
        place.append("Mac region set to \(country)")
    }
    if !place.isEmpty { lines.append("Rough location: " + place.joined(separator: "; ")) }
    return "<context>\n" + lines.joined(separator: "\n") + "\n</context>\n"
}

extension RunRequest {
    // Where the model may read (read-only): attached folders, and the
    // folders holding attached PDFs (to read pages its text extraction missed).
    var readableDirs: [String] {
        let all = (history + [question]).flatMap(\.attachments)
        let folders = all.filter { $0.kind == .folder }.map(\.path)
        let pdfs = all.filter { $0.kind == .file && $0.url.pathExtension.lowercased() == "pdf" }
            .map { $0.url.deletingLastPathComponent().path }
        return Array(Set(folders + pdfs)).sorted()
    }
}

// The prompt as text and images in order. Each run sends the whole chat, so
// edits, forks and model switches need no CLI session state.
enum PromptPart {
    case text(String)
    case image(URL)
}

func promptParts(_ req: RunRequest) -> [PromptPart] {
    var parts: [PromptPart] = []
    // Text is gathered in one buffer and becomes a part at each image (or the
    // end). Appending to the last part instead copied the whole prompt each
    // time: quadratic in a long chat.
    var text = ""
    func add(_ s: String) { text += s }
    func flushText() {
        guard !text.isEmpty else { return }
        parts.append(.text(text))
        text = ""
    }
    func addMessage(_ m: Message) {
        if let q = m.quote { add("<reply><quote>\(q)</quote></reply>\n") }
        for r in m.replies ?? [] { add("<reply><quote>\(r.quote)</quote><note>\(r.note)</note></reply>\n") }
        add(m.text)
        for a in m.attachments {
            switch a.kind {
            case .image:
                add("\n[Image: \(a.name)]\n")
                flushText()
                parts.append(.image(a.url))
            case .folder:
                add("\n[Folder: \(a.path) — you can list, search and read the files in it]\n")
            case .file:
                // A PDF's path too: its pages can be read when the text alone isn't enough.
                let path = a.url.pathExtension.lowercased() == "pdf" ? " path=\"\(a.path)\"" : ""
                add("\n<file name=\"\(a.name)\"\(path)>\n\(extractText(a.url))\n</file>\n")
            }
        }
    }
    let earlier = req.history.filter { $0.error == nil || $0.role == .user }
    if !earlier.isEmpty {
        add("<conversation_history>\n")
        for m in earlier {
            add(m.role == .user ? "<user>\n" : "<assistant>\n")
            addMessage(m)
            add(m.role == .user ? "\n</user>\n" : "\n</assistant>\n")
        }
        add("</conversation_history>\n\n")
    }
    if !req.background, let context = localContext() { add(context) }
    addMessage(req.question)
    flushText()
    return parts
}

func classify(_ message: String) -> RunError {
    if message.range(of: #"not logged in|login expired|/login|invalid api key|authenticat|unauthori[sz]ed|401"#, options: [.regularExpression, .caseInsensitive]) != nil {
        return RunError(kind: .notLoggedIn, message: message)
    }
    if message.range(of: #"hit your .*limit|usage limit|rate.?limit|quota|429"#, options: [.regularExpression, .caseInsensitive]) != nil {
        return RunError(kind: .usageLimit, message: message)
    }
    return RunError(kind: .other, message: message)
}

// Ends a run that has gone quiet: a CLI can hang, or sit retrying a request.
final class Watchdog {
    private var work: DispatchWorkItem?
    private let seconds: Double
    private let onTimeout: () -> Void
    init(seconds: Double, onTimeout: @escaping () -> Void) {
        self.seconds = seconds
        self.onTimeout = onTimeout
        kick()
    }
    func kick() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onTimeout() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
    func stop() { work?.cancel(); work = nil }
}

// A short trail of what the CLIs did, for when something goes wrong.
// Written on its own queue: never file work on the main thread.
private let logQueue = DispatchQueue(label: "TapChat.log", qos: .utility)
private let logStamp = ISO8601DateFormatter()

func log(_ line: String) {
    let date = Date()
    logQueue.async { writeLog(line, date) }
}

private func writeLog(_ line: String, _ date: Date) {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/TapChat.log")
    let stamp = logStamp.string(from: date)
    guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       (attrs[.size] as? Int ?? 0) > 1_000_000 {
        try? FileManager.default.removeItem(at: url)
    }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: url)
    }
}

func findBinary(_ preferred: String, _ candidates: [String]) -> String? {
    let fm = FileManager.default
    if !preferred.isEmpty, fm.isExecutableFile(atPath: preferred) { return preferred }
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}

// MARK: - Claude

final class ClaudeRunner {
    static let shared = ClaudeRunner()
    private var spare: (key: [String], process: LineProcess)?

    var binary: String? {
        findBinary(Settings.claudePath, ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }

    // A chat model, not a coding agent: no tools but web search (when asked)
    // and, for attached folders and PDFs, reading them: Read, Glob and Grep,
    // limited to those folders (--add-dir), never writing or running anything.
    // No MCP, settings files, slash commands or saved sessions.
    func arguments(model: String, effort: String?, webSearch: Bool, fast: Bool = false, readable: [String] = [], edit: Bool = false) -> [String] {
        var args = ["-p", "--model", model]
        // Fast mode: a setting of its own (only the session's settings are read).
        // Fast mode, and with file editing Claude Code's sandbox: commands
        // run without asking inside the working folder (TapChat's own) and
        // can't write outside it unless the user allows that one.
        var settings: [String: Any] = [:]
        if fast { settings["fastMode"] = true }
        if edit { settings["sandbox"] = ["enabled": true, "autoAllowBashIfSandboxed": true] }
        if !settings.isEmpty, let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            args += ["--settings", json]
        }
        let web = webSearch ? ["WebSearch", "WebFetch"] : []
        if edit {
            // File editing: reading the attached folders is allowed; anything
            // else (other reads, every edit and command) asks over stdio
            // (control_request), as Claude Code's own permission prompts.
            let tools = web + ["Read", "Glob", "Grep", "Edit", "Write", "Bash"]
            // Edits inside the working folder (and attached folders) go ahead; others ask.
            args += ["--tools", tools.joined(separator: ","), "--permission-prompt-tool", "stdio", "--permission-mode", "acceptEdits"]
            if !web.isEmpty { args += ["--allowedTools", web.joined(separator: ",")] }
        } else {
            let tools = web + (readable.isEmpty ? [] : ["Read", "Glob", "Grep"])
            if tools.isEmpty {
                args += ["--tools", ""]
            } else {
                let list = tools.joined(separator: ",")
                args += ["--tools", list, "--allowedTools", list]
            }
        }
        for dir in readable { args += ["--add-dir", dir] }
        // Instant: the lowest effort, and no extended thinking (see `environment`).
        if let effort { args += ["--effort", effort == "instant" ? "low" : effort] }
        args += [
            "--input-format", "stream-json",
            "--output-format", "stream-json", "--include-partial-messages", "--verbose",
            "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
            "--no-session-persistence",
            "--system-prompt", instructions(edit: edit),
        ]
        return args
    }

    private func environment(_ effort: String?) -> [String: String] {
        effort == "instant" ? ["MAX_THINKING_TOKENS": "0"] : [:]
    }

    private func spawn(_ args: [String], _ env: [String: String], background: Bool = false) -> LineProcess? {
        guard let bin = binary else { return nil }
        let p = LineProcess(executable: bin, arguments: args, directory: Paths.work, extraEnvironment: env)
        p.background = background
        do { try p.start() } catch { return nil }
        return p
    }

    // Claude Code's startup (~2-3 s) happens while the user types: the process
    // waits on stdin, making no requests, until the question comes.
    func prewarm(model: String, effort: String?, webSearch: Bool, fast: Bool = false) {
        let args = arguments(model: model, effort: effort, webSearch: webSearch, fast: fast, edit: Settings.fileEditing)
        let key = args + (effort == "instant" ? ["instant"] : [])
        if let spare, spare.key == key, spare.process.isRunning { return }
        discardSpare()
        if let p = spawn(args, environment(effort)) { spare = (key, p) }
    }

    func discardSpare() {
        spare?.process.kill()
        spare = nil
    }

    func run(_ req: RunRequest, onEvent: @escaping (RunEvent) -> Void, completion: @escaping (RunResult) -> Void) -> RunHandle {
        let handle = RunHandle()
        let args = arguments(model: req.model, effort: req.effort, webSearch: req.webSearch, fast: req.fastTier != nil,
                             readable: req.readableDirs, edit: req.canEdit)
        let key = args + (req.effort == "instant" ? ["instant"] : [])
        let process: LineProcess
        var warm = false
        if !req.background, let spare, spare.key == key, spare.process.isRunning {
            process = spare.process
            self.spare = nil
            warm = true
        } else if let p = spawn(args, environment(req.effort), background: req.background) {
            process = p
        } else {
            DispatchQueue.main.async {
                completion(RunResult(text: "", error: RunError(kind: .notInstalled, message: "Claude Code CLI not found. Install it, or set its path in Settings.")))
            }
            return handle
        }

        let started = Date()
        var text = ""
        var resultText: String?
        var resultIsError = false
        var cancelled = false
        var completed = false
        log("claude start model=\(req.model) effort=\(req.effort ?? "-") web=\(req.webSearch) warm=\(warm)")
        var watchdog: Watchdog?
        let complete = { (r: RunResult) in
            guard !completed else { return }
            completed = true
            watchdog?.stop()
            log("claude done ms=\(r.durationMs ?? 0) chars=\(r.text.count) error=\(r.error.map { "\($0.kind): \($0.message.prefix(200))" } ?? "none")")
            completion(r)
        }
        let ms = { Int(Date().timeIntervalSince(started) * 1000) }
        // Out of usage: stop now instead of waiting for Claude Code's retries.
        let limitHit = { (message: String) in
            process.kill()
            complete(RunResult(text: text, error: RunError(kind: .usageLimit, message: message), durationMs: ms()))
        }
        watchdog = Watchdog(seconds: 180) {
            process.kill()
            complete(RunResult(text: text, error: RunError(kind: .other, message: "Claude stopped responding."), durationMs: ms()))
        }
        handle.cancelAction = {
            cancelled = true
            process.interrupt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                process.kill()
                complete(RunResult(text: text, error: RunError(kind: .cancelled, message: "Stopped."), durationMs: ms()))
            }
        }

        process.onLine = { line in
            watchdog?.kick()
            guard let event = jsonObject(line) else { return }
            switch event["type"] as? String {
            case "system":
                guard event["subtype"] as? String == "api_retry" else { break }
                let status = event["error_status"] as? Int
                let err = "\(event["error"] ?? "")"
                log("claude api_retry status=\(status.map(String.init) ?? "-") error=\(err)")
                if status == 429 || err.range(of: "rate.?limit|usage", options: [.regularExpression, .caseInsensitive]) != nil {
                    limitHit("Claude usage limit reached.")
                } else {
                    onEvent(.status("Retrying…"))
                }
            case "stream_event":
                guard let ev = event["event"] as? [String: Any] else { return }
                if ev["type"] as? String == "message_start", !text.isEmpty, !text.hasSuffix("\n\n") {
                    text += "\n\n"
                }
                // Only real reasoning is shown as "Thinking…".
                if ev["type"] as? String == "content_block_start",
                   let block = ev["content_block"] as? [String: Any] {
                    if block["type"] as? String == "thinking" { onEvent(.status("Thinking…")) }
                    // A tool's input is written out first (a whole file, for
                    // Write), which can take a while before it runs or asks:
                    // said from the start, not a blank wait.
                    if block["type"] as? String == "tool_use" {
                        switch block["name"] as? String ?? "" {
                        case "Write": onEvent(.status("Writing a file…"))
                        case "Edit", "MultiEdit": onEvent(.status("Preparing an edit…"))
                        case "Bash": onEvent(.status("Preparing a command…"))
                        case "Read", "Glob", "Grep": onEvent(.status("Looking through files…"))
                        case "WebSearch": onEvent(.status("Searching the web…"))
                        case "WebFetch": onEvent(.status("Reading a page…"))
                        default: break
                        }
                    }
                }
                if ev["type"] as? String == "content_block_delta",
                   let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    text += t
                    onEvent(.status(nil))
                    onEvent(.text(text))
                }
            case "control_request":
                // A tool that needs the user's go-ahead (file editing only).
                guard let id = event["request_id"] as? String, let r = event["request"] as? [String: Any],
                      r["subtype"] as? String == "can_use_tool", let tool = r["tool_name"] as? String else { break }
                let input = r["input"] as? [String: Any] ?? [:]
                // Inside the working folder (TapChat's own) it's free: a
                // command run in the sandbox (which keeps its writes there;
                // Claude Code still asks about some, heredocs say), or an
                // edit of a file there. Going outside asks the user.
                if req.canEdit, inWorkspace(tool, input) {
                    process.writeJSON(["type": "control_response",
                                       "response": ["subtype": "success", "request_id": id, "response": ["behavior": "allow", "updatedInput": input]]])
                    break
                }
                // No time limit while the user decides.
                watchdog?.stop()
                let approval = claudeApproval(tool, input) { decision in
                    guard !completed else { return }
                    watchdog?.kick()
                    let reply: [String: Any] = decision == .deny
                        ? ["behavior": "deny", "message": "The user declined this. Don't try another way to reach outside your working folder unless they ask; you can still do the work inside it (\(Paths.work.path)) without asking."]
                        : ["behavior": "allow", "updatedInput": input]
                    process.writeJSON(["type": "control_response",
                                       "response": ["subtype": "success", "request_id": id, "response": reply]])
                }
                onEvent(.approval(approval))
            case "assistant":
                let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content where block["type"] as? String == "tool_use" {
                    let input = block["input"] as? [String: Any]
                    let name = block["name"] as? String ?? ""
                    if ["Edit", "Write"].contains(name), let file = input?["file_path"] as? String {
                        onEvent(.status("Editing \((file as NSString).lastPathComponent)"))
                    } else if name == "Bash" {
                        onEvent(.status("Running a command"))
                    } else if let q = input?["query"] as? String {
                        onEvent(.status("Searching the web: \(q)"))
                    } else if let url = input?["url"] as? String {
                        onEvent(.status("Reading \(URL(string: url)?.host ?? url)"))
                    } else if let file = input?["file_path"] as? String {
                        onEvent(.status("Reading \((file as NSString).lastPathComponent)"))
                    } else if ["Glob", "Grep"].contains(block["name"] as? String ?? "") {
                        onEvent(.status("Looking through files"))
                    }
                }
            case "rate_limit_event":
                if let info = event["rate_limit_info"] as? [String: Any], let usage = Usage(claude: info) {
                    onEvent(.usage(usage))
                    if (info["status"] as? String) == "rejected", text.isEmpty { limitHit("Claude usage limit reached.") }
                }
            case "result":
                process.closeInput()
                resultText = event["result"] as? String
                // Fast mode asked for but not given (the account doesn't
                // allow it): not offered again until the model list says so.
                if req.fastTier != nil, event["fast_mode_state"] as? String == "off" {
                    let why = event["fast_mode_disabled_reason"] as? String ?? "off"
                    DispatchQueue.main.async { ModelCatalog.shared.claudeFastUnavailable(why) }
                }
                resultIsError = (event["is_error"] as? Bool ?? false) || (event["subtype"] as? String != "success")
                // Done now: Claude Code takes up to a second more to exit,
                // which kept Stop showing after the answer had ended.
                if !cancelled {
                    let final = text.isEmpty ? (resultText ?? "") : text
                    if resultIsError {
                        let message = (resultText ?? "Claude returned an error.").trimmingCharacters(in: .whitespacesAndNewlines)
                        complete(RunResult(text: text, error: classify(message), durationMs: ms()))
                    } else {
                        complete(RunResult(text: final, error: nil, durationMs: ms()))
                    }
                }
            default:
                break
            }
        }
        process.onExit = { code, stderr in
            if cancelled {
                complete(RunResult(text: text, error: RunError(kind: .cancelled, message: "Stopped."), durationMs: ms()))
                return
            }
            let final = text.isEmpty ? (resultText ?? "") : text
            if resultIsError || (code != 0 && final.isEmpty) {
                let message = (resultText ?? (stderr.isEmpty ? "claude exited with code \(code)" : stderr))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                complete(RunResult(text: resultIsError ? text : final, error: classify(message), durationMs: ms()))
                return
            }
            complete(RunResult(text: final, error: nil, durationMs: ms()))
        }

        var content: [[String: Any]] = []
        for part in promptParts(req) {
            switch part {
            case .text(let s):
                content.append(["type": "text", "text": s])
            case .image(let url):
                guard let data = try? Data(contentsOf: url) else { continue }
                content.append(["type": "image", "source": [
                    "type": "base64", "media_type": imageMediaType(url), "data": data.base64EncodedString(),
                ]])
            }
        }
        process.writeJSON(["type": "user", "message": ["role": "user", "content": content]])
        return handle
    }
}

// A Claude request that stays in the working folder: a sandboxed command
// (not one asking to run outside the sandbox), or reading or editing a file
// in the folder.
func inWorkspace(_ tool: String, _ input: [String: Any]) -> Bool {
    if tool == "Bash" { return input["dangerouslyDisableSandbox"] as? Bool != true }
    let path = (input["file_path"] as? String) ?? (input["path"] as? String) ?? ""
    guard !path.isEmpty else { return false }
    let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    let work = Paths.work.standardizedFileURL.resolvingSymlinksInPath().path
    return resolved == work || resolved.hasPrefix(work + "/")
}

// What Claude wants to do, in words.
func claudeApproval(_ tool: String, _ input: [String: Any], respond: @escaping (Approval.Decision) -> Void) -> Approval {
    let path = (input["file_path"] as? String) ?? (input["path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
    let name = path.isEmpty ? "a file" : (path as NSString).lastPathComponent
    switch tool {
    case "Edit", "MultiEdit", "NotebookEdit":
        return Approval(kind: .edit, title: "Edit \(name)", detail: tildePath(path), respond: respond)
    case "Write":
        let exists = FileManager.default.fileExists(atPath: path)
        return Approval(kind: .edit, title: exists ? "Replace \(name)" : "Create \(name)", detail: tildePath(path), respond: respond)
    case "Bash":
        let command = input["command"] as? String ?? ""
        let what = (input["description"] as? String).map { "Run a command: \($0)" } ?? "Run a command"
        return Approval(kind: .command, title: what, detail: command, scope: Approval.program(command), respond: respond)
    case "Read":
        return Approval(kind: .read, title: "Read \(name)", detail: tildePath(path), respond: respond)
    case "Glob", "Grep":
        let pattern = (input["pattern"] as? String) ?? ""
        return Approval(kind: .read, title: "Look through \(path.isEmpty ? "files" : name)",
                        detail: [tildePath(path), pattern].filter { !$0.isEmpty }.joined(separator: "  "), respond: respond)
    default:
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return Approval(kind: .command, title: "Use \(tool)", detail: String(json.prefix(600)), scope: "tool:" + tool, respond: respond)
    }
}

// MARK: - Codex

// `codex app-server` streams the answer (`codex exec` only gives it at the
// end) and reports usage limits. Each run uses a new ephemeral thread.
final class CodexRunner {
    static let shared = CodexRunner()

    private final class Server {
        let process: LineProcess
        let webSearch: Bool
        var threadId: String?
        var whenReady: [(String) -> Void] = []
        var failed: String?
        var nextId = 10
        var handlers: [Int: ([String: Any]) -> Void] = [:]
        var onNotification: ((String, [String: Any]) -> Void)?
        // Requests from the server (approvals): the running turn's, else refused.
        var onRequest: ((Any, String, [String: Any]) -> Void)?
        var onExit: ((Int32, String) -> Void)?

        init(process: LineProcess, webSearch: Bool) {
            self.process = process
            self.webSearch = webSearch
        }

        func request(_ method: String, _ params: [String: Any], _ reply: @escaping ([String: Any]) -> Void) {
            nextId += 1
            handlers[nextId] = reply
            process.writeJSON(["jsonrpc": "2.0", "id": nextId, "method": method, "params": params])
        }
    }

    private var spare: Server?

    var binary: String? {
        let own = "\(NSHomeDirectory())/.local/bin/codex"
        if Settings.codexPath.isEmpty, Settings.ownCodex, FileManager.default.isExecutableFile(atPath: own) { return own }
        return findBinary(Settings.codexPath, [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(NSHomeDirectory())/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex",
        ])
    }

    // No shell, plugins, apps or MCP servers: a chat model only. With
    // attached folders or PDFs (`files`), its shell and image viewer are on
    // so it can read them; the read-only sandbox lets it read, never write.
    private func arguments(webSearch: Bool, files: Bool = false) -> [String] {
        let fileTools = ["shell_tool", "unified_exec", "view_image"]
        let features = ["apps", "plugins", "multi_agent", "image_generation", "goals", "tool_suggest", "skill_search",
                        "sleep_tool", "browser_use", "computer_use"] + (files ? [] : fileTools)
        let config = [
            "web_search=\"\(webSearch ? "live" : "disabled")\"",
            "skills.include_instructions=false",
            "include_permissions_instructions=false",
            "include_apps_instructions=false",
            "include_collaboration_mode_instructions=false",
            "include_environment_context=false",
            "tools.update_plan.enabled=false",
            "mcp_servers={}",
        ] + features.map { "features.\($0)=false" }
        return ["app-server"] + config.flatMap { ["-c", $0] }
    }

    private func startServer(webSearch: Bool, startThread: Bool, readable: [String] = [], edit: Bool = false, background: Bool = false) -> Server? {
        guard let bin = binary else { return nil }
        let p = LineProcess(executable: bin, arguments: arguments(webSearch: webSearch, files: edit || !readable.isEmpty), directory: Paths.work)
        p.background = background
        let server = Server(process: p, webSearch: webSearch)
        p.onLine = { [weak server] line in
            guard let server, let msg = jsonObject(line) else { return }
            if let id = msg["id"] as? Int, msg["method"] == nil {
                server.handlers.removeValue(forKey: id)?(msg)
            } else if let method = msg["method"] as? String {
                if let id = msg["id"] {
                    // A request from the server (e.g. an approval): the turn's
                    // handler (file editing), else refused.
                    if let handler = server.onRequest {
                        handler(id, method, msg["params"] as? [String: Any] ?? [:])
                    } else {
                        p.writeJSON(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported"]])
                    }
                } else {
                    server.onNotification?(method, msg["params"] as? [String: Any] ?? [:])
                }
            }
        }
        p.onExit = { [weak server] code, stderr in
            guard let server else { return }
            if server.threadId == nil, server.failed == nil {
                server.failed = stderr.isEmpty ? "Codex exited with code \(code)." : stderr
                let waiting = server.whenReady
                server.whenReady = []
                waiting.forEach { $0("") }
            }
            server.onExit?(code, stderr)
        }
        do { try p.start() } catch { return nil }
        server.request("initialize", ["clientInfo": ["name": "tapchat", "title": "TapChat", "version": "1.0"]]) { [weak server] _ in
            guard let server else { return }
            p.writeJSON(["jsonrpc": "2.0", "method": "initialized"])
            guard startThread else { return }
            server.request("thread/start", [
                // File editing: still the read-only sandbox, but it may ask
                // to go beyond it (to write, or run something), and the user
                // decides each time, as in the Codex app.
                // With it, writing in the working folder (TapChat's own) is free.
                "ephemeral": true, "sandbox": edit ? "workspace-write" : "read-only", "approvalPolicy": edit ? "on-request" : "never",
                "baseInstructions": instructions(edit: edit), "cwd": edit ? Paths.work.path : readable.first ?? Paths.work.path,
            ]) { reply in
                if let thread = (reply["result"] as? [String: Any])?["thread"] as? [String: Any],
                   let id = thread["id"] as? String {
                    server.threadId = id
                } else {
                    server.failed = ((reply["error"] as? [String: Any])?["message"] as? String) ?? "Codex could not start a chat."
                }
                let waiting = server.whenReady
                server.whenReady = []
                waiting.forEach { $0(server.threadId ?? "") }
            }
        }
        return server
    }

    func prewarm(webSearch: Bool) {
        if let spare, spare.webSearch == webSearch, spare.process.isRunning, spare.failed == nil { return }
        discardSpare()
        spare = startServer(webSearch: webSearch, startThread: true)
    }

    func discardSpare() {
        spare?.process.kill()
        spare = nil
    }

    func run(_ req: RunRequest, onEvent: @escaping (RunEvent) -> Void, completion: @escaping (RunResult) -> Void) -> RunHandle {
        let handle = RunHandle()
        let server: Server
        // The spare has no file access: with attached folders or PDFs, a new one.
        let readable = req.readableDirs
        if readable.isEmpty, !req.canEdit, !req.background, let spare, spare.webSearch == req.webSearch, spare.process.isRunning, spare.failed == nil {
            server = spare
            self.spare = nil
        } else if let s = startServer(webSearch: req.webSearch, startThread: true, readable: readable, edit: req.canEdit, background: req.background) {
            server = s
        } else {
            DispatchQueue.main.async {
                completion(RunResult(text: "", error: RunError(kind: .notInstalled, message: "Codex CLI not found. Install it with `brew install codex`, or set its path in Settings.")))
            }
            return handle
        }

        let started = Date()
        var text = ""
        var failure: RunError?
        var cancelled = false
        var finished = false
        var turnId: String?
        var watchdog: Watchdog?
        log("codex start model=\(req.model) effort=\(req.effort ?? "-") web=\(req.webSearch) warm=\(server.threadId != nil)")
        let finish = { (error: RunError?) in
            guard !finished else { return }
            finished = true
            watchdog?.stop()
            log("codex done chars=\(text.count) cancelled=\(cancelled) error=\(error.map { "\($0.kind): \($0.message.prefix(200))" } ?? "none")")
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            server.onNotification = nil
            server.onRequest = nil
            server.onExit = nil
            server.process.kill()
            if cancelled {
                completion(RunResult(text: text, error: RunError(kind: .cancelled, message: "Stopped."), durationMs: ms))
            } else {
                completion(RunResult(text: text, error: error ?? (text.isEmpty ? RunError(kind: .other, message: "Codex returned no answer.") : nil), durationMs: ms))
            }
        }
        handle.cancelAction = {
            cancelled = true
            if let threadId = server.threadId, let turnId {
                server.request("turn/interrupt", ["threadId": threadId, "turnId": turnId]) { _ in finish(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(nil) }
            } else {
                finish(nil)
            }
        }

        watchdog = Watchdog(seconds: 180) {
            finish(RunError(kind: .other, message: "Codex stopped responding."))
        }
        // The file changes each fileChange item will make, for its approval.
        var changes: [String: [String]] = [:]
        // Items whose changes delete a file.
        var deleting: Set<String> = []
        server.onRequest = { id, method, params in
            let reply = { (result: [String: Any]) in
                server.process.writeJSON(["jsonrpc": "2.0", "id": id, "result": result])
            }
            let approval: Approval
            let respond = { (d: Approval.Decision) in
                guard !finished else { return }
                watchdog?.kick()
                reply(["decision": d == .deny ? "decline" : "accept"])
            }
            switch method {
            case "item/commandExecution/requestApproval":
                let command = params["command"] as? String ?? ""
                let reason = (params["reason"] as? String).map { "Run a command: \($0)" } ?? "Run a command"
                approval = Approval(kind: .command, title: reason, detail: command, scope: Approval.program(command), respond: respond)
            case "item/fileChange/requestApproval":
                let itemId = params["itemId"] as? String ?? ""
                let paths = changes[itemId] ?? []
                let title = paths.count == 1 ? "Edit \((paths[0] as NSString).lastPathComponent)" : "Edit \(paths.count) files"
                let deletes = deleting.contains(itemId)
                approval = Approval(kind: .edit, title: deletes ? "Delete or change files" : paths.isEmpty ? "Edit files" : title,
                                    detail: paths.map(tildePath).joined(separator: "\n"),
                                    scope: deletes ? "delete" : nil, deletes: deletes, respond: respond)
            default:
                server.process.writeJSON(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported"]])
                return
            }
            watchdog?.stop()
            onEvent(.approval(approval))
        }
        server.onNotification = { method, params in
            watchdog?.kick()
            switch method {
            case "item/started":
                let item = params["item"] as? [String: Any]
                switch item?["type"] as? String {
                case "fileChange":
                    let all = item?["changes"] as? [[String: Any]] ?? []
                    let list = all.compactMap { $0["path"] as? String }
                    if let id = item?["id"] as? String {
                        changes[id] = list
                        if all.contains(where: { ($0["kind"] as? [String: Any])?["type"] as? String == "delete" }) { deleting.insert(id) }
                    }
                    onEvent(.status(list.count == 1 ? "Editing \((list[0] as NSString).lastPathComponent)" : "Editing files"))
                case "commandExecution":
                    onEvent(.status("Running a command"))
                case "agentMessage":
                    if !text.isEmpty, !text.hasSuffix("\n\n") { text += "\n\n" }
                case "webSearch":
                    let q = (item?["query"] as? String) ?? ""
                    onEvent(.status(q.isEmpty ? "Searching the web…" : "Searching the web: \(q)"))
                case "reasoning":
                    onEvent(.status("Thinking…"))
                default: break
                }
            case "item/agentMessage/delta":
                if let d = params["delta"] as? String {
                    text += d
                    onEvent(.status(nil))
                    onEvent(.text(text))
                }
            case "account/rateLimits/updated":
                if let limits = params["rateLimits"] as? [String: Any], let usage = Usage(codex: limits) {
                    onEvent(.usage(usage))
                }
            case "error":
                if let err = params["error"] as? [String: Any] {
                    let e = codexError(err)
                    log("codex error willRetry=\(params["willRetry"] ?? "-") \(e.message.prefix(200))")
                    if e.kind == .usageLimit, text.isEmpty { finish(e) }
                    else if params["willRetry"] as? Bool != true { failure = e }
                    else { onEvent(.status("Retrying…")) }
                }
            case "turn/completed":
                let turn = params["turn"] as? [String: Any]
                if turn?["status"] as? String == "failed" {
                    let err = (turn?["error"] as? [String: Any]).map(codexError)
                    finish(err ?? failure ?? RunError(kind: .other, message: "Codex request failed."))
                } else {
                    finish(failure)
                }
            default: break
            }
        }
        server.onExit = { code, stderr in
            let message = stderr.split(separator: "\n").last.map(String.init) ?? "Codex exited with code \(code)."
            finish(failure ?? (text.isEmpty ? classify(message) : nil))
        }

        let startTurn = { (threadId: String) in
            guard !finished else { return }
            guard !threadId.isEmpty else {
                finish(classify(server.failed ?? "Codex could not start."))
                return
            }
            var input: [[String: Any]] = []
            for part in promptParts(req) {
                switch part {
                case .text(let s): input.append(["type": "text", "text": s])
                case .image(let url): input.append(["type": "localImage", "path": url.path])
                }
            }
            var params: [String: Any] = ["threadId": threadId, "input": input]
            let model = String(req.model.dropFirst(codexPrefix.count))
            if !model.isEmpty, model != "default" { params["model"] = model }
            // Codex has no level below Low: Instant uses it.
            if let effort = req.effort { params["effort"] = effort == "instant" ? "low" : effort }
            if let tier = req.fastTier { params["serviceTier"] = tier }
            server.request("turn/start", params) { reply in
                if let err = reply["error"] as? [String: Any] {
                    finish(classify((err["message"] as? String) ?? "Codex request failed."))
                } else if let turn = (reply["result"] as? [String: Any])?["turn"] as? [String: Any] {
                    turnId = turn["id"] as? String
                    if cancelled { handle.cancel() }
                }
            }
        }
        if let id = server.threadId {
            startTurn(id)
        } else if server.failed != nil {
            startTurn("")
        } else {
            server.whenReady.append(startTurn)
        }
        return handle
    }

    // The current limits, without a model request.
    func fetchUsage(_ completion: @escaping (Usage?) -> Void) {
        // The spare is asked (and kept): no process started just for this.
        if let spare, spare.process.isRunning, spare.failed == nil {
            var done = false
            spare.request("account/rateLimits/read", [:]) { reply in
                guard !done else { return }
                done = true
                let limits = (reply["result"] as? [String: Any])?["rateLimits"] as? [String: Any]
                completion(limits.flatMap { Usage(codex: $0) })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if !done { done = true; completion(nil) } }
            return
        }
        guard let server = startServer(webSearch: false, startThread: false, background: true) else {
            completion(nil)
            return
        }
        var done = false
        let finish = { (u: Usage?) in
            guard !done else { return }
            done = true
            server.process.kill()
            completion(u)
        }
        server.request("account/rateLimits/read", [:]) { reply in
            let limits = (reply["result"] as? [String: Any])?["rateLimits"] as? [String: Any]
            finish(limits.flatMap { Usage(codex: $0) })
        }
        server.onExit = { _, _ in finish(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish(nil) }
    }
}

private func codexError(_ err: [String: Any]) -> RunError {
    let message = (err["message"] as? String) ?? "Codex request failed."
    let info = err["codexErrorInfo"]
    let infoText = (info as? String) ?? ((info as? [String: Any])?.keys.first ?? "")
    if ["usageLimitExceeded", "rateLimitExceeded"].contains(infoText) {
        return RunError(kind: .usageLimit, message: message)
    }
    return classify(message)
}

func imageMediaType(_ url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    default: return "image/png"
    }
}
