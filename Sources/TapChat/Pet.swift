import AppKit
import SwiftUI

// The pet (Settings → Pet): a little creature in the corner of the screen.
// Tap it and the chat opens or closes; drag it anywhere. It watches the
// cursor, listens while you type, hums while the answer comes, cheers when
// it's done (or looks sorry when it failed), likes being petted (rest or
// rub the cursor on it), gets dizzy when shaken, wanders a little, yawns,
// and falls asleep when you're away.
//
// Its motion is simulated, not keyframed: jumps under gravity, a springy
// body that squashes on landing, a sprout that lags behind every move, and a
// face whose every part eases toward where the mood wants it. So any state
// blends into any other. One `PetPose` per frame is all the drawing reads.

// MARK: - What the drawing reads

struct PetPose: Equatable {
    var time: Double = 0
    var lift: CGFloat = 0        // height above the floor
    var bob: CGFloat = 0         // walking bounce
    var squash: CGFloat = 0      // + wide and flat, − tall and thin
    var lean: CGFloat = 0        // degrees, + to the right
    var facing: CGFloat = 0      // −1 left … 1 right: the face turns that way
    var lookX: CGFloat = 0, lookY: CGFloat = 0
    var lid: CGFloat = 1         // 1 open … 0 shut
    var wide: CGFloat = 0        // eyes bigger
    var joy: CGFloat = 0         // eyes become ^ ^
    var dizzy: CGFloat = 0       // spiral eyes
    var spin: CGFloat = 0        // the spirals' turn
    var smile: CGFloat = 0.4     // −1 frown … 1 big smile
    var mouth: CGFloat = 0       // how open
    var blush: CGFloat = 0.35
    var brow: CGFloat = 0        // −1 worried … 1 cross
    var browShow: CGFloat = 0
    var armL: CGFloat = 0, armR: CGFloat = 0   // degrees raised
    var footL: CGFloat = 0, footR: CGFloat = 0 // each foot's lift
    var dangle: CGFloat = 0      // held up by the cursor
    var swing: CGFloat = 0       // feet swinging while held
    var sprout: CGFloat = 0      // degrees
}

struct PetParticle: Identifiable {
    enum Kind { case heart, note, z, sparkle, sweat, bang, question, dust }
    let id: Int
    let kind: Kind
    let born: Double
    let life: Double
    let x: CGFloat, y: CGFloat      // start, from the top of the head (y up)
    let vx: CGFloat, vy: CGFloat    // points a second
}

struct PetBubble: Equatable {
    let id: Int
    let text: String
}

@Observable final class PetBrain {
    var pose = PetPose()
    var particles: [PetParticle] = []
    var bubble: PetBubble?
}

// MARK: - Behaviour

private struct PetSpring {
    var x: CGFloat = 0, v: CGFloat = 0
    mutating func step(to target: CGFloat, k: CGFloat, d: CGFloat, dt: CGFloat) {
        v += (k * (target - x) - d * v) * dt
        x += v * dt
    }
}

private func ease(_ v: inout CGFloat, _ target: CGFloat, _ rate: CGFloat, _ dt: CGFloat) {
    v += (target - v) * (1 - exp(-rate * dt))
}

private func bell(_ p: Double) -> CGFloat { p <= 0 || p >= 1 ? 0 : CGFloat(sin(p * .pi)) }

final class PetController: NSObject {
    enum Mood { case idle, listening, thinking, happy, sad, love, sleepy, sleeping, dizzy, held }
    enum ActKind: CaseIterable { case wiggle, lookAround, hum, stretch, dance, sneeze, yawn, nod, startle, peek }
    struct Act { let kind: ActKind; let start: Double; let duration: Double }

    static let size = NSSize(width: 230, height: 220)
    static let floor: CGFloat = 16
    static let bodyW: CGFloat = 84, bodyH: CGFloat = 72

    let window: PetWindow
    let brain = PetBrain()
    private let model: ChatModel
    private let chat: PanelController
    private let toggleChat: () -> Void
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    // State.
    private var mood: Mood = .idle
    private var moodUntil: Double = 0
    private var act: Act?
    private var nextAct: Double = 0
    private var pose = PetPose()
    private var last = CACurrentMediaTime()

    // Physics.
    private var liftV: CGFloat = 0
    private var squash = PetSpring()
    private var lean = PetSpring()
    private var sprout = PetSpring()
    private var armL = PetSpring(), armR = PetSpring()
    private var swing = PetSpring()
    private var launches: [Double] = []       // hops waiting to leave the ground
    private var crouches: [Double] = []

    // Walking: the window moves toward walkTo (its origin's x).
    private var walkTo: CGFloat?
    private var stepPhase: Double = 0
    private var home = NSPoint.zero

    // Blinks.
    private var nextBlink: Double = 0
    private var blinkAt: Double = -10

    // Chat.
    private var wasRunning = false
    private var lastCount = 0
    private var lastDraft = 0
    private var typedAt: Double = -100

    // The cursor.
    private var lastMouse = NSPoint.zero
    private var mouseSpeed: CGFloat = 0
    private var hoverSince: Double?
    private var rubbed: CGFloat = 0
    private var lastLoved: Double = -100
    private var lastStartle: Double = -100

    // Held.
    private var holding = false
    private var holdStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragVX: CGFloat = 0
    private var lastDragX: CGFloat = 0
    private var shakes: [Double] = []
    private var lastDragDir: CGFloat = 0

    private var lastIdleCheck: Double = 0
    private var idleSeconds: Double = 0
    private var lastQuip: Double = -100
    private var glance: (CGPoint, Double)?
    private var particleId = 0
    private var bubbleUntil: Double = 0
    private var bubbleId = 0

