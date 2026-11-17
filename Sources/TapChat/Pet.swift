import AppKit
import SwiftUI

// The pet (Settings → Pet): a little creature on the screen. Tap it and the
// chat opens or closes; drag it (it hangs from the cursor on a rope), throw
// it to a corner, or drop it near an edge and it snaps there. It watches the
// cursor, listens while you type, thinks while the answer comes, cheers when
// it's done (or looks sorry), puts on shades for temporary chats, peeks at
// side chats, gasps at highlighted text, loves being petted, says "hey!" to a
// right-click (a second one opens its menu: Hide for a While walks it off
// the screen, sad), gets dizzy when shaken, and keeps itself busy when
// you're not around: butterflies, soap bubbles, naps, a look at the clock.
//
// Its motion is simulated, not keyframed: jumps under gravity, a springy
// body that squashes on landing, a sprout that lags behind every move, a
// pendulum on the rope, and a face whose every part eases toward where the
// mood wants it, so any state blends into any other. Every reaction has
// several animations and many lines, never the same one twice in a row.

// MARK: - What the drawing reads

struct PetPose: Equatable {
    var time: Double = 0
    var lift: CGFloat = 0        // height above the floor
    var bob: CGFloat = 0         // walking bounce
    var squash: CGFloat = 0      // + wide and flat, − tall and thin
    var lean: CGFloat = 0        // degrees, + to the right
    var turn: CGFloat = 0        // spinning round (radians)
    var facing: CGFloat = 0      // −1 left … 1 right: the face turns that way
    var lookX: CGFloat = 0, lookY: CGFloat = 0
    var lid: CGFloat = 1         // 1 open … 0 shut
    var wide: CGFloat = 0        // eyes bigger
    var joy: CGFloat = 0         // eyes become ^ ^
    var dizzy: CGFloat = 0       // spiral eyes
    var awe: CGFloat = 0         // sparkly eyes
    var spin: CGFloat = 0        // the spirals' turn
    var smile: CGFloat = 0.4     // −1 frown … 1 big smile
    var mouth: CGFloat = 0       // how open
    var tongue: CGFloat = 0      // sticking it out
    var blush: CGFloat = 0.35
    var brow: CGFloat = 0        // −1 worried … 1 cross
    var browShow: CGFloat = 0
    var shades: CGFloat = 0      // sunglasses (temporary chats)
    var armL: CGFloat = 0, armR: CGFloat = 0   // degrees raised
    var footL: CGFloat = 0, footR: CGFloat = 0 // each foot's lift
    var dangle: CGFloat = 0      // held up
    var swing: CGFloat = 0       // feet swinging while held
    var rope: CGFloat = 0        // hanging from the cursor by one hand, while dragged
    var ropeAngle: CGFloat = 0   // the pendulum's swing (radians, + body to the right)
    var juggle: Double = 0       // juggling: the balls' time, 0 when not
    var prop: PetProp?           // something it's playing with (a paper plane, a balloon…)
    var wink: CGFloat = 0        // its right eye shut
    var sproutScale: CGFloat = 1 // what's on its head, bigger after watering
    var carry: String?           // something brought back from off the screen, held up
    var skip: Double = 0         // skipping rope: the rope's turn, 0 when not
    var sprout: CGFloat = 0      // degrees
    var propeller: CGFloat = 0   // the sprout's leaves spinning (phase), 0 when still
    var butterfly: CGPoint?      // from the body's bottom centre, y up
    var soap: CGFloat = 0        // a soap bubble's size, 0 when none
    var soapRise: CGFloat = 0
}

// A thing in an idle scene, from the body's bottom centre (y up). `hand` is
// where a string starts (balloon, yo-yo); `angle` in degrees; `phase` 0…1.
struct PetProp: Equatable {
    enum Kind { case plane, ball, book, cloud, balloon, cup, yoyo, can }
    var kind: Kind
    var x: CGFloat, y: CGFloat
    var angle: CGFloat = 0
    var phase: CGFloat = 0
    var hand: CGPoint?
}

struct PetParticle: Identifiable {
    enum Kind { case heart, note, z, sparkle, sweat, bang, question, dust, tear, star }
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
    // Where the bubble goes: 0 above, −1 to the left, 1 to the right (clear of the chat).
    var bubbleSide: CGFloat = 0
    // Its look (Settings → Pet → Look): the default, or an imported pet.
    var look = PetLook.current
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

func bell(_ p: Double) -> CGFloat { p <= 0 || p >= 1 ? 0 : CGFloat(sin(p * .pi)) }

// Where every part wants to be this frame, before easing.
private struct PetTargets {
    var lookX: CGFloat = 0, lookY: CGFloat = 0, lid: CGFloat = 1, wide: CGFloat = 0
    var joy: CGFloat = 0, dizzy: CGFloat = 0, awe: CGFloat = 0
    var smile: CGFloat = 0.4, mouth: CGFloat = 0, tongue: CGFloat = 0, blush: CGFloat = 0.35
    var brow: CGFloat = 0, browShow: CGFloat = 0
    var armL: CGFloat = 0, armR: CGFloat = 0, lean: CGFloat = 0, squash: CGFloat = 0
    var sprout: CGFloat = 0, shades: CGFloat = 0, facing: CGFloat = 0
    var footL: CGFloat = 0, footR: CGFloat = 0, float: CGFloat = 0
    var propeller = false
}

final class PetController: NSObject {
    enum Mood { case idle, listening, thinking, happy, sad, love, sleepy, sleeping, dizzy, held, flying, awe, leaving, away }
    enum ActKind {
        case wiggle, lookAround, hum, stretch, dance, sneeze, yawn, nod, startle, peek, spin, sitKick, checkTime
        case meditate, butterfly, soap, trip, wave, giggle, boop, raspberry, rollEyes, salute, clap, doubleTake
        case purr, melt, shrug, sigh, bigJump, propeller, tapFoot, rubEyes, shadesOn, shadesOff, blushHide, cheer, lookBack, cross
        case hiccup, juggle, pushups, whistle, shiver, sproutPat, flex, readHistory, zoom
        case paperPlane, ball, book, raincloud, balloon, tea, yoyo
        case wink, scratchHead, sideStretch, pebbleKick, tinyBounce, lookUp, perk, showItem, peekIn, water, nap, skipRope
    }
    struct Act { let kind: ActKind; let start: Double; let duration: Double; let side: CGFloat; var fired = 0 }

    // Wide enough for a speech bubble beside the pet, not only above it.
    static let size = NSSize(width: 520, height: 330)
    static let floor: CGFloat = 16
    static let bodyW: CGFloat = 84, bodyH: CGFloat = 72
    // While dragged, it holds the cursor with its right hand, stretched up
    // over its head: here in the window (from the bottom left).
    static let hand = CGPoint(x: size.width / 2 + bodyW / 2 - 2, y: floor + 5 + bodyH / 2 + 48.5)
    // Hanging from that hand, its body settles to the side, under it.
    static let hangTilt = -atan(40.0 / 48.5)
    // Held, it's drawn this much higher, so hanging it stays inside its window.
    static let holdRaise: CGFloat = 34

    let window: PetWindow
    let brain = PetBrain()
    private let touch: PetTouchView
    private let model: ChatModel
    private let chat: PanelController
    private let toggleChat: () -> Void
    private let sideVisible: () -> Bool
    private let turnOff: () -> Void
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    // State.
    private var mood: Mood = .idle
    private var moodUntil: Double = 0
    private var act: Act?
    private var nextAct: Double = 0
    private var thinkStyle = 0
    private var pose = PetPose()
    private var last = CACurrentMediaTime()

    // Physics.
    private var liftV: CGFloat = 0
    private var float = PetSpring()
    private var squash = PetSpring()
    private var lean = PetSpring()
    private var sprout = PetSpring()
    private var armL = PetSpring(), armR = PetSpring()
    private var swing = PetSpring()
    private var launches: [(at: Double, v: CGFloat)] = []
    private var crouches: [Double] = []

    // Walking: the window moves toward walkTo (its origin's x).
    private var walkTo: CGFloat?
    private var walkSpeed: CGFloat = 46
    private var stepPhase: Double = 0
    private var moving: CGFloat = 0           // how fast it really moved, for the steps
    private var stuckSince: Double?
    private var tripped = false
    private var home = NSPoint.zero

    // Blinks and an idle gaze.
    private var nextBlink: Double = 0
    private var blinkAt: Double = -10
    private var gaze = CGPoint.zero
    private var nextGaze: Double = 0

    // Chat.
    private var wasRunning = false
    private var lastCount = 0
    private var lastDraft = 0
    private var typedAt: Double = -100
    private var lastChatId: UUID?
    private var wasTemporary = false
    private var wasSecret = false
    private var wasSide = false
    private var wasSelecting = false
    private var lastModel = ""
    private var lastEffort = ""
    private var wasHistory = false
    private var lastAttachments = 0
    private var lastSetting: Double = -100
    private var lastAwe: Double = -100

    // The cursor.
    private var lastMouse = NSPoint.zero
    private var mouseMovedAt: Double = 0
    private var mouseSpeed: CGFloat = 0
    private var hoverSince: Double?
    private var rubbed: CGFloat = 0
    private var lastLoved: Double = -100
    private var lastStartle: Double = -100
    private var lastBoop: Double = -100

    // Held: on a rope under the cursor, swinging like a pendulum.
    private var holding = false
    private var mouseVX: CGFloat = 0, mouseAX: CGFloat = 0
    private var ropeTheta: CGFloat = 0, ropeOmega: CGFloat = 0
    private var shakes: [Double] = []
    private var lastShakeDir: CGFloat = 0
    private var dragSamples: [(t: Double, p: NSPoint)] = []

    // Thrown or snapping to an edge: the window flies there on a spring.
    private var flyTo: NSPoint?
    private var flyV = CGVector.zero

    // Away (Hide for a While): off the screen until this, or the chat opens.
    private var awaySince: Double = 0
    private var awayEdge: CGFloat = 0

    private var nextScene: Double = CACurrentMediaTime() + 60
    // Outings: off the screen to fetch something, or to peek back in from the edge.
    private enum Outing { case fetch, peek }
    private var outing: Outing?
    private var outingStage = 0
    private var outingUntil: Double = 0
    private var outingOff: CGFloat = 0, outingPeek: CGFloat = 0, outingSide: CGFloat = 1
    private var forceWalk = false
    private var wasChatVisible = false
    private var lastIdleCheck: Double = 0
    private var idleSeconds: Double = 0
    private var lastQuip: Double = -100
    private var glance: (CGPoint, Double)?
    private var particleId = 0
    private var bubbleUntil: Double = 0
    private var bubbleId = 0
    private var talkUntil: Double = 0
    private var decks: [String: [Int]] = [:]
    private var lastLine: [String: Int] = [:]

    init(model: ChatModel, panel: PanelController, toggleChat: @escaping () -> Void,
         sideVisible: @escaping () -> Bool, turnOff: @escaping () -> Void) {
        self.model = model
        chat = panel
        self.toggleChat = toggleChat
        self.sideVisible = sideVisible
        self.turnOff = turnOff
        window = PetWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        touch = PetTouchView(frame: NSRect(origin: .zero, size: Self.size))
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
        host.frame = touch.bounds
        host.autoresizingMask = [.width, .height]
        touch.addSubview(host)
        touch.onTap = { [weak self] in self?.tapped() }
        touch.onHold = { [weak self] in self?.hold() }
        touch.onDrag = { [weak self] in self?.dragged() }
        touch.onDrop = { [weak self] in self?.dropped() }
        touch.onRightClick = { [weak self] e in self?.rightClicked(e) }
        window.contentView = touch
        home = startOrigin()
        window.setFrameOrigin(home)

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
        observers.append(NotificationCenter.default.addObserver(forName: PetLook.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.brain.look = PetLook.current
            self.decks = [:]
            self.hop()
            self.emit(.sparkle, count: 4, spread: 30, life: 0.8, y: -10, vy: 40, delay: 0.08)
        })
        lastCount = model.chat.messages.count
        lastDraft = model.draft.utf8.count
        lastChatId = model.chat.id
        lastModel = model.model
        lastEffort = model.effort
        wasHistory = model.showingHistory
        lastAttachments = model.draftAttachments.count
        wasTemporary = model.chat.isTemporary
        wasSecret = wasTemporary && panel.panel.isVisible
        pose.shades = wasSecret ? 1 : 0
        let t = CACurrentMediaTime()
        nextAct = t + 8
        nextBlink = t + 1.5
        // Arrives from above: falls, lands with a squash, says hi.
        pose.lift = 170
        liftV = -40
        sprout.x = -20
        say(line("hello", ["hi! tap me ✨", "hello hello!", "it's me! 👋", "hiii! tap me to chat", "reporting for duty! 🫡", "did someone call? ✨"]), for: 3, at: t + 0.55, must: true)
        // Shown only once its first frame is up in the air, so it never
        // flashes on the ground before falling in.
        brain.pose = pose
        host.layoutSubtreeIfNeeded()
        host.display()
        // Fades in as it falls, rather than popping up.
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        resume()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
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
        timer = nil
        schedule(1.0 / 60)
    }

