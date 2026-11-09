import AppKit
import SwiftUI

// First run (and Settings → Set Up…): install and sign in to Claude Code or
// Codex without a terminal. TapChat needs at least one. Styled like Fandy's
// setup window: a heading, a few short rows, two buttons.

enum SetupState: Equatable {
    case checking, notInstalled, installing, signedOut, signingIn, ready
    case failed(String)
}

@Observable
final class SetupModel {
    var claude: SetupState = .checking
    var codex: SetupState = .checking
    var anyReady: Bool { claude == .ready || codex == .ready }
    @ObservationIgnored private var login: [Provider: Process] = [:]
    @ObservationIgnored private var poll: Timer?

    func state(_ p: Provider) -> SetupState { p == .claude ? claude : codex }
    private func set(_ p: Provider, _ s: SetupState) {
        DispatchQueue.main.async { if p == .claude { self.claude = s } else { self.codex = s } }
    }

    // MARK: Status

    func refresh(_ done: (() -> Void)? = nil) {
        let group = DispatchGroup()
        for p in [Provider.claude, .codex] {
            let current = state(p)
            if current == .installing || current == .signingIn { continue }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.set(p, Self.check(p))
                group.leave()
            }
        }
        group.notify(queue: .main) { done?() }
    }

    // Installed? Signed in? (The CLIs' own status commands.)
    static func check(_ p: Provider) -> SetupState {
        guard let bin = p == .claude ? ClaudeRunner.shared.binary : CodexRunner.shared.binary else { return .notInstalled }
        let args = p == .claude ? ["auth", "status", "--json"] : ["login", "status"]
        guard let (code, out) = run(bin, args, timeout: 15) else { return .signedOut }
        if p == .claude {
            let json = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
            return json?["loggedIn"] as? Bool == true ? .ready : .signedOut
        }
        return code == 0 && out.localizedCaseInsensitiveContains("logged in") ? .ready : .signedOut
    }

    // MARK: Install

    func install(_ p: Provider) {
        set(p, .installing)
        DispatchQueue.global(qos: .userInitiated).async {
            let error = p == .claude ? Self.installClaude() : Self.installCodex()
            if let error { self.set(p, .failed(error)) } else { self.set(p, Self.check(p)) }
        }
    }

    // Anthropic's own installer (as on claude.com), run in the background.
    private static func installClaude() -> String? {
        guard let (code, out) = run("/bin/bash", ["-c", "curl -fsSL https://claude.ai/install.sh | bash"], timeout: 600)
        else { return "Couldn't start the installer." }
        return code == 0 && ClaudeRunner.shared.binary != nil ? nil : "Install failed. " + lastLine(out)
    }

    // OpenAI's release build from GitHub, into ~/.local/bin (no Homebrew or npm needed).
    private static func installCodex() -> String? {
        let arch = run("/usr/bin/uname", ["-m"], timeout: 5)?.1.trimmingCharacters(in: .whitespacesAndNewlines) == "x86_64" ? "x86_64" : "aarch64"
        let url = URL(string: "https://github.com/openai/codex/releases/latest/download/codex-\(arch)-apple-darwin.tar.gz")!
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("TapChat-codex-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var downloaded: URL?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.downloadTask(with: url) { file, response, _ in
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                let dest = temp.appendingPathComponent("codex.tar.gz")
                try? FileManager.default.moveItem(at: file, to: dest)
                downloaded = dest
            }
            done.signal()
        }.resume()
        done.wait()
        guard let archive = downloaded else { return "Download failed. Check your connection." }
        guard run("/usr/bin/tar", ["-xzf", archive.path, "-C", temp.path], timeout: 120)?.0 == 0 else { return "Couldn't unpack Codex." }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        guard let name = files.first(where: { $0.hasPrefix("codex") && !$0.hasSuffix(".tar.gz") }) else { return "Codex wasn't in the download." }
        let bin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dest = bin.appendingPathComponent("codex")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: temp.appendingPathComponent(name), to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        } catch { return "Couldn't install Codex: \(error.localizedDescription)" }
        return nil
    }

    // MARK: Sign in

    // The CLI's own browser sign-in; ready once its status says so.
    func signIn(_ p: Provider) {
        guard let bin = p == .claude ? ClaudeRunner.shared.binary : CodexRunner.shared.binary else { return }
        login[p]?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = p == .claude ? ["auth", "login"] : ["login"]
        process.environment = childEnvironment()
        process.currentDirectoryURL = Paths.work
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = Pipe()
        // If the browser didn't open by itself, the sign-in link it prints is opened.
        var opened = false
        out.fileHandleForReading.readabilityHandler = { h in
            let text = String(data: h.availableData, encoding: .utf8) ?? ""
            guard !opened, let link = text.firstMatch(of: #/https://\S+/#) else { return }
            opened = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if self.state(p) == .signingIn, let url = URL(string: String(link.0)) { NSWorkspace.shared.open(url) }
            }
        }
        do { try process.run() } catch { set(p, .failed("Couldn't start sign-in.")); return }
        login[p] = process
        set(p, .signingIn)
        startPolling()
    }

    func cancelSignIn(_ p: Provider) {
        login[p]?.terminate()
        login[p] = nil
        refreshOne(p, force: true)
    }

    // While signing in: ready once the status says so; back to Sign In if
    // the CLI's sign-in ended without it (or on Cancel).
    private func refreshOne(_ p: Provider, force: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = Self.check(p)
            DispatchQueue.main.async {
                let running = self.login[p]?.isRunning == true
                guard s == .ready || force || !running else { return }
                self.login[p]?.terminate()
                self.login[p] = nil
                if p == .claude { self.claude = s } else { self.codex = s }
            }
        }
    }

    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            let waiting = [Provider.claude, .codex].filter { self.state($0) == .signingIn }
            if waiting.isEmpty { t.invalidate(); self.poll = nil; return }
            waiting.forEach { self.refreshOne($0) }
        }
    }

    func stop() {
        login.values.forEach { $0.terminate() }
        login = [:]
        poll?.invalidate()
        poll = nil
    }

    // MARK: Running a command

    // Exit code and output (stdout and stderr), or nil if it couldn't start or took too long.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (Int32, String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = childEnvironment()
        p.currentDirectoryURL = Paths.work
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        var data = Data()
        let reader = DispatchQueue(label: "TapChat.setup.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        let deadline = DispatchTime.now() + timeout
        if readDone.wait(timeout: deadline) == .timedOut { p.terminate(); return nil }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func lastLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).last.map(String.init)?.prefix(160).description ?? ""
    }
}

