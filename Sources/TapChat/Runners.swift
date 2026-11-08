import AppKit
import Foundation

struct RunRequest {
    var model: String
    var effort: String?
    var webSearch: Bool
    // Earlier turns, then the question (a user message).
    var history: [Message]
    var question: Message
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
}

final class RunHandle {
    var cancelAction: (() -> Void)?
    func cancel() { cancelAction?() }
}

let systemPrompt = """
You are a helpful, concise assistant in a quick-access chat window on the user's Mac, used for quick lookups and help with writing. \
Reply in the language the user writes in. Skip filler and preambles. Use Markdown when it helps; use fenced code blocks with a language tag for code. \
Earlier turns of the conversation, if any, come first inside <conversation_history>; continue the conversation and answer the user's latest message.
"""

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
        add(m.text)
        for a in m.attachments {
            switch a.kind {
            case .image:
                add("\n[Image: \(a.name)]\n")
                flushText()
                parts.append(.image(a.url))
            case .folder:
                add("\n[Folder: \(a.path)]\n")
            case .file:
                add("\n<file name=\"\(a.name)\">\n\(extractText(a.url))\n</file>\n")
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

    // A chat model, not a coding agent: no tools (but web search when asked),
    // MCP, settings files, slash commands or saved sessions.
    func arguments(model: String, effort: String?, webSearch: Bool) -> [String] {
        var args = ["-p", "--model", model]
        if webSearch {
            args += ["--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch"]
        } else {
            args += ["--tools", ""]
        }
        // Instant: the lowest effort, and no extended thinking (see `environment`).
        if let effort { args += ["--effort", effort == "instant" ? "low" : effort] }
        args += [
            "--input-format", "stream-json",
            "--output-format", "stream-json", "--include-partial-messages", "--verbose",
            "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
            "--no-session-persistence",
            "--system-prompt", systemPrompt,
        ]
        return args
    }

    private func environment(_ effort: String?) -> [String: String] {
        effort == "instant" ? ["MAX_THINKING_TOKENS": "0"] : [:]
    }

    private func spawn(_ args: [String], _ env: [String: String]) -> LineProcess? {
        guard let bin = binary else { return nil }
        let p = LineProcess(executable: bin, arguments: args, directory: Paths.work, extraEnvironment: env)
        do { try p.start() } catch { return nil }
        return p
    }

    // Claude Code's startup (~2-3 s) happens while the user types: the process
    // waits on stdin, making no requests, until the question comes.
    func prewarm(model: String, effort: String?, webSearch: Bool) {
        let args = arguments(model: model, effort: effort, webSearch: webSearch)
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
        let args = arguments(model: req.model, effort: req.effort, webSearch: req.webSearch)
        let key = args + (req.effort == "instant" ? ["instant"] : [])
        let process: LineProcess
        if let spare, spare.key == key, spare.process.isRunning {
            process = spare.process
            self.spare = nil
        } else if let p = spawn(args, environment(req.effort)) {
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
        log("claude start model=\(req.model) effort=\(req.effort ?? "-") web=\(req.webSearch)")
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
                   (ev["content_block"] as? [String: Any])?["type"] as? String == "thinking" {
                    onEvent(.status("Thinking…"))
                }
                if ev["type"] as? String == "content_block_delta",
                   let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    text += t
                    onEvent(.status(nil))
                    onEvent(.text(text))
                }
            case "assistant":
                let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content where block["type"] as? String == "tool_use" {
                    let input = block["input"] as? [String: Any]
                    if let q = input?["query"] as? String {
                        onEvent(.status("Searching the web: \(q)"))
                    } else if let url = input?["url"] as? String {
                        onEvent(.status("Reading \(URL(string: url)?.host ?? url)"))
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
                resultIsError = (event["is_error"] as? Bool ?? false) || (event["subtype"] as? String != "success")
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
        findBinary(Settings.codexPath, [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(NSHomeDirectory())/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex",
        ])
    }

    // No shell, plugins, apps or MCP servers: a chat model only.
    private func arguments(webSearch: Bool) -> [String] {
        let features = ["apps", "plugins", "multi_agent", "image_generation", "goals", "tool_suggest", "skill_search",
                        "sleep_tool", "browser_use", "computer_use", "shell_tool", "unified_exec", "view_image"]
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

    private func startServer(webSearch: Bool, startThread: Bool) -> Server? {
        guard let bin = binary else { return nil }
        let p = LineProcess(executable: bin, arguments: arguments(webSearch: webSearch), directory: Paths.work)
        let server = Server(process: p, webSearch: webSearch)
        p.onLine = { [weak server] line in
            guard let server, let msg = jsonObject(line) else { return }
            if let id = msg["id"] as? Int, msg["method"] == nil {
                server.handlers.removeValue(forKey: id)?(msg)
            } else if let method = msg["method"] as? String {
                if let id = msg["id"] {
                    // A request from the server (e.g. an approval): refuse.
                    p.writeJSON(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported"]])
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
                "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never",
                "baseInstructions": systemPrompt, "cwd": Paths.work.path,
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
        if let spare, spare.webSearch == req.webSearch, spare.process.isRunning, spare.failed == nil {
            server = spare
            self.spare = nil
        } else if let s = startServer(webSearch: req.webSearch, startThread: true) {
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
        server.onNotification = { method, params in
            watchdog?.kick()
            switch method {
            case "item/started":
                let item = params["item"] as? [String: Any]
                switch item?["type"] as? String {
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
        guard let server = startServer(webSearch: false, startThread: false) else {
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