    // 60 frames a second while it moves; asleep and still, 20; away, one
    // check every 2 s.
    private func schedule(_ every: TimeInterval) {
        guard timer == nil || every != interval else { return }
        timer?.invalidate()
        interval = every
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func startOrigin() -> NSPoint {
        // (Saved by the narrower window it had before as petOrigin: the same body spot.)
        let saved = UserDefaults.standard.string(forKey: "petSpot2").map(NSPointFromString)
            ?? UserDefaults.standard.string(forKey: "petSpot").map { NSPoint(x: NSPointFromString($0).x + 210 - Self.size.width / 2, y: NSPointFromString($0).y) }
            ?? UserDefaults.standard.string(forKey: "petOrigin").map { NSPoint(x: NSPointFromString($0).x + 120 - Self.size.width / 2, y: NSPointFromString($0).y) }
        if let p = saved {
            let body = NSPoint(x: p.x + Self.size.width / 2, y: p.y + Self.floor + 30)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -10, dy: -10).contains(body) }) { return p }
        }
        return edges(for: NSScreen.main ?? NSScreen.screens[0]).map { NSPoint(x: $0.right - 20, y: $0.bottom) } ?? .zero
    }

    // Window origins that put the body against each edge of a screen.
    private func edges(for screen: NSScreen) -> (left: CGFloat, right: CGFloat, bottom: CGFloat, top: CGFloat)? {
        let v = screen.visibleFrame
        let side = (Self.size.width - Self.bodyW) / 2
        return (v.minX - side + 6, v.maxX - Self.size.width + side - 6,
                v.minY - Self.floor + 6, v.maxY - Self.floor - Self.bodyH - 30)
    }

    private var screen: NSScreen {
        let c = NSPoint(x: window.frame.midX, y: window.frame.minY + Self.floor + 30)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? window.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // The body on screen (for clicks and petting).
    private var bodyRect: NSRect {
        let f = window.frame
        let w = Self.bodyW * (1 + pose.squash), h = Self.bodyH * (1 - pose.squash)
        return NSRect(x: f.midX - w / 2, y: f.minY + Self.floor + pose.lift + pose.bob - 6, width: w, height: h + 22)
    }

    // MARK: Lines and effects

    // A line from a deck: none comes again before the rest have been said.
    private func line(_ key: String, _ builtIn: [String], _ vars: [String: String] = [:]) -> String {
        // An imported pet's own lines for this moment, if it has some.
        var options = builtIn
        if let custom = brain.look.lines[key], !custom.isEmpty {
            options = custom.map { l in vars.reduce(l) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) } }
        }
        guard options.count > 1 else { return options.first ?? "" }
        var deck = decks[key] ?? []
        if deck.isEmpty {
            deck = Array(options.indices).shuffled()
            if deck.last == lastLine[key] { deck.swapAt(0, deck.count - 1) }
        }
        let i = deck.removeLast()
        decks[key] = deck
        lastLine[key] = i
        return options[min(i, options.count - 1)]
    }

    private func chance(_ p: Double) -> Bool { Double.random(in: 0...1) < p }

    // Optional remarks (most of them) only now and then: not within 9 s of
    // the last one. `must`: always (hello, goodbye, coming back).
    private var lastSpoke: Double = -100
    private func say(_ text: String, for seconds: Double = 2.4, at time: Double? = nil, must: Bool = false) {
        let now = CACurrentMediaTime()
        guard must || now - lastSpoke > 9 else { return }
        lastSpoke = now
        let start = time ?? now
        let delay = max(0, start - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.mood != .away else { return }
            self.bubbleId += 1
            self.brain.bubble = PetBubble(id: self.bubbleId, text: text)
            let now = CACurrentMediaTime()
            self.bubbleUntil = now + seconds
            // It talks: the mouth moves for a while, longer for longer lines.
            self.talkUntil = now + min(1.8, 0.3 + Double(text.count) * 0.055)
        }
    }

    private func emit(_ kind: PetParticle.Kind, count: Int = 1, spread: CGFloat = 22, life: Double = 1.6,
                      x: CGFloat = 0, y: CGFloat = 0, vx: CGFloat = 0, vy: CGFloat = 34, delay: Double = 0.18) {
        let t = CACurrentMediaTime()
        for i in 0..<count {
            particleId += 1
            brain.particles.append(PetParticle(id: particleId, kind: kind, born: t + Double(i) * delay, life: life,
                                               x: x + CGFloat.random(in: -spread...spread), y: y,
                                               vx: vx + CGFloat.random(in: -8...8), vy: vy * CGFloat.random(in: 0.8...1.2)))
        }
    }

    private func hop(_ count: Int = 1, gap: Double = 0.48, at time: Double? = nil, height: CGFloat = 280) {
        let t = time ?? CACurrentMediaTime()
        for i in 0..<count {
            crouches.append(t + Double(i) * gap)
            launches.append((t + Double(i) * gap + 0.09, height))
        }
    }

    private func setMood(_ m: Mood, for seconds: Double? = nil) {
        if m == .thinking, mood != .thinking { thinkStyle = Int.random(in: 0..<4) }
        mood = m
        moodUntil = seconds.map { CACurrentMediaTime() + $0 } ?? 0
    }

    private func duration(_ kind: ActKind) -> Double {
        switch kind {
        case .wiggle: 0.9
        case .lookAround: 2.4
        case .hum: 3.0
        case .stretch: 1.8
        case .dance: 2.6
        case .sneeze: 1.7
        case .yawn: 2.2
        case .nod: 0.8
        case .startle: 0.8
        case .peek: 2.0
        case .spin: 0.9
        case .sitKick: 4.0
        case .checkTime: 2.6
        case .meditate: 6.0
        case .butterfly: 7.5
        case .soap: 4.6
        case .trip: 2.2
        case .wave: 1.8
        case .giggle: 1.4
        case .boop: 0.9
        case .raspberry: 1.6
        case .rollEyes: 1.6
        case .salute: 1.4
        case .clap: 1.4
        case .doubleTake: 1.6
        case .purr: 2.2
        case .melt: 2.2
        case .shrug: 1.4
        case .sigh: 2.0
        case .bigJump: 1.4
        case .propeller: 3.2
        case .tapFoot: 2.4
        case .rubEyes: 1.8
        case .shadesOn, .shadesOff: 1.4
        case .blushHide: 1.8
        case .cheer: 2.0
        case .lookBack: 1.3
        case .cross: 1.4
        case .hiccup: 2.6
        case .juggle: 4.2
        case .pushups: 3.4
        case .whistle: 2.8
        case .shiver: 1.8
        case .sproutPat: 2.0
        case .flex: 1.7
        case .readHistory: 2.6
        case .zoom: 1.2
        case .paperPlane: 5.5
        case .ball: 5.0
        case .book: 6.5
        case .raincloud: 6.0
        case .balloon: 6.5
        case .tea: 4.6
        case .yoyo: 4.2
        case .wink: 0.9
        case .scratchHead: 1.8
        case .sideStretch: 1.8
        case .pebbleKick: 1.4
        case .tinyBounce: 1.5
        case .lookUp: 2.0
        case .perk: 0.9
        case .showItem: 2.8
        case .peekIn: 3.0
        case .water: 4.6
        case .nap: 7.0
        case .skipRope: 5.0
        }
    }

    private func perform(_ kind: ActKind, _ t: Double = CACurrentMediaTime(), side: CGFloat? = nil) {
        act = Act(kind: kind, start: t, duration: duration(kind), side: side ?? (Bool.random() ? 1 : -1))
        switch kind {
        case .hum:
            emit(.note, count: 3, spread: 14, life: 1.8, x: 18, vy: 30, delay: 0.7)
            if chance(0.5) { say(line("hum", ["♪ hm hm hmm ♪", "la la la", "♫ ♪", "doo be doo ♪", "♪ do re mi ♪", "*hums a tune*"]), for: 2.2) }
        case .dance: hop(2, gap: 1.1, at: t + 0.4); emit(.note, count: 2, spread: 24, life: 1.6, delay: 0.8)
        case .sneeze: say(line("presneeze", ["a… a…", "ah… ahh…", "hh… hhh…"]), for: 0.95)
        case .startle: emit(.bang, life: 0.9, x: 22, vy: 20); hop()
        case .yawn: say(line("yawn", ["*yawn*", "hwaaah…", "so sleepy…", "*big yawn*"]), for: 1.6, at: t + 0.4)
        case .spin: emit(.sparkle, count: 3, spread: 30, life: 0.8, y: -20, vy: 30, delay: 0.1)
        case .checkTime: say(timeLine(), for: 2.4, at: t + 0.9)
        case .meditate: say(line("ommm", ["ommm…", "inner peace…", "*breathes in*", "zen mode 🧘"]), for: 2.2)
        case .butterfly: say(line("butterfly", ["ooh, a butterfly! 🦋", "hello little friend", "a butterfly!!", "come here, butterfly!"]), for: 2, at: t + 0.6)
        case .soap: if chance(0.4) { say(line("soap", ["*blows a bubble*", "watch this!", "bubble time 🫧"]), for: 1.6) }
        case .trip: tripped = true
        case .giggle: emit(.heart, count: 1, life: 1.2)
        case .raspberry: emit(.dust, count: 2, spread: 8, life: 0.5, x: 6, y: -44, vy: 10, delay: 0.1)
        case .clap: emit(.sparkle, count: 2, spread: 24, life: 0.7, y: -30, vy: 20, delay: 0.3)
        case .doubleTake: break
        case .purr: emit(.heart, count: 2, spread: 18, life: 1.5, delay: 0.5)
        case .melt: if chance(0.35) { say(line("melt", ["mmm…", "*melts*", "so nice…"]), for: 1.6) }
        case .bigJump: hop(1, at: t + 0.2, height: 470); emit(.sparkle, count: 3, spread: 30, life: 0.8, y: -10, vy: 50, delay: 0.25)
        case .propeller: if chance(0.5) { say(line("prop", ["look, I can fly!", "whirrrr", "propeller mode 🚁", "wheee"]), for: 1.8) }
        case .tapFoot: if chance(0.4) { say(line("tap", ["*tap tap tap*", "waiting…", "hmm hm"]), for: 1.6) }
        case .rubEyes: if chance(0.5) { say(line("rub", ["*rubs eyes*", "where am I…", "mmh?"]), for: 1.6) }
        case .cheer: hop(2, gap: 0.6, at: t + 0.1); emit(.sparkle, count: 5, spread: 36, life: 0.9, y: -10, vy: 45, delay: 0.1)
        case .hiccup: for (i, at) in [0.15, 0.5, 0.82].enumerated() { hop(1, at: t + at * duration(.hiccup), height: 120 + CGFloat(i) * 20) }
            say(line("hic", ["hic!", "*hic*", "hic… sorry", "oh no, hiccups"]), for: 1.2, at: t + 0.3)
        case .juggle: if chance(0.5) { say(line("juggle", ["look, juggling!", "don't drop it…", "1, 2, 3!", "circus mode 🎪"]), for: 1.8) }
        case .pushups: say(line("pushups", ["1… 2… 3…", "gotta stay fit 💪", "huff… puff…", "leg day? no, push day"]), for: 2)
        case .whistle: emit(.note, count: 3, spread: 10, life: 1.6, x: 12, y: -30, vy: 26, delay: 0.6)
        case .shiver: say(line("brr", ["brrr 🥶", "chilly in here…", "*shivers*"]), for: 1.4)
        case .sproutPat: if chance(0.5) { say(line("sprout", ["still growing 🌱", "my little leaf ✨", "*pats sprout*", "needs water?"]), for: 1.6) }
        case .flex: emit(.sparkle, count: 2, spread: 30, life: 0.7, y: -20, vy: 20, delay: 0.2)
        case .zoom: emit(.dust, count: 3, spread: 6, life: 0.5, x: -30, y: -Self.bodyH, vx: -30, vy: 4, delay: 0.08)
        case .paperPlane: if chance(0.3) { say(line("plane", ["fly, little plane! ✈️", "watch this throw", "whoosh~"]), for: 1.6, at: t + 1.2) }
        case .ball: if chance(0.3) { say(line("ball", ["catch!", "boing boing ⚽️", "play with me!"]), for: 1.4) }
        case .book: if chance(0.3) { say(line("book", ["*reading* 📖", "ooh, plot twist", "just one more page…"]), for: 1.8, at: t + 1.5) }
        case .raincloud: if chance(0.4) { say(line("cloud", ["hey! go rain somewhere else 🌧", "why me?!", "my own little storm…"]), for: 1.8, at: t + 1.8) }
        case .balloon: if chance(0.3) { say(line("balloon", ["my balloon! 🎈", "bye balloon…", "I let go 😮"]), for: 1.6, at: t + 5) }
        case .tea: if chance(0.35) { say(line("tea", ["ahh ☕", "tea time~", "*sip*"]), for: 1.4, at: t + 2) }
        case .yoyo: if chance(0.3) { say(line("yoyo", ["walk the dog!", "up and down~", "yo-yo time"]), for: 1.4) }
        case .scratchHead: emit(.question, life: 1.2, x: 18, vy: 20)
        case .pebbleKick: break
        case .tinyBounce: for i in 0..<3 { hop(1, at: t + Double(i) * 0.42, height: 130) }
        case .lookUp: if chance(0.25) { say(line("lookup", ["is that a bird? 🐦", "nice sky today", "hmm, clouds"]), for: 1.6) }
        case .perk:
            sprout.v += 420
            emit(.sparkle, count: 3, spread: 18, life: 0.7, x: 26 * (side ?? 1), y: -14, vy: 30, delay: 0.06)
        case .showItem:
            emit(.sparkle, count: 5, spread: 30, life: 0.9, y: 6, vy: 40, delay: 0.08)
            say(line("found", ["look what I found!", "for you! 💝", "ta-da!", "found it!", "a gift 🎁", "treasure!"]), for: 2)
        case .peekIn: if chance(0.6) { say(line("peekin", ["peekaboo!", "👀", "is it safe?", "hi again!", "boo!"]), for: 1.6, at: t + 0.4) }
        case .water: if chance(0.3) { say(line("water", ["gotta stay hydrated 🌱", "grow, little leaf!", "*splish*"]), for: 1.6, at: t + 1) }
        case .nap: if chance(0.3) { say(line("nap", ["just a quick nap…", "5 minutes… zzz", "*nods off*"]), for: 1.6) }
        case .skipRope: for i in 0..<7 { hop(1, at: t + 0.22 + Double(i) * 0.62, height: 210) }
        default: break
        }
    }

    private func fire(_ bit: Int, _ when: Bool) -> Bool {
        guard when, var a = act, a.fired & bit == 0 else { return false }
        a.fired |= bit
        act = a
        return true
    }

    private func timeLine() -> String {
        let c = Calendar.current, now = Date()
        let h = c.component(.hour, from: now), wd = c.component(.weekday, from: now)
        let time = now.formatted(date: .omitted, time: .shortened)
        var lines = ["it's \(time) already?!", "\(time)… time flies ⏰", "*checks watch* \(time)"]
        if h < 5 || h >= 23 { lines += ["it's \(time)… shouldn't we sleep? 🌙", "night owl mode 🦉"] }
        else if h < 11 { lines += ["good morning ☀️", "breakfast time? 🥐"] }
        else if h < 14 { lines += ["lunch soon? 🍙", "midday already!"] }
        else if h < 18 { lines += ["afternoon snack time? 🍪", "still \(time)…"] }
        else { lines += ["evening already 🌆", "dinner time? 🍝"] }
        if wd == 6 { lines.append("it's friday!! 🎉") }
        if wd == 1 || wd == 7 { lines.append("weekend vibes 😎") }
        return line("time", lines, ["time": time])
    }

    // MARK: Input

    private func tapped() {
        let t = CACurrentMediaTime()
        guard mood != .leaving, mood != .flying else { return }
        if mood == .sleeping || mood == .sleepy {
            wake(t)
            return
        }
        let opening = !chat.panel.isVisible
        toggleChat()
        if opening {
            switch Int.random(in: 0..<4) {
            case 0: hop()
            case 1: perform(.wave, t)
            case 2: perform(.nod, t)
            default: squash.v -= 6
            }
            if chance(0.4) { say(line("open", ["what's up?", "ask me anything!", "hiii", "✨", "yes?", "at your service!", "ooh, a question?", "I'm listening 👂", "go on, ask!", "what are we wondering?"]), for: 1.6) }
        } else {
            squash.v += 4
            if chance(0.35) { perform(.wave, t) }
            if chance(0.35) { say(line("close", ["bye bye 👋", "ok!", "later ✌️", "see ya", "👋", "byeee", "call me anytime!", "done already?"]), for: 1.4) }
        }
    }

    private func wake(_ t: Double) {
        setMood(.idle)
        switch Int.random(in: 0..<3) {
        case 0:
            perform(.startle, t)
            act = Act(kind: .stretch, start: t + 0.8, duration: duration(.stretch), side: 1)
        case 1:
            perform(.rubEyes, t)
        default:
            perform(.yawn, t)
        }
        say(line("wake", ["oh! you're back!", "i wasn't sleeping 😳", "welcome back ✨", "*yawn* hi", "five more minutes…",
                          "I was just resting my eyes", "huh? what'd I miss?", "mmh… hi 😴", "I'm up! I'm up!"]), at: t + 0.45)
    }

    private func rightClicked(_ event: NSEvent) {
        let t = CACurrentMediaTime()
        guard mood != .leaving, mood != .flying, !holding else { return }
        // A second right-click soon after: its menu.
        if t - lastBoop < 4 {
            lastBoop = -100
            let menu = NSMenu()
            menu.addItem(withTitle: "Hide for a While", action: #selector(hideForAWhile), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Turn Off Pet", action: #selector(turnOffPet), keyEquivalent: "").target = self
            NSMenu.popUpContextMenu(menu, with: event, for: touch)
            return
        }
        lastBoop = t
        if mood == .sleeping || mood == .sleepy { wake(t); return }
        let kinds: [ActKind] = [.boop, .giggle, .rollEyes, .raspberry, .spin, .startle, .cross, .blushHide]
        let names = kinds.map { "\($0)" }
        let kind = kinds[names.firstIndex(of: line("boopAct", names)) ?? 0]
        perform(kind, t)
        let text: String = switch kind {
        case .raspberry: line("boopRasp", ["pffft 😛", "blehh 😝", "thpthpth"])
        case .cross: line("boopCross", ["hey!", "rude! 😤", "what's that for?!", "excuse me??", "watch it!"])
        case .blushHide: line("boopShy", ["eep! 🙈", "not in front of everyone…", "*hides*", "s-stop it 😳"])
        case .rollEyes: line("boopRoll", ["really? 🙄", "ugh, again?", "very funny.", "mhm. sure."])
        default: line("boop", ["boop!", "hehe", "beep boop", "that's my nose! (I think)", "*squeak*", "ow! jk", "again?", "boop boop!", "hey there 👀", "that tickles!"])
        }
        say(text, for: 1.6)
    }

    @objc private func hideForAWhile() {
        let t = CACurrentMediaTime()
        walkTo = nil
        flyTo = nil
        setMood(.leaving)
        let v = screen.frame
        // Off the nearest side.
        let left = window.frame.midX - v.minX < v.maxX - window.frame.midX
        awayEdge = left ? v.minX - Self.size.width - 10 : v.maxX + 10
        perform(chance(0.5) ? .wave : .sigh, t, side: 1)
        emit(.tear, count: 2, spread: 10, life: 1.2, x: 0, y: -26, vy: -20, delay: 0.5)
        say(line("bye", ["ok… bye 🥺", "I'll be back! 👋", "see you soon…", "fine, I'll go… 😢", "don't forget me!",
                         "going for a walk…", "miss me, ok?", "*sniff* bye", "I'll be right outside…", "call me if you need me 🥲"]), for: 2.6, must: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in
            guard let self, self.mood == .leaving else { return }
            self.walkSpeed = 64
            self.walkTo = self.awayEdge
            if self.chance(0.5) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                    guard let self, self.mood == .leaving else { return }
                    self.perform(.lookBack, CACurrentMediaTime())
                    self.say(self.line("bye2", ["…bye", "*waves*", "🥺", "bye for real…"]), for: 1.3)
                }
            }
        }
    }

    @objc private func turnOffPet() {
        say(line("off", ["goodnight 💤", "bye! ✨", "see you next time"]), for: 1, must: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.turnOff() }
    }

    private func comeBack() {
        let t = CACurrentMediaTime()
        window.setFrameOrigin(NSPoint(x: awayEdge, y: home.y))
        window.orderFrontRegardless()
        setMood(.idle)
        walkSpeed = 70
        walkTo = home.x
        resume()
        say(line("back", ["I'm back! ✨", "missed me?", "hiii again!", "did you miss me? 🥺", "back from my walk!",
                          "I brought nothing, but hi!", "guess who's back", "the walk was nice!"]), for: 2.4, at: t + 0.4, must: true)
    }

    private func hold() {
        holding = true
        outing = nil
        forceWalk = false
        let m = NSEvent.mouseLocation, o = window.frame.origin
        grabStart = CGPoint(x: m.x - o.x, y: m.y - o.y - Self.holdRaise * pose.rope)
        grab = 0
        mouseVX = 0; mouseAX = 0
        ropeTheta = 0; ropeOmega = 0
        walkTo = nil
        flyTo = nil
        launches = []
        crouches = []
        pose.lift = 0
        liftV = 0
        shakes = []
        dragSamples = []
        setMood(.held)
        emit(.bang, life: 0.7, x: 20, vy: 18)
        say(line("hold", ["whoa!", "wheee!", "where are we going?", "eep!", "up we go!", "hold on tight!", "I'm flying!",
                          "careful!!", "got your hand!", "adventure time!", "don't let go!"]), for: 1.4)
    }

    // Held: where the cursor is on the pet moves, over the grab, from where
    // it was clicked to its raised hand; the body is drawn raised as much.
    private var grabStart = CGPoint.zero
    private var grab: CGFloat = 0
    private func placeHeld(_ m: NSPoint) {
        let e = 1 - pow(1 - grab, 3)
        let cx = grabStart.x + (Self.hand.x - grabStart.x) * e
        let cy = grabStart.y + (Self.hand.y - grabStart.y) * e
        window.setFrameOrigin(NSPoint(x: m.x - cx, y: m.y - cy - Self.holdRaise * e))
        pose.rope = e
    }

    private func dragged() {
        placeHeld(NSEvent.mouseLocation)
        dragSamples.append((CACurrentMediaTime(), window.frame.origin))
        if dragSamples.count > 10 { dragSamples.removeFirst() }
    }

    private func dropped() {
        holding = false
        let t = CACurrentMediaTime()
        // Let go exactly where it hangs: the window moved so the body stays put
        // upright, and the tilt carried into its lean, which springs back.
        do {
            let e = pose.rope, phi = Double(pose.ropeAngle)
            let pivot = CGPoint(x: Self.hand.x, y: Self.hand.y + Self.holdRaise * e)
            let dx = Self.size.width / 2 - pivot.x, dy = Self.floor + Self.holdRaise * e - pivot.y
            let bx = pivot.x + dx * CGFloat(cos(phi)) + dy * CGFloat(sin(phi))
            let by = pivot.y - dx * CGFloat(sin(phi)) + dy * CGFloat(cos(phi))
            let o = window.frame.origin
            window.setFrameOrigin(NSPoint(x: o.x + bx - Self.size.width / 2, y: o.y + by - Self.floor))
            lean.x = CGFloat(phi * 180 / .pi)
            lean.v = ropeOmega * 57
            pose.rope = 0
            pose.ropeAngle = 0
            ropeTheta = 0
        }
        // How fast it was going when let go (the last ~0.1 s).
        var v = CGVector.zero
        if let lastS = dragSamples.last, let first = dragSamples.first(where: { lastS.t - $0.t <= 0.1 }), lastS.t - first.t > 0.01 {
            v = CGVector(dx: (lastS.p.x - first.p.x) / (lastS.t - first.t), dy: (lastS.p.y - first.p.y) / (lastS.t - first.t))
        }
        if t - (dragSamples.last?.t ?? 0) > 0.08 { v = .zero }
        let shaken = shakes.filter { t - $0 < 1.4 }.count >= 4
        // Where it goes: thrown, a bit further; near an edge or corner, onto it.
        let o = window.frame.origin
        let speed = hypot(v.dx, v.dy)
        var target = speed > 900 ? NSPoint(x: o.x + v.dx * 0.3, y: o.y + v.dy * 0.3) : o
        if let e = edges(for: screen) {
            target.x = min(max(target.x, e.left), e.right)
            target.y = min(max(target.y, e.bottom), e.top)
            let magnet: CGFloat = 90
            if target.x - e.left < magnet { target.x = e.left } else if e.right - target.x < magnet { target.x = e.right }
            if target.y - e.bottom < magnet { target.y = e.bottom } else if e.top - target.y < magnet { target.y = e.top }
        }
        if hypot(target.x - o.x, target.y - o.y) > 3 {
            flyTo = target
            flyStart = t
            flyV = CGVector(dx: max(-3000, min(3000, v.dx)), dy: max(-3000, min(3000, v.dy)))
            setMood(.flying)
            if speed > 900 { say(line("throw", ["wheeeee!", "yeet!", "aaaaa!", "zoom!", "whooosh", "to infinity! 🚀"]), for: 1.2) }
        } else {
            // Let go in place: a little drop.
            window.setFrameOrigin(NSPoint(x: o.x, y: o.y - 10))
            pose.lift = 10
            liftV = 0
            landed(shaken: shaken)
        }
        dizzyAfterFlight = shaken
    }

    private var dizzyAfterFlight = false

    private func landed(shaken: Bool) {
        home = window.frame.origin
        UserDefaults.standard.set(NSStringFromPoint(home), forKey: "petSpot2")
        emit(.dust, count: 4, spread: 30, life: 0.6, y: -Self.bodyH - 6, vy: 6, delay: 0)
        if shaken {
            setMood(.dizzy, for: 2.8)
            emit(.star, count: 3, spread: 20, life: 1.6, y: 4, vy: 6, delay: 0.25)
            say(line("dizzy", ["@_@", "the room is spinning…", "wobble wobble", "whoa… whoa…", "too much spin", "I see stars ✨", "which way is up?"]), for: 2.2)
        } else {
            setMood(.idle)
            if chance(0.45) { say(line("drop", ["nice spot!", "ooh, new view", "here? ok!", "home sweet home", "cozy!", "I like it here", "*lands gracefully*", "stuck the landing!"]), for: 1.6) }
        }
    }

    private func appChanged(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app != .current, mood == .idle, !holding else { return }
        let t = CACurrentMediaTime()
        let toward: CGFloat = window.frame.midX > screen.frame.midX ? -1 : 1
        glance = (CGPoint(x: toward, y: 0.5), t + 1.4)
        guard t - lastQuip > 30, chance(0.45) else { return }
        lastQuip = t
        say(quip(for: app))
    }

    private func quip(for app: NSRunningApplication) -> String {
        let id = (app.bundleIdentifier ?? "").lowercased(), name = app.localizedName ?? "that"
        let table: [(String, [String])] = [
            ("xcode", ["code time 🛠", "no bugs pls 🐛", "compile, compile!", "swift and steady"]),
            ("safari", ["what're we reading? 👀", "ooh, the internet", "surfing! 🏄"]),
            ("chrome", ["so many tabs…", "browsing 🌐"]),
            ("arc", ["browsing 🌐", "fancy browser ✨"]),
            ("music", ["♪ ♫ ♪", "is this a bop?", "music! 🎶"]),
            ("spotify", ["♪ ♫ ♪", "turn it up!", "what are we listening to?"]),
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
            ("photos", ["ooh, pictures! 📸"]),
            ("claude", ["another chat? 👀", "ooh, Claude"]),
            ("chatgpt", ["hey! I'm right here 😤", "cheating on me? 👀"]),
        ]
        if brain.look.lines["app"] == nil {
            for (key, lines) in table where id.contains(key) || name.lowercased().contains(key) { return line("app-" + key, lines) }
        }
        return line("app", ["ooh, \(name)", "\(name)? cool", "hmm 🤔", "what's this?", "\(name)! nice"], ["app": name])
    }

    // MARK: Every frame

    private func tick() {
        let t = CACurrentMediaTime()
        let dt = CGFloat(min(max(t - last, 0.001), 1.0 / 15))
        last = t

        // Away: only waits to come back (after half an hour, or when the chat opens).
        if mood == .away {
            if t - awaySince > 1800 || (chat.panel.isVisible && t - awaySince > 30) { comeBack() }
            return
        }

        let mouse = NSEvent.mouseLocation
        let body = bodyRect
        let over = holding || (mood != .flying && mood != .leaving && body.insetBy(dx: -4, dy: -4).contains(mouse))
        if window.ignoresMouseEvents == over { window.ignoresMouseEvents = !over }
        let moved = hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y)
        if moved > 0.5 { mouseMovedAt = t }
        mouseSpeed = mouseSpeed * 0.8 + moved / dt * 0.2
        let vdt = max(dt, 1.0 / 120)
        let vx = max(-6000, min(6000, (mouse.x - lastMouse.x) / vdt))
        mouseAX = max(-60000, min(60000, mouseAX * 0.6 + (vx - mouseVX) / vdt * 0.4))
        mouseVX = mouseVX * 0.6 + vx * 0.4
        lastMouse = mouse

        checkIdle(t)
        watchChat(t)
        if mood != .held, mood != .flying, mood != .leaving { pet(t, over: over, moved: moved, body: body, mouse: mouse) }
        if holding { hang(t, dt, mouse: mouse) }
        if let to = flyTo { fly(to, dt) }

        // Blinks, now and then a double one.
        if t > nextBlink {
            blinkAt = t
            nextBlink = t + Double.random(in: 2...6)
            if chance(0.2) { nextBlink = t + 0.32 }
        }

        // Something to do now and then.
        if act.map({ t > $0.start + $0.duration }) == true {
            if act?.kind == .trip { tripped = false }
            act = nil
        }
        if t > nextAct {
            nextAct = t + Double.random(in: 8...20) / brain.look.activity
            if act == nil, walkTo == nil, launches.isEmpty, outing == nil { idleTrick(t, mouse: mouse) }
        }
        walk(t, dt)
        runOuting(t)

        // The chat opening: it perks up toward it.
        let chatVisible = chat.panel.isVisible
        if chatVisible, !wasChatVisible, act == nil, mood == .idle || mood == .listening { chatOpened(t) }
        wasChatVisible = chatVisible

        animate(t, dt, mouse: mouse)

        // Particles and the bubble wear off.
        if !brain.particles.isEmpty { brain.particles.removeAll { t - $0.born > $0.life } }
        if brain.bubble != nil, t > bubbleUntil { brain.bubble = nil }
        placeBubble()
        if mood == .sleeping, !brain.particles.contains(where: { $0.kind == .z && t - $0.born < 0.9 }) {
            emit(.z, spread: 4, life: 2.6, x: 24, y: -6, vy: 22)
        }

        brain.pose = pose
        let still = mood == .sleeping && act == nil && pose.lift == 0 && walkTo == nil && !holding
        schedule(still ? 1.0 / 20 : 1.0 / 60)
    }

    static func bubbleWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 24
    }

    // The bubble above the pet, unless the chat is there: then beside it, on
    // the side away from the chat. Nowhere clear: the pet comes in front of
    // the chat while it talks.
    private func placeBubble() {
        var front = false
        if let b = brain.bubble {
            let f = window.frame
            let w = Self.bubbleWidth(b.text), h: CGFloat = 30
            let x = f.midX, ground = f.minY + Self.floor + pose.lift + pose.bob
            func rect(_ side: CGFloat) -> NSRect {
                side == 0
                    ? NSRect(x: x - w / 2, y: ground + Self.bodyH + 30, width: w, height: h)
                    : NSRect(x: x + side * (Self.bodyW / 2 + 18) - (side < 0 ? w : 0), y: ground + Self.bodyH * 0.55 - h / 2, width: w, height: h)
            }
            var chats: [NSRect] = []
            if chat.panel.isVisible { chats.append(chat.barFrame.insetBy(dx: -6, dy: -6)) }
            let visible = screen.visibleFrame.insetBy(dx: -4, dy: -4)
            let away: CGFloat = chats.first.map { $0.midX > x ? -1 : 1 } ?? 1
            // Clear of the chat, on screen, and inside the pet's own window (which
            // would cut it off).
            let inside = f.insetBy(dx: 2, dy: 2)
            let clear = { (side: CGFloat) in
                let r = rect(side)
                return !chats.contains { $0.intersects(r) } && visible.contains(r) && inside.contains(r)
            }
            let side = [brain.bubbleSide, 0, away, -away].first(where: clear)
            // Keep the current place while it's clear, so it doesn't hop about.
            let chosen = clear(brain.bubbleSide) && (brain.bubbleSide == 0 || !clear(0)) ? brain.bubbleSide : (side ?? 0)
            if chosen != brain.bubbleSide { brain.bubbleSide = chosen }
            front = side == nil && !chats.isEmpty
        }
        let level: NSWindow.Level = front ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) : .floating
        if window.level != level { window.level = level }
    }

    // Away from the keyboard (checked twice a second): sleepy, then asleep.
    private func checkIdle(_ t: Double) {
        guard t - lastIdleCheck > 0.5 else { return }
        lastIdleCheck = t
        idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let hour = Calendar.current.component(.hour, from: Date())
        let late = hour >= 23 || hour < 5
        let busy = model.isRunning || chat.panel.isVisible || holding || mood == .flying || mood == .leaving
        if !busy, idleSeconds > (late ? 120 : 180), mood != .sleeping {
            setMood(.sleeping)
            act = nil
            brain.bubble = nil
        } else if !busy, idleSeconds > (late ? 35 : 75), mood == .idle {
            setMood(.sleepy)
            perform(.yawn, t)
        } else if mood == .sleeping || mood == .sleepy, idleSeconds < 1 || busy {
            let wasAsleep = mood == .sleeping
            setMood(.idle)
            if wasAsleep { wake(t) } else if chance(0.5) { perform(.rubEyes, t) }
        }
    }

    private func watchChat(_ t: Double) {
        let running = model.isRunning
        let count = model.chat.messages.count
        let id = model.chat.id
        let temporary = model.chat.isTemporary
        if id != lastChatId {
            lastChatId = id
            if count == 0, !temporary, !wasTemporary { newChat(t) }
            else if count > 0, chance(0.35) {
                perform(.lookAround, t)
                say(line("reopen", ["ooh, this one!", "memories…", "back to this?", "I remember this one!", "the classics 📚"]), for: 1.6)
            }
        } else if count > lastCount, model.chat.messages.last?.role == .user {
            sent(t)
        }
        lastCount = count

        // Temporary chats: shades on while one is on screen; off when it
        // ends or the chat window hides (and on again when it's back).
        let secret = temporary && chat.panel.isVisible
        if secret != wasSecret {
            wasSecret = secret
            if temporary == wasTemporary {
                perform(secret ? .shadesOn : .shadesOff, t)
                if chance(0.3) { say(secret ? line("reshades", ["shades back on 😎", "*slips shades on*", "secret mode again"]) : line("offshades", ["*takes off shades*", "off duty 😌", "phew"]), for: 1.4, at: t + 0.4) }
            }
        }
        if temporary != wasTemporary {
            wasTemporary = temporary
            if temporary {
                perform(.shadesOn, t)
                if chance(0.6) { say(line("temp", ["shh 🤫", "incognito mode 😎", "my lips are sealed 🤐", "this never happened", "*puts on shades*",
                                  "I didn't see anything 👀", "secret mode activated", "I'll forget all about it", "top secret 🕶"]), for: 2.2, at: t + 0.5) }
            } else {
                perform(.shadesOff, t)
                if chance(0.35) { say(line("untemp", ["ok, back to normal 😌", "secrets over!", "*takes off shades*", "I remember things again"]), for: 1.8, at: t + 0.4) }
            }
        }

        // A side chat opening.
        let side = sideVisible()
        if side != wasSide {
            wasSide = side
            if side, mood == .idle || mood == .listening {
                perform([ActKind.doubleTake, .peek, .wave, .salute][Int.random(in: 0..<4)], t, side: 1)
                if chance(0.4) { say(line("side", ["a side quest! ⚔️", "psst, over here", "ooh, a little side chat", "multitasking!", "two chats?! 🤯",
                                                    "sneaky side chat", "a chat within a chat", "side quest unlocked"]), for: 1.8) }
            }
        }

        // Highlighting text: awe.
        let selecting = model.selection != nil
        if selecting, !wasSelecting, mood == .idle || mood == .listening {
            setMood(.awe)
            emit(.sparkle, count: 2, spread: 26, life: 0.8, y: -10, vy: 30, delay: 0.15)
            if t - lastAwe > 15, chance(0.55) {
                lastAwe = t
                say(line("awe", ["ooh 👀", "whoa", "highlighting? smart!", "that part's important?", "✨ fancy ✨", "good find!",
                                 "ooh, quotable", "I see it too!", "wow…", "that one!"]), for: 1.6)
            }
        } else if !selecting, mood == .awe {
            setMood(.idle)
        }
        wasSelecting = selecting

        settingsChanges(t)

        let draft = model.draft.utf8.count
        if draft != lastDraft { typedAt = t; lastDraft = draft }
        if running, !wasRunning, mood != .held, mood != .flying { setMood(.thinking) }
        if !running, wasRunning { answered(t) }
        wasRunning = running

        if moodUntil > 0, t > moodUntil { setMood(.idle) }
        if mood == .thinking, !running { setMood(.idle) }
        if mood == .idle || mood == .listening {
            let typing = chat.panel.isVisible && t - typedAt < 2.5
            setMood(typing ? .listening : .idle)
        }
    }

    // Calm enough to react to something small (not mid-answer, asleep or held).
    private var free: Bool { mood == .idle || mood == .listening }

    // The model, reasoning, History and attachments.
    private func settingsChanges(_ t: Double) {
        if model.model != lastModel {
            lastModel = model.model
            if free, t - lastSetting > 3 {
                lastSetting = t
                let name = ModelCatalog.shared.fullTitle(model.model)
                perform([ActKind.nod, .lookAround, .spin, .sproutPat][Int.random(in: 0..<4)], t)
                if chance(0.4) {
                    say(line("model", ["\(name)? good choice", "ooh, \(name)!", "switching brains 🧠", "new model, who dis", "\(name), nice pick",
                                       "fresh brain, who's this?", "\(name) it is!", "a different brain? 🤔"], ["model": name]), for: 2)
                }
            }
        }
        if model.effort != lastEffort {
            let order = ["minimal", "none", "instant", "low", "medium", "high", "xhigh", "max", "ultra"]
            let up = (order.firstIndex(of: model.effort) ?? 0) > (order.firstIndex(of: lastEffort) ?? 0)
            lastEffort = model.effort
            if free, t - lastSetting > 2 {
                lastSetting = t
                if up {
                    perform(chance(0.5) ? .flex : .propeller, t)
                    if chance(0.4) { say(line("effortUp", ["thinking harder 💪", "big brain mode 🧠", "deep thoughts ahead", "let's think hard!", "max power!"]), for: 1.8) }
                } else {
                    perform(chance(0.5) ? .zoom : .nod, t)
                    if chance(0.4) { say(line("effortDown", ["speedy mode ⚡", "quick thinking!", "fast and light 🪶", "zoom zoom", "less thinking, more doing"]), for: 1.8) }
                }
            }
        }
        if model.showingHistory != wasHistory {
            wasHistory = model.showingHistory
            if wasHistory, free, chance(0.7) {
                perform(.readHistory, t)
                if chance(0.4) { say(line("history", ["the archives 📚", "ooh, memories", "looking for something?", "so many chats!", "a trip down memory lane",
                                     "history class 🏛"]), for: 1.8) }
            }
        }
        let attached = model.draftAttachments.count
        if attached > lastAttachments, free, let a = model.draftAttachments.last {
            perform([ActKind.startle, .doubleTake, .clap][Int.random(in: 0..<3)], t, side: chat.panel.frame.midX > window.frame.midX ? 1 : -1)
            let text: String = switch a.kind {
            case .image: line("attachImage", ["ooh, a picture! 📸", "pretty!", "let me see!", "a photo? 👀", "nice pic!"])
            case .folder: line("attachFolder", ["a whole folder?!", "so many files 📁", "big folder energy"])
            case .file: line("attachFile", ["a file! 📎", "what's in there?", "ooh, a document", "homework? 📄", "attached!"])
            }
            if chance(0.45) { say(text, for: 1.6) }
        }
        lastAttachments = attached
    }

    // Settings opened.
    func settingsOpened() {
        let t = CACurrentMediaTime()
        guard free, t - lastSetting > 2 else { return }
        lastSetting = t
        perform([ActKind.peek, .salute, .sproutPat][Int.random(in: 0..<3)], t)
        if chance(0.35) {
            say(line("settings", ["tweaking things? 🔧", "ooh, settings", "don't turn me off 🥺", "make me pretty!", "settings time ⚙️",
                                  "careful with those switches", "what are we changing?"]), for: 1.8)
        }
    }

    private func newChat(_ t: Double) {
        switch Int.random(in: 0..<6) {
        case 0: perform(.wiggle, t)
        case 1: perform(.stretch, t)
        case 2: hop(); emit(.sparkle, count: 4, spread: 30, life: 0.8, y: -10, vy: 40, delay: 0.08)
        case 3: perform(.clap, t)
        case 4: perform(.spin, t)
        default: perform(.salute, t)
        }
        if chance(0.4) {
            say(line("new", ["fresh start ✨", "clean slate!", "new chat, who dis", "what are we talking about?", "✨ blank page ✨",
                             "ready when you are!", "ooh, something new", "let's goooo", "a new adventure!", "I'm all ears (I have no ears)",
                             "round two!", "what's next?"]), for: 1.8)
        }
    }

    private func sent(_ t: Double) {
        switch Int.random(in: 0..<5) {
        case 0: hop()
        case 1: perform(.nod, t)
        case 2: perform(.salute, t)
        case 3: perform(.clap, t)
        default: perform(.peek, t, side: chat.panel.frame.midX > window.frame.midX ? 1 : -1)
        }
        if chance(0.5) {
            say(line("send", ["ooh!", "on it!", "hmm…", "ok ok!", "good question!", "let's see…", "ooh, tricky", "noted ✍️", "hmmm 🤔",
                              "asking the big brain…", "one sec!", "oh, I wanna know too", "brb thinking", "great question!"]), for: 1.4)
        }
    }

    private func answered(_ t: Double) {
        guard let m = model.chat.messages.last, m.role == .assistant else { return }
        if m.error == "Stopped." {
            perform(.shrug, t)
            if chance(0.35) { say(line("stop", ["ok, stopping!", "nevermind then", "cut short ✂️", "stopped!"]), for: 1.4) }
        } else if m.error != nil {
            setMood(.sad, for: 3.2)
            perform([ActKind.sigh, .shrug][Int.random(in: 0..<2)], t)
            emit(.sweat, life: 1.2, x: 26, y: -10, vy: -14)
            say(line("error", ["oh no…", "that didn't work 😔", "oops", "uh oh", "hmm, try again?", "not my fault! …maybe", "😿",
                               "the robots are tired", "something broke…"]), for: 2.2)
        } else {
            setMood(.happy, for: 2.6)
            switch Int.random(in: 0..<6) {
            case 0: hop(3, gap: 0.5); emit(.heart, count: 3, spread: 26, life: 1.6)
            case 1: perform(.spin, t); hop(1, at: t + 0.9)
            case 2: perform(.dance, t)
            case 3: perform(.bigJump, t)
            case 4: perform(.cheer, t)
            default: perform(.clap, t); emit(.heart, count: 2, spread: 22, life: 1.5)
            }
            emit(.sparkle, count: 4, spread: 34, life: 0.9, y: -20, vy: 40, delay: 0.08)
            if chance(0.35) {
                say(line("done", ["yay!", "done! ✨", "ta-da!", "hehe 💖", "nailed it", "there you go!", "fresh answer, hot off the press 📰",
                                  "smart stuff!", "woo! 🎉", "✨ ✨ ✨", "that was a good one", "learned something new!", "big brain moment 🧠"]), for: 1.8)
            }
        }
    }

    // Petting: rest the cursor on it, or rub it.
    private func pet(_ t: Double, over: Bool, moved: CGFloat, body: NSRect, mouse: NSPoint) {
        if over, mood == .idle || mood == .listening || mood == .love {
            if hoverSince == nil { hoverSince = t }
            rubbed += moved
            if (t - hoverSince! > 0.9 || rubbed > 260), t - lastLoved > 2.6 {
                lastLoved = t
                rubbed = 0
                setMood(.love, for: 2.4)
                perform([ActKind.purr, .giggle, .melt, .wiggle, .blushHide][Int.random(in: 0..<5)], t)
                emit(.heart, count: 3, spread: 22, life: 1.5)
                if chance(0.35) {
                    say(line("pet", ["hehe", "💕", "purr~", "more pets pls", "that tickles!", "mmm…", "best day ever", "again! again!",
                                     "*happy noises*", "you're nice", "🥰", "hehehe stop it", "right there!", "so soft…"]), for: 1.5)
                }
            }
        } else if !over {
            hoverSince = nil
            rubbed = 0
        }
        // The cursor whizzing past: a little startle.
        let near = hypot(mouse.x - body.midX, mouse.y - body.midY)
        if mood == .idle, act == nil, near < 110, mouseSpeed > 2600, t - lastStartle > 30 {
            lastStartle = t
            perform(chance(0.5) ? .startle : .doubleTake, t)
        }
    }

    // When nobody's doing anything: a trick, a walk, a look at the cursor.
    private func idleTrick(_ t: Double, mouse: NSPoint) {
        switch mood {
        case .idle:
            let r = Double.random(in: 0...1)
            if r < 0.18 { wander() }
            else if r < 0.25 { chaseCursor(mouse) }
            else if r < 0.32 { hop(Int.random(in: 1...2)) }
            else {
                // Small things most of the time; a bigger scene (a butterfly, juggling,
                // a balloon…) only now and then, never two within ~2 minutes, and
                // not the same one twice in a row.
                let scenes: [ActKind] = [.butterfly, .soap, .juggle, .propeller, .meditate, .paperPlane, .ball, .book, .raincloud,
                                         .balloon, .tea, .yoyo, .pushups, .sitKick, .checkTime, .dance, .bigJump, .water, .nap, .skipRope]
                if t > nextScene, chance(0.35) {
                    let names = scenes.map { "\($0)" } + ["fetch", "peekOut"]
                    let pick = line("scene", names)
                    if pick == "fetch" { startOuting(.fetch) } else if pick == "peekOut" { startOuting(.peek) }
                    else { perform(scenes[names.firstIndex(of: pick) ?? 0], t) }
                    nextScene = t + Double.random(in: 100...200) / brain.look.activity
                } else {
                    var kinds: [ActKind] = [.wiggle, .lookAround, .lookAround, .hum, .stretch, .sneeze, .peek, .nod, .spin,
                                            .tapFoot, .hiccup, .whistle, .shiver, .sproutPat, .flex, .wink, .scratchHead,
                                            .sideStretch, .pebbleKick, .tinyBounce, .lookUp, .giggle, .raspberry, .salute, .clap]
                    if t - mouseMovedAt < 3, hypot(mouse.x - window.frame.midX, mouse.y - window.frame.minY) < 300 { kinds += [.wave, .wave] }
                    perform(kinds.randomElement()!, t)
                }
            }
        case .sleepy: perform(chance(0.6) ? .yawn : .rubEyes, t)
        case .thinking: if chance(0.3) { perform(.tapFoot, t) }
        default: break
        }
    }

    // The chat opened: a burst of sparkles toward it, the sprout springs, and
    // one of several reactions (never the same twice in a row).
    private func chatOpened(_ t: Double) {
        let side: CGFloat = chat.panel.frame.midX > window.frame.midX ? 1 : -1
        sprout.v += 380
        squash.v -= 4
        emit(.sparkle, count: 5, spread: 10, life: 0.8, x: 20 * side, y: -16, vx: 70 * side, vy: 45, delay: 0.05)
        let reactions = ["perk", "hopHeart", "wave", "salute", "bounce", "spin", "cheer", "clap", "scoot", "starEyes"]
        switch line("chatOpen", reactions) {
        case "hopHeart": hop(); emit(.heart, count: 2, spread: 14, life: 1.4, x: 10 * side, delay: 0.2)
        case "wave": perform(.wave, t, side: side)
        case "salute": perform(.salute, t, side: side)
        case "bounce": perform(.tinyBounce, t, side: side)
        case "spin": perform(.spin, t, side: side)
        case "cheer": perform(.cheer, t, side: side)
        case "clap": perform(.clap, t, side: side)
        case "scoot":
            // A few steps toward the chat, staying on screen.
            if let e = edges(for: screen) {
                walkSpeed = 80
                walkTo = min(max(window.frame.origin.x + 34 * side, e.left), e.right)
            }
            perform(.perk, t, side: side)
        case "starEyes":
            perform(.perk, t, side: side)
            emit(.star, count: 3, spread: 22, life: 1.2, y: -4, vy: 26, delay: 0.12)
        default: perform(.perk, t, side: side)
        }
        if chance(0.15) {
            say(line("chatOpenLine", ["ooh, chat time!", "what are we asking?", "hi!", "✨", "ready!", "let's go!"]), for: 1.4)
        }
    }

    // Off the nearest side of the screen and back: with something it found,
    // or peeking back in from the edge first.
    private func startOuting(_ kind: Outing) {
        guard !chat.panel.isVisible else { return perform(.lookAround) }
        let v = screen.frame
        let left = window.frame.midX - v.minX < v.maxX - window.frame.midX
        let W = Self.size.width, half = Self.bodyW / 2
        outingSide = left ? -1 : 1
        outingOff = left ? v.minX - W / 2 - half - 24 : v.maxX - W / 2 + half + 24
        outingPeek = left ? v.minX - W / 2 + 6 : v.maxX - W / 2 - 6
        outing = kind
        outingStage = 0
        walkSpeed = 72
        walkTo = outingOff
        if kind == .fetch, chance(0.5) { say(line("brb", ["brb!", "be right back 🏃", "gonna get something", "wait here!"]), for: 1.4) }
    }

    private func runOuting(_ t: Double) {
        guard let o = outing else { return }
        // Called back by the chat, an answer, a grab or sleep: home at once.
        if holding || flyTo != nil || chat.panel.isVisible || model.isRunning || !(mood == .idle || mood == .listening) {
            outing = nil
            brain.pose.carry = nil
            pose.carry = nil
            if !holding, flyTo == nil { walkTo = home.x; walkSpeed = 110; forceWalk = true }
            return
        }
        switch outingStage {
        case 0:
            if walkTo == nil { outingStage = 1; outingUntil = t + (o == .fetch ? Double.random(in: 1.5...3) : 0.9) }
        case 1:
            guard t > outingUntil else { return }
            if o == .fetch {
                pose.carry = ["⭐️", "🍎", "🌸", "🎁", "🍄", "🧦", "🍪", "💎", "🪙", "🍓", "🎈", "🐚"].randomElement()!
                walkSpeed = 64
                walkTo = home.x
                outingStage = 3
            } else {
                walkSpeed = 40
                walkTo = outingPeek
                outingStage = 2
            }
        case 2:
            if walkTo == nil {
                perform(.peekIn, t, side: -outingSide)
                outingUntil = t + 3
                outingStage = 4
            }
        case 4:
            if t > outingUntil { walkSpeed = 60; walkTo = home.x; outingStage = 3 }
        default:
            if walkTo == nil {
                outing = nil
                if pose.carry != nil {
                    perform(.showItem, t)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
                        guard let self, self.outing == nil else { return }
                        self.pose.carry = nil
                        self.emit(.sparkle, count: 3, spread: 14, life: 0.6, y: 10, vy: 20, delay: 0)
                    }
                }
            }
        }
    }

    // A few steps away from home and, next time, back.
    private func wander() {
        guard let e = edges(for: screen) else { return }
        let x = window.frame.origin.x
        var target = abs(x - home.x) > 20 ? home.x : home.x + CGFloat.random(in: 40...120) * (Bool.random() ? 1 : -1)
        target = min(max(target, e.left), e.right)
        guard abs(target - x) > 8 else { return }
        walkSpeed = CGFloat.random(in: 38...58)
        walkTo = target
    }

    // Walks over to where the cursor is, if it's not far.
    private func chaseCursor(_ mouse: NSPoint) {
        guard let e = edges(for: screen) else { return }
        let target = min(max(mouse.x - Self.size.width / 2, e.left), e.right)
        let x = window.frame.origin.x
        guard abs(target - x) > 30, abs(target - x) < 380 else { return wander() }
        walkSpeed = 60
        walkTo = target
        if chance(0.4) { say(line("chase", ["wait for me!", "where are you going?", "coming!", "follow the cursor!"]), for: 1.4) }
    }

    private func walk(_ t: Double, _ dt: CGFloat) {
        guard let to = walkTo, !holding, flyTo == nil else { moving = 0; return }
        guard forceWalk || mood == .idle || mood == .listening || mood == .leaving else { walkTo = nil; moving = 0; return }
        guard !tripped else { moving = 0; return }
        let o = window.frame.origin
        let dx = to - o.x
        if abs(dx) < 1.5 {
            walkTo = nil
            moving = 0
            forceWalk = false
            if mood == .leaving {
                // Off the screen: gone until it comes back.
                window.orderOut(nil)
                setMood(.away)
                awaySince = t
                act = nil
                brain.bubble = nil
                brain.particles = []
                walkSpeed = 46
                timer?.invalidate()
                timer = nil
                schedule(2)
            }
            return
        }
        let step = min(abs(dx), walkSpeed * dt) * (dx > 0 ? 1 : -1)
        window.setFrameOrigin(NSPoint(x: o.x + step, y: o.y))
        let actual = window.frame.origin.x - o.x
        // Didn't move (blocked somehow): stop instead of walking on the spot.
        if abs(actual) < 0.01 {
            if stuckSince == nil { stuckSince = t }
            if t - stuckSince! > 0.25 { walkTo = nil; moving = 0; stuckSince = nil }
            return
        }
        stuckSince = nil
        moving = actual / dt
        stepPhase += Double(abs(actual)) * 0.22
        // Now and then it trips on the way.
        if mood == .idle, act == nil, chance(Double(dt) * 0.025) {
            perform(.trip, t, side: dx > 0 ? 1 : -1)
            say(line("trip", ["oof", "whoops!", "I meant to do that", "ow…"]), for: 1.3, at: t + 0.3)
        }
    }

    // Hanging from the cursor by one hand: a pendulum pushed by the cursor's moves.
    private func hang(_ t: Double, _ dt: CGFloat, mouse: NSPoint) {
        // Its hand reaches the cursor over a third of a second, easing out.
        grab = min(1, grab + dt / 0.32)
        placeHeld(mouse)
        // A pendulum round the hand: it swings into hanging a little to the
        // side (under its hand), pushed about by the cursor's moves.
        // (Angle: clockwise on screen.)
        let rest = CGFloat(Self.hangTilt) * pose.rope
        let length: CGFloat = 70, g: CGFloat = 1100
        let a = -(g / length) * sin(ropeTheta - rest) - 2.6 * ropeOmega + (mouseAX / length) * cos(ropeTheta)
        ropeOmega += a * dt
        ropeTheta = max(-1.3, min(1.3, ropeTheta + ropeOmega * dt))
        pose.ropeAngle = ropeTheta
        // Shaking: count the turns of a fast drag.
        let dir: CGFloat = mouseVX > 600 ? 1 : mouseVX < -600 ? -1 : 0
        if dir != 0, dir != lastShakeDir { shakes.append(t); lastShakeDir = dir }
    }

    private func fly(_ to: NSPoint, _ dt: CGFloat) {
        let o = window.frame.origin
        let k: CGFloat = 70, d: CGFloat = 12
        flyV.dx += (k * (to.x - o.x) - d * flyV.dx) * dt
        flyV.dy += (k * (to.y - o.y) - d * flyV.dy) * dt
        let n = NSPoint(x: o.x + flyV.dx * dt, y: o.y + flyV.dy * dt)
        window.setFrameOrigin(n)
        let at = window.frame.origin
        // Landed, or held back short of the spot (macOS keeps some windows on
        // screen), or simply too long: it lands where it is. Before, a flight
        // that couldn't reach its spot never ended, and the pet stayed stuck.
        let arrived = hypot(to.x - at.x, to.y - at.y) < 1 && hypot(flyV.dx, flyV.dy) < 20
        let blocked = hypot(at.x - o.x, at.y - o.y) < 0.05 && hypot(flyV.dx, flyV.dy) > 30
        if blocked { flyBlocked += 1 } else { flyBlocked = 0 }
        if arrived || flyBlocked > 8 || CACurrentMediaTime() - flyStart > 2.5 || !at.x.isFinite || !at.y.isFinite {
            if arrived { window.setFrameOrigin(to) }
            flyTo = nil
            flyBlocked = 0
            squash.v += 8
            landed(shaken: dizzyAfterFlight)
        }
    }

    private var flyStart: Double = 0
    private var flyBlocked = 0

    // Brought back from Hide for a While (Settings).
    func comeBackIfAway() {
        if mood == .away { comeBack() } else if mood == .leaving { walkTo = nil; setMood(.idle) }
    }

    // MARK: The pose

    private func animate(_ t: Double, _ dt: CGFloat, mouse: NSPoint) {
        let f = window.frame
        let eye = CGPoint(x: f.midX, y: f.minY + Self.floor + pose.lift + Self.bodyH * 0.55)
        var T = PetTargets()
        var dx = mouse.x - eye.x, dy = mouse.y - eye.y
        if mood == .listening || (chat.panel.isVisible && t - typedAt < 4) {
            let c = chat.panel.frame
            dx = c.midX - eye.x
            dy = c.minY + 40 - eye.y
        }
        let dist = max(1, hypot(dx, dy))
        T.lookX = dx / max(dist, 150)
        T.lookY = dy / max(dist, 150)
        // The cursor still for a while: its eyes wander instead.
        if t - mouseMovedAt > 7, mood == .idle {
            if t > nextGaze {
                nextGaze = t + Double.random(in: 1.8...4.5)
                gaze = chance(0.3) ? CGPoint(x: T.lookX, y: T.lookY) : CGPoint(x: CGFloat.random(in: -1...1), y: CGFloat.random(in: -0.4...0.8))
            }
            T.lookX = gaze.x; T.lookY = gaze.y
        }
        if let (p, until) = glance { if t < until { T.lookX = p.x; T.lookY = p.y } else { glance = nil } }
        T.wide = dist < 150 ? 0.25 : 0
        T.shades = model.chat.isTemporary && chat.panel.isVisible ? 1 : 0
        var breathe = CGFloat(sin(t * 2.4)) * 0.022

        switch mood {
        case .idle, .flying, .away: break
        case .listening:
            T.lean = (dx > 0 ? 1 : -1) * 5
            T.smile = 0.55; T.wide = 0.2
            T.lookY -= CGFloat(max(0, sin(t * 4.2))) * 0.25
        case .thinking:
            T.browShow = 0.7; T.brow = -0.2; T.smile = 0.05
            switch thinkStyle {
            case 0:   // hand on chin, eyes up
                T.lookX = CGFloat(sin(t * 0.8)) * 0.7; T.lookY = 0.75
                T.mouth = 0.15 + 0.08 * CGFloat(abs(sin(t * 3)))
                T.armL = 20; T.armR = 72 + CGFloat(sin(t * 5)) * 8
                T.lean = CGFloat(sin(t * 2.2)) * 4
            case 1:   // sprout spinning, a little float
                T.propeller = true; T.float = 4 + CGFloat(sin(t * 3)) * 2
                T.lookY = 0.9; T.lookX = 0
                T.armL = 50; T.armR = 50; T.smile = 0.3
            case 2:   // pacing glances, tapping a foot
                T.lookX = CGFloat(sin(t * 1.6)) > 0 ? 0.8 : -0.8; T.lookY = 0.3
                T.footR = CGFloat(abs(sin(t * 9))) * 5
                T.lean = CGFloat(sin(t * 1.6)) * 3
            default:  // humming along
                T.lid = 0.55; T.smile = 0.5; T.mouth = 0.12 + 0.12 * CGFloat(abs(sin(t * 5)))
                T.lean = CGFloat(sin(t * 3)) * 6
            }
            if Int(t * 0.7) % 6 == 0, !brain.particles.contains(where: { ($0.kind == .note || $0.kind == .question) && t - $0.born < 2.5 }) {
                emit(chance(0.5) ? .note : .question, spread: 10, life: 1.6, x: 20, vy: 28)
            }
            T.sprout = thinkStyle == 1 ? 0 : CGFloat(sin(t * 7)) * 12
        case .happy:
            T.joy = 1; T.smile = 1; T.mouth = 0.55; T.blush = 0.75
            T.armL = 140 + CGFloat(sin(t * 15)) * 18; T.armR = 140 + CGFloat(sin(t * 15 + 1)) * 18
        case .sad, .leaving:
            T.lid = 0.7; T.smile = -0.65; T.browShow = 1; T.brow = -1
            T.lookY = -0.55; T.lookX *= 0.3; T.armL = -6; T.armR = -6; T.squash = 0.06
            T.sprout = -18
        case .love:
            T.joy = 1; T.smile = 0.85; T.mouth = 0.2; T.blush = 1
            T.lean = CGFloat(sin(t * 3.2)) * 7
            T.armL = 45; T.armR = 45
        case .awe:
            T.awe = 1; T.wide = 1; T.mouth = 0.32; T.smile = 0.3; T.blush = 0.6
            T.armL = 60; T.armR = 60
            let c = chat.panel.frame
            T.lookX = max(-1, min(1, (c.midX - eye.x) / 300)); T.lookY = 0.4
        case .sleepy:
            T.lid = 0.32 + CGFloat(sin(t * 0.7)) * 0.08; T.smile = 0.12
            T.lean = CGFloat(sin(t * 0.9)) * 3; T.lookY = -0.3
            T.sprout = -12
        case .sleeping:
            T.lid = 0; T.smile = 0.15; T.mouth = 0.12 + 0.08 * CGFloat(sin(t * 1.3))
            T.lean = -7; T.lookX = 0; T.lookY = -0.4
            breathe = CGFloat(sin(t * 1.3)) * 0.05
            T.sprout = -32
        case .dizzy:
            T.dizzy = 1; T.smile = -0.15; T.mouth = 0.3
            T.lean = CGFloat(sin(t * 5)) * 11
            T.sprout = CGFloat(sin(t * 5 + 1)) * 20
        case .held:
            T.wide = 0.8; T.smile = 0.5; T.mouth = 0.25
            T.armR = 142                                   // straight up, holding on
            T.armL = 70 + CGFloat(sin(t * 7)) * 25         // the other one waving about
            T.lookY = 0.7; T.lookX = 0.3
        }
        if mood == .flying { T.wide = 1; T.mouth = 0.55; T.armL = 120; T.armR = 120; T.smile = 0.5 }

        var turn: CGFloat = 0
        var butterfly: CGPoint?
        var soap: CGFloat = 0, soapRise: CGFloat = 0
        var prop: PetProp?
        if let a = act, t >= a.start {
            applyAct(a, t, dt, &T, &turn, &butterfly, &soap, &soapRise, &prop)
        }

        // Blink: shut for a moment.
        let b = t - blinkAt
        if b >= 0, b < 0.16 { T.lid = min(T.lid, CGFloat(abs(b - 0.08) / 0.08)) }

        // Talking: the mouth moves with the words.
        if t < talkUntil, mood != .sleeping {
            let flap = CGFloat(abs(sin(t * 17))) * (0.65 + 0.35 * CGFloat(sin(t * 5.3)))
            T.mouth = max(T.mouth, 0.1 + 0.32 * flap)
        }

        // Walking, only while it really moves: steps, a bounce, leaning into it.
        var bob: CGFloat = 0
        let walking = abs(moving) > 5
        if walking {
            let dir: CGFloat = moving > 0 ? 1 : -1
            T.facing = dir
            T.lean += dir * 6
            bob = CGFloat(abs(sin(stepPhase))) * 3
            T.footL = max(T.footL, CGFloat(max(0, sin(stepPhase))) * 5)
            T.footR = max(T.footR, CGFloat(max(0, -sin(stepPhase))) * 5)
            T.armL = max(T.armL, 18 + CGFloat(sin(stepPhase)) * 16); T.armR = max(T.armR, 18 - CGFloat(sin(stepPhase)) * 16)
            if mood != .leaving { T.lookX = dir * 0.8 }
        }

        // Carrying something home: held up over its head.
        if pose.carry != nil, act?.kind != .showItem { T.armL = max(T.armL, 150); T.armR = max(T.armR, 150); T.smile = max(T.smile, 0.8) }

        // Jumps: crouch, take off, fly under gravity, land with a squash.
        if let c = crouches.first, t >= c { crouches.removeFirst(); squash.v += 5 }
        if let l = launches.first, t >= l.at, pose.lift <= 0.5, !holding {
            launches.removeFirst()
            liftV = mood == .happy ? l.v * 1.15 : l.v
            squash.v -= 9
        }
        if holding || mood == .flying {
            pose.lift = 0; liftV = 0
        } else if pose.lift > 0 || liftV > 0 {
            liftV -= 1500 * dt
            pose.lift += liftV * dt
            if pose.lift <= 0 {
                if liftV < -120 {
                    squash.v += min(16, -liftV * 0.035)
                    if liftV < -420 { emit(.dust, count: 3, spread: 28, life: 0.5, y: -Self.bodyH - 6, vy: 4, delay: 0) }
                }
                pose.lift = 0; liftV = 0
            }
        }
        let airborne = pose.lift > 0
        if airborne, mood != .held { T.armL = max(T.armL, 50); T.armR = max(T.armR, 50); T.footL = max(T.footL, 2); T.footR = max(T.footR, 2) }

        // Springs: the body's squash, lean and float, the arms, and the
        // sprout, which lags behind everything the body does.
        float.step(to: T.float, k: 40, d: 9, dt: dt)
        squash.step(to: T.squash + breathe + (airborne ? -0.06 : 0) + (holding ? -0.08 : 0), k: 320, d: 15, dt: dt)
        lean.step(to: T.lean, k: 150, d: 13, dt: dt)
        armL.step(to: T.armL, k: 180, d: 16, dt: dt)
        armR.step(to: T.armR, k: 180, d: 16, dt: dt)
        swing.step(to: holding ? max(-35, min(35, ropeOmega * 9)) : 0, k: 60, d: 4, dt: dt)
        sprout.step(to: T.sprout + lean.x * 0.6 - lean.v * 0.05 - liftV * 0.035 - (holding ? ropeOmega * 6 : 0), k: 110, d: 6, dt: dt)

        pose.time = t
        pose.squash = max(-0.32, min(0.36, squash.x))
        pose.lean = lean.x
        pose.turn = turn
        pose.armL = armL.x
        pose.armR = armR.x
        pose.swing = swing.x
        pose.sprout = sprout.x
        pose.bob = bob + max(0, float.x)
        pose.butterfly = butterfly
        pose.juggle = act?.kind == .juggle && t >= (act?.start ?? 0) ? t - act!.start + 0.01 : 0
        pose.soap = soap
        pose.soapRise = soapRise
        pose.prop = prop
        pose.skip = act?.kind == .skipRope && t >= (act?.start ?? 0) ? .pi + 2 * .pi * (t - act!.start - 0.44) / 0.62 : 0
        ease(&pose.wink, act?.kind == .wink && t >= act!.start ? bell((t - act!.start) / act!.duration) * 1.6 : 0, 18, dt)
        ease(&pose.sproutScale, act?.kind == .water && t >= act!.start ? 1 + 0.45 * bell(max(0, (t - act!.start) / act!.duration - 0.35) / 0.65) : 1, 6, dt)
        if T.propeller { pose.propeller += dt * 22 } else { pose.propeller = 0 }
        if !holding { pose.ropeAngle *= 1 - min(1, 10 * dt); ease(&pose.rope, 0, 18, dt) }
        ease(&pose.footL, T.footL, 22, dt)
        ease(&pose.footR, T.footR, 22, dt)
        ease(&pose.facing, T.facing, 6, dt)
        ease(&pose.lookX, T.lookX, 12, dt)
        ease(&pose.lookY, T.lookY, 12, dt)
        // Lids shut fast and open a little slower.
        ease(&pose.lid, T.lid, T.lid < pose.lid ? 40 : 14, dt)
        ease(&pose.wide, T.wide, 10, dt)
        ease(&pose.joy, T.joy, 9, dt)
        ease(&pose.dizzy, T.dizzy, 6, dt)
        ease(&pose.awe, T.awe, 8, dt)
        pose.spin += dt * 9 * pose.dizzy
        ease(&pose.smile, T.smile, 8, dt)
        ease(&pose.mouth, T.mouth, 16, dt)
        ease(&pose.tongue, T.tongue, 12, dt)
        ease(&pose.blush, T.blush, 4, dt)
        ease(&pose.brow, T.brow, 8, dt)
        ease(&pose.browShow, T.browShow, 8, dt)
        ease(&pose.shades, T.shades, act?.kind == .shadesOn || act?.kind == .shadesOff ? 7 : 4, dt)
        ease(&pose.dangle, holding ? 1 : 0, 10, dt)
    }

    // What it's doing now, blended over the mood by how far along it is.
    private func applyAct(_ a: Act, _ t: Double, _ dt: CGFloat, _ T: inout PetTargets, _ turn: inout CGFloat,
                          _ butterfly: inout CGPoint?, _ soap: inout CGFloat, _ soapRise: inout CGFloat, _ prop: inout PetProp?) {
        let p = (t - a.start) / a.duration
        let e = bell(p)
        let s = a.side
        // The arm on the side it's using (the toy's side), not always the right one.
        func arm(_ v: CGFloat) { if s > 0 { T.armR = max(T.armR, v) } else { T.armL = max(T.armL, v) } }
        switch a.kind {
        case .wiggle:
            T.lean += CGFloat(sin(p * .pi * 7)) * 11 * (1 - CGFloat(p))
            T.smile = max(T.smile, 0.7); T.joy = max(T.joy, e)
        case .lookAround:
            T.lookX = CGFloat(sin(p * .pi * 2)) * 1.1 * s; T.lookY = 0.2 * e
            T.lean += CGFloat(sin(p * .pi * 2)) * 4 * s
        case .hum:
            T.smile = max(T.smile, 0.6); T.mouth = max(T.mouth, 0.12 + 0.15 * CGFloat(abs(sin(t * 6)))); T.lid = min(T.lid, 1 - 0.55 * e)
            T.lean += CGFloat(sin(t * 4)) * 5 * e
        case .stretch:
            T.armL = max(T.armL, 165 * e); T.armR = max(T.armR, 165 * e)
            T.squash -= 0.2 * e; T.lid = min(T.lid, 1 - 0.75 * e); T.mouth = max(T.mouth, 0.7 * e); T.smile = 0.2
        case .dance:
            T.lean += CGFloat(sin(p * .pi * 8)) * 13 * e
            T.armL = max(T.armL, 80 + CGFloat(sin(p * .pi * 8)) * 60); T.armR = max(T.armR, 80 - CGFloat(sin(p * .pi * 8)) * 60)
            T.joy = max(T.joy, e); T.smile = 0.9; T.mouth = max(T.mouth, 0.3)
        case .sneeze:
            if p < 0.62 {
                let b = CGFloat(p / 0.62)
                T.lean -= 9 * b; T.lid = min(T.lid, 1 - 0.6 * b); T.mouth = max(T.mouth, 0.55 * b); T.lookY = 0.5 * b
            } else {
                if fire(1, true) {
                    squash.v += 10; lean.v += 300
                    emit(.sparkle, count: 5, spread: 30, life: 0.7, x: 0, y: -24, vy: 30, delay: 0)
                    say(line("sneeze", ["achoo!", "ACHOO!", "a-choo! 🤧", "*sneeze*"]), for: 1.1)
                }
                let r = CGFloat((p - 0.62) / 0.38)
                T.lid = min(T.lid, 0.15 + r); T.smile = 0.3
                if p > 0.85, fire(2, true), chance(0.5) { say(line("bless", ["excuse me!", "bless me", "hehe, sorry"]), for: 1) }
            }
        case .yawn:
            T.mouth = max(T.mouth, 0.95 * e); T.lid = min(T.lid, 1 - 0.8 * e)
            T.armL = max(T.armL, 60 * e); T.armR = max(T.armR, 60 * e); T.squash -= 0.08 * e; T.smile = 0.1
        case .nod:
            T.lookY -= 0.6 * CGFloat(abs(sin(p * .pi * 2))); T.smile = max(T.smile, 0.6)
        case .startle:
            T.wide = max(T.wide, e); T.mouth = max(T.mouth, 0.5 * e); T.armL = max(T.armL, 110 * e); T.armR = max(T.armR, 110 * e)
        case .peek:
            T.lean += s * 16 * e; T.lookX = s * e; T.lookY = 0.1; T.wide = max(T.wide, 0.4 * e)
        case .spin:
            let q = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            turn = CGFloat(q * 2 * .pi) * s
            T.joy = max(T.joy, e); T.smile = 0.9; T.armL = max(T.armL, 70 * e); T.armR = max(T.armR, 70 * e)
        case .sitKick:
            T.squash += 0.12 * e
            T.footL = CGFloat(max(0, sin(t * 7))) * 8 * e; T.footR = CGFloat(max(0, -sin(t * 7))) * 8 * e
            T.smile = 0.7; T.lookX = CGFloat(sin(t * 0.9)) * 0.6; T.lookY = 0.3
            if fire(1, p > 0.3) { emit(.note, count: 2, spread: 16, life: 1.5, x: 16, delay: 0.6) }
        case .checkTime:
            T.armR = max(T.armR, 95 * e); T.lookX = 0.7 * e; T.lookY = 0.05; T.wide = max(T.wide, 0.3 * e)
            if p > 0.4 { T.wide = max(T.wide, 0.6 * e) }
        case .meditate:
            T.lid = min(T.lid, 1 - e); T.float = 9 * e; T.armL = 60 * e; T.armR = 60 * e; T.smile = 0.35
            if fire(1, p > 0.5) { emit(.sparkle, count: 3, spread: 30, life: 1.2, y: -30, vy: 10, delay: 0.3) }
        case .butterfly:
            // It flutters round the pet, which watches, tries to catch it, and waves it off.
            let w = p * 2 * .pi
            var bx = CGFloat(sin(w * 1.5)) * 62 * s, by = 92 + CGFloat(sin(w * 3)) * 22
            if p < 0.12 { bx += CGFloat(0.12 - p) * 900 * s; by += CGFloat(0.12 - p) * 300 }
            if p > 0.85 { bx += CGFloat(p - 0.85) * 900 * s; by += CGFloat(p - 0.85) * 700 }
            butterfly = CGPoint(x: bx, y: by)
            T.lookX = max(-1, min(1, bx / 70)); T.lookY = max(-0.2, min(1, (by - 50) / 60))
            T.wide = 0.5; T.smile = 0.8; T.awe = max(T.awe, 0.4)
            if fire(1, p > 0.55) { hop(1, height: 330) }
            if p > 0.55, p < 0.7 { T.armL = 150; T.armR = 150 }
            if fire(2, p > 0.86) { perform(.wave, t, side: s); say(line("bfly", ["bye butterfly!", "come back soon 🦋", "so pretty…", "almost had it!"]), for: 1.6) }
        case .soap:
            if p < 0.15 {
                T.blush = 0.9; T.squash -= 0.05
            } else if p < 0.6 {
                let g = CGFloat((p - 0.15) / 0.45)
                soap = g; T.mouth = 0.14; T.smile = 0; T.blush = 0.8; T.lookX = 0.6; T.lookY = 0
            } else if p < 0.95 {
                let r = CGFloat((p - 0.6) / 0.35)
                soap = 1; soapRise = r * 70; T.lookX = 0.4; T.lookY = 0.3 + r * 0.6; T.wide = 0.4; T.smile = 0.8
            } else {
                if fire(1, true) {
                    emit(.sparkle, count: 4, spread: 14, life: 0.5, x: 28, y: 50, vy: 10, delay: 0)
                    if chance(0.5) { say(line("pop", ["pop!", "oh! 🫧", "aww, it popped"]), for: 1) }
                }
                T.wide = 1
            }
        case .trip:
            let fall = p < 0.18 ? CGFloat(p / 0.18) : p < 0.7 ? 1 : CGFloat(1 - (p - 0.7) / 0.3)
            T.lean = s * 72 * fall; T.squash += 0.12 * fall; T.mouth = 0.4 * fall; T.lid = min(T.lid, 1 - 0.7 * fall)
            T.armL = 110 * fall; T.armR = 110 * fall
            if fire(1, p > 0.16) { squash.v += 8; emit(.dust, count: 3, spread: 30, life: 0.5, x: s * 30, y: -Self.bodyH, vy: 4, delay: 0) }
            if fire(2, p > 0.8), chance(0.6) { say(line("tripok", ["I'm ok!", "nobody saw that", "all good 👍"]), for: 1.3) }
        case .wave:
            T.armR = max(T.armR, 150 + CGFloat(sin(t * 14)) * 25 * e); T.smile = max(T.smile, 0.8); T.joy = max(T.joy, 0.4 * e)
        case .giggle:
            T.joy = 1; T.smile = 1; T.mouth = max(T.mouth, 0.4); T.blush = max(T.blush, 0.8)
            T.lean += CGFloat(sin(t * 30)) * 5 * e; T.squash += CGFloat(abs(sin(t * 20))) * 0.06 * e
        case .boop:
            if p < 0.45 { T.lid = 0; T.squash += 0.22 * bell(p / 0.45) } else { T.wide = max(T.wide, e) }
            T.mouth = max(T.mouth, 0.3); T.blush = max(T.blush, 0.8)
        case .raspberry:
            T.tongue = e; T.mouth = max(T.mouth, 0.3 * e); T.lid = min(T.lid, 1 - 0.5 * e); T.smile = 0.3
            T.lean += CGFloat(sin(t * 26)) * 3 * e
        case .rollEyes:
            T.lookX = CGFloat(cos(p * 2 * .pi)) * 0.9; T.lookY = 0.7 + CGFloat(sin(p * 2 * .pi)) * 0.3
            T.browShow = e; T.brow = 0.2; T.smile = -0.1; T.lid = min(T.lid, 0.75)
        case .salute:
            T.armR = max(T.armR, 158 * e); T.smile = 0.7; T.lean -= 3 * e; T.wide = max(T.wide, 0.3 * e)
        case .clap:
            T.armL = max(T.armL, 70 + CGFloat(abs(sin(t * 16))) * 40 * e); T.armR = max(T.armR, 70 + CGFloat(abs(sin(t * 16))) * 40 * e)
            T.joy = max(T.joy, 0.6 * e); T.smile = 0.9; T.mouth = max(T.mouth, 0.3)
        case .doubleTake:
            if p < 0.25 { T.lookX = s * 0.9 } else if p < 0.45 { T.lookX = 0; T.lookY = 0 } else {
                T.lookX = s; T.wide = 1; T.mouth = max(T.mouth, 0.45)
                if fire(1, true) { emit(.bang, life: 0.8, x: 22 * s, vy: 18); squash.v -= 6 }
            }
        case .purr:
            T.lid = min(T.lid, 0.12); T.joy = max(T.joy, 0.5); T.lean += s * 9 * e; T.smile = 0.8; T.blush = 1; T.squash += 0.05 * e
        case .melt:
            T.squash += 0.3 * e; T.joy = 1; T.smile = 0.9; T.blush = 0.9; T.armL = -10; T.armR = -10
        case .shrug:
            T.armL = max(T.armL, 110 * e); T.armR = max(T.armR, 110 * e); T.browShow = max(T.browShow, e); T.brow = -0.3
            T.smile = -0.1; T.lean += s * 4 * e; T.lookY = 0.2
        case .sigh:
            T.lid = min(T.lid, 0.6); T.squash += 0.1 * e; T.mouth = max(T.mouth, p > 0.4 && p < 0.8 ? 0.3 : 0); T.lookY = -0.4
            if fire(1, p > 0.45) { emit(.dust, count: 1, spread: 2, life: 0.8, x: 4, y: -44, vx: 10, vy: 8) }
        case .bigJump:
            T.armL = max(T.armL, 150 * e); T.armR = max(T.armR, 150 * e); T.joy = max(T.joy, e); T.smile = 1; T.mouth = max(T.mouth, 0.5)
        case .propeller:
            T.propeller = true; T.float = 16 * e; T.armL = max(T.armL, 70 * e); T.armR = max(T.armR, 70 * e)
            T.joy = max(T.joy, 0.5 * e); T.smile = 0.9; T.lean += CGFloat(sin(t * 3)) * 4 * e
        case .tapFoot:
            T.footR = max(T.footR, CGFloat(abs(sin(t * 10))) * 5 * e); T.lookX = s * 0.6; T.browShow = max(T.browShow, 0.5 * e)
            T.brow = 0.3; T.smile = min(T.smile, 0.05)
        case .rubEyes:
            T.armL = max(T.armL, 125 * e); T.armR = max(T.armR, 125 * e)
            T.lid = min(T.lid, 0.15 + 0.3 * CGFloat(abs(sin(t * 8)))); T.mouth = max(T.mouth, 0.3 * e); T.smile = 0.1
        case .shadesOn, .shadesOff:
            T.armL = max(T.armL, 150 * e); T.armR = max(T.armR, 150 * e); T.smile = 0.8
            if a.kind == .shadesOn { T.shades = p > 0.35 ? 1 : 0 } else { T.shades = p > 0.6 ? 0 : 1 }
        case .blushHide:
            T.blush = 1; T.lid = min(T.lid, 0); T.lean += s * 10 * e; T.squash += 0.1 * e; T.smile = 0.6
            T.armL = max(T.armL, 40 * e); T.armR = max(T.armR, 40 * e)
        case .cheer:
            T.armL = max(T.armL, 120 + CGFloat(sin(t * 12)) * 40); T.armR = max(T.armR, 120 - CGFloat(sin(t * 12)) * 40)
            T.joy = 1; T.smile = 1; T.mouth = max(T.mouth, 0.6)
        case .lookBack:
            T.lookX = -s * 1; T.facing = 0; T.lid = min(T.lid, 0.7); T.armR = max(T.armR, 140 + CGFloat(sin(t * 12)) * 20 * e)
        case .hiccup:
            T.wide = max(T.wide, 0.5); T.mouth = max(T.mouth, 0.2); T.smile = 0.1; T.blush = 0.6
        case .juggle:
            T.armL = 70 + CGFloat(max(0, sin(t * 10))) * 50 * e; T.armR = 70 + CGFloat(max(0, -sin(t * 10))) * 50 * e
            T.lookY = 0.9; T.lookX = CGFloat(sin(t * 5)) * 0.4; T.smile = 0.7; T.mouth = max(T.mouth, 0.15)
        case .pushups:
            T.squash += 0.25 * CGFloat(abs(sin(t * 5.5))) * e; T.armL = 100 * e; T.armR = 100 * e
            T.browShow = 0.8 * e; T.brow = 0.6; T.smile = 0.2; T.blush = 0.6 + 0.3 * e
        case .whistle:
            T.mouth = 0.1; T.smile = -0.1; T.lookY = 0.5; T.lookX = s * 0.6; T.lean += CGFloat(sin(t * 3)) * 4 * e
        case .shiver:
            T.lean += CGFloat(sin(t * 60)) * 3 * e; T.squash += 0.05 * e; T.armL = 30; T.armR = 30
            T.lid = min(T.lid, 0.8); T.smile = -0.2; T.mouth = max(T.mouth, 0.15)
        case .sproutPat:
            T.armR = max(T.armR, 165 * e); T.lookY = 1; T.lookX = 0.1; T.smile = 0.8
            T.sprout += CGFloat(sin(t * 18)) * 14 * e
        case .flex:
            T.armL = max(T.armL, 120 * e); T.armR = max(T.armR, 120 * e); T.squash -= 0.1 * e
            T.browShow = e; T.brow = 0.6; T.smile = 1; T.wide = max(T.wide, 0.3 * e)
        case .readHistory:
            T.lookY = -0.1; T.lookX = CGFloat(sin(t * 4)) * 0.7; T.wide = 0.3; T.mouth = max(T.mouth, 0.12); T.smile = 0.4
        case .paperPlane:
            // Holds it up, throws it, and it loops away.
            if p < 0.28 {
                let q = CGFloat(p / 0.28)
                arm(120 + 40 * q); T.lookX = 0.6 * s; T.lookY = 0.5; T.smile = 0.7
                prop = PetProp(kind: .plane, x: 40 * s, y: 62 + 6 * q, angle: -10 * s)
            } else {
                let q = (p - 0.28) / 0.72
                if fire(1, true) { lean.v += 200 * s }
                let x = CGFloat(40 + q * 300 + sin(q * 2 * .pi) * 30) * s
                let y = CGFloat(68 + sin(q * .pi * 2) * 55 + q * 90)
                let dx = (300 + cos(q * 2 * .pi) * 60) * Double(s), dy = cos(q * .pi * 2) * 110 + 90
                prop = PetProp(kind: .plane, x: x, y: y, angle: CGFloat(-atan2(dy, dx) * 180 / .pi))
                T.lookX = max(-1, min(1, x / 90)); T.lookY = max(-0.3, min(1, (y - 50) / 80)); T.wide = 0.4; T.smile = 0.8
                if q < 0.15 { arm(60) }
                if fire(2, q > 0.85), chance(0.4) { perform(.wave, t, side: s) }
            }
        case .ball:
            // Kicks a ball; it bounces away and back, and gets caught.
            let q = p
            let out = CGFloat(sin(q * .pi))
            let x = (34 + out * 120) * s
            let bounce = CGFloat(abs(sin(q * .pi * 5))) * 44 * (0.4 + 0.6 * out)
            prop = PetProp(kind: .ball, x: x, y: 6 + bounce, angle: CGFloat(q * 900) * s)
            if fire(1, q > 0.02) { T.footR = 8 }
            T.lookX = max(-1, min(1, x / 100)); T.lookY = bounce / 60; T.smile = 0.8; T.wide = 0.3
            if q > 0.88 { T.armL = 90; T.armR = 90; T.joy = 0.7 }
            if fire(2, q > 0.9) { squash.v += 4 }
        case .book:
            // Reads a little book, turning a page now and then.
            prop = PetProp(kind: .book, x: 0, y: 8, phase: CGFloat((p * 3).truncatingRemainder(dividingBy: 1)))
            T.armL = 55 * e; T.armR = 55 * e; T.lookY = -0.6; T.lookX = CGFloat(sin(t * 3)) * 0.5
            T.smile = 0.4; T.mouth = max(T.mouth, 0.06); T.wide = 0.2
        case .raincloud:
            // A little cloud rains on it; it sulks, shakes, and the cloud drifts off.
            let leave = p > 0.75 ? CGFloat((p - 0.75) / 0.25) : 0
            let arrive = CGFloat(min(1, p / 0.12))
            prop = PetProp(kind: .cloud, x: (1 - arrive) * -160 * s + leave * 200 * s, y: Self.bodyH + 48)
            if p > 0.12, p < 0.78, chance(Double(dt) * 14) {
                emit(.sweat, spread: 16, life: 0.55, x: (1 - arrive) * -160 * s + leave * 200 * s, y: 28, vy: -70, delay: 0)
            }
            T.lid = min(T.lid, 0.7); T.smile = -0.5; T.browShow = 0.9; T.brow = -0.6; T.lookY = 0.8
            T.squash += 0.06 * e
            if p > 0.8 { T.lean += CGFloat(sin(t * 40)) * 6 * CGFloat(1 - (p - 0.8) / 0.2); T.lid = 1; T.smile = 0.3 }
        case .balloon:
            // Holds a balloon on a string; then it slips away up.
            let hand = CGPoint(x: 44 * s, y: 58)
            let bob = CGFloat(sin(t * 2.2)) * 4
            let gone = p > 0.7 ? CGFloat((p - 0.7) / 0.3) : 0
            let bx = (44 + 8 * CGFloat(sin(t * 1.3))) * s + gone * 60 * s, by = 108 + bob + gone * gone * 260
            prop = PetProp(kind: .balloon, x: bx, y: by, angle: CGFloat(sin(t * 1.3)) * 8, hand: gone > 0 ? CGPoint(x: bx, y: by - 26 - 14) : hand)
            arm(gone > 0 ? 90 : 110); T.lookX = max(-1, min(1, bx / 80)); T.lookY = min(1, (by - 40) / 90); T.smile = gone > 0 ? -0.2 : 0.8
            if gone > 0 { T.wide = 0.6; T.mouth = max(T.mouth, 0.35) }
        case .tea:
            // A cup of tea: two sips, steam, a happy sigh.
            let sip = CGFloat(max(bell((p - 0.25) / 0.2), bell((p - 0.6) / 0.2)))
            prop = PetProp(kind: .cup, x: 8 * s, y: 12 + sip * 12, angle: -sip * 25 * s)
            T.armL = 60 * e + sip * 20; T.armR = 60 * e + sip * 20
            T.lid = min(T.lid, 1 - 0.85 * sip); T.blush = 0.6 + 0.3 * sip; T.smile = 0.5; T.lookY = -0.3
            if chance(Double(dt) * 3) { emit(.dust, spread: 6, life: 1, x: 6 * s, y: -30, vy: 18, delay: 0) }
        case .yoyo:
            let hand = CGPoint(x: 42 * s, y: 46)
            let drop = CGFloat(abs(sin(t * 4.2))) * 46 * e
            prop = PetProp(kind: .yoyo, x: hand.x, y: hand.y - drop - 6, angle: CGFloat(t * 720), hand: hand)
            arm(70 + (1 - drop / 46) * 20); T.lookX = 0.5 * s; T.lookY = -0.2 - drop / 60; T.smile = 0.7
        case .wink:
            T.smile = 0.85; T.blush = max(T.blush, 0.6); T.lookX = 0.3
        case .scratchHead:
            arm(165 + CGFloat(sin(t * 22)) * 8 * e); T.lookY = 0.6; T.browShow = 0.6 * e; T.brow = -0.2; T.smile = 0.05
            T.lean += s * 4 * e
        case .sideStretch:
            T.lean += s * 15 * e; T.armL = max(T.armL, 150 * e); T.armR = max(T.armR, 150 * e); T.squash -= 0.1 * e
            T.lid = min(T.lid, 1 - 0.5 * e); T.mouth = max(T.mouth, 0.3 * e)
        case .pebbleKick:
            let k = bell(min(1, max(0, (p - 0.25) / 0.3)))
            if s > 0 { T.footR = max(T.footR, 10 * k) } else { T.footL = max(T.footL, 10 * k) }
            T.lookX = s * 0.8; T.lookY = -0.5; T.lean += -s * 5 * k
            if fire(1, p > 0.4) { emit(.dust, count: 2, spread: 4, life: 0.6, x: s * 30, y: -Self.bodyH - 2, vx: s * 90, vy: 10, delay: 0.05) }
        case .tinyBounce:
            T.smile = 0.85; T.joy = max(T.joy, 0.5 * e)
        case .lookUp:
            T.lookY = 1; T.lookX = CGFloat(sin(t * 1.2)) * 0.4; T.wide = max(T.wide, 0.3); T.mouth = max(T.mouth, 0.18)
        case .perk:
            T.wide = max(T.wide, 0.7 * e); T.armL = max(T.armL, 70 * e); T.armR = max(T.armR, 70 * e)
            T.smile = 0.8; T.joy = max(T.joy, 0.3 * e); T.lookX = s; T.lookY = 0.4
        case .showItem:
            T.armL = max(T.armL, 160 * e); T.armR = max(T.armR, 160 * e); T.joy = max(T.joy, 0.8); T.smile = 1; T.mouth = max(T.mouth, 0.45)
        case .peekIn:
            T.lean += s * 22 * e; T.wide = max(T.wide, 0.6); T.lookX = s; T.lookY = 0.1; T.smile = 0.6
            arm(60 * e)
        case .water:
            arm(150); T.lookY = 1; T.lookX = 0.1 * s; T.smile = 0.7; T.lid = min(T.lid, 0.8)
            prop = PetProp(kind: .can, x: 16 * s, y: Self.bodyH + 26, angle: -CGFloat(min(1, p * 4)) * 35 * s)
            if p > 0.2, p < 0.8, chance(Double(dt) * 16) { emit(.sweat, spread: 4, life: 0.4, x: 6 * s, y: 14, vy: -50, delay: 0) }
            if fire(1, p > 0.85) { emit(.sparkle, count: 4, spread: 16, life: 0.8, y: 10, vy: 26, delay: 0.08) }
        case .nap:
            T.squash += 0.1 * e; T.lid = 0; T.lean += s * 8 * e; T.smile = 0.2; T.lookY = -0.5
            if p > 0.1, p < 0.85, !brain.particles.contains(where: { $0.kind == .z && t - $0.born < 1.2 }) { emit(.z, spread: 4, life: 2, x: 22, y: -6, vy: 22) }
            if fire(1, p > 0.9) { squash.v -= 6; T.wide = 1 }
        case .skipRope:
            T.armL = max(T.armL, 55); T.armR = max(T.armR, 55); T.smile = 0.9; T.joy = max(T.joy, 0.4); T.lookY = -0.2
        case .zoom:
            T.lean += s * -18 * e; T.wide = max(T.wide, 0.4); T.smile = 0.8; T.armL = 60 * e; T.armR = 60 * e
        case .cross:
            T.browShow = 1; T.brow = 1; T.smile = -0.5; T.mouth = max(T.mouth, 0.2); T.lean += s * 6 * e
            T.armL = max(T.armL, 30 * e); T.armR = max(T.armR, 30 * e); T.squash += 0.06 * e
        }
    }
}

