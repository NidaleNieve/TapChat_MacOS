import AppKit
import ServiceManagement

// Only with `--debug-hooks` at launch: lets a script drive the window and
// save a picture of it, for testing layout without Screen Recording access.
//   notification "local.tapchat.debug", object: "show" | "hide" | "new" |
//   "history" | "send:<text>" | "type:<text>" | "snap:<path.png>" | "edit-last" | "fork-last"
enum DebugHooks {
    static func install(_ delegate: AppDelegate) {
        guard CommandLine.arguments.contains("--debug-hooks") else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.tapchat.debug"), object: nil, queue: .main
        ) { note in
            guard let command = note.object as? String else { return }
            let model = delegate.model
            let (verb, arg) = command.firstIndex(of: ":").map {
                (String(command[..<$0]), String(command[command.index(after: $0)...]))
            } ?? (command, "")
            switch verb {
            case "show": delegate.panel.show()
            case "hide": delegate.panel.hide()
            case "toggle": delegate.panel.toggle()
            case "toggle-history": delegate.panel.toggleHistory()
            case "open-first": if let first = model.history.first { model.open(first.id) }
            case "quit": NSApp.terminate(nil)
            case "new": model.newChat()
            case "temp": model.newChat(temporary: true)
            case "history": model.toggleHistory()
            case "type": model.draft = arg
            case "send": model.draft = arg; model.send()
            case "model": model.select(model: arg)
            case "edit-last": model.editLast()
            case "fork-last": if let m = model.chat.messages.last { model.fork(at: m.id) }
            case "snap": snapshot(delegate.panel.panel, to: arg)
            case "search":
                let parts = arg.split(separator: "|", maxSplits: 1).map(String.init)
                let out = ChatStore.shared.search(parts.count > 1 ? parts[1] : "").map { "\($0.summary.title) — \($0.snippet ?? "(title)")" }
                try? out.joined(separator: "\n").write(toFile: parts[0], atomically: true, encoding: .utf8)
            case "state":
                let s = "layout=\(model.layout) messages=\(model.chat.messages.count) running=\(model.isRunning) temp=\(model.chat.isTemporary) frame=\(delegate.panel.panel.frame) glass=\(model.glassHeight) canvas=\(model.canvasHeight) through=\(delegate.panel.panel.ignoresMouseEvents) effort=\(model.effort) reveal=\(model.revealId != nil) bar=\(model.barHeight) focus=\(delegate.panel.panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none") login=\(SMAppService.mainApp.status.rawValue) visible=\(delegate.panel.panel.isVisible) history=\(model.showingHistory) draft=\(model.draft.debugDescription) editing=\(model.editingId != nil) chat=\(model.chat.id.uuidString.prefix(8)) hotkeyProblem=\(model.hotkeyProblem ?? "none") last=\(model.chat.messages.last.map { "\($0.role):\($0.text.prefix(80)) err=\($0.error ?? "-")" } ?? "-")"
                try? s.write(toFile: arg, atomically: true, encoding: .utf8)
            default: break
            }
        }
    }

    static func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
