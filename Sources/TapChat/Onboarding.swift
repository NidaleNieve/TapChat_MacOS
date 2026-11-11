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

    // The open shortcut was pressed while this shows: confetti from the
    // keys, out over the screen, and this closes (the chat is opening).
    func shortcutUsed() {
        guard !state.tried, let window, let screen = window.screen ?? NSScreen.main else { return }
        state.tried = true
        let keys = NSPoint(x: window.frame.midX, y: window.frame.maxY - 100)
        ConfettiWindow.burst(from: keys, on: screen)
        close()
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
                Text("Press it to open TapChat").foregroundStyle(.secondary)
                    .font(.system(size: 13, weight: .medium))
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

// Confetti over the whole screen, in a window of its own that clicks pass
// through: it pops up and out to the sides from a point, then tumbles down.
enum ConfettiWindow {
    static var current: NSWindow?

    static func burst(from point: NSPoint, on screen: NSScreen) {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false
        let origin = CGPoint(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y)
        w.contentView = NSHostingView(rootView: ConfettiBurst(origin: origin))
        w.setFrame(screen.frame, display: false)
        w.orderFrontRegardless()
        current = w
        DispatchQueue.main.asyncAfter(deadline: .now() + ConfettiBurst.duration + 0.1) {
            if current === w { current = nil }
            w.close()
        }
    }
}

struct ConfettiBurst: View {
    static let duration = 3.2
    let origin: CGPoint

    private struct Piece {
        var angle, speed, spin, flutter, phase, size: Double
        var round: Bool
        var color: Color
    }
    @State private var start = Date()
    private let pieces: [Piece] = (0..<200).map { _ in
        // Mostly up, fanning out to both sides.
        Piece(angle: .random(in: -170 ... -10) * .pi / 180, speed: .random(in: 500...1400),
              spin: .random(in: -10...10), flutter: .random(in: 6...14), phase: .random(in: 0...(2 * .pi)),
              size: .random(in: 7...13), round: Double.random(in: 0..<1) < 0.25,
              color: [Color(red: 1, green: 0.27, blue: 0.33), Color(red: 1, green: 0.62, blue: 0.1), Color(red: 1, green: 0.85, blue: 0.2),
                      Color(red: 0.2, green: 0.8, blue: 0.45), Color(red: 0.2, green: 0.55, blue: 1), Color(red: 0.62, green: 0.4, blue: 1),
                      Color(red: 1, green: 0.45, blue: 0.75)].randomElement()!)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                guard t < Self.duration else { return }
                // Air slows them; then gravity takes over.
                let drag = 2.2
                let travel = (1 - exp(-drag * t)) / drag
                for p in pieces {
                    let x = origin.x + cos(p.angle) * p.speed * travel
                    let y = origin.y + sin(p.angle) * p.speed * travel + 560 * t * t * 0.5
                    guard y < size.height + 30, x > -30, x < size.width + 30 else { continue }
                    var c = context
                    c.opacity = min(1, max(0, (Self.duration - t) / 0.7))
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.spin * t))
                    // Turning over as it falls: narrower, then wide again.
                    c.scaleBy(x: abs(cos(p.flutter * t + p.phase)) * 0.85 + 0.15, y: 1)
                    let r = CGRect(x: -p.size / 2, y: -p.size / 3.2, width: p.size, height: p.size / 1.6)
                    c.fill(p.round ? Path(ellipseIn: CGRect(x: -p.size / 3, y: -p.size / 3, width: p.size / 1.5, height: p.size / 1.5))
                                   : Path(roundedRect: r, cornerRadius: 1.5), with: .color(p.color))
                }
            }
        }
        .ignoresSafeArea()
    }
}