// MARK: - Window and touch

final class PetWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Anywhere, the menu bar's height included: no keeping it below the bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// A tap opens the chat; a drag picks the pet up; a right-click boops it.
final class PetTouchView: NSView {
    var onTap: (() -> Void)?
    var onHold: (() -> Void)?
    var onDrag: (() -> Void)?
    var onDrop: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
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
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
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
    static let rope = Color(red: 0.62, green: 0.47, blue: 0.33)
}

struct PetView: View {
    let brain: PetBrain

    var body: some View {
        let p = brain.pose
        let W = PetController.size.width, H = PetController.size.height
        let ground = PetController.floor + p.lift + p.bob
        ZStack(alignment: .bottom) {
            // The shadow: smaller and fainter the higher it is; none while held.
            let s = max(0.35, 1 - p.lift / 170)
            Ellipse()
                .fill(RadialGradient(colors: [.black.opacity(0.26 * Double(s) * Double(1 - p.dangle)), .clear], center: .center, startRadius: 0, endRadius: 40))
                .frame(width: 92 * s, height: 16 * s)
                .offset(y: -PetController.floor + 8)

            // The pet, and the rope it hangs from while dragged, swinging together.
            ZStack(alignment: .bottom) {
                PetCreature(p: p, look: brain.look, c: brain.look.palette)
                    .offset(y: -ground - PetController.holdRaise * p.rope)
            }
            .frame(width: W, height: H, alignment: .bottom)
            // Held: it hangs from its hand, at the cursor, swinging round it.
            .rotationEffect(.radians(Double(p.ropeAngle)),
                            anchor: UnitPoint(x: PetController.hand.x / W, y: 1 - (PetController.hand.y + PetController.holdRaise * p.rope) / H))

            if let item = p.carry {
                Text(item).font(.system(size: 24))
                    .offset(y: -(ground + PetController.bodyH + 20))
            }

            if p.skip != 0 {
                // The skipping rope: from hand to hand, swinging over the head and under the feet.
                let bottom = 46 - CGFloat(cos(p.skip)) * 58
                Path { path in
                    path.move(to: CGPoint(x: W / 2 - 44, y: H - (ground + 46)))
                    path.addQuadCurve(to: CGPoint(x: W / 2 + 44, y: H - (ground + 46)), control: CGPoint(x: W / 2, y: H - (ground + 2 * bottom - 46)))
                }
                .stroke(Color(red: 0.95, green: 0.55, blue: 0.3), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: W, height: H)
                .opacity(sin(p.skip) > 0 ? 0.45 : 1)
            }

            if let prop = p.prop {
                PetPropView(prop: prop)
                    .offset(x: prop.x, y: -(ground + prop.y))
                if let hand = prop.hand {
                    // The string, from the hand to the thing.
                    let dx = prop.x - hand.x, dy = prop.y - hand.y
                    Capsule().fill(Color(white: 0.45))
                        .frame(width: 1, height: max(1, hypot(dx, dy)))
                        .rotationEffect(.radians(Double(atan2(dx, dy))), anchor: .bottom)
                        .offset(x: hand.x, y: -(ground + hand.y))
                }
            }

            if p.juggle > 0 {
                ForEach(0..<3, id: \.self) { i in
                    let k = (p.juggle * 1.3 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let fade = min(1, p.juggle * 3) * Double(min(1, max(0, (4.2 - p.juggle) * 3)))
                    Circle()
                        .fill([Color(red: 1, green: 0.55, blue: 0.4), Color(red: 0.45, green: 0.75, blue: 1), Color(red: 1, green: 0.8, blue: 0.3)][i])
                        .frame(width: 8, height: 8)
                        .offset(x: CGFloat(cos(k * 2 * .pi)) * 30, y: -(ground + PetController.bodyH + 8 + CGFloat(abs(sin(k * 2 * .pi))) * 34))
                        .opacity(fade)
                }
            }

            if p.soap > 0.01 {
                let d = 6 + p.soap * 24
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.05), Color(red: 0.7, green: 0.85, blue: 1).opacity(0.3)], center: .center, startRadius: 0, endRadius: d / 2))
                    .overlay(Circle().stroke(LinearGradient(colors: [.pink.opacity(0.6), .cyan.opacity(0.6), .purple.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    .overlay(Circle().fill(.white.opacity(0.8)).frame(width: d * 0.2, height: d * 0.2).offset(x: -d * 0.2, y: -d * 0.2))
                    .frame(width: d, height: d)
                    .offset(x: 22 + d / 2 + CGFloat(sin(p.time * 3)) * p.soapRise * 0.15, y: -(ground + 26 + p.soapRise))
            }

            if let b = p.butterfly {
                PetButterfly(time: p.time)
                    .offset(x: b.x, y: -(ground + b.y))
            }

            ForEach(brain.particles) { particle in
                PetParticleView(particle: particle, time: p.time)
                    .offset(y: -(ground + PetController.bodyH + 14))
            }

            if let b = brain.bubble {
                let side = brain.bubbleSide
                let w = PetController.bubbleWidth(b.text)
                PetSpeech(text: b.text, tail: side)
                    .id(b.id)
                    .offset(x: side * (PetController.bodyW / 2 + 18 + w / 2),
                            y: side == 0 ? -(ground + PetController.bodyH + 34) : -(ground + PetController.bodyH * 0.55 - 15))
                    .transition(.scale(scale: 0.4, anchor: side == 0 ? .bottom : side < 0 ? .trailing : .leading).combined(with: .opacity))
            }
        }
        .frame(width: W, height: H, alignment: .bottom)
        .animation(.spring(duration: 0.35, bounce: 0.45), value: brain.bubble)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: brain.bubbleSide)
    }
}

