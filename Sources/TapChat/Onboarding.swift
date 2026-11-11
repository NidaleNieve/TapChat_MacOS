import AppKit
import SwiftUI

// After setup, once: try the shortcut (confetti when it works), the other
// shortcuts, and two choices. Few words; keys drawn as keys.

@Observable final class OnboardingState {
    var tried = false
    var menuBar = Settings.showMenuBarIcon
    var haptics = Settings.haptics
}

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let state = OnboardingState()
    var onMenuBarChange: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // Under the chat window (also floating, shown later), over other apps.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(
            state: state,
            menuBar: { [weak self] on in Settings.showMenuBarIcon = on; self?.onMenuBarChange?(on) },
            done: { [weak self] in self?.close() }))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // The open shortcut was pressed while this shows.
    func shortcutUsed() {
        guard !state.tried else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.3)) { state.tried = true }
    }

    func windowWillClose(_ notification: Notification) {
        Settings.onboarded = true
        onClose?()
    }
}

private struct OnboardingView: View {
    @Bindable var state: OnboardingState
    let menuBar: (Bool) -> Void
    let done: () -> Void

    private let shortcuts: [(ShortcutKind, String)] = [
        (.newChat, "square.and.pencil"), (.temporaryChat, "eye.slash"),
        (.history, "clock"), (.dismissSide, "rectangle.on.rectangle"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            // Try it.
            VStack(spacing: 10) {
                Keys(label: ShortcutKind.open.current?.label ?? "⌥ Space", large: true)
                Group {
                    if state.tried {
                        Label("That's it", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("Press it to open TapChat").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))

            VStack(spacing: 9) {
                ForEach(shortcuts, id: \.0) { kind, symbol in
                    HStack(spacing: 10) {
                        Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(kind == .dismissSide ? "Close Side Chat" : kind.title)
                        Spacer()
                        if let label = kind.current?.label { Keys(label: label) }
                    }
                    .font(.system(size: 13))
                }
            }

            Divider()

            VStack(spacing: 8) {
                choice("Menu bar icon", "menubar.rectangle", $state.menuBar)
                    .onChange(of: state.menuBar) { menuBar(state.menuBar) }
                choice("Haptic feedback", "hand.tap", $state.haptics)
                    .onChange(of: state.haptics) { Settings.haptics = state.haptics }
            }

            Button(action: done) { Text("Done").frame(maxWidth: .infinity) }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 20)
        .frame(width: 360)
        .overlay { if state.tried { Confetti().allowsHitTesting(false) } }
    }
}

private func choice(_ title: String, _ symbol: String, _ on: Binding<Bool>) -> some View {
    HStack(spacing: 10) {
        Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
        Text(title)
        Spacer()
        Toggle(title, isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
    .font(.system(size: 13))
}

// A shortcut as keycaps: ⌥, ⌘, ⇧ and ⌃ as their symbols, then the key.
struct Keys: View {
    let label: String
    var large = false

    private var caps: [(symbol: String?, text: String)] {
        let parts = label.split(separator: " ", maxSplits: 1).map(String.init)
        let mods = parts.count == 2 ? parts[0] : ""
        let key = parts.last ?? ""
        let names: [Character: String] = ["⌃": "control", "⌥": "option", "⇧": "shift", "⌘": "command"]
        return mods.map { (names[$0], String($0)) } + [(nil, key)]
    }

    var body: some View {
        HStack(spacing: large ? 6 : 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Group {
                    if let symbol = cap.symbol { Image(systemName: symbol) } else { Text(cap.text) }
                }
                .font(.system(size: large ? 17 : 11, weight: .medium))
                .frame(minWidth: large ? 40 : 22, minHeight: large ? 40 : 22)
                .padding(.horizontal, cap.text.count > 1 && cap.symbol == nil ? (large ? 14 : 6) : 0)
                .background(
                    RoundedRectangle(cornerRadius: large ? 9 : 5)
                        .fill(Color.primary.opacity(0.06))
                        .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
                )
                .overlay(RoundedRectangle(cornerRadius: large ? 9 : 5).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
        }
    }
}

// A burst of confetti from the top, falling for a few seconds.
struct Confetti: View {
    private struct Piece {
        var x, vx, vy, spin, size: Double
        var color: Color
    }
    @State private var start = Date()
    private let pieces: [Piece] = (0..<90).map { _ in
        Piece(x: .random(in: 0...1), vx: .random(in: -0.25...0.25), vy: .random(in: -260 ... -60),
              spin: .random(in: -9...9), size: .random(in: 5...9),
              color: [.red, .orange, .yellow, .green, .blue, .purple, .pink].randomElement()!)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                guard t < 3.5 else { return }
                for p in pieces {
                    let x = p.x * size.width + p.vx * size.width * t
                    // Up from a third of the way down, then falling.
                    let y = size.height * 0.3 + p.vy * 1.4 * t + 520 * t * t
                    guard y < size.height + 20 else { continue }
                    var c = context
                    c.opacity = max(0, min(1, (3.5 - t) / 0.8))
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.spin * t))
                    c.fill(Path(CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)), with: .color(p.color))
                }
            }
        }
    }
}