    init(model: ChatModel, panel: PanelController, toggleChat: @escaping () -> Void) {
        self.model = model
        chat = panel
        self.toggleChat = toggleChat
        window = PetWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.canHide = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PetView(brain: brain))
        host.sizingOptions = []
        let touch = PetTouchView(frame: NSRect(origin: .zero, size: Self.size))
        host.frame = touch.bounds
        host.autoresizingMask = [.width, .height]
        touch.addSubview(host)
        touch.onTap = { [weak self] in self?.tapped() }
        touch.onHold = { [weak self] in self?.hold() }
        touch.onDrag = { [weak self] in self?.dragged() }
        touch.onDrop = { [weak self] in self?.dropped() }
        window.contentView = touch
        home = startOrigin()
        window.setFrameOrigin(home)
        window.orderFrontRegardless()

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            self?.appChanged(n)
        })
        // Nothing runs while the screens sleep or the Mac is locked.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.pause() })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.resume() })
        }
        lastCount = model.chat.messages.count
        lastDraft = model.draft.utf8.count
        let t = CACurrentMediaTime()
        nextAct = t + 6
        nextBlink = t + 1.5
        // Arrives from above: falls, lands with a squash, says hi.
        pose.lift = 150
        liftV = -40
        sprout.x = -20
        say("hi! tap me ✨", for: 3.2, at: t + 0.5)
        resume()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        window.orderOut(nil)
        window.close()
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
    }

    private func resume() {
        last = CACurrentMediaTime()
        schedule(1.0 / 60)
    }

    // 60 frames a second while it moves; asleep and still, 20.
    private func schedule(_ every: TimeInterval) {
        guard timer == nil || every != interval else { return }
        timer?.invalidate()
        interval = every
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func startOrigin() -> NSPoint {
        if let s = UserDefaults.standard.string(forKey: "petOrigin") {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(NSPoint(x: p.x + Self.size.width / 2, y: p.y + 30)) }) { return p }
        }
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: v.maxX - Self.size.width - 20, y: v.minY)
    }

    // The body on screen (for clicks and petting).
    private var bodyRect: NSRect {
        let f = window.frame
        let w = Self.bodyW * (1 + pose.squash), h = Self.bodyH * (1 - pose.squash)
        return NSRect(x: f.midX - w / 2, y: f.minY + Self.floor + pose.lift + pose.bob - 6, width: w, height: h + 22)
    }

    // MARK: Things it says and shows

    private func say(_ text: String, for seconds: Double = 2.4, at time: Double? = nil) {
        let start = time ?? CACurrentMediaTime()
        let delay = max(0, start - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.bubbleId += 1
            self.brain.bubble = PetBubble(id: self.bubbleId, text: text)
            self.bubbleUntil = CACurrentMediaTime() + seconds
        }
    }

    private func emit(_ kind: PetParticle.Kind, count: Int = 1, spread: CGFloat = 22, life: Double = 1.6,
                      x: CGFloat = 0, y: CGFloat = 0, vy: CGFloat = 34, delay: Double = 0.18) {
        let t = CACurrentMediaTime()
        for i in 0..<count {
            particleId += 1
            brain.particles.append(PetParticle(id: particleId, kind: kind, born: t + Double(i) * delay, life: life,
                                               x: x + CGFloat.random(in: -spread...spread), y: y,
                                               vx: CGFloat.random(in: -8...8), vy: vy * CGFloat.random(in: 0.8...1.2)))
        }
    }

    private func hop(_ count: Int = 1, gap: Double = 0.48, at time: Double? = nil) {
        let t = time ?? CACurrentMediaTime()
        for i in 0..<count {
            crouches.append(t + Double(i) * gap)
            launches.append(t + Double(i) * gap + 0.09)
        }
    }

    private func setMood(_ m: Mood, for seconds: Double? = nil) {
        mood = m
        moodUntil = seconds.map { CACurrentMediaTime() + $0 } ?? 0
    }

    private func perform(_ kind: ActKind, _ t: Double) {
        let duration: Double = switch kind {
        case .wiggle: 0.9
        case .lookAround: 2.4
        case .hum: 3.0
        case .stretch: 1.8
        case .dance: 2.6
        case .sneeze: 1.7
        case .yawn: 2.2
        case .nod: 0.7
        case .startle: 0.8
        case .peek: 2.0
        }
        act = Act(kind: kind, start: t, duration: duration)
        switch kind {
        case .hum:
            emit(.note, count: 3, spread: 14, life: 1.8, x: 18, vy: 30, delay: 0.7)
            if Double.random(in: 0...1) < 0.5 { say(["♪ hm hm hmm ♪", "la la la", "♫ ♪"].randomElement()!, for: 2.2) }
        case .dance: hop(2, gap: 1.1, at: t + 0.4)
        case .sneeze: say("a… a…", for: 0.95)
        case .startle: emit(.bang, life: 0.9, x: 22, vy: 20); hop()
        case .yawn: if mood != .sleeping { say("*yawn*", for: 1.6, at: t + 0.4) }
        default: break
        }
    }

    // MARK: Input

    private func tapped() {
        let t = CACurrentMediaTime()
        if mood == .sleeping || mood == .sleepy {
            setMood(.idle)
            perform(.startle, t)
            say(["huh?! 👀", "i'm up! i'm up!", "five more minutes…"].randomElement()!)
            act = Act(kind: .stretch, start: t + 0.7, duration: 1.8)
            return
        }
        let opening = !chat.panel.isVisible
        toggleChat()
        if opening {
            hop()
            if Double.random(in: 0...1) < 0.35 { say(["what's up?", "ask me anything!", "hiii", "✨"].randomElement()!, for: 1.6) }
        } else {
            squash.v += 3
            if Double.random(in: 0...1) < 0.35 { say(["bye bye 👋", "ok!", "later ✌️"].randomElement()!, for: 1.4) }
        }
    }

    private func hold() {
        holding = true
        holdStart = (NSEvent.mouseLocation, window.frame.origin)
        walkTo = nil
        launches = []
        crouches = []
        pose.lift = 0
        liftV = 0
        shakes = []
        setMood(.held)
        emit(.bang, life: 0.7, x: 20, vy: 18)
        say(["whoa!", "wheee!", "where are we going?", "eep!"].randomElement()!, for: 1.4)
    }

    private func dragged() {
        guard let s = holdStart else { return }
        let p = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: s.origin.x + p.x - s.mouse.x, y: s.origin.y + p.y - s.mouse.y))
    }

    private func dropped() {
        holding = false
        holdStart = nil
        home = window.frame.origin
        UserDefaults.standard.set(NSStringFromPoint(home), forKey: "petOrigin")
        let t = CACurrentMediaTime()
        squash.v += 9
        emit(.dust, count: 4, spread: 30, life: 0.6, y: -Self.bodyH - 6, vy: 6, delay: 0)
        // Shaken hard: dizzy for a bit.
        if shakes.filter({ t - $0 < 1.4 }).count >= 4 {
            setMood(.dizzy, for: 2.8)
            say(["@_@", "the room is spinning…", "wobble wobble"].randomElement()!, for: 2.2)
        } else {
            setMood(.idle)
            if Double.random(in: 0...1) < 0.5 { say(["nice spot!", "ooh, new view", "here? ok!"].randomElement()!, for: 1.6) }
        }
    }

    private func appChanged(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app != .current, mood == .idle, !holding else { return }
        let t = CACurrentMediaTime()
        let toward: CGFloat = window.frame.midX > (window.screen?.frame.midX ?? 0) ? -1 : 1
        glance = (CGPoint(x: toward, y: 0.5), t + 1.4)
        guard t - lastQuip > 30, Double.random(in: 0...1) < 0.45 else { return }
        lastQuip = t
        say(Self.quip(for: app))
    }

    static func quip(for app: NSRunningApplication) -> String {
        let id = (app.bundleIdentifier ?? "").lowercased(), name = app.localizedName ?? "that"
        let table: [(String, [String])] = [
            ("xcode", ["code time 🛠", "no bugs pls 🐛"]),
            ("safari", ["what're we reading? 👀", "ooh, the internet"]),
            ("chrome", ["so many tabs…", "browsing 🌐"]),
            ("arc", ["browsing 🌐"]),
            ("music", ["♪ ♫ ♪", "is this a bop?"]),
            ("spotify", ["♪ ♫ ♪", "turn it up!"]),
            ("messages", ["who's that? 💬", "say hi from me!"]),
            ("whatsapp", ["gossip? 💬"]),
            ("mail", ["📬 mail!", "inbox zero?"]),
            ("terminal", ["hacker mode 😎", "sudo make me a sandwich"]),
            ("ghostty", ["hacker mode 😎"]),
            ("iterm", ["hacker mode 😎"]),
            ("finder", ["tidy time 🧹", "lost something?"]),
            ("figma", ["pretty pixels ✨"]),
            ("slack", ["work work 💼"]),
            ("discord", ["gamer moment 🎮"]),
            ("vscode", ["code time 🛠"]),
            ("notes", ["write it down ✏️"]),
            ("calendar", ["busy day? 📅"]),
            ("claude", ["oh hi, cousin 👋"]),
        ]
        for (key, lines) in table where id.contains(key) || name.lowercased().contains(key) { return lines.randomElement()! }
        return ["ooh, \(name)", "\(name)? cool", "hmm 🤔", "what's this?"].randomElement()!
    }

    // MARK: Every frame

    private func tick() {
        let t = CACurrentMediaTime()
        let dt = CGFloat(min(max(t - last, 0.001), 1.0 / 15))
        last = t
        let mouse = NSEvent.mouseLocation
        let body = bodyRect
        let over = holding || body.insetBy(dx: -4, dy: -4).contains(mouse)
        if window.ignoresMouseEvents == over { window.ignoresMouseEvents = !over }
        let moved = hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y)
        mouseSpeed = mouseSpeed * 0.8 + moved / dt * 0.2
        lastMouse = mouse

        // Away from the keyboard (checked twice a second): sleepy, then asleep.
        if t - lastIdleCheck > 0.5 {
            lastIdleCheck = t
            idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            let busy = model.isRunning || chat.panel.isVisible || holding
            if !busy, idleSeconds > 180, mood != .sleeping {
                setMood(.sleeping)
                brain.bubble = nil
            } else if !busy, idleSeconds > 75, mood == .idle {
                setMood(.sleepy)
                perform(.yawn, t)
            } else if (mood == .sleeping || mood == .sleepy), idleSeconds < 1 || busy {
                let wasAsleep = mood == .sleeping
                setMood(.idle)
                if wasAsleep {
                    perform(.startle, t)
                    say(["oh! you're back!", "i wasn't sleeping 😳", "welcome back ✨"].randomElement()!, at: t + 0.4)
                    act = Act(kind: .stretch, start: t + 0.8, duration: 1.8)
                }
            }
        }

        // The chat.
        let running = model.isRunning
        let count = model.chat.messages.count
        if count > lastCount, model.chat.messages.last?.role == .user {
            hop()
            if Double.random(in: 0...1) < 0.5 { say(["ooh!", "on it!", "hmm…", "ok ok!"].randomElement()!, for: 1.3) }
        } else if count == 0, lastCount > 0 {
            say("fresh start ✨", for: 1.6)
        }
        lastCount = count
        let draft = model.draft.utf8.count
        if draft != lastDraft { typedAt = t; lastDraft = draft }
        if running, !wasRunning, mood != .held { setMood(.thinking) }
        if !running, wasRunning {
            let failed = model.chat.messages.last.map { $0.role == .assistant && $0.error != nil && $0.error != "Stopped." } ?? false
            if failed {
                setMood(.sad, for: 3.2)
                emit(.sweat, life: 1.2, x: 26, y: -10, vy: -14)
                say(["oh no…", "that didn't work 😔", "oops"].randomElement()!, for: 2.2)
            } else {
                setMood(.happy, for: 2.6)
                hop(3, gap: 0.5)
                emit(.heart, count: 3, spread: 26, life: 1.6)
                emit(.sparkle, count: 4, spread: 34, life: 0.9, y: -20, vy: 40, delay: 0.08)
                if Double.random(in: 0...1) < 0.6 { say(["yay!", "done! ✨", "ta-da!", "hehe 💖"].randomElement()!, for: 1.8) }
            }
        }
        wasRunning = running

        // Moods running out, or settling on their own.
        if moodUntil > 0, t > moodUntil { setMood(.idle) }
        if mood == .thinking, !running { setMood(.idle) }
        if mood == .idle || mood == .listening {
            let typing = chat.panel.isVisible && t - typedAt < 2.5
            setMood(typing ? .listening : .idle)
        }

        // Petting: rest the cursor on it, or rub it.
        if over, !holding, mood == .idle || mood == .listening || mood == .love {
            if hoverSince == nil { hoverSince = t }
            rubbed += moved
            if (t - hoverSince! > 0.9 || rubbed > 260), t - lastLoved > 2.4 {
                lastLoved = t
                rubbed = 0
                setMood(.love, for: 2.2)
                emit(.heart, count: 3, spread: 22, life: 1.5)
                if Double.random(in: 0...1) < 0.5 { say(["hehe", "💕", "purr~", "more pets pls", "that tickles!"].randomElement()!, for: 1.5) }
            }
        } else if !over {
            hoverSince = nil
            rubbed = 0
        }

        // The cursor whizzing past: a little startle.
        let near = hypot(mouse.x - body.midX, mouse.y - body.midY)
        if mood == .idle, act == nil, near < 110, mouseSpeed > 2600, t - lastStartle > 8 {
            lastStartle = t
            perform(.startle, t)
        }

        // Held: the feet swing with the drag; shaking counts the turns.
        if holding {
            let x = mouse.x
            let vx = (x - lastDragX) / dt
            lastDragX = x
            dragVX = dragVX * 0.7 + vx * 0.3
            let dir: CGFloat = dragVX > 500 ? 1 : dragVX < -500 ? -1 : 0
            if dir != 0, dir != lastDragDir { shakes.append(t); lastDragDir = dir }
        } else {
            lastDragX = mouse.x
            dragVX *= 0.8
        }

        // Blinks, now and then a double one.
        if t > nextBlink {
            blinkAt = t
            nextBlink = t + Double.random(in: 2...6)
            if Double.random(in: 0...1) < 0.2 { nextBlink = t + 0.32 }
        }

        // Something to do now and then; sometimes a little walk.
        if act.map({ t > $0.start + $0.duration }) == true { act = nil }
        if t > nextAct {
            nextAct = t + Double.random(in: 5...14)
            if act == nil, walkTo == nil, launches.isEmpty {
                switch mood {
                case .idle:
                    if Double.random(in: 0...1) < 0.22 { wander() } else if Double.random(in: 0...1) < 0.25 { hop(Int.random(in: 1...2)) } else {
                        let kinds: [ActKind] = [.wiggle, .lookAround, .lookAround, .hum, .stretch, .dance, .sneeze, .peek, .nod]
                        perform(kinds.randomElement()!, t)
                    }
                case .sleepy: perform(.yawn, t)
                default: break
                }
            }
        }
        walk(t, dt)

        animate(t, dt, mouse: mouse)

        // Particles and the bubble wear off.
        if !brain.particles.isEmpty { brain.particles.removeAll { t - $0.born > $0.life } }
        if brain.bubble != nil, t > bubbleUntil { brain.bubble = nil }
        if mood == .sleeping, brain.particles.filter({ $0.kind == .z }).count < 3,
           !brain.particles.contains(where: { $0.kind == .z && t - $0.born < 0.9 }) {
            emit(.z, spread: 4, life: 2.6, x: 24, y: -6, vy: 22)
        }

        brain.pose = pose
        let still = mood == .sleeping && act == nil && pose.lift == 0 && walkTo == nil && !holding
        schedule(still ? 1.0 / 20 : 1.0 / 60)
    }

    // A few steps away from home and, next time, back.
    private func wander() {
        guard let v = window.screen?.visibleFrame else { return }
        let x = window.frame.origin.x
        var target = abs(x - home.x) > 20 ? home.x : home.x + CGFloat.random(in: 40...110) * (Bool.random() ? 1 : -1)
        target = min(max(target, v.minX - 40), v.maxX - Self.size.width + 40)
        walkTo = target
    }

    private func walk(_ t: Double, _ dt: CGFloat) {
        guard let to = walkTo, !holding else { return }
        guard mood == .idle || mood == .listening else { walkTo = nil; return }
        let o = window.frame.origin
        let dx = to - o.x
        if abs(dx) < 1.5 { walkTo = nil; return }
        let step = min(abs(dx), 46 * dt) * (dx > 0 ? 1 : -1)
        window.setFrameOrigin(NSPoint(x: o.x + step, y: o.y))
        stepPhase += Double(dt) * 10
    }

    // Where every part wants to be for the mood and what it's doing; the
    // pose eases or springs there.
    private func animate(_ t: Double, _ dt: CGFloat, mouse: NSPoint) {
        let f = window.frame
        let eye = CGPoint(x: f.midX, y: f.minY + Self.floor + pose.lift + Self.bodyH * 0.55)
        var lookX: CGFloat, lookY: CGFloat
        var dx = mouse.x - eye.x, dy = mouse.y - eye.y
        if mood == .listening || (chat.panel.isVisible && t - typedAt < 4) {
            let c = chat.panel.frame
            dx = c.midX - eye.x
            dy = c.minY + 40 - eye.y
        }
        let dist = max(1, hypot(dx, dy))
        lookX = dx / max(dist, 150)
        lookY = dy / max(dist, 150)
        if let (p, until) = glance { if t < until { lookX = p.x; lookY = p.y } else { glance = nil } }

        var lid: CGFloat = 1, wide: CGFloat = dist < 150 ? 0.25 : 0, joy: CGFloat = 0, dizzy: CGFloat = 0
        var smile: CGFloat = 0.4, mouth: CGFloat = 0, blush: CGFloat = 0.35, brow: CGFloat = 0, browShow: CGFloat = 0
        var armL: CGFloat = 0, armR: CGFloat = 0, lean: CGFloat = 0, squash: CGFloat = 0
        var sproutBase: CGFloat = 0
        var breathe = CGFloat(sin(t * 2.4)) * 0.022

        switch mood {
        case .idle: break
        case .listening:
            lean = (dx > 0 ? 1 : -1) * 5
            smile = 0.55
            wide = 0.2
            lookY -= CGFloat(max(0, sin(t * 4.2))) * 0.25   // little nods
        case .thinking:
            lookX = CGFloat(sin(t * 0.8)) * 0.7
            lookY = 0.75
            browShow = 0.7; brow = -0.2
            smile = 0.05; mouth = 0.18 + 0.1 * CGFloat(abs(sin(t * 3)))
            lean = CGFloat(sin(t * 2.2)) * 5
            armL = 20; armR = 70 + CGFloat(sin(t * 5)) * 10   // hand on chin, tapping
            sproutBase = CGFloat(sin(t * 7)) * 14
            if Int(t * 1.4) % 5 == 0, !brain.particles.contains(where: { $0.kind == .note && t - $0.born < 1.2 }) {
                emit(.note, spread: 10, life: 1.6, x: 20, vy: 28)
            }
        case .happy:
            joy = 1; smile = 1; mouth = 0.6; blush = 0.75
            armL = 140 + CGFloat(sin(t * 15)) * 18; armR = 140 + CGFloat(sin(t * 15 + 1)) * 18
        case .sad:
            lid = 0.7; smile = -0.65; browShow = 1; brow = -1
            lookY = -0.55; lookX *= 0.3; armL = -6; armR = -6; squash = 0.06
            sproutBase = -18
        case .love:
            joy = 1; smile = 0.85; mouth = 0.2; blush = 1
            lean = CGFloat(sin(t * 3.2)) * 7
            armL = 45; armR = 45
        case .sleepy:
            lid = 0.32 + CGFloat(sin(t * 0.7)) * 0.08; smile = 0.12
            lean = CGFloat(sin(t * 0.9)) * 3; lookY = -0.3
            sproutBase = -12
        case .sleeping:
            lid = 0; smile = 0.15; mouth = 0.12 + 0.08 * CGFloat(sin(t * 1.3))
            lean = -7; lookX = 0; lookY = -0.4
            breathe = CGFloat(sin(t * 1.3)) * 0.05
            sproutBase = -32
        case .dizzy:
            dizzy = 1; smile = -0.15; mouth = 0.3
            lean = CGFloat(sin(t * 5)) * 11
            sproutBase = CGFloat(sin(t * 5 + 1)) * 20
        case .held:
            wide = 1; smile = 0.15; mouth = 0.5
            armL = 95; armR = 95
            lean = max(-20, min(20, -dragVX * 0.012))
        }

        // What it's doing now, blended over the mood by how far along it is.
        if let a = act, t >= a.start {
            let p = (t - a.start) / a.duration
            let e = bell(p)
            switch a.kind {
            case .wiggle:
                lean += CGFloat(sin(p * .pi * 7)) * 11 * (1 - CGFloat(p))
                smile = max(smile, 0.7); joy = max(joy, e)
            case .lookAround:
                lookX = CGFloat(sin(p * .pi * 2)) * 1.1; lookY = 0.2 * e
                lean += CGFloat(sin(p * .pi * 2)) * 4
            case .hum:
                smile = max(smile, 0.6); mouth = max(mouth, 0.15 + 0.15 * CGFloat(abs(sin(t * 6)))) ; lid = min(lid, 1 - 0.55 * e)
                lean += CGFloat(sin(t * 4)) * 5 * e
            case .stretch:
                armL = max(armL, 165 * e); armR = max(armR, 165 * e)
                squash -= 0.2 * e; lid = min(lid, 1 - 0.75 * e); mouth = max(mouth, 0.7 * e); smile = 0.2
            case .dance:
                lean += CGFloat(sin(p * .pi * 8)) * 13 * e
                armL = max(armL, 80 + CGFloat(sin(p * .pi * 8)) * 60); armR = max(armR, 80 - CGFloat(sin(p * .pi * 8)) * 60)
                joy = max(joy, e); smile = 0.9; mouth = max(mouth, 0.3)
            case .sneeze:
                if p < 0.62 {
                    let b = CGFloat(p / 0.62)
                    lean -= 9 * b; lid = min(lid, 1 - 0.6 * b); mouth = max(mouth, 0.55 * b); lookY = 0.5 * b
                } else {
                    if a.start + a.duration * 0.62 > t - Double(dt) * 1.5 {
                        self.squash.v += 10; self.lean.v += 300
                        emit(.sparkle, count: 5, spread: 30, life: 0.7, x: 0, y: -24, vy: 30, delay: 0)
                        say("achoo!", for: 1.1)
                    }
                    let r = CGFloat((p - 0.62) / 0.38)
                    lid = min(lid, 0.15 + r); smile = 0.3
                }
            case .yawn:
                mouth = max(mouth, 0.95 * e); lid = min(lid, 1 - 0.8 * e)
                armL = max(armL, 60 * e); armR = max(armR, 60 * e); squash -= 0.08 * e; smile = 0.1
            case .nod:
                lookY -= 0.5 * e; lean += 0
            case .startle:
                wide = max(wide, e); mouth = max(mouth, 0.5 * e); armL = max(armL, 110 * e); armR = max(armR, 110 * e)
            case .peek:
                let side: CGFloat = sin(Double(a.start) * 13) > 0 ? 1 : -1
                lean += side * 16 * e; lookX = side * e; lookY = 0.1; wide = max(wide, 0.4 * e)
            }
        }

        // Blink: shut for a moment.
        let b = t - blinkAt
        if b >= 0, b < 0.16 { lid = min(lid, CGFloat(abs(b - 0.08) / 0.08)) }

        // Walking: steps, a bounce, leaning into it, the face turned that way.
        var facing: CGFloat = 0, bob: CGFloat = 0, footL: CGFloat = 0, footR: CGFloat = 0
        if let to = walkTo {
            let dir: CGFloat = to > window.frame.origin.x ? 1 : -1
            facing = dir; lean += dir * 6
            bob = CGFloat(abs(sin(stepPhase))) * 3
            footL = CGFloat(max(0, sin(stepPhase))) * 5
            footR = CGFloat(max(0, -sin(stepPhase))) * 5
            armL = max(armL, 18 + CGFloat(sin(stepPhase)) * 16); armR = max(armR, 18 - CGFloat(sin(stepPhase)) * 16)
            lookX = dir * 0.8
        }

        // Jumps: crouch, take off, fly under gravity, land with a squash.
        if let c = crouches.first, t >= c { crouches.removeFirst(); self.squash.v += 5 }
        if let l = launches.first, t >= l, pose.lift <= 0.5, !holding {
            launches.removeFirst()
            liftV = mood == .happy ? 330 : 280
            self.squash.v -= 9
        }
        if holding {
            pose.lift = 0; liftV = 0
        } else if pose.lift > 0 || liftV > 0 {
            liftV -= 1500 * dt
            pose.lift += liftV * dt
            if pose.lift <= 0 {
                if liftV < -120 {
                    self.squash.v += min(16, -liftV * 0.035)
                    if liftV < -420 { emit(.dust, count: 3, spread: 28, life: 0.5, y: -Self.bodyH - 6, vy: 4, delay: 0) }
                }
                pose.lift = 0; liftV = 0
            }
        }
        let airborne = pose.lift > 0
        if airborne { armL = max(armL, 50); armR = max(armR, 50); footL = max(footL, 2); footR = max(footR, 2) }

        // Springs: the body's squash and lean, the arms, and the sprout,
        // which lags behind everything the body does.
        self.squash.step(to: squash + breathe + (airborne ? -0.06 : 0), k: 320, d: 15, dt: dt)
        self.lean.step(to: lean, k: 150, d: 13, dt: dt)
        self.armL.step(to: armL, k: 180, d: 16, dt: dt)
        self.armR.step(to: armR, k: 180, d: 16, dt: dt)
        swing.step(to: holding ? max(-35, min(35, -dragVX * 0.03)) : 0, k: 60, d: 4, dt: dt)
        sprout.step(to: sproutBase + self.lean.x * 0.6 - self.lean.v * 0.05 - liftV * 0.035, k: 110, d: 6, dt: dt)

        pose.time = t
        pose.squash = max(-0.32, min(0.36, self.squash.x))
        pose.lean = self.lean.x
        pose.armL = self.armL.x
        pose.armR = self.armR.x
        pose.swing = swing.x
        pose.sprout = sprout.x
        pose.bob = bob
        ease(&pose.footL, footL, 22, dt)
        ease(&pose.footR, footR, 22, dt)
        ease(&pose.facing, facing, 6, dt)
        ease(&pose.lookX, lookX, 12, dt)
        ease(&pose.lookY, lookY, 12, dt)
        // Lids shut fast and open a little slower.
        ease(&pose.lid, lid, lid < pose.lid ? 40 : 14, dt)
        ease(&pose.wide, wide, 10, dt)
        ease(&pose.joy, joy, 9, dt)
        ease(&pose.dizzy, dizzy, 6, dt)
        pose.spin += dt * 9 * pose.dizzy
        ease(&pose.smile, smile, 8, dt)
        ease(&pose.mouth, mouth, 12, dt)
        ease(&pose.blush, blush, 4, dt)
        ease(&pose.brow, brow, 8, dt)
        ease(&pose.browShow, browShow, 8, dt)
        ease(&pose.dangle, holding ? 1 : 0, 10, dt)
    }
}