struct PetCreature: View {
    let p: PetPose
    let look: PetLook
    let c: PetColors

    var body: some View {
        let w = PetController.bodyW, h = PetController.bodyH
        let sx = 1 + p.squash, sy = 1 - p.squash
        // Spinning round: narrower side-on, the face gone while its back is turned.
        let turnCos = CGFloat(cos(Double(p.turn)))
        let front = max(0, turnCos)
        ZStack(alignment: .bottom) {
            // Feet: stepping, tucked in the air, swinging while held.
            ForEach([-1.0, 1.0], id: \.self) { side in
                let s = CGFloat(side)
                Ellipse()
                    .fill(LinearGradient(colors: [c.limb, c.foot], startPoint: .top, endPoint: .bottom))
                    .frame(width: 21, height: 11)
                    .rotationEffect(.degrees(Double(p.swing * (1 + s * 0.15) + s * 8 * p.dangle)), anchor: .top)
                    .offset(x: (s * 18 * sx + p.swing * 0.25) * max(0.3, abs(turnCos)), y: -(side < 0 ? p.footL : p.footR) + p.dangle * 7)
            }

            ZStack {
                // Arms, behind the body, peeking out at its sides.
                ForEach([-1.0, 1.0], id: \.self) { side in
                    let s = CGFloat(side)
                    let raise = side < 0 ? p.armL : p.armR
                    // Held, the right arm stretches up to hold on.
                    let length = 23 + (side > 0 ? 23 * p.rope : 0)
                    Capsule()
                        .fill(LinearGradient(colors: [c.limb, c.foot], startPoint: .top, endPoint: .bottom))
                        .frame(width: 11, height: length)
                        .rotationEffect(.degrees(Double(-s * (38 + raise))), anchor: .top)
                        .offset(x: s * (w / 2 - 2), y: -2.5 + length / 2)
                }

                PetBlob()
                    .fill(LinearGradient(colors: [c.top, c.bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(PetBlob().stroke(c.edge.opacity(0.35), lineWidth: 1))
                    .overlay(PetBlob().inset(by: 1.5).stroke(.white.opacity(0.45), lineWidth: 1.2).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
                    .frame(width: w, height: h)

                // Belly and shine.
                Ellipse().fill(c.belly.opacity((look.belly ? 0.55 : 0) * Double(front)))
                    .frame(width: w * 0.5, height: h * 0.32)
                    .offset(y: h * 0.31)
                Ellipse().fill(.white.opacity(look.shine ? 0.55 : 0))
                    .frame(width: 17, height: 9)
                    .rotationEffect(.degrees(-28))
                    .offset(x: -w * 0.24, y: -h * 0.27)

                PetFace(p: p, look: look, c: c)
                    .offset(x: p.facing * 8 + p.lookX * 4, y: -4 - p.lookY * 3)
                    .opacity(Double(min(1, front * 1.6)))

                PetTop(p: p, kind: look.top, c: c)
                    .offset(y: -h / 2 - 6)
            }
            .frame(width: w, height: h)
            .scaleEffect(x: sx * max(0.16, abs(turnCos)) * look.width, y: sy * look.height, anchor: .bottom)
            .offset(y: -5)
        }
        .frame(width: 140, height: 140, alignment: .bottom)
        // Leaning far over (a trip), it rests on its side instead of sinking into the floor.
        .rotationEffect(.degrees(Double(p.lean)), anchor: .bottom)
        .offset(y: -abs(sin(Double(p.lean) * .pi / 180)) * Double(w) * 0.42)
    }
}

struct PetFace: View {
    let p: PetPose
    let look: PetLook
    let c: PetColors

    var body: some View {
        ZStack {
            // Cheeks.
            HStack(spacing: 30) {
                ForEach(0..<2, id: \.self) { _ in
                    Ellipse()
                        .fill(RadialGradient(colors: [c.cheek.opacity(Double(p.blush) * (look.cheeks ? 0.75 : 0.25)), c.cheek.opacity(0)], center: .center, startRadius: 0, endRadius: 8))
                        .frame(width: 15, height: 9)
                }
            }
            .offset(y: 7)

            HStack(spacing: 17) {
                PetEye(p: p, side: -1, c: c, scale: look.eyes == "big" ? 1.3 : look.eyes == "small" ? 0.72 : 1)
                PetEye(p: p, side: 1, c: c, scale: look.eyes == "big" ? 1.3 : look.eyes == "small" ? 0.72 : 1)
            }
            .offset(x: p.lookX * 1.5, y: -p.lookY * 1.5)

            // Brows, for worry, thought and a cross look.
            HStack(spacing: 15) {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Capsule().fill(c.ink.opacity(0.8))
                        .frame(width: 9, height: 2.2)
                        .rotationEffect(.degrees(side * Double(p.brow) * -22))
                }
            }
            .offset(y: -12 - p.wide * 2)
            .opacity(Double(p.browShow))

            // Shades: slid down onto the eyes.
            PetShades()
                .offset(y: -1 - 16 * (1 - p.shades))
                .opacity(Double(min(1, p.shades * 1.4)))

            PetMouth(p: p, c: c)
                .offset(y: 10)
        }
    }
}

struct PetShades: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .topLeading) {
                        Capsule().fill(.white.opacity(0.5)).frame(width: 5, height: 1.6).rotationEffect(.degrees(-20)).offset(x: 3, y: 3)
                    }
                    .frame(width: 16, height: 11)
            }
        }
        .overlay(Capsule().fill(Color(white: 0.1)).frame(width: 40, height: 2).offset(y: -4))
    }
}

