import Foundation

// A child process that talks JSON lines over stdin/stdout. Callbacks run on
// the main queue, in order; onExit comes after the last line.
final class LineProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    private var stderrData = Data()
    private var outputClosed = false
    private var exitCode: Int32?
    private var finished = false

    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    var isRunning: Bool { process.isRunning }

    init(executable: String, arguments: [String], directory: URL, extraEnvironment: [String: String] = [:]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = childEnvironment().merging(extraEnvironment) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    // Lower CPU priority (background checks): an answer starting meanwhile goes first.
    var background = false

    func start() throws {
        if background { process.qualityOfService = .utility }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                if data.isEmpty { handle.readabilityHandler = nil } else { self?.stderrData.append(data) }
            }
        }
        process.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            DispatchQueue.main.async {
                self?.exitCode = code
                self?.finishIfDone()
            }
        }
        try process.run()
    }

    private func received(_ data: Data) {
        if data.isEmpty {
            output.fileHandleForReading.readabilityHandler = nil
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { onLine?(line) }
            buffer.removeAll()
            outputClosed = true
            finishIfDone()
            return
        }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { onLine?(line) }
        }
    }

    private func finishIfDone() {
        guard !finished, outputClosed, let code = exitCode else { return }
        finished = true
        let err = String(data: stderrData, encoding: .utf8) ?? ""
        onExit?(code, err)
        onLine = nil
        onExit = nil
    }

    func write(_ line: String) {
        guard process.isRunning, let data = (line + "\n").data(using: .utf8) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func writeJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let s = String(data: data, encoding: .utf8) else { return }
        write(s)
    }

    func closeInput() { try? input.fileHandleForWriting.close() }

    func interrupt() { if process.isRunning { process.interrupt() } }

    func kill() {
        onLine = nil
        // codex app-server exits when its stdin closes; SIGTERM alone can leave it running.
        closeInput()
        if process.isRunning { process.terminate() }
    }
}

// GUI apps get a minimal PATH and no shell profile; the CLIs need a normal one.
func childEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    env["PATH"] = (extra + current.filter { !extra.contains($0) }).joined(separator: ":")
    env["USER"] = env["USER"] ?? NSUserName()
    env["LOGNAME"] = env["LOGNAME"] ?? NSUserName()
    env["HOME"] = home
    env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
    // With an API key set, the CLIs bill it instead of the subscription.
    env.removeValue(forKey: "ANTHROPIC_API_KEY")
    env.removeValue(forKey: "OPENAI_API_KEY")
    env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
    env["DISABLE_AUTOUPDATER"] = "1"
    // --setting-sources "" skips ~/.claude/settings.json; keep its proxy settings.
    if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude/settings.json")),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let settingsEnv = json["env"] as? [String: Any] {
        for key in ["HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"] {
            if let v = settingsEnv[key] as? String { env[key] = v }
        }
    }
    return env
}

func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