// MARK: - Window and touch

final class PetWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// A tap opens the chat; a drag picks the pet up and moves it.
final class PetTouchView: NSView {
    var onTap: (() -> Void)?
    var onHold: (() -> Void)?
    var onDrag: (() -> Void)?
    var onDrop: (() -> Void)?
    private var start: NSPoint?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - start.x, p.y - start.y) > 3 {
            dragging = true
            onHold?()
        }
        if dragging { onDrag?() }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { onDrop?() } else { onTap?() }
        start = nil
        dragging = false
    }
}

// MARK: - Drawing

private enum PetInk {
    static let ink = Color(red: 0.22, green: 0.14, blue: 0.2)
    static let top = Color(red: 1.0, green: 0.86, blue: 0.87)
    static let bottom = Color(red: 0.99, green: 0.64, blue: 0.72)
    static let edge = Color(red: 0.86, green: 0.42, blue: 0.53)
    static let limb = Color(red: 0.98, green: 0.62, blue: 0.7)
    static let foot = Color(red: 0.93, green: 0.5, blue: 0.6)
    static let belly = Color(red: 1.0, green: 0.95, blue: 0.93)
    static let cheek = Color(red: 1.0, green: 0.42, blue: 0.55)
    static let mouth = Color(red: 0.62, green: 0.16, blue: 0.27)
    static let tongue = Color(red: 1.0, green: 0.55, blue: 0.62)
}