struct PetEye: View {
    let p: PetPose
    let side: CGFloat
    let c: PetColors
    var scale: CGFloat = 1

    // One shape at a time, never two faded over each other: the open eye
    // closes (as in a blink) before it turns into ^ or a spiral, which then
    // grow in.
    var body: some View {
        let size = (1 + p.wide * 0.28) * scale
        // How shut the open eye is: its lid, and it closing on the way to another shape.
        let lid = min(side > 0 ? min(p.lid, 1 - min(1, p.wink)) : p.lid, 1 - min(1, max(p.joy, p.dizzy) * 2))
        ZStack {
            if p.dizzy >= 0.5 {
                PetSpiral()
                    .stroke(c.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 12, height: 12)
                    .rotationEffect(.radians(Double(p.spin * side)))
                    .scaleEffect(min(1, (p.dizzy - 0.5) * 2.5))
            } else if p.joy >= 0.5 {
                PetArc(up: true)
                    .stroke(c.ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .frame(width: 11, height: 6)
                    .scaleEffect(x: 1, y: min(1, 0.3 + (p.joy - 0.5) * 2), anchor: .bottom)
            } else if lid < 0.16 {
                PetArc(up: false)
                    .stroke(c.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .frame(width: 11, height: 5)
            } else {
                ZStack {
                    Ellipse().fill(c.ink).frame(width: 9.5 * size, height: 12.5 * size)
                    if p.awe >= 0.5 {
                        // Starry-eyed.
                        Image(systemName: "sparkle").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.white)
                            .offset(x: 0.8, y: -1.6)
                            .scaleEffect(0.8 + 0.25 * CGFloat(sin(p.time * 9)))
                    } else {
                        Circle().fill(.white).frame(width: 3.8, height: 3.8).offset(x: 1.6 * size, y: -2.8 * size)
                        Circle().fill(.white.opacity(0.8)).frame(width: 1.7, height: 1.7).offset(x: -1.8 * size, y: 2.8 * size)
                    }
                }
                .scaleEffect(x: 1, y: lid, anchor: .center)
            }
        }
        .frame(width: 14, height: 16)
    }
}

struct PetMouth: View {
    let p: PetPose
    let c: PetColors

