import AppKit
import CryptoKit
import SwiftUI

// First run (and Settings → Set Up…): install and sign in to Claude Code or
// Codex without a terminal. TapChat needs at least one. Styled like Fandy's
// setup window: a heading, a few short rows, two buttons.

enum SetupState: Equatable {
    // installing: how far the download is (0-1), nil while finishing up.
    case checking, notInstalled, installing(Double?), signedOut, signingIn, ready
    case failed(String)

    var isBusy: Bool {
        if case .installing = self { return true }
        return self == .signingIn
    }
}

@Observable
final class SetupModel {
    var claude: SetupState = .checking
    var codex: SetupState = .checking
    var anyReady: Bool { claude == .ready || codex == .ready }
    // The sign-in page each CLI printed, for Open Page if the browser didn't open.
    var links: [Provider: URL] = [:]
    // Installed but older than the newest release: its newest version.
    var updates: [Provider: String] = [:]
    var updating: Set<Provider> = []
    @ObservationIgnored private var login: [Provider: Process] = [:]
    @ObservationIgnored private var poll: Timer?

    func state(_ p: Provider) -> SetupState { p == .claude ? claude : codex }
    // Signing in started (true) or ended (false): the window steps back
    // for the browser, then comes forward again.
    @ObservationIgnored var onSigningIn: ((Bool) -> Void)?
    var signingIn: Bool { claude == .signingIn || codex == .signingIn }

    private func set(_ p: Provider, _ s: SetupState) {
        DispatchQueue.main.async {
            let was = self.signingIn
            if p == .claude { self.claude = s } else { self.codex = s }
            if self.signingIn != was { self.onSigningIn?(self.signingIn) }
        }
    }

    // MARK: Status

    func refresh(_ done: (() -> Void)? = nil) {
        let group = DispatchGroup()
        for p in [Provider.claude, .codex] {
            if state(p).isBusy { continue }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let state = Self.check(p)
                self.set(p, state)
                // Installed: is there a newer one?
                if state == .ready || state == .signedOut, let current = ToolUpdates.installed(p),
                   let newest = ToolUpdates.latest(p), ToolUpdates.newer(newest, than: current) {
                    DispatchQueue.main.async { self.updates[p] = newest }
                } else {
                    DispatchQueue.main.async { self.updates[p] = nil }
                }
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

    func update(_ p: Provider) {
        guard !updating.contains(p) else { return }
        updating.insert(p)
        DispatchQueue.global(qos: .userInitiated).async {
            let changed = ToolUpdates.updateNow(p)
            DispatchQueue.main.async {
                self.updating.remove(p)
                if changed { self.updates[p] = nil; ModelCatalog.shared.refresh() }
                self.refresh()
            }
        }
    }

    // MARK: Install

    func install(_ p: Provider) {
        set(p, .installing(0))
        let progress: (Double?) -> Void = { [weak self] f in self?.set(p, .installing(f)) }
        DispatchQueue.global(qos: .userInitiated).async {
            let error = p == .claude ? Self.installClaude(progress) : Self.installCodex(progress)
            if let error { self.set(p, .failed(error)) } else { self.set(p, Self.check(p)) }
        }
    }

    private static var isIntel: Bool {
        run("/usr/bin/uname", ["-m"], timeout: 5)?.1.trimmingCharacters(in: .whitespacesAndNewlines) == "x86_64"
    }

    // Downloads a file, reporting how far it is; blocks until done.
    private static func download(_ url: URL, to dest: URL, progress: @escaping (Double?) -> Void) -> Bool {
        var ok = false
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: url) { file, response, _ in
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.removeItem(at: dest)
                ok = (try? FileManager.default.moveItem(at: file, to: dest)) != nil
            }
            done.signal()
        }
        let watch = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
        task.resume()
        done.wait()
        watch.invalidate()
        return ok
    }