struct PetView: View {
    let brain: PetBrain

    var body: some View {
        let p = brain.pose
        let ground = PetController.floor + p.lift + p.bob
        ZStack(alignment: .bottom) {
            // The shadow: smaller and fainter the higher it is.
            let s = max(0.35, 1 - p.lift / 170)
            Ellipse()
                .fill(RadialGradient(colors: [.black.opacity(0.26 * Double(s) * Double(1 - p.dangle * 0.7)), .clear], center: .center, startRadius: 0, endRadius: 40))
                .frame(width: 92 * s, height: 16 * s)
                .offset(y: -PetController.floor + 8)

            PetCreature(p: p)
                .offset(y: -ground)

            ForEach(brain.particles) { particle in
                PetParticleView(particle: particle, time: p.time)
                    .offset(y: -(ground + PetController.bodyH + 14))
            }

            if let b = brain.bubble {
                PetSpeech(text: b.text)
                    .id(b.id)
                    .offset(y: -(ground + PetController.bodyH + 34))
                    .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: PetController.size.width, height: PetController.size.height, alignment: .bottom)
        .animation(.spring(duration: 0.35, bounce: 0.45), value: brain.bubble)
    }
}

struct PetCreature: View {
    let p: PetPose

    var body: some View {
        let w = PetController.bodyW, h = PetController.bodyH
        let sx = 1 + p.squash, sy = 1 - p.squash
        ZStack(alignment: .bottom) {
            // Feet: stepping, tucked in the air, swinging while held.
            ForEach([-1.0, 1.0], id: \.self) { side in
                let s = CGFloat(side)
                Ellipse()
                    .fill(LinearGradient(colors: [PetInk.limb, PetInk.foot], startPoint: .top, endPoint: .bottom))
                    .frame(width: 21, height: 11)
                    .rotationEffect(.degrees(Double(p.swing * (1 + s * 0.15) + s * 8 * p.dangle)), anchor: .top)
                    .offset(x: s * 18 * sx + p.swing * 0.25, y: -(side < 0 ? p.footL : p.footR) + p.dangle * 7)
            }

            ZStack {
                // Arms, behind the body, peeking out at its sides.
                ForEach([-1.0, 1.0], id: \.self) { side in
                    let s = CGFloat(side)
                    let raise = side < 0 ? p.armL : p.armR
                    Capsule()
                        .fill(LinearGradient(colors: [PetInk.limb, PetInk.foot], startPoint: .top, endPoint: .bottom))
                        .frame(width: 11, height: 23)
                        .rotationEffect(.degrees(Double(-s * (38 + raise))), anchor: .top)
                        .offset(x: s * (w / 2 - 2), y: 9)
                }

                PetBlob()
                    .fill(LinearGradient(colors: [PetInk.top, PetInk.bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(PetBlob().stroke(PetInk.edge.opacity(0.35), lineWidth: 1))
                    .overlay(PetBlob().inset(by: 1.5).stroke(.white.opacity(0.45), lineWidth: 1.2).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
                    .frame(width: w, height: h)

                // Belly and shine.
                Ellipse().fill(PetInk.belly.opacity(0.55))
                    .frame(width: w * 0.5, height: h * 0.32)
                    .offset(y: h * 0.31)
                Ellipse().fill(.white.opacity(0.55))
                    .frame(width: 17, height: 9)
                    .rotationEffect(.degrees(-28))
                    .offset(x: -w * 0.24, y: -h * 0.27)

                PetFace(p: p)
                    .offset(x: p.facing * 8 + p.lookX * 4, y: -4 - p.lookY * 3)

                PetSprout(p: p)
                    .offset(y: -h / 2 - 6)
            }
            .frame(width: w, height: h)
            .scaleEffect(x: sx, y: sy, anchor: .bottom)
            .offset(y: -5)
            .rotationEffect(.degrees(Double(p.lean)), anchor: .bottom)
        }
        .frame(width: 140, height: 140, alignment: .bottom)
    }
}

struct PetFace: View {
    let p: PetPose

    var body: some View {
        ZStack {
            // Cheeks.
            HStack(spacing: 30) {
                ForEach(0..<2, id: \.self) { _ in
                    Ellipse()
                        .fill(RadialGradient(colors: [PetInk.cheek.opacity(Double(p.blush) * 0.75), PetInk.cheek.opacity(0)], center: .center, startRadius: 0, endRadius: 8))
                        .frame(width: 15, height: 9)
                }
            }
            .offset(y: 7)

            HStack(spacing: 17) {
                PetEye(p: p, side: -1)
                PetEye(p: p, side: 1)
            }
            .offset(x: p.lookX * 1.5, y: -p.lookY * 1.5)

            // Brows, for worry and thought.
            HStack(spacing: 15) {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Capsule().fill(PetInk.ink.opacity(0.8))
                        .frame(width: 9, height: 2.2)
                        .rotationEffect(.degrees(side * Double(p.brow) * -22))
                }
            }
            .offset(y: -12 - p.wide * 2)
            .opacity(Double(p.browShow))

            PetMouth(p: p)
                .offset(y: 10)
        }
    }
}

struct PetEye: View {
    let p: PetPose
    let side: CGFloat

    var body: some View {
        let other = max(p.joy, p.dizzy)
        let open = min(1, max(0, (p.lid - 0.1) / 0.2))
        let size = 1 + p.wide * 0.28
        ZStack {
            ZStack {
                Ellipse().fill(PetInk.ink).frame(width: 9.5 * size, height: 12.5 * size)
                Circle().fill(.white).frame(width: 3.8, height: 3.8).offset(x: 1.6 * size, y: -2.8 * size)
                Circle().fill(.white.opacity(0.8)).frame(width: 1.7, height: 1.7).offset(x: -1.8 * size, y: 2.8 * size)
            }
            .scaleEffect(x: 1, y: max(0.08, p.lid), anchor: .center)
            .opacity(Double((1 - other) * open))

            PetArc(up: false)
                .stroke(PetInk.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .frame(width: 11, height: 5)
                .opacity(Double((1 - other) * (1 - open)))

            PetArc(up: true)
                .stroke(PetInk.ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .frame(width: 11, height: 6)
                .opacity(Double(p.joy * (1 - p.dizzy)))

            PetSpiral()
                .stroke(PetInk.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.radians(Double(p.spin * side)))
                .opacity(Double(p.dizzy))
        }
        .frame(width: 14, height: 16)
    }
}

struct PetMouth: View {
    let p: PetPose

    var body: some View {
        let open = min(1, max(0, (p.mouth - 0.05) / 0.12))
        ZStack {
            PetMouthLine(smile: p.smile)
                .stroke(PetInk.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 10, height: 6)
                .opacity(Double(1 - open))
            PetMouthOpen(smile: p.smile, open: p.mouth)
                .fill(PetInk.mouth)
                .overlay(alignment: .bottom) {
                    Ellipse().fill(PetInk.tongue)
                        .frame(width: 6 + p.mouth * 3, height: 3 + p.mouth * 3)
                        .offset(y: -1)
                        .opacity(Double(min(1, max(0, (p.mouth - 0.25) * 3))))
                }
                .clipShape(PetMouthOpen(smile: p.smile, open: p.mouth))
                .frame(width: 10 + p.mouth * 4, height: 3 + p.mouth * 11)
                .opacity(Double(open))
        }
        .frame(width: 18, height: 16)
    }
}

// The body: a gumdrop, rounder on top, wide and soft at the bottom.
struct PetBlob: InsettableShape {
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> PetBlob { PetBlob(inset: inset + amount) }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        var p = Path()
        p.move(to: CGPoint(x: x + w * 0.5, y: y + h))
        p.addCurve(to: CGPoint(x: x, y: y + h * 0.6), control1: CGPoint(x: x + w * 0.16, y: y + h), control2: CGPoint(x: x, y: y + h * 0.88))
        p.addCurve(to: CGPoint(x: x + w * 0.5, y: y), control1: CGPoint(x: x, y: y + h * 0.24), control2: CGPoint(x: x + w * 0.22, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + h * 0.6), control1: CGPoint(x: x + w * 0.78, y: y), control2: CGPoint(x: x + w, y: y + h * 0.24))
        p.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h), control1: CGPoint(x: x + w, y: y + h * 0.88), control2: CGPoint(x: x + w * 0.84, y: y + h))
        p.closeSubpath()
        return p
    }
}

// ∩ when up, ∪ when not.
struct PetArc: Shape {
    var up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if up {
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY + r.height))
        }
        return p
    }
}

