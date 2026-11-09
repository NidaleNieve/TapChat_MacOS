import AppKit
import SwiftUI

// Borderless, without the system shadow (which draws an outline of its own
// around the window): the glass gets a SwiftUI shadow inside this margin.
let shadowMargin: CGFloat = 36

final class ChatPanel: NSPanel, NSServicesMenuRequestor {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Continuity Camera ("Import from iPhone"): the window takes the photo,
    // scan or sketch whatever has focus inside it (macOS greys the menu item
    // out when nobody in the responder chain says it can take an image).
    var onImport: ((NSPasteboard) -> Bool)?

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if onImport != nil, let returnType, Attachments.deviceImportTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        onImport?(pboard) ?? false
    }
}

// The edges a resize handle moves: one for a side, two for a corner.
struct ResizeEdge: OptionSet, Hashable {
    let rawValue: Int
    static let top = ResizeEdge(rawValue: 1)
    static let bottom = ResizeEdge(rawValue: 2)
    static let left = ResizeEdge(rawValue: 4)
    static let right = ResizeEdge(rawValue: 8)
}
enum ResizePhase { case began, changed, ended }

let dropZoneHeight: CGFloat = 84

// The window is a fixed, transparent canvas as tall as the chat; the glass
// inside grows from the one-line bar to the chat and back, animated by
// SwiftUI, so the box and its text always move together. Where there's no
// glass, clicks go through to the apps behind.
final class PanelController: NSObject, NSWindowDelegate {
    let panel: ChatPanel
    let model: ChatModel
    private var adjusting = false
    private var drag: (edge: ResizeEdge, frame: NSRect, mouse: CGPoint)?
    private var monitors: [Any] = []
    private var dragCount = 0
    // Whether the drag in progress carries files (read once per drag).
    private var dragHasFiles: Bool?
    // A side chat's window: placed beside `parent`, its size and place not remembered.
    let isSide: Bool
    weak var parent: PanelController?
    private var selectionCheck: DispatchWorkItem?
    // Where the selection is (its text view and range), kept while a reply
    // box has the keyboard, so both can follow the text when scrolling.
    private weak var selectionView: NSTextView?
    private var selectionRange = NSRange()

    init(model: ChatModel, parent: PanelController? = nil) {
        self.model = model
        self.parent = parent
        isSide = parent != nil
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                          styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        let root = RootView(model: model, onResize: { [weak self] edge, phase in self?.resize(edge, phase) })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        model.onLayoutChange = { [weak self] in self?.updatePassThrough() }
        model.onHide = { [weak self] in self?.hide() }
        model.onDropped = { [weak self] in self?.endDropZone() }
        model.clearSelection = { [weak self] in
            guard let tv = self?.panel.firstResponder as? NSTextView, !(tv is ComposerNSTextView) else { return }
            tv.setSelectedRange(NSRange(location: tv.selectedRange().location, length: 0))
        }
        panel.onImport = { [weak model] pb in model?.importFromDevice(pb) ?? false }
        // macOS asks an app's windows whether they can take an iPhone import
        // only for types the app registered: without this, Import from iPhone
        // stays greyed out however the window answers.
        NSApp.registerServicesMenuSendTypes([.string], returnTypes: Attachments.deviceImportTypes)
    }

    // The shortcut: shows the window, or hides it whenever it's on screen,
    // focused or not.
    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    // The History shortcut: opens History, or closes the window if History is showing.
    func toggleHistory() {
        if panel.isVisible && model.showingHistory {
            hide()
            return
        }
        if !panel.isVisible { show() }
        if !model.showingHistory { model.toggleHistory() }
    }