    // Anthropic's release, the way their installer gets it: the stable
    // version's build for this Mac, its checksum checked, then the build
    // installs itself (into ~/.local/bin and ~/.local/share/claude).
    private static func installClaude(_ progress: @escaping (Double?) -> Void) -> String? {
        let bucket = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
        guard let version = (try? String(contentsOf: URL(string: "\(bucket)/stable")!, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty
        else { return "Couldn't reach Anthropic. Check your connection." }
        let platform = isIntel ? "darwin-x64" : "darwin-arm64"
        guard let data = try? Data(contentsOf: URL(string: "\(bucket)/\(version)/manifest.json")!),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let build = (manifest["platforms"] as? [String: Any])?[platform] as? [String: Any],
              let checksum = build["checksum"] as? String
        else { return "Couldn't read the Claude release." }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("TapChat-claude-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let binary = temp.appendingPathComponent("claude")
        guard download(URL(string: "\(bucket)/\(version)/\(platform)/claude")!, to: binary, progress: progress)
        else { return "Download failed. Check your connection." }
        progress(nil)
        guard sha256(binary) == checksum.lowercased() else { return "The download was damaged. Try again." }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        guard let (code, out) = run(binary.path, ["install"], timeout: 300) else { return "Couldn't finish installing." }
        return code == 0 && ClaudeRunner.shared.binary != nil ? nil : "Install failed. " + lastLine(out)
    }

    private static func sha256(_ file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // OpenAI's release build from GitHub, into ~/.local/bin (no Homebrew or npm needed).
    static func installCodex(_ progress: @escaping (Double?) -> Void) -> String? {
        let arch = isIntel ? "x86_64" : "aarch64"
        let url = URL(string: "https://github.com/openai/codex/releases/latest/download/codex-\(arch)-apple-darwin.tar.gz")!
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("TapChat-codex-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let archive = temp.appendingPathComponent("codex.tar.gz")
        guard download(url, to: archive, progress: progress) else { return "Download failed. Check your connection." }
        progress(nil)
        guard run("/usr/bin/tar", ["-xzf", archive.path, "-C", temp.path], timeout: 120)?.0 == 0 else { return "Couldn't unpack Codex." }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        guard let name = files.first(where: { $0.hasPrefix("codex") && !$0.hasSuffix(".tar.gz") }) else { return "Codex wasn't in the download." }
        let bin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dest = bin.appendingPathComponent("codex")
        // Next to it first, then swapped in at once (rename): there's never a
        // moment without Codex (an update while answering stays unnoticed).
        let staged = bin.appendingPathComponent(".codex-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: temp.appendingPathComponent(name), to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            guard rename(staged.path, dest.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            return "Couldn't install Codex: \(error.localizedDescription)"
        }
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
        // The CLI opens the sign-in page itself (opening it again made that
        // attempt invalid); the link it prints is kept for Open Page.
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(data: h.availableData, encoding: .utf8) ?? ""
            guard let link = text.firstMatch(of: #/https://\S+/#), let url = URL(string: String(link.0)) else { return }
            DispatchQueue.main.async { if self?.links[p] == nil { self?.links[p] = url } }
        }
        links[p] = nil
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
                let was = self.signingIn
                if p == .claude { self.claude = s } else { self.codex = s }
                if self.signingIn != was { self.onSigningIn?(self.signingIn) }
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
    // `background`: at a low CPU priority (updates nobody waits for).
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval, background: Bool = false) -> (Int32, String)? {
        let p = Process()
        if background { p.qualityOfService = .utility }
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
    // The onboarding follows in this window: Next, and the window stays.
    var continues = false { didSet { model.continues = continues } }
    private let model = SetupFlow()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 230),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Set Up TapChat"
        // The title as a header in the window instead (as the onboarding's).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // Above everything (the chat and Settings float too).
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(setup: setup, flow: model, done: { [weak self] in self?.finish() }))
        // Above everything, except while signing in: the browser's page must
        // be seen. Back in front once it's done.
        setup.onSigningIn = { [weak window] signing in
            guard let window else { return }
            window.level = signing ? .normal : .modalPanel
            if !signing {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        setup.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func finish() {
        setup.stop()
        if continues, !handedOn {
            handedOn = true
            // Handed on: the onboarding takes this window over.
            window?.delegate = nil
            onDone?()
        } else {
            close()
            onDone?()
        }
    }

    // The onboarding has the window (Back gives it back).
    var handedOn = false

    func windowWillClose(_ notification: Notification) { setup.stop() }
    // Back in front: checked again (a sign-in or sign-out may have happened elsewhere).
    func windowDidBecomeKey(_ notification: Notification) { setup.refresh() }
}

@Observable final class SetupFlow { var continues = false }

private struct SetupView: View {
    @Bindable var setup: SetupModel
    let flow: SetupFlow
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up TapChat").font(.system(size: 20, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
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
                Button(flow.continues ? "Next" : "Done", action: done).keyboardShortcut(.defaultAction).disabled(!setup.anyReady)
            }
        }
        // The title bar's own space is above this already.
        .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 2)
        .frame(width: 400, height: 230)
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
            case .installing(let f):
                if let f {
                    ProgressView(value: f).frame(width: 110)
                    Text("\(Int(f * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Finishing…").font(.caption).foregroundStyle(.secondary)
                }
            case .notInstalled:
                Button("Install") { setup.install(p) }
            case .signedOut:
                Button("Sign In") { setup.signIn(p) }
            case .signingIn:
                Text("Finish in your browser").font(.caption).foregroundStyle(.secondary)
                if let link = setup.links[p] { Button("Open Page") { NSWorkspace.shared.open(link) } }
                Button("Cancel") { setup.cancelSignIn(p) }
            case .ready where setup.updating.contains(p):
                ProgressView().controlSize(.small)
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            case .ready:
                if let newest = setup.updates[p] {
                    Button("Update") { setup.update(p) }.help("Version \(newest) is out")
                } else {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .failed:
                Button("Retry") { ClaudeRunner.shared.binary == nil && p == .claude || CodexRunner.shared.binary == nil && p == .codex ? setup.install(p) : setup.signIn(p) }
            }
        }
        .frame(height: 24)
    }
}

// Claude Code and Codex kept current with their own update commands: an old
// CLI lists old models (and lacks newer options). Once a day in the
// background, and right after setup; the model list is fetched again when
// either changed.
enum ToolUpdates {
    private static var running = false

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    // First launch of a new TapChat (an update, or the first install): soon.
    static var newApp: Bool { Settings.toolsUpdatedFor != appVersion }

