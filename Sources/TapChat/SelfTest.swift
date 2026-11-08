import AppKit

// `TapChat --selftest [model …]`: one real request per model, with an
// earlier turn, an image and a text file, printed to stdout. For checking the
// CLI round trip without the window.
func selfTest(_ args: [String]) {
    let models = args.isEmpty ? ["haiku", "codex:default"] : args
    let folder = Paths.temporary.appendingPathComponent("selftest")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.systemBlue.setFill()
        rect.fill()
        return true
    }
    let textURL = folder.appendingPathComponent("note.txt")
    try? "The secret word is pineapple.".write(to: textURL, atomically: true, encoding: .utf8)
    guard let img = Attachments.importImage(image, name: "square.png", into: folder),
          let file = Attachments.importFile(textURL, into: folder) else {
        print("FAIL: could not create attachments")
        exit(1)
    }
    let history = [
        Message(role: .user, text: "My name is Ada."),
        Message(role: .assistant, text: "Nice to meet you, Ada!"),
    ]
    let question = Message(role: .user,
                           text: "Answer in one short line: my name, the colour of the image, and the secret word in the file.",
                           attachments: [img, file])

    var remaining = models
    var failed = false
    func next() {
        guard let model = remaining.first else {
            try? FileManager.default.removeItem(at: folder)
            exit(failed ? 1 : 0)
        }
        remaining.removeFirst()
        let req = RunRequest(model: model, effort: "low", webSearch: false, history: history, question: question)
        var deltas = 0
        let started = Date()
        let onEvent: (RunEvent) -> Void = { e in
            switch e {
            case .text: deltas += 1
            case .status(let s): if let s { print("  status: \(s)") }
            case .usage(let u): print("  usage: \(u.summary) reached=\(u.limitReached)")
            }
        }
        let done: (RunResult) -> Void = { r in
            print("  \(deltas) text updates, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            if let e = r.error { print("  ERROR (\(e.kind)): \(e.message)"); failed = true }
            print("  answer: \(r.text)")
            next()
        }
        print("== \(model)")
        _ = providerOf(model) == .claude
            ? ClaudeRunner.shared.run(req, onEvent: onEvent, completion: done)
            : CodexRunner.shared.run(req, onEvent: onEvent, completion: done)
    }
    next()
    if args.contains("--usage") { }
    RunLoop.main.run()
}
