import AppKit
import Carbon
import SwiftUI

// After setup, once: try the shortcut (confetti when it works), the other
// shortcuts, and two choices. Few words; keys drawn as keys.

@Observable final class OnboardingState {
    var tried = false
    // Bumped when a shortcut changes here, so the keys redraw.
    var shortcuts = 0
    var menuBar = Settings.showMenuBarIcon
    var haptics = Settings.haptics
}

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let state = OnboardingState()
    var onMenuBarChange: ((Bool) -> Void)?
    var onShortcutChange: (() -> Void)?
    var onClose: (() -> Void)?

    // `existing`: setup's window, which turns into this one: its content
    // fades out, it resizes (top edge kept), and this fades in.
    init(reusing existing: NSWindow? = nil) {
        let window = existing ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        let host = NSHostingView(rootView: OnboardingView(
            state: state,
            menuBar: { [weak self] on in Settings.showMenuBarIcon = on; self?.onMenuBarChange?(on) },
            shortcutChanged: { [weak self] in self?.onShortcutChange?() },
            done: { [weak self] in self?.close() }))
        let size = host.fittingSize
        let style = { (w: NSWindow) in
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // Under the chat window (also floating, shown later), over other apps.
            w.level = .floating
        }
        guard let existing, existing.isVisible, let old = existing.contentView else {
            style(window)
            window.contentView = host
            window.setContentSize(size)
            window.center()
            window.delegate = self
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            old.animator().alphaValue = 0
        }, completionHandler: {
            style(existing)
            let top = existing.frame.maxY, mid = existing.frame.midX
            host.alphaValue = 0
            existing.contentView = host
            let frame = NSRect(x: mid - size.width / 2, y: top - size.height, width: size.width, height: size.height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                existing.animator().setFrame(frame, display: true)
                host.animator().alphaValue = 1
            }
        })
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // The open shortcut was pressed while this shows: confetti from the
    // keys, out over the screen (once). This stays, for the rest.
    func shortcutUsed() {
        guard !state.tried, let window, window.isVisible, let screen = window.screen ?? NSScreen.main else { return }
        state.tried = true
        let keys = NSPoint(x: window.frame.midX, y: window.frame.maxY - 100)
        ConfettiWindow.burst(from: keys, on: screen)
    }

    func windowWillClose(_ notification: Notification) {
        Settings.onboarded = true
        onClose?()
    }
}

struct OnboardingView: View {
    @Bindable var state: OnboardingState
    let menuBar: (Bool) -> Void
    let shortcutChanged: () -> Void
    let done: () -> Void
    @State var editing: ShortcutKind?
    @State var hovered: ShortcutKind?
    @State var problem: String?
    @State var monitor: Any?

    private let shortcuts: [(ShortcutKind, String)] = [
        (.newChat, "square.and.pencil"), (.temporaryChat, "eye.slash"),
        (.history, "clock"), (.dismissSide, "rectangle.on.rectangle"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Text("Welcome to TapChat").font(.system(size: 20, weight: .bold))
            // Try it.
            VStack(spacing: 10) {
                if editing == .open { recordingKeys(large: true) } else { Keys(label: ShortcutKind.open.current?.label ?? "None", large: true) }
                Text(editing == .open ? (problem ?? "Press the new shortcut") : "Press it to open TapChat")
                    .foregroundStyle(editing == .open && problem != nil ? .orange : .secondary)
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
            // While another shortcut is being changed, none other can be.
            .overlay(alignment: .topTrailing) { if editing == nil || editing == .open { pencil(.open).padding(6) } }

            VStack(spacing: 9) {
                ForEach(shortcuts, id: \.0) { kind, symbol in
                    HStack(spacing: 10) {
                        Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(editing == kind && problem != nil ? problem! : kind == .dismissSide ? "Close Side Chat" : kind.title)
                            .foregroundStyle(editing == kind && problem != nil ? .orange : .primary)
                        Spacer()
                        Group {
                            if editing == kind { recordingKeys(large: false) } else if let label = kind.current?.label { Keys(label: label) }
                        }
                        // On hover only, beside the keys, taking no room.
                        .overlay(alignment: .leading) {
                            if (hovered == kind && editing == nil) || editing == kind { pencil(kind).offset(x: -24).transition(.opacity) }
                        }
                    }
                    .font(.system(size: 13))
                    .contentShape(Rectangle())
                    .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? kind : (hovered == kind ? nil : hovered) } }
                }
            }

            Divider()

            VStack(spacing: 8) {
                choice("Menu bar icon", "menubar.rectangle", $state.menuBar)
                    .onChange(of: state.menuBar) { menuBar(state.menuBar) }
                choice("Haptic feedback", "hand.tap", $state.haptics)
                    .onChange(of: state.haptics) { Settings.haptics = state.haptics }
            }

            Button(action: { stopRecording(); done() }) { Text("Done").frame(maxWidth: .infinity) }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        // The title bar's own space is above this already.
        .padding(.horizontal, 22).padding(.top, 2).padding(.bottom, 20)
        .frame(width: 360)
        .id(state.shortcuts)
        .onDisappear { stopRecording() }
    }
}