    var body: some View {
        let open = min(1, max(0, (p.mouth - 0.05) / 0.1))
        ZStack(alignment: .top) {
            ZStack {
                PetMouthLine(smile: p.smile)
                    .stroke(c.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 10, height: 6)
                    .opacity(Double(1 - open))
                PetMouthOpen(smile: p.smile, open: p.mouth)
                    .fill(c.mouth)
                    .overlay(alignment: .bottom) {
                        Ellipse().fill(c.tongue)
                            .frame(width: 6 + p.mouth * 3, height: 3 + p.mouth * 3)
                            .offset(y: -1)
                            .opacity(Double(min(1, max(0, (p.mouth - 0.25) * 3))))
                    }
                    .clipShape(PetMouthOpen(smile: p.smile, open: p.mouth))
                    .frame(width: 10 + p.mouth * 4, height: 3 + p.mouth * 11)
                    .opacity(Double(open))
            }
            .frame(width: 18, height: 16)
            // Sticking its tongue out.
            Capsule().fill(c.tongue)
                .overlay(Capsule().fill(c.mouth.opacity(0.25)).frame(width: 1, height: 5).offset(y: -1))
                .frame(width: 8, height: 9 * p.tongue)
                .offset(y: 8)
                .opacity(Double(min(1, p.tongue * 2)))
        }
        .frame(width: 18, height: 16, alignment: .top)
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

// What's on its head: swaying (and spinning like a propeller) with the body.
struct PetTop: View {
    let p: PetPose
    let kind: String
    let c: PetColors

    var body: some View {
        let flutter = CGFloat(sin(p.time * 3.1)) * 4
        let prop = p.propeller == 0 ? 1 : CGFloat(cos(Double(p.propeller)))
        let light = LinearGradient(colors: [c.accessory, c.accessory.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        ZStack(alignment: .bottom) {
            switch kind {
            case "none":
                EmptyView()
            case "catEars":
                ForEach([-1.0, 1.0], id: \.self) { side in
                    PetEar().fill(light)
                        .overlay(PetEar().fill(c.accent).scaleEffect(0.5, anchor: .bottom).offset(y: -1))
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(side * Double(16 + flutter * 0.5)), anchor: .bottom)
                        .offset(x: CGFloat(side) * 21, y: 9)
                }
            case "bunnyEars":
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Capsule().fill(light)
                        .overlay(Capsule().fill(c.accent).padding(.horizontal, 3).padding(.vertical, 5))
                        .frame(width: 11, height: 32)
                        .rotationEffect(.degrees(side * Double(12 + flutter)), anchor: .bottom)
                        .offset(x: CGFloat(side) * 11, y: 6)
                }
            case "bearEars":
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Circle().fill(light)
                        .overlay(Circle().fill(c.accent).padding(4))
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(side * Double(flutter * 0.4)), anchor: .bottom)
                        .offset(x: CGFloat(side) * 25, y: 15)
                }
            case "antenna":
                Capsule().fill(c.accent).frame(width: 2.4, height: 15)
                Circle().fill(RadialGradient(colors: [.white, c.accessory], center: .topLeading, startRadius: 0, endRadius: 7))
                    .shadow(color: c.accessory.opacity(0.7), radius: 3 + 2 * CGFloat(abs(sin(p.time * 2))))
                    .frame(width: 9, height: 9).offset(y: -13)
            case "horns":
                ForEach([-1.0, 1.0], id: \.self) { side in
                    PetEar().fill(LinearGradient(colors: [c.accent, c.accessory], startPoint: .top, endPoint: .bottom))
                        .frame(width: 9, height: 13)
                        .rotationEffect(.degrees(side * 14), anchor: .bottom)
                        .offset(x: CGFloat(side) * 14, y: 4)
                }
            case "bow":
                ForEach([-1.0, 1.0], id: \.self) { side in
                    PetEar().fill(light).frame(width: 12, height: 14)
                        .rotationEffect(.degrees(side * Double(-90 + flutter)), anchor: .bottom)
                        .offset(x: 0, y: -5)
                }
                Circle().fill(c.accent).frame(width: 7, height: 7).offset(y: -4)
            case "crown":
                PetCrown().fill(LinearGradient(colors: [c.accessory, c.accessory.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                    .overlay(HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().fill(c.accent).frame(width: 3.5, height: 3.5) } }.offset(y: 3))
                    .frame(width: 26, height: 14)
                    .offset(y: 4)
            case "flower":
                Capsule().fill(c.accent).frame(width: 2.4, height: 10)
                ZStack {
                    ForEach(0..<5, id: \.self) { i in
                        Ellipse().fill(c.accessory).frame(width: 7, height: 9)
                            .offset(y: -5).rotationEffect(.degrees(Double(i) * 72))
                    }
                    Circle().fill(c.accent).frame(width: 6, height: 6)
                }
                .rotationEffect(.degrees(Double(flutter) * 2))
                .offset(y: -12)
            default:
                // The sprout.
                Capsule().fill(c.accent).frame(width: 2.6, height: 13)
                ZStack(alignment: .bottom) {
                    Ellipse().fill(LinearGradient(colors: [c.accessory, c.accent], startPoint: .top, endPoint: .bottom))
                        .frame(width: 14, height: 7.5)
                        .rotationEffect(.degrees(Double(-28 - flutter)), anchor: .trailing)
                        .offset(x: -7, y: -10)
                    Ellipse().fill(LinearGradient(colors: [c.accessory, c.accent], startPoint: .top, endPoint: .bottom))
                        .frame(width: 14, height: 7.5)
                        .rotationEffect(.degrees(Double(28 + flutter)), anchor: .leading)
                        .offset(x: 7, y: -11)
                }
                .scaleEffect(x: max(0.08, abs(prop)), y: 1, anchor: .bottom)
            }
        }
        .frame(width: 70, height: 30, alignment: .bottom)
        .scaleEffect(x: kind == "sprout" ? 1 : max(0.15, abs(prop)), y: 1, anchor: .bottom)
        .scaleEffect(p.sproutScale, anchor: .bottom)
        .rotationEffect(.degrees(Double(p.sprout)), anchor: .bottom)
    }
}

// A rounded triangle, point up (ears, horns, bow loops).
struct PetEar: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.3))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.maxX - r.width * 0.2, y: r.minY + r.height * 0.3))
        p.closeSubpath()
        return p
    }
}

