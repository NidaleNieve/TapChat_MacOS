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
            case "bench-mem":
                var r: [String: Any] = [:]
                r["footprintMB"] = Bench.footprintMB()
                r["cpuSeconds"] = Bench.cpuSeconds()
                Bench.write(r, to: arg)
            // For looking at a long chat: saves one with <n> exchanges (open it
            // with open-first), and deletes the open chat.
            case "make-chat": ChatStore.shared.save(Bench.chat(exchanges: Int(arg) ?? 50)); model.history = ChatStore.shared.index
            case "delete-open": model.delete(model.chat.id)
            case "retitle": model.retitleNow()
            // Shows the import menu for a moment and reports what AppKit did with it.
            // arg: "<result path>" or "regular|<result path>" (as a Dock app).
            case "probe-import":
                let parts = arg.split(separator: "|").map(String.init)
                let out = parts.last ?? "/dev/null"
                if parts.contains("regular") { NSApp.setActivationPolicy(.regular) }
                delegate.panel.show()
                NSApp.activate(ignoringOtherApps: true)
                let window = delegate.panel.panel
                window.makeKeyAndOrderFront(nil)
                // Once active and key, as when you click +.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let probe = ImportAnchor.RequestView(frame: NSRect(x: 60, y: 60, width: 20, height: 20))
                    window.contentView?.addSubview(probe)
                    ImportAnchor.RequestView.asked = []
                    if parts.contains("register") { ImportAnchor.registerTypes() }
                    let menu = NSMenu()
                    let device = NSMenuItem(title: "Import from iPhone", action: nil, keyEquivalent: "")
                    device.identifier = NSMenuItem.importFromDeviceIdentifier
                    menu.addItem(device)
                    var report = "policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) key=\(window.isKeyWindow)\n"
                    let t = Timer(timeInterval: 0.8, repeats: false) { _ in
                        func dump(_ m: NSMenu, _ indent: String) {
                            for i in m.items {
                                report += "\(indent)\(i.isSeparatorItem ? "---" : i.title) enabled=\(i.isEnabled) id=\(i.identifier?.rawValue ?? "-")\n"
                                if let sub = i.submenu { dump(sub, indent + "  ") }
                            }
                        }
                        dump(menu, "")
                        menu.cancelTracking()
                    }
                    RunLoop.main.add(t, forMode: .common)
                    probe.present(menu)
                    let images = ImportAnchor.RequestView.asked.filter { !$0.contains("rtf") && !$0.contains("RTF") && !$0.contains("plain-text") && !$0.contains("NSString") && !$0.contains("Rich Text") }
                    report += "asked about non-text: \(images.isEmpty ? "nothing" : images.joined(separator: ", "))\n"
                    probe.removeFromSuperview()
                    try? report.write(toFile: out, atomically: true, encoding: .utf8)
                }
            // Whether the window offers to take an iPhone import (what greys the menu item out or not).
            case "check-import":
                let w = delegate.panel.panel
                let chain = (w.firstResponder?.validRequestor(forSendType: nil, returnType: .png) != nil, w.validRequestor(forSendType: nil, returnType: .png) != nil)
                try? "firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "none") takes=\(chain.0) window takes=\(chain.1) key=\(w.isKeyWindow)".write(toFile: arg, atomically: true, encoding: .utf8)
            // A slow fake answer in the open chat: <n> seconds of waiting, then text.
            case "fake-answer": model.simulateAnswer("Here is a short **fake** answer, streamed in.", chunk: 4, every: Double(arg) ?? 3) {}
            // Like sending a question: a long answer streams in over a few seconds.
            case "fake-send": model.simulateAnswer(Bench.answer(3) + "\n\n" + Bench.answer(5), chunk: 6, every: 0.04, likeSend: true) {}
            case "bench-chat": benchChat(delegate, arg)
            case "bench-stream": benchStream(delegate, arg)
            case "bench-attach": benchAttach(delegate, arg)
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

    // MARK: Benchmarks (scripts/bench.sh)

    private static func parse(_ arg: String) -> (Int, String) {
        let parts = arg.split(separator: "|", maxSplits: 1).map(String.init)
        return (Int(parts[0]) ?? 0, parts.count > 1 ? parts[1] : "/dev/null")
    }

    // Opening a long saved chat from History (cold, then warm), then
    // scrolling through it very fast.
    static func benchChat(_ d: AppDelegate, _ arg: String) {
        let (n, out) = parse(arg)
        let model = d.model, window = d.panel.panel
        d.panel.show()
        model.newChat()
        Bench.settle(window)
        let chat = Bench.chat(exchanges: n)
        ChatStore.shared.save(chat)
        // Clicking it in History: from the click to the chat's first frame.
        // The first time, nothing about it is in memory yet.
        var opens: [Double] = []
        for _ in 0..<6 {
            model.newChat()
            model.toggleHistory()
            Bench.settle(window, seconds: 0.6)
            let t = DispatchTime.now().uptimeNanoseconds
            model.open(chat.id)
            Bench.render(window)
            opens.append(Bench.ms(t))
        }
        Bench.settle(window, seconds: 0.6)
        // A frame with nothing changed: the floor under every timing here.
        var idle: [Double] = []
        for _ in 0..<20 {
            let t = DispatchTime.now().uptimeNanoseconds
            window.contentView?.needsDisplay = true
            Bench.render(window)
            idle.append(Bench.ms(t))
        }
        // A fast fling to the top and back: the scroll view moves 600 pt per
        // frame (about 36,000 pt/s at 60 Hz), so rows keep coming into view.
        var steps: [Double] = []
        if let scroll = Bench.chatScrollView(in: window) {
            let height = scroll.documentView?.frame.height ?? 0
            let visible = scroll.contentView.bounds.height
            let flipped = scroll.documentView?.isFlipped ?? true
            let bottom = max(0, height - visible)
            // Top-to-bottom offsets in the document's own coordinates.
            func y(_ fromTop: CGFloat) -> CGFloat { flipped ? fromTop : bottom - fromTop }
            let up: [CGFloat] = Array(stride(from: bottom, through: 0, by: -600)) + [0]
            let down: [CGFloat] = Array(stride(from: 0, through: bottom, by: 600)) + [bottom]
            for offset in up + down {
                let t = DispatchTime.now().uptimeNanoseconds
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y(offset)))
                scroll.reflectScrolledClipView(scroll.contentView)
                Bench.render(window)
                steps.append(Bench.ms(t))
            }
        }
        let mem: Double = Bench.footprintMB()
        model.delete(chat.id)
        model.newChat()
        Bench.render(window)
        var r: [String: Any] = [:]
        r["messages"] = n * 2
        r["openColdMs"] = opens[0]
        r["openWarm"] = Bench.stats(Array(opens.dropFirst()))
        r["idleFrameMs"] = Bench.stats(idle)
        r["scrollStepMs"] = Bench.stats(steps)
        r["footprintWithChatMB"] = mem
        Bench.write(r, to: out)
    }

    // A long answer streamed in (no CLI): CPU used by TapChat while it appears.
    // arg: "<chars>|<result.json>", or "<chars>x<exchanges>|<result.json>" to
    // stream at the end of a chat that already has that many exchanges.
    static func benchStream(_ d: AppDelegate, _ arg: String) {
        let (spec, out) = { () -> (String, String) in
            let parts = arg.split(separator: "|", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "/dev/null")
        }()
        let numbers = spec.split(separator: "x").compactMap { Int($0) }
        let chars = numbers.first ?? 0, earlier = numbers.count > 1 ? numbers[1] : 0
        let model = d.model, window = d.panel.panel
        d.panel.show()
        model.newChat(temporary: true)
        if earlier > 0 { model.chat.messages = Bench.chat(exchanges: earlier).messages }
        Bench.settle(window)
        var text = ""
        var i = 0
        while text.count < chars { text += Bench.answer(i) + "\n\n"; i += 1 }
        let cpu0 = Bench.cpuSeconds(), t0 = DispatchTime.now().uptimeNanoseconds
        var peak = Bench.footprintMB()
        let sampler = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in peak = max(peak, Bench.footprintMB()) }
        // ~1000 characters a second, in network-sized chunks: a fast model.
        model.simulateAnswer(text, chunk: 25, every: 0.025) {
            sampler.invalidate()
            let wall: Double = Bench.ms(t0) / 1000
            let cpu: Double = Bench.cpuSeconds() - cpu0
            let percent: Double = cpu / wall * 100
            model.newChat()
            var r: [String: Any] = [:]
            r["chars"] = text.count
            r["earlierMessages"] = earlier * 2
            r["wallSeconds"] = wall
            r["cpuSeconds"] = cpu
            r["cpuPercent"] = percent
            r["peakFootprintMB"] = peak
            Bench.write(r, to: out)
        }
    }

    // Adding screenshots to the composer, then removing them one at a time.
    // arg: "<folder of images>|<result.json>" (scripts/bench.sh makes the
    // images outside the app, so making them costs the app no memory).
    static func benchAttach(_ d: AppDelegate, _ arg: String) {
        let parts = arg.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let out = parts[1]
        let model = d.model, window = d.panel.panel
        d.panel.show()
        model.newChat(temporary: true)
        Bench.settle(window)
        let src = URL(fileURLWithPath: parts[0])
        let urls = ((try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
        // Each step in its own autorelease pool, as when the run loop runs
        // between them in real use.
        let before = Bench.footprintMB()
        let t0 = DispatchTime.now().uptimeNanoseconds
        autoreleasepool {
            model.attach(urls: urls)
            Bench.render(window)
        }
        let addMs = Bench.ms(t0)
        let withImages = Bench.footprintMB()
        var removes: [Double] = []
        while let first = model.draftAttachments.first {
            let t = DispatchTime.now().uptimeNanoseconds
            autoreleasepool {
                model.draftAttachments.removeAll { $0.id == first.id }
                Bench.render(window)
            }
            removes.append(Bench.ms(t))
        }
        let after = Bench.footprintMB()
        model.newChat()
        var r: [String: Any] = [:]
        r["images"] = urls.count
        r["addAllMs"] = addMs
        r["removeMs"] = Bench.stats(removes)
        r["footprintBeforeMB"] = before
        r["footprintWithImagesMB"] = withImages
        r["footprintAfterRemovingMB"] = after
        Bench.write(r, to: out)
    }
}