// A closed mouth: a curve, smiling or frowning.
struct PetMouthLine: Shape {
    var smile: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let mid = r.midY - smile * r.height * 0.4
        p.move(to: CGPoint(x: r.minX, y: mid))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: mid), control: CGPoint(x: r.midX, y: mid + smile * r.height * 1.3))
        return p
    }
}

// An open mouth: wide and smiling, a round "o", or a frown.
struct PetMouthOpen: Shape {
    var smile: CGFloat
    var open: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let s = max(0, smile)
        let top = r.minY + r.height * 0.2 * (1 - s)
        p.move(to: CGPoint(x: r.minX, y: top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: top), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.4 * (1 - s)))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: top), control: CGPoint(x: r.midX, y: r.maxY + r.height * (0.6 + 0.4 * s) + min(0, smile) * r.height * 0.6))
        p.closeSubpath()
        return p
    }
}

struct PetSpiral: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let turns = 2.2, steps = 48
        for i in 0...steps {
            let a = Double(i) / Double(steps) * turns * 2 * .pi
            let rad = CGFloat(Double(i) / Double(steps)) * r.width / 2
            let pt = CGPoint(x: c.x + rad * CGFloat(cos(a)), y: c.y + rad * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

struct PetSprout: View {
    let p: PetPose

    var body: some View {
        let flutter = CGFloat(sin(p.time * 3.1)) * 4
        ZStack(alignment: .bottom) {
            Capsule().fill(Color(red: 0.36, green: 0.68, blue: 0.4)).frame(width: 2.6, height: 13)
            Ellipse().fill(LinearGradient(colors: [Color(red: 0.55, green: 0.88, blue: 0.52), Color(red: 0.38, green: 0.74, blue: 0.42)], startPoint: .top, endPoint: .bottom))
                .frame(width: 14, height: 7.5)
                .rotationEffect(.degrees(Double(-28 - flutter)), anchor: .trailing)
                .offset(x: -7, y: -10)
            Ellipse().fill(LinearGradient(colors: [Color(red: 0.6, green: 0.9, blue: 0.55), Color(red: 0.4, green: 0.76, blue: 0.44)], startPoint: .top, endPoint: .bottom))
                .frame(width: 14, height: 7.5)
                .rotationEffect(.degrees(Double(28 + flutter)), anchor: .leading)
                .offset(x: 7, y: -11)
        }
        .frame(width: 30, height: 24, alignment: .bottom)
        .rotationEffect(.degrees(Double(p.sprout)), anchor: .bottom)
    }
}

struct PetParticleView: View {
    let particle: PetParticle
    let time: Double

    var body: some View {
        let age = time - particle.born
        let k = age / particle.life
        if k >= 0, k <= 1 {
            let fadeIn = min(1, k * 7), fadeOut = 1 - pow(k, 2.2)
            let pop = particle.kind == .sparkle || particle.kind == .bang ? 0.6 + 0.6 * bell(min(1, k * 2)) : 1
            let wobble = particle.kind == .heart || particle.kind == .note || particle.kind == .z ? CGFloat(sin(age * 5 + Double(particle.id))) * 5 : 0
            symbol(k)
                .scaleEffect(pop)
                .opacity(fadeIn * fadeOut)
                .offset(x: particle.x + particle.vx * CGFloat(age) + wobble,
                        y: -(particle.y + particle.vy * CGFloat(age)))
        }
    }

    @ViewBuilder private func symbol(_ k: Double) -> some View {
        switch particle.kind {
        case .heart:
            Image(systemName: "heart.fill").font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.38, blue: 0.55))
        case .note:
            Image(systemName: ["music.note", "music.quarternote.3"][particle.id % 2]).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.55, green: 0.45, blue: 0.9))
        case .z:
            Text("z").font(.system(size: 10 + k * 9, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.45, green: 0.5, blue: 0.9))
        case .sparkle:
            Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(Color(red: 1, green: 0.78, blue: 0.25))
        case .sweat:
            Image(systemName: "drop.fill").font(.system(size: 9)).foregroundStyle(Color(red: 0.5, green: 0.75, blue: 1))
        case .bang:
            Text("!").font(.system(size: 18, weight: .black, design: .rounded)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.2))
        case .question:
            Text("?").font(.system(size: 17, weight: .black, design: .rounded)).foregroundStyle(Color(red: 0.45, green: 0.5, blue: 0.9))
        case .dust:
            Circle().fill(Color.gray.opacity(0.35)).frame(width: 5 + k * 8, height: 5 + k * 8)
        }
    }
}