struct PetCrown: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.25))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.25, y: r.minY + r.height * 0.6))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.25, y: r.minY + r.height * 0.6))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.25))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct PetPropView: View {
    let prop: PetProp

    var body: some View {
        switch prop.kind {
        case .plane:
            PetPlane()
                .fill(.white)
                .overlay(PetPlane().stroke(Color(white: 0.6), lineWidth: 0.8))
                .frame(width: 24, height: 12)
                .rotationEffect(.degrees(Double(prop.angle)))
                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
        case .ball:
            Circle()
                .fill(AngularGradient(colors: [.red, .white, .blue, .white, .yellow, .white, .red], center: .center))
                .overlay(Circle().stroke(Color(white: 0.5).opacity(0.4), lineWidth: 0.6))
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(Double(prop.angle)))
        case .book:
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.35, green: 0.45, blue: 0.85)).frame(width: 34, height: 22)
                HStack(spacing: 1) {
                    ForEach(0..<2, id: \.self) { _ in
                        VStack(spacing: 2.5) { ForEach(0..<4, id: \.self) { _ in Capsule().fill(Color(white: 0.75)).frame(width: 10, height: 1) } }
                            .frame(width: 15, height: 19).background(Color(white: 0.98))
                    }
                }
                // The page being turned.
                Rectangle().fill(Color(white: 0.95)).frame(width: 15, height: 19)
                    .scaleEffect(x: cos(Double(prop.phase) * .pi), y: 1, anchor: .leading)
                    .offset(x: 8)
                    .opacity(prop.phase > 0.02 && prop.phase < 0.98 ? 1 : 0)
            }
        case .cloud:
            ZStack {
                Ellipse().fill(Color(white: 0.78)).frame(width: 46, height: 20).offset(y: 4)
                Circle().fill(Color(white: 0.82)).frame(width: 24, height: 24).offset(x: -8, y: -3)
                Circle().fill(Color(white: 0.86)).frame(width: 20, height: 20).offset(x: 10, y: -1)
            }
        case .balloon:
            ZStack {
                Ellipse().fill(RadialGradient(colors: [Color(red: 1, green: 0.5, blue: 0.55), Color(red: 0.9, green: 0.2, blue: 0.3)], center: .topLeading, startRadius: 2, endRadius: 22))
                    .frame(width: 22, height: 26)
                Ellipse().fill(.white.opacity(0.5)).frame(width: 5, height: 8).offset(x: -5, y: -6)
                PetTail().fill(Color(red: 0.9, green: 0.2, blue: 0.3)).frame(width: 5, height: 4).offset(y: 14)
            }
            .rotationEffect(.degrees(Double(prop.angle)))
        case .cup:
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.98)).frame(width: 17, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.75), lineWidth: 0.8))
                Circle().stroke(Color(white: 0.75), lineWidth: 1.8).frame(width: 7, height: 7).offset(x: 10)
                Rectangle().fill(Color(red: 0.6, green: 0.4, blue: 0.25)).frame(width: 15, height: 2.5).offset(y: -4.5)
            }
            .rotationEffect(.degrees(Double(prop.angle)))
        case .can:
            // A little watering can, spout to the side.
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.4, green: 0.7, blue: 0.95)).frame(width: 16, height: 13)
                Capsule().fill(Color(red: 0.35, green: 0.62, blue: 0.88)).frame(width: 12, height: 3)
                    .rotationEffect(.degrees(-30)).offset(x: 11, y: -3)
                Circle().stroke(Color(red: 0.35, green: 0.62, blue: 0.88), lineWidth: 2).frame(width: 8, height: 8).offset(x: -9)
            }
            .rotationEffect(.degrees(Double(prop.angle)))
        case .yoyo:
            ZStack {
                Circle().fill(Color(red: 0.95, green: 0.4, blue: 0.4)).frame(width: 11, height: 11)
                Capsule().fill(.white.opacity(0.7)).frame(width: 2, height: 9)
            }
            .rotationEffect(.degrees(Double(prop.angle)))
        }
    }
}