extension OnboardingView {
    // Edit: press the new keys (Esc to keep the old ones).
    func pencil(_ kind: ShortcutKind) -> some View {
        Button { editing == kind ? stopRecording() : record(kind) } label: {
            Image(systemName: editing == kind ? "xmark" : "pencil")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(editing == kind ? "Keep the old shortcut" : "Change shortcut")
    }

    func recordingKeys(large: Bool) -> some View {
        Text("…").font(.system(size: large ? 17 : 11, weight: .medium))
            .frame(minWidth: large ? 94 : 50, minHeight: large ? 40 : 22)
            .background(RoundedRectangle(cornerRadius: large ? 9 : 5).fill(Color.accentColor.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: large ? 9 : 5).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
    }

    func record(_ kind: ShortcutKind) {
        stopRecording()
        editing = kind
        problem = nil
        // The current one reaches this too (⌥ Space would open the chat).
        HotKeys.shared.unregister(kind)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                stopRecording()
                return nil
            }
            guard let shortcut = Shortcut(event) else {
                problem = "Use ⌘, ⌥ or ⌃"
                return nil
            }
            if let why = kind.assign(shortcut) {
                problem = why
                HotKeys.shared.unregister(kind)
                return nil
            }
            shortcutChanged()
            stopRecording()
            state.shortcuts += 1
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let editing { HotKeys.shared.register(editing, editing.current) }
        editing = nil
        problem = nil
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

// Paper confetti, simulated step by step: a burst up and out, air that
// slows each piece differently (by its size and how flat it's falling),
// side-to-side drift as it flutters, and flips about two axes, darker when
// seen edge-on.
final class ConfettiSimulation {
    struct Piece {
        var x, y, vx, vy: Double
        var drag: Double            // per second; flat paper slows most
        var spin, angle: Double     // in the plane
        var flipX, flipY, flipRateX, flipRateY: Double
        var swayRate, swayPhase, sway: Double
        var size: Double
        var round: Bool
        var hue: (Double, Double, Double)
        var delay: Double
    }
    var pieces: [Piece]
    private var last: Date?
    private var elapsed = 0.0

    init(origin: CGPoint, count: Int = 220) {
        let colors: [(Double, Double, Double)] = [(1, 0.27, 0.33), (1, 0.62, 0.1), (1, 0.85, 0.2), (0.2, 0.8, 0.45),
                                                    (0.2, 0.55, 1), (0.62, 0.4, 1), (1, 0.45, 0.75)]
        pieces = (0..<count).map { _ in
            let angle = Double.random(in: -172 ... -8) * .pi / 180
            let speed = Double.random(in: 500...1500) * (Double.random(in: 0..<1) < 0.2 ? 0.6 : 1)
            return Piece(x: origin.x + .random(in: -14...14), y: origin.y + .random(in: -8...8),
                         vx: cos(angle) * speed, vy: sin(angle) * speed,
                         drag: .random(in: 1.4...3.0), spin: .random(in: -9...9), angle: .random(in: 0...(2 * .pi)),
                         flipX: .random(in: 0...(2 * .pi)), flipY: .random(in: 0...(2 * .pi)),
                         flipRateX: .random(in: 4...11), flipRateY: .random(in: 1...5),
                         swayRate: .random(in: 2...4.5), swayPhase: .random(in: 0...(2 * .pi)), sway: .random(in: 250...650),
                         size: .random(in: 7...13), round: Double.random(in: 0..<1) < 0.2,
                         hue: colors.randomElement()!, delay: .random(in: 0...0.08))
        }
    }

    var time: Double { elapsed }

    func step(to now: Date) {
        let dt = min(1.0 / 30, last.map { now.timeIntervalSince($0) } ?? 0)
        last = now
        elapsed += dt
        let g = 980.0
        for i in pieces.indices {
            var p = pieces[i]
            guard elapsed > p.delay else { continue }
            // Edge-on it cuts through the air; flat, it catches it.
            let flat = abs(cos(p.flipX)) * 0.7 + 0.3
            let k = p.drag * flat
            p.vy += g * dt
            // Drifting side to side as it flutters, more once the burst is spent.
            let settled = min(1, max(0, (elapsed - 0.35) / 0.6))
            p.vx += sin(elapsed * p.swayRate + p.swayPhase) * p.sway * settled * dt
            p.vx -= p.vx * k * dt
            p.vy -= p.vy * k * dt
            p.x += p.vx * dt
            p.y += p.vy * dt
            // Spinning slows down in the air, the flips keep going.
            p.spin -= p.spin * 0.6 * dt
            p.angle += (p.spin + p.vx * 0.004) * dt
            p.flipX += p.flipRateX * dt
            p.flipY += p.flipRateY * dt
            pieces[i] = p
        }
    }
}

struct ConfettiBurst: View {
    static let duration = 5.0
    // Made once with the view (its window shows one burst).
    private let sim: ConfettiSimulation
    init(origin: CGPoint) { sim = ConfettiSimulation(origin: origin) }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                sim.step(to: timeline.date)
                let t = sim.time
                guard t < Self.duration else { return }
                let fade = min(1, max(0, (Self.duration - t) / 0.8))
                for p in sim.pieces where t > p.delay {
                    guard p.y < size.height + 30, p.x > -40, p.x < size.width + 40 else { continue }
                    var c = context
                    c.opacity = fade
                    c.translateBy(x: p.x, y: p.y)
                    c.rotate(by: .radians(p.angle))
                    let sx = cos(p.flipX), sy = cos(p.flipY) * 0.35 + 0.65
                    c.scaleBy(x: max(0.08, abs(sx)), y: sy)
                    // The back of the paper, and edge-on, a little darker.
                    let shade = 0.72 + 0.28 * abs(sx) - (sx < 0 ? 0.1 : 0)
                    let color = Color(red: p.hue.0 * shade, green: p.hue.1 * shade, blue: p.hue.2 * shade)
                    let shape = p.round
                        ? Path(ellipseIn: CGRect(x: -p.size / 3, y: -p.size / 3, width: p.size / 1.5, height: p.size / 1.5))
                        : Path(roundedRect: CGRect(x: -p.size / 2, y: -p.size / 3.4, width: p.size, height: p.size / 1.7), cornerRadius: 1.2)
                    c.fill(shape, with: .color(color))
                }
            }
        }
        .ignoresSafeArea()
    }
}