// The window: shown at launch and on the shortcut until a provider is ready.
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let setup = SetupModel()
    var onDone: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 210),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up TapChat"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(setup: setup, done: { [weak self] in self?.finish() }))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        setup.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        setup.stop()
        close()
        onDone?()
    }

    func windowWillClose(_ notification: Notification) { setup.stop() }
}

private struct SetupView: View {
    @Bindable var setup: SetupModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect Claude or Codex", systemImage: "bolt.fill").font(.headline)
            Text("TapChat needs at least one.").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                row(.claude, "Claude", setup.claude)
                Divider()
                row(.codex, "Codex", setup.codex)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).disabled(!setup.anyReady)
            }
        }
        .padding(20)
        .frame(width: 400, height: 210)
    }

    @ViewBuilder
    private func row(_ p: Provider, _ name: String, _ state: SetupState) -> some View {
        HStack(spacing: 8) {
            Text(name).frame(width: 60, alignment: .leading)
            if case .failed(let message) = state {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            switch state {
            case .checking:
                ProgressView().controlSize(.small)
            case .installing:
                ProgressView().controlSize(.small)
                Text("Installing…").font(.caption).foregroundStyle(.secondary)
            case .notInstalled:
                Button("Install") { setup.install(p) }
            case .signedOut:
                Button("Sign In") { setup.signIn(p) }
            case .signingIn:
                Text("Finish in your browser").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { setup.cancelSignIn(p) }
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Button("Retry") { ClaudeRunner.shared.binary == nil && p == .claude || CodexRunner.shared.binary == nil && p == .codex ? setup.install(p) : setup.signIn(p) }
            }
        }
        .frame(height: 24)
    }
}