struct PetPlane: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.3, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        p.move(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.3, y: r.midY))
        return p
    }
}

struct PetButterfly: View {
    let time: Double

    var body: some View {
        let flap = max(0.15, abs(CGFloat(sin(time * 22))))
        ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                ZStack {
                    Ellipse().fill(LinearGradient(colors: [Color(red: 1, green: 0.75, blue: 0.3), Color(red: 1, green: 0.5, blue: 0.4)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 9, height: 8).offset(y: -2)
                    Ellipse().fill(Color(red: 1, green: 0.62, blue: 0.5)).frame(width: 6, height: 6).offset(x: 0, y: 4)
                }
                .scaleEffect(x: flap, y: 1, anchor: side < 0 ? .trailing : .leading)
                .offset(x: CGFloat(side) * 4.5)
            }
            Capsule().fill(Color(white: 0.2)).frame(width: 2, height: 9)
        }
        .rotationEffect(.degrees(sin(time * 3) * 12))
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
            let pop = particle.kind == .sparkle || particle.kind == .bang || particle.kind == .star ? 0.6 + 0.6 * bell(min(1, k * 2)) : 1
            let wobble = particle.kind == .heart || particle.kind == .note || particle.kind == .z || particle.kind == .question ? CGFloat(sin(age * 5 + Double(particle.id))) * 5 : 0
            let gravity: CGFloat = particle.kind == .tear || particle.kind == .sweat ? -60 * CGFloat(age * age) : 0
            symbol(k)
                .scaleEffect(pop)
                .opacity(fadeIn * fadeOut)
                .offset(x: particle.x + particle.vx * CGFloat(age) + wobble,
                        y: -(particle.y + particle.vy * CGFloat(age) + gravity))
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
        case .star:
            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.3))
                .rotationEffect(.degrees(k * 360))
        case .sweat, .tear:
            Image(systemName: "drop.fill").font(.system(size: 9)).foregroundStyle(Color(red: 0.5, green: 0.75, blue: 1))
        case .bang:
            Text("!").font(.system(size: 18, weight: .black, design: .rounded)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.2))
        case .question:
            Text("?").font(.system(size: 16, weight: .black, design: .rounded)).foregroundStyle(Color(red: 0.45, green: 0.5, blue: 0.9))
        case .dust:
            Circle().fill(Color.gray.opacity(0.35)).frame(width: 5 + k * 8, height: 5 + k * 8)
        }
    }
}

struct PetSpeech: View {
    let text: String
    // Where the pet is: below (0), or to the right (−1, the bubble on its left) or left (1).
    var tail: CGFloat = 0

    var body: some View {
        let label = Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.black.opacity(0.8))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white))
        Group {
            if tail == 0 {
                VStack(spacing: 0) {
                    label
                    PetTail().fill(.white).frame(width: 10, height: 5)
                }
            } else {
                HStack(spacing: 0) {
                    if tail > 0 { PetTail().fill(.white).frame(width: 10, height: 5).rotationEffect(.degrees(90)).frame(width: 5, height: 10) }
                    label
                    if tail < 0 { PetTail().fill(.white).frame(width: 10, height: 5).rotationEffect(.degrees(-90)).frame(width: 5, height: 10) }
                }
            }
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

// `TapChat --render-pet <folder>`: the pet in a range of poses as PNGs,
// without starting the app (to check the drawing).
enum PetRender {
    @discardableResult @MainActor static func run(_ folder: String, look: PetLook = .default) -> [String] {
        var base = PetPose(); base.time = 1
        func with(_ f: (inout PetPose) -> Void) -> PetPose { var p = base; f(&p); return p }
        let poses: [(String, PetPose)] = [
            ("idle", base),
            ("happy", with { $0.joy = 1; $0.smile = 1; $0.mouth = 0.6; $0.blush = 0.75; $0.armL = 140; $0.armR = 150; $0.lift = 30; $0.squash = -0.08 }),
            ("thinking", with { $0.lookX = 0.5; $0.lookY = 0.75; $0.browShow = 0.7; $0.brow = -0.2; $0.smile = 0.05; $0.mouth = 0.22; $0.armR = 75; $0.armL = 20; $0.sprout = 12 }),
            ("shades", with { $0.shades = 1; $0.smile = 0.8 }),
            ("awe", with { $0.awe = 1; $0.wide = 1; $0.mouth = 0.32; $0.smile = 0.3; $0.blush = 0.6; $0.armL = 60; $0.armR = 60 }),
            ("held", with { $0.rope = 1; $0.ropeAngle = CGFloat(PetController.hangTilt); $0.dangle = 1; $0.armL = 80; $0.armR = 142; $0.wide = 0.8; $0.mouth = 0.25; $0.smile = 0.5; $0.lookY = 0.7; $0.swing = 12; $0.squash = -0.08 }),
            ("juggle", with { $0.juggle = 1; $0.armL = 110; $0.armR = 80; $0.lookY = 0.9; $0.smile = 0.7 }),
            ("flex", with { $0.armL = 120; $0.armR = 120; $0.squash = -0.1; $0.browShow = 1; $0.brow = 0.6; $0.smile = 1 }),
            ("raspberry", with { $0.tongue = 1; $0.mouth = 0.3; $0.lid = 0.5; $0.smile = 0.3 }),
            ("cross", with { $0.browShow = 1; $0.brow = 1; $0.smile = -0.5; $0.mouth = 0.2 }),
            ("spin", with { $0.turn = 2.2; $0.joy = 1 }),
            ("butterfly", with { $0.butterfly = CGPoint(x: 40, y: 100); $0.lookX = 0.6; $0.lookY = 0.7; $0.wide = 0.5; $0.smile = 0.8 }),
            ("soap", with { $0.soap = 1; $0.soapRise = 30; $0.lookX = 0.4; $0.lookY = 0.6; $0.smile = 0.8 }),
            ("trip", with { $0.lean = 72; $0.squash = 0.12; $0.mouth = 0.4; $0.lid = 0.3; $0.armL = 110; $0.armR = 110 }),
            ("propeller", with { $0.propeller = 1.2; $0.bob = 14; $0.armL = 70; $0.armR = 70; $0.joy = 0.6; $0.smile = 0.9 }),
            ("plane", with { $0.prop = PetProp(kind: .plane, x: 90, y: 110, angle: -20); $0.lookX = 0.8; $0.lookY = 0.7; $0.smile = 0.8 }),
            ("ball", with { $0.prop = PetProp(kind: .ball, x: 90, y: 30, angle: 40); $0.lookX = 0.8; $0.smile = 0.8 }),
            ("book", with { $0.prop = PetProp(kind: .book, x: 0, y: 8, phase: 0.4); $0.armL = 55; $0.armR = 55; $0.lookY = -0.6 }),
            ("raincloud", with { $0.prop = PetProp(kind: .cloud, x: 0, y: 120); $0.lid = 0.7; $0.smile = -0.5; $0.browShow = 0.9; $0.brow = -0.6; $0.lookY = 0.8 }),
            ("balloon", with { $0.prop = PetProp(kind: .balloon, x: 46, y: 108, hand: CGPoint(x: 44, y: 58)); $0.armR = 110; $0.lookX = 0.5; $0.lookY = 0.8; $0.smile = 0.8 }),
            ("tea", with { $0.prop = PetProp(kind: .cup, x: 8, y: 24, angle: -15); $0.armL = 70; $0.armR = 70; $0.lid = 0.3; $0.blush = 0.8; $0.smile = 0.5 }),
            ("yoyo", with { $0.prop = PetProp(kind: .yoyo, x: 42, y: 10, angle: 40, hand: CGPoint(x: 42, y: 46)); $0.armR = 75; $0.lookX = 0.5; $0.lookY = -0.6; $0.smile = 0.7 }),
            ("carry", with { $0.carry = "🍓"; $0.armL = 150; $0.armR = 150; $0.smile = 0.8; $0.footL = 5; $0.facing = 1 }),
            ("water", with { $0.prop = PetProp(kind: .can, x: 16, y: PetController.bodyH + 26, angle: -35); $0.armR = 150; $0.lookY = 1; $0.sproutScale = 1.4; $0.smile = 0.7 }),
            ("skip", with { $0.skip = 0.6; $0.armL = 55; $0.armR = 55; $0.smile = 0.9; $0.lift = 20 }),
            ("wink", with { $0.wink = 1; $0.smile = 0.85; $0.blush = 0.6 }),
            ("balloonLeft", with { $0.prop = PetProp(kind: .balloon, x: -46, y: 108, hand: CGPoint(x: -44, y: 58)); $0.armL = 110; $0.lookX = -0.5; $0.lookY = 0.8; $0.smile = 0.8 }),
            ("sleeping", with { $0.lid = 0; $0.smile = 0.15; $0.mouth = 0.16; $0.lean = -7; $0.lookY = -0.4; $0.sprout = -32 }),
            ("sad", with { $0.lid = 0.7; $0.smile = -0.65; $0.browShow = 1; $0.brow = -1; $0.lookY = -0.55; $0.squash = 0.06; $0.sprout = -18 }),
            ("love", with { $0.joy = 1; $0.smile = 0.85; $0.mouth = 0.2; $0.blush = 1; $0.lean = 7; $0.armL = 45; $0.armR = 45 }),
            ("dizzy", with { $0.dizzy = 1; $0.spin = 2; $0.smile = -0.15; $0.mouth = 0.3; $0.lean = 9 }),
        ]
        for (name, pose) in poses {
            let brain = PetBrain()
            brain.look = look
            brain.pose = pose
            if name == "shades" { brain.bubble = PetBubble(id: 1, text: "incognito mode 😎"); brain.bubbleSide = -1 }
            if name == "idle" { brain.bubble = PetBubble(id: 2, text: look.lines["hello"]?.first ?? "hiii! tap me to chat") }
            let r = ImageRenderer(content: PetView(brain: brain).background(Color(white: 0.92)))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
            }
        }
        return poses.map(\.0)
    }
}
