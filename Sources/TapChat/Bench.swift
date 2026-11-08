import AppKit
import Darwin

// Benchmarks, run through DebugHooks (only with `--debug-hooks`); driven by
// scripts/bench.sh. Each scenario measures with the real window: state change,
// layout and drawing, so the numbers reflect what you see.
enum Bench {
    // This process's memory as Activity Monitor counts it (phys_footprint), in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    // CPU time used by this process so far, in seconds.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let t = { (v: timeval) in Double(v.tv_sec) + Double(v.tv_usec) / 1_000_000 }
        return t(usage.ru_utime) + t(usage.ru_stime)
    }

    // Lets SwiftUI apply pending changes, then lays out and draws the window now.
    static func render(_ window: NSWindow) {
        RunLoop.main.run(mode: .default, before: Date())
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    // The chat's scroll view: the tallest scrolling document in the window.
    static func chatScrollView(in window: NSWindow) -> NSScrollView? {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return all(window.contentView ?? NSView()).compactMap { $0 as? NSScrollView }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    static func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

    static func stats(_ xs: [Double]) -> [String: Double] {
        guard !xs.isEmpty else { return [:] }
        let s = xs.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
        let avg: Double = xs.reduce(0, +) / Double(xs.count)
        var r: [String: Double] = [:]
        r["avg"] = avg
        r["p50"] = p(0.5)
        r["p95"] = p(0.95)
        r["max"] = s[s.count - 1]
        r["n"] = Double(xs.count)
        return r
    }

    static func write(_ result: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    // A realistic answer: paragraphs with inline styles, a list, sometimes a
    // code block or a table. About 1.2 KB.
    static func answer(_ i: Int) -> String {
        var s = "Here is **answer \(i)**. It explains the idea with `inline code`, a [link](https://example.com) and *emphasis*, across a couple of sentences so the paragraph wraps over several lines in the window.\n\n"
        s += "## Details \(i)\n\n"
        s += "- First point about the topic, with **bold** text\n- Second point, slightly longer, that also wraps onto another line in a narrow window\n- Third point with `code`\n\n"
        if i % 3 == 0 {
            s += "```swift\nfunc example\(i)(x: Int) -> Int {\n    let y = x * 2\n    return y + \(i)\n}\n```\n\n"
        }
        if i % 5 == 0 {
            s += "| Name | Value | Note |\n|---|---|---|\n| alpha | \(i) | first |\n| beta | \(i * 2) | second |\n\n"
        }
        s += "A closing paragraph that summarises the answer in plain words, long enough to wrap, with one more `inline` bit and a final sentence."
        return s
    }

    static func chat(exchanges n: Int) -> Chat {
        var c = Chat()
        c.title = "Benchmark chat (\(n * 2) messages)"
        for i in 0..<n {
            c.messages.append(Message(role: .user, text: "Question \(i): how does this part work, and what should I watch out for?"))
            c.messages.append(Message(role: .assistant, text: answer(i), model: "sonnet", durationMs: 2300))
        }
        return c
    }
}
