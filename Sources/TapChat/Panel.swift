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

enum ResizeEdge { case top, left, right }
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

    init(model: ChatModel) {
        self.model = model
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
        Haptics.windowVisible = true
        watchMouse(true)
        model.didShow()
        updatePassThrough()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.selection = nil
        Haptics.windowVisible = false
        watchMouse(false)
        model.dropZone = false
        model.didHide()
        // Back to the app that was in front before.
        NSApp.hide(nil)
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
    private func checkSelection(at p: NSPoint) {
        guard let tv = panel.firstResponder as? NSTextView, !(tv is ComposerNSTextView), tv.selectedRange().length > 0 else {
            if model.selection != nil { model.selection = nil }
            return
        }
        let text = (tv.string as NSString).substring(with: tv.selectedRange()).trimmingCharacters(in: .whitespacesAndNewlines)
        let height = panel.contentView?.bounds.height ?? 0
        model.selection = text.isEmpty ? nil : ChatModel.Selection(text: text, at: CGPoint(x: p.x, y: height - p.y))
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
        // After a click or drag: text selected in a message? Then a Reply button.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] e in
            let p = e.locationInWindow
            DispatchQueue.main.async { self?.checkSelection(at: p) }
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
            switch d.edge {
            case .top:
                guard model.layout != .bar else { return }
                let minH = model.barHeight + 160 + m2
                f.size.height = min(max(d.frame.height + mouse.y - d.mouse.y, minH), visible.maxY - f.minY + shadowMargin)
            case .left:
                let w = min(max(d.frame.width - (mouse.x - d.mouse.x), range.lowerBound + m2), range.upperBound + m2)
                f.origin.x = d.frame.maxX - w
                f.size.width = w
            case .right:
                f.size.width = min(max(d.frame.width + mouse.x - d.mouse.x, range.lowerBound + m2), range.upperBound + m2)
            }
            adjusting = true
            panel.setFrame(f.integral, display: true)
            adjusting = false
            model.canvasHeight = f.height - m2
        case .ended:
            drag = nil
            let f = panel.frame
            Settings.storedWidth = Double(f.width - 2 * shadowMargin)
            if edge == .top { Settings.expandedHeight = Double(f.height - 2 * shadowMargin) }
            Settings.anchor = CGPoint(x: f.midX, y: f.minY + shadowMargin)
            updatePassThrough()
        }
    }

    func windowDidMove(_ notification: Notification) {
        // Only a drag by the user; the app's own moves don't count.
        guard !adjusting, drag == nil else { return }
        Settings.anchor = CGPoint(x: panel.frame.midX, y: panel.frame.minY + shadowMargin)
    }
}

// Behind the glass's content: dragging anywhere that isn't a control moves the window.
struct MoveArea: NSViewRepresentable {
    func makeNSView(context: Context) -> MoveView { MoveView() }
    func updateNSView(_ v: MoveView, context: Context) {}

    final class MoveView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
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
            addCursorRect(bounds, cursor: edge == .top ? .resizeUpDown : .resizeLeftRight)
        }
        override func mouseDown(with event: NSEvent) { onResize?(edge, .began) }
        override func mouseDragged(with event: NSEvent) { onResize?(edge, .changed) }
        override func mouseUp(with event: NSEvent) { onResize?(edge, .ended) }
    }
}