    func show() {
        if !panel.isVisible { placeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !isSide { Haptics.windowVisible = true; onShow?() }
        watchMouse(true)
        model.didShow()
        updatePassThrough()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.selection = nil
        watchMouse(false)
        model.dropZone = false
        model.didHide()
        if isSide {
            // Dismissed: its answer stops; back to the main chat.
            model.stop(answerQueued: false)
            onDismiss?()
            parent?.panel.makeKey()
            return
        }
        onHide?()
        Haptics.windowVisible = false
        // Back to the app that was in front before.
        NSApp.hide(nil)
    }
    // The main window hides: its side chat is put away with it (and back when it shows).
    var onHide: (() -> Void)?
    var onShow: (() -> Void)?
    // A side chat closed by its user (✕, Esc, the shortcut).
    var onDismiss: (() -> Void)?

    // A side chat out of sight while the main window is hidden, kept as it is.
    func conceal() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.selection = nil
        watchMouse(false)
        model.dropZone = false
    }

    // Back beside the main window, without taking the keyboard from it.
    func reveal() {
        guard !panel.isVisible else { return }
        panel.orderFront(nil)
        watchMouse(true)
        updatePassThrough()
    }

    private var visible: NSRect { (panel.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame }

    // The glass's width: a quarter of the screen until resized.
    private var glassWidth: CGFloat {
        let range = Settings.widthRange
        let w = Settings.storedWidth ?? Double(visible.width / 4)
        return CGFloat(min(max(w, range.lowerBound), range.upperBound))
    }

    // Bottom third and right third of the screen, clear of the edge, until moved.
    private func defaultAnchor(width w: CGFloat) -> CGPoint {
        let v = visible
        return CGPoint(x: v.maxX - v.width * 0.07 - w / 2, y: v.minY + v.height / 6 - 25)
    }

    // The canvas: the glass's bottom centre at the anchor, as tall as the chat
    // window may get there.
    func placeWindow() {
        if isSide, let parent { return placeBeside(parent) }
        let v = visible
        let w = min(glassWidth, v.width - 2 * shadowMargin)
        var anchor = Settings.anchor ?? defaultAnchor(width: w)
        anchor.x = min(max(anchor.x, v.minX + w / 2), v.maxX - w / 2)
        anchor.y = min(max(anchor.y, v.minY), v.maxY - 260)
        let h = min(CGFloat(Settings.expandedHeight), v.maxY - anchor.y)
        let frame = NSRect(x: anchor.x - w / 2 - shadowMargin, y: anchor.y - shadowMargin,
                           width: w + 2 * shadowMargin, height: h + 2 * shadowMargin).integral
        model.canvasHeight = h
        guard frame != panel.frame else { return }
        adjusting = true
        panel.setFrame(frame, display: true)
        adjusting = false
    }

    // Beside the main window (right if there's room, else left), a little
    // narrower, bottoms level.
    private func placeBeside(_ parent: PanelController) {
        let v = visible, gap: CGFloat = 14
        let main = parent.panel.frame.insetBy(dx: shadowMargin, dy: shadowMargin)
        let w = min(max(main.width * 0.7, CGFloat(Settings.widthRange.lowerBound)), v.width / 3)
        let h = max(300, parent.model.canvasHeight * 0.65)
        var x = main.maxX + gap
        if x + w > v.maxX - 24 { x = main.minX - gap - w }
        x = min(max(x, v.minX + 24), v.maxX - 24 - w)
        let frame = NSRect(x: x - shadowMargin, y: main.minY - shadowMargin, width: w + 2 * shadowMargin, height: h + 2 * shadowMargin).integral
        model.canvasHeight = h
        adjusting = true
        panel.setFrame(frame, display: true)
        adjusting = false
    }

    // MARK: Clicks outside the glass

    // The glass as laid out, in screen coordinates (with the resize strips).
    private var glassRect: NSRect {
        let f = panel.frame
        return NSRect(x: f.minX + shadowMargin, y: f.minY + shadowMargin,
                      width: f.width - 2 * shadowMargin, height: model.glassHeight).insetBy(dx: -4, dy: -4)
    }

    func updatePassThrough() {
        guard panel.isVisible else { return }
        let inside = glassRect.contains(NSEvent.mouseLocation)
        // While files are dragged, the whole canvas takes the drop.
        let through = !(inside || model.dropZone || drag != nil || NSEvent.pressedMouseButtons != 0 && !panel.ignoresMouseEvents)
        if panel.ignoresMouseEvents != through { panel.ignoresMouseEvents = through }
    }

    // Mouse moves (to let clicks through outside the glass) and file drags
    // (to open the drop area); watched only while the window is open.
    // Selected text in a message is held by a text view SwiftUI puts in focus.
    // The bar goes just above the selection's first line; for a tall
    // selection (or one whose top is out of view), by the pointer.
    private func checkSelection(at p: NSPoint) {
        // A reply box open: a click outside it (not in its field) closes it.
        if model.replyBox != nil {
            let inField = (panel.firstResponder as? NSTextView)?.isFieldEditor == true
            if !inField, Date().timeIntervalSince(model.replyBoxOpened) > 0.4 { model.replyBox = nil } else { return }
        }
        guard let tv = panel.firstResponder as? NSTextView, !(tv is ComposerNSTextView), tv.selectedRange().length > 0 else {
            if model.selection != nil { withAnimation(.easeOut(duration: 0.15)) { model.selection = nil } }
            return
        }
        let range = tv.selectedRange()
        let text = (tv.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { withAnimation(.easeOut(duration: 0.15)) { model.selection = nil }; return }
        selectionView = tv
        selectionRange = range
        let place = selectionPlace(tv, range)
        let next = ChatModel.Selection(text: text, x: place.x, above: place.above, below: place.below,
                                       messageId: model.messageId(showing: tv.string))
        withAnimation(.easeOut(duration: 0.15)) { model.selection = next }
    }

    // Where the bar goes for a selection: just above its first line (below
    // its last when there's no room above), in the window, top-left origin.
    private func selectionPlace(_ tv: NSTextView, _ range: NSRange) -> (x: CGFloat, above: CGFloat, below: CGFloat) {
        let height = panel.contentView?.bounds.height ?? 0
        func line(_ r: NSRange) -> CGRect {
            let s = tv.firstRect(forCharacterRange: r, actualRange: nil)
            let o = panel.convertPoint(fromScreen: s.origin)
            return CGRect(x: o.x, y: height - o.y - s.height, width: s.width, height: s.height)
        }
        let first = line(NSRange(location: range.location, length: 1))
        let last = line(NSRange(location: NSMaxRange(range) - 1, length: 1))
        return (first.minX, first.minY - 4, last.maxY + 4)
    }

    // The chat's scroll view under a point (the tallest one there, not the composer's).
    private func chatScrollView(at p: NSPoint) -> NSScrollView? {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return all(panel.contentView ?? NSView()).compactMap { $0 as? NSScrollView }
            .filter { !($0 is ComposerScrollView) && $0.convert($0.bounds, to: nil).contains(p) }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    // Scrolling: the bar (and a reply box) move with the selected text.
    private func followSelection() {
        guard model.selection != nil || model.replyBox != nil, let tv = selectionView,
              NSMaxRange(selectionRange) <= (tv.string as NSString).length else { return }
        let place = selectionPlace(tv, selectionRange)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            for keyPath in [\ChatModel.selection, \ChatModel.replyBox] {
                guard var s = model[keyPath: keyPath] else { continue }
                s.x = place.x
                s.above = place.above
                s.below = place.below
                model[keyPath: keyPath] = s
            }
        }
    }

    private func watchMouse(_ on: Bool) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard on else { return }
        let pb = NSPasteboard(name: .drag)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.updatePassThrough()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in
            self?.updatePassThrough()
            return e
        }) { monitors.append(m) }
        // After a click or drag: text selected in a message? Then, once it has
        // settled (0.3 s without another click: a double-click becoming a
        // triple-click), the Reply · Highlight bar.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            let p = e.locationInWindow
            self.selectionCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.checkSelection(at: p) }
            self.selectionCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            DispatchQueue.main.async { self.followSelection() }
            // Over the selection bar or reply box: the chat beneath scrolls.
            let h = self.panel.contentView?.bounds.height ?? 0
            let p = CGPoint(x: e.locationInWindow.x, y: h - e.locationInWindow.y)
            if self.model.popupFrames.values.contains(where: { $0.contains(p) }), let chat = self.chatScrollView(at: e.locationInWindow) {
                chat.scrollWheel(with: e)
                return nil
            }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            self.selectionCheck?.cancel()
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.dragCount = pb.changeCount
            self?.dragHasFiles = nil
        }) { monitors.append(m) }
        // The drop area shows only while dragged files are near the glass.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            guard let self, pb.changeCount != self.dragCount else { return }
            if self.dragHasFiles == nil { self.dragHasFiles = Attachments.pasteboardHasAttachments(pb) }
            guard self.dragHasFiles == true else { return }
            let near = self.glassRect.insetBy(dx: -90, dy: -90).contains(NSEvent.mouseLocation)
            if near != self.model.dropZone {
                self.model.dropZone = near
                self.updatePassThrough()
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.endDropZone() }
        }) { monitors.append(m) }
    }

    func endDropZone() {
        guard model.dropZone else { return }
        model.dropZone = false
        updatePassThrough()
    }

    // MARK: Resizing by the edges

    func resize(_ edge: ResizeEdge, _ phase: ResizePhase) {
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .began:
            drag = (edge, panel.frame, mouse)
        case .changed:
            guard let d = drag else { return }
            var f = d.frame
            let range = Settings.widthRange
            let m2 = 2 * shadowMargin
            // Height only for a chat or History (the bar is one line).
            let minH = model.barHeight + 160 + m2
            if d.edge.contains(.top), model.layout != .bar {
                f.size.height = min(max(d.frame.height + mouse.y - d.mouse.y, minH), visible.maxY - f.minY + shadowMargin)
            }
            if d.edge.contains(.bottom), model.layout != .bar {
                // The bottom moves; the top stays.
                let minY = min(max(d.frame.minY + mouse.y - d.mouse.y, visible.minY - shadowMargin), d.frame.maxY - minH)
                f.origin.y = minY
                f.size.height = d.frame.maxY - minY
            }
            if d.edge.contains(.left) {
                let w = min(max(d.frame.width - (mouse.x - d.mouse.x), range.lowerBound + m2), range.upperBound + m2)
                f.origin.x = d.frame.maxX - w
                f.size.width = w
            }
            if d.edge.contains(.right) {
                f.size.width = min(max(d.frame.width + mouse.x - d.mouse.x, range.lowerBound + m2), range.upperBound + m2)
            }
            adjusting = true
            panel.setFrame(f.integral, display: true)
            adjusting = false
            model.canvasHeight = f.height - m2
        case .ended:
            drag = nil
            let f = panel.frame
            guard !isSide else { return updatePassThrough() }
            Settings.storedWidth = Double(f.width - 2 * shadowMargin)
            if !edge.isDisjoint(with: [.top, .bottom]), model.layout != .bar { Settings.expandedHeight = Double(f.height - 2 * shadowMargin) }
            Settings.anchor = CGPoint(x: f.midX, y: f.minY + shadowMargin)
            updatePassThrough()
        }
    }

    // Moved by a drag or a throw: remembered.
    func moved() {
        guard !isSide else { return }
        Settings.anchor = CGPoint(x: panel.frame.midX, y: panel.frame.minY + shadowMargin)
    }

    func windowDidMove(_ notification: Notification) {
        // Only a drag by the user; the app's own moves don't count.
        guard !adjusting, drag == nil, !isSide else { return }
        Settings.anchor = CGPoint(x: panel.frame.midX, y: panel.frame.minY + shadowMargin)
    }
}