struct PetSpeech: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.8))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white))
            PetTail().fill(.white).frame(width: 10, height: 5)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .fixedSize()
    }
}

struct PetTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// `TapChat --render-pet <folder>`: the pet in each mood as PNGs, without
// starting the app (to check the drawing).
enum PetRender {
    @MainActor static func run(_ folder: String) {
        var base = PetPose(); base.time = 1
        func with(_ f: (inout PetPose) -> Void) -> PetPose { var p = base; f(&p); return p }
        let poses: [(String, PetPose)] = [
            ("idle", base),
            ("look", with { $0.lookX = 0.9; $0.lookY = 0.5; $0.wide = 0.25 }),
            ("happy", with { $0.joy = 1; $0.smile = 1; $0.mouth = 0.6; $0.blush = 0.75; $0.armL = 140; $0.armR = 150; $0.lift = 30; $0.squash = -0.08 }),
            ("love", with { $0.joy = 1; $0.smile = 0.85; $0.mouth = 0.2; $0.blush = 1; $0.lean = 7; $0.armL = 45; $0.armR = 45 }),
            ("thinking", with { $0.lookX = 0.5; $0.lookY = 0.75; $0.browShow = 0.7; $0.brow = -0.2; $0.smile = 0.05; $0.mouth = 0.22; $0.armR = 75; $0.armL = 20; $0.sprout = 12 }),
            ("sad", with { $0.lid = 0.7; $0.smile = -0.65; $0.browShow = 1; $0.brow = -1; $0.lookY = -0.55; $0.squash = 0.06; $0.sprout = -18 }),
            ("sleepy", with { $0.lid = 0.32; $0.smile = 0.12; $0.lookY = -0.3; $0.sprout = -12 }),
            ("sleeping", with { $0.lid = 0; $0.smile = 0.15; $0.mouth = 0.16; $0.lean = -7; $0.lookY = -0.4; $0.sprout = -32 }),
            ("dizzy", with { $0.dizzy = 1; $0.spin = 2; $0.smile = -0.15; $0.mouth = 0.3; $0.lean = 9 }),
            ("held", with { $0.wide = 1; $0.mouth = 0.5; $0.smile = 0.15; $0.armL = 95; $0.armR = 95; $0.dangle = 1; $0.swing = 18; $0.lean = -8 }),
            ("stretch", with { $0.armL = 165; $0.armR = 165; $0.squash = -0.2; $0.lid = 0.25; $0.mouth = 0.7; $0.smile = 0.2 }),
            ("yawn", with { $0.mouth = 0.95; $0.lid = 0.2; $0.armL = 60; $0.armR = 60; $0.smile = 0.1 }),
            ("walk", with { $0.facing = 1; $0.lean = 6; $0.bob = 3; $0.footL = 5; $0.lookX = 0.8; $0.armL = 30; $0.armR = 8 }),
            ("land", with { $0.squash = 0.3 }),
        ]
        for (name, pose) in poses {
            let brain = PetBrain()
            brain.pose = pose
            if name == "happy" {
                brain.particles = [PetParticle(id: 1, kind: .heart, born: 0.6, life: 1.6, x: -14, y: 0, vx: 0, vy: 34),
                                   PetParticle(id: 2, kind: .sparkle, born: 0.8, life: 0.9, x: 22, y: -10, vx: 0, vy: 40)]
                brain.bubble = PetBubble(id: 1, text: "done! ✨")
            }
            if name == "sleeping" { brain.particles = [PetParticle(id: 3, kind: .z, born: 0, life: 2.6, x: 24, y: -6, vx: 0, vy: 22)] }
            let r = ImageRenderer(content: PetView(brain: brain).background(Color(white: 0.92)))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
            }
        }
    }
}