    static func updateIfDue() {
        guard Date().timeIntervalSince(Settings.toolsUpdatedAt) > 86_400 else { return }
        update()
    }

    private static var codexByTapChat: String { NSHomeDirectory() + "/.local/bin/codex" }
    private static func binary(_ p: Provider) -> String? { p == .claude ? ClaudeRunner.shared.binary : CodexRunner.shared.binary }

    // The installed version ("2.1.319"), and the newest one out (Claude's
    // "latest" channel, which its update command follows; Codex's latest
    // GitHub release, from where "latest" leads: …/tag/rust-v0.168.0).
    static func installed(_ p: Provider) -> String? {
        guard let bin = binary(p), let out = SetupModel.run(bin, ["--version"], timeout: 20, background: true)?.1 else { return nil }
        return out.firstMatch(of: #/(\d+(?:\.\d+)+)/#).map { String($0.1) }
    }

    static func latest(_ p: Provider) -> String? {
        if p == .claude {
            let url = URL(string: "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest")!
            return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var request = URLRequest(url: URL(string: "https://github.com/openai/codex/releases/latest")!, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        var final: URL?
        let wait = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in final = response?.url; wait.signal() }.resume()
        _ = wait.wait(timeout: .now() + 25)
        guard let tag = final?.lastPathComponent, let m = tag.firstMatch(of: #/(\d+(?:\.\d+)+)$/#) else { return nil }
        return String(m.1)
    }

    static func newer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    // One tool brought up to date (blocking: call it off the main thread).
    // True when its version changed. `before`/`after`: its versions.
    @discardableResult
    static func updateNow(_ p: Provider, versions: ((String?, String?) -> Void)? = nil) -> Bool {
        guard let bin = binary(p) else { return false }
        let before = installed(p)
        var result = SetupModel.run(bin, ["update"], timeout: 300, background: true)
        // Codex as setup installs it (one file in ~/.local/bin) has no
        // updater of its own: the newer release, the same way.
        if p == .codex, result?.0 != 0, bin == codexByTapChat, let latest = latest(.codex),
           let current = before, newer(latest, than: current) {
            let error = SetupModel.installCodex { _ in }
            result = (error == nil ? 0 : 1, error ?? "")
        }
        let after = installed(p)
        log("\(p.name) update exit=\(result?.0 ?? -1) \(before ?? "?") -> \(after ?? "?")")
        versions?(before, after)
        return before != after
    }

    // `force`: asked for (Settings): waits for a run already going, then
    // reports. `progress`: what it's doing ("Updating Claude…"). `report`:
    // what happened, one line per tool ("Claude 2.1.319 → 2.1.322").
    static func update(force: Bool = false, progress: ((String) -> Void)? = nil,
                       report: (([String]) -> Void)? = nil, _ done: ((Bool) -> Void)? = nil) {
        if running {
            if force {
                progress?("Waiting for an update in progress…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { update(force: true, progress: progress, report: report, done) }
            }
            return
        }
        running = true
        let tools = [Provider.claude, .codex].filter { binary($0) != nil }
        let say = { (s: String) in DispatchQueue.main.async { progress?(s) } }
        DispatchQueue.global(qos: .utility).async {
            var changed = false
            var lines: [String] = []
            for p in tools {
                say("Checking \(p.name)…")
                if let current = installed(p), let newest = latest(p), newer(newest, than: current) {
                    say("Updating \(p.name) to \(newest)…")
                }
                var line = ""
                if updateNow(p, versions: { before, after in
                    line = before != after ? "\(p.name) updated: \(before ?? "?") → \(after ?? "?")" : "\(p.name) \(after ?? "") is up to date"
                }) { changed = true }
                lines.append(line)
            }
            DispatchQueue.main.async {
                running = false
                Settings.toolsUpdatedAt = Date()
                Settings.toolsUpdatedFor = appVersion
                if changed { ModelCatalog.shared.refresh() }
                report?(lines)
                done?(changed)
            }
        }
    }
}