// Behind the glass's content: dragging anywhere that isn't a control moves the window.
struct MoveArea: NSViewRepresentable {
    func makeNSView(context: Context) -> MoveView { MoveView() }
    func updateNSView(_ v: MoveView, context: Context) {}

    final class MoveView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        // The window follows the pointer; let go while moving fast and it's
        // thrown that way, gliding to a stop, kept a little off the screen's
        // edges.
        // Debug hook test-flick: its made-up events' positions are relative to
        // where the window started (real ones go stale as the window moves,
        // so the pointer's own position is read instead).
        static var simulated = false

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let origin = window.frame.origin
            let screen = { (e: NSEvent) -> NSPoint in
                Self.simulated ? NSPoint(x: origin.x + e.locationInWindow.x, y: origin.y + e.locationInWindow.y) : NSEvent.mouseLocation
            }
            let start = screen(event)
            var samples: [(t: TimeInterval, p: NSPoint)] = [(event.timestamp, start)]
            var moved = false
            while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let p = screen(e)
                if e.type == .leftMouseUp {
                    if moved { fling(window, samples: samples + [(e.timestamp, p)]) }
                    return
                }
                moved = true
                window.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
                samples.append((e.timestamp, p))
                if samples.count > 8 { samples.removeFirst() }
            }
        }

        private func fling(_ window: NSWindow, samples: [(t: TimeInterval, p: NSPoint)]) {
            // Speed over the last ~100 ms of the drag.
            guard let last = samples.last, let first = samples.first(where: { last.t - $0.t <= 0.1 }),
                  last.t - first.t > 0.005 else { return finished(window) }
            let dt = last.t - first.t
            let v = CGVector(dx: (last.p.x - first.p.x) / dt, dy: (last.p.y - first.p.y) / dt)
            guard hypot(v.dx, v.dy) > 600 else { return finished(window) }
            // Glides about a quarter of a second's worth further.
            var frame = window.frame
            frame.origin.x += v.dx * 0.25
            frame.origin.y += v.dy * 0.25
            frame.origin = kept(window, frame.origin)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                // Fast away, then a long soft settle, like something thrown.
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.12, 0.9, 0.2, 1)
                // The window's frame animates; its origin alone doesn't.
                window.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                guard let self, let window = self.window else { return }
                self.finished(window)
            })
        }

        // The glass at least 24 pt from the screen's edges.
        private func kept(_ window: NSWindow, _ origin: NSPoint) -> NSPoint {
            guard let screen = window.screen ?? NSScreen.main else { return origin }
            let v = screen.visibleFrame, f = window.frame, gap: CGFloat = 24
            let glassHeight = (window.delegate as? PanelController)?.model.glassHeight ?? f.height - 2 * shadowMargin
            var o = origin
            o.x = min(max(o.x, v.minX + gap - shadowMargin), v.maxX - gap - f.width + shadowMargin)
            o.y = min(max(o.y, v.minY + gap - shadowMargin), v.maxY - gap - shadowMargin - glassHeight)
            return o
        }

        private func finished(_ window: NSWindow) {
            (window.delegate as? PanelController)?.moved()
        }
    }
}

// Strips along the edges that resize the window instead of moving it.
struct EdgeHandle: NSViewRepresentable {
    let edge: ResizeEdge
    var onResize: (ResizeEdge, ResizePhase) -> Void

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.edge = edge
        v.onResize = onResize
        return v
    }

    func updateNSView(_ v: HandleView, context: Context) { v.onResize = onResize }

    final class HandleView: NSView {
        var edge: ResizeEdge = .top
        var onResize: ((ResizeEdge, ResizePhase) -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() {
            let position: NSCursor.FrameResizePosition = switch edge {
            case [.top, .left]: .topLeft
            case [.top, .right]: .topRight
            case [.bottom, .left]: .bottomLeft
            case [.bottom, .right]: .bottomRight
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            default: .right
            }
            addCursorRect(bounds, cursor: .frameResize(position: position, directions: .all))
        }
        override func mouseDown(with event: NSEvent) { onResize?(edge, .began) }
        override func mouseDragged(with event: NSEvent) { onResize?(edge, .changed) }
        override func mouseUp(with event: NSEvent) { onResize?(edge, .ended) }
    }
}
