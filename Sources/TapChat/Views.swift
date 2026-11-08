import AppKit
import SwiftUI
import UniformTypeIdentifiers

let windowRadius: CGFloat = 24

struct RootView: View {
    @Bindable var model: ChatModel
    var onResize: (ResizeEdge, ResizePhase) -> Void
    @State private var targeted = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: windowRadius) }

    // The glass's visible height: the bar, or the whole canvas for a chat or History.
    private var visibleHeight: CGFloat {
        model.layout == .bar ? model.barHeight + (model.dropZone ? dropZoneHeight : 0) : model.canvasHeight
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The canvas: empty, except while files are dragged (then all of it,
            // margin included, takes the drop).
            Color.white.opacity(model.dropZone ? 0.001 : 0)
            glass
        }
        .frame(height: model.canvasHeight, alignment: .bottom)
        .padding(shadowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(Color.white.opacity(model.dropZone ? 0.001 : 0))
        .ignoresSafeArea()
        .animation(.spring(duration: 0.36, bounce: 0.1), value: model.layout)
        .animation(.spring(duration: 0.3, bounce: 0.08), value: model.dropZone)
        .onAppear { model.glassHeight = visibleHeight }
        .onChange(of: visibleHeight) { _, h in
            model.glassHeight = h
            model.onLayoutChange?()
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
            drop(providers)
            return true
        }
    }

    // The content is always laid out at full height, in its final place; only
    // the glass behind it and the mask over it grow and shrink. So nothing
    // inside ever travels: what's new appears where it belongs as the glass
    // reveals it (no History header or Stop button riding up from the bar).
    private var glass: some View {
        let h = visibleHeight
        return VStack(spacing: 0) {
            if model.layout == .expanded {
                Header(model: model)
                if model.showingHistory {
                    HistoryList(model: model)
                } else {
                    MessagesView(model: model)
                }
            } else if model.layout == .history {
                HistoryList(model: model)
            } else {
                Spacer(minLength: 0)
                if model.dropZone {
                    DropZone(targeted: targeted).frame(height: dropZoneHeight).transition(.opacity)
                }
            }
            Composer(model: model)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bar in
                    if abs(model.barHeight - bar) > 0.5 { model.barHeight = bar }
                }
        }
        .frame(height: model.canvasHeight, alignment: .bottom)
        .mask(alignment: .bottom) { shape.frame(height: h) }
        .background(alignment: .bottom) {
            ZStack {
                // A tint under the content makes the glass a little more opaque.
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.4))
                    .glassEffect(.regular, in: shape)
                    .background(shape.fill(Color.black.opacity(0.001)).shadow(color: .black.opacity(0.28), radius: 16, y: 7))
                    .allowsHitTesting(false)
                // Dragging any empty part of the glass moves the window.
                MoveArea()
            }
            .frame(height: h)
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if model.layout != .bar && (model.dropZone || targeted) {
                    // In a chat: an outline and a small label, not a big panel.
                    ZStack(alignment: .bottom) {
                        shape.strokeBorder(Color.accentColor.opacity(targeted ? 0.9 : 0.55), lineWidth: 1.5)
                        Label("Drop to attach", systemImage: "paperclip")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.regularMaterial))
                            .padding(.bottom, model.barHeight + 8)
                    }
                    .transition(.opacity)
                }
                // A hairline along the glass's own edge.
                shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.6)
                if model.chat.isTemporary {
                    shape.strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
            }
            .frame(height: h)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Color.clear
                .frame(height: h)
                .overlay(alignment: .top) {
                    if model.layout != .bar { EdgeHandle(edge: .top, onResize: onResize).frame(height: 5) }
                }
                .overlay(alignment: .leading) { EdgeHandle(edge: .left, onResize: onResize).frame(width: 5).padding(.vertical, 14) }
                .overlay(alignment: .trailing) { EdgeHandle(edge: .right, onResize: onResize).frame(width: 5).padding(.vertical, 14) }
        }
    }

    private func drop(_ providers: [NSItemProvider]) {
        let toEdit = model.editingId != nil
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.attach(urls: [url], toEdit: toEdit) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    DispatchQueue.main.async {
                        if let a = Attachments.importImage(image, name: "Dropped Image", into: Paths.folder(for: model.chat)) {
                            model.attach([a], toEdit: toEdit)
                        }
                    }
                }
            }
        }
        model.onDropped?()
    }
}

struct DropZone: View {
    var targeted: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc").font(.system(size: 20, weight: .medium))
            Text("Drop files here").font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(targeted ? 0.2 : 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor.opacity(targeted ? 0.9 : 0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

// MARK: - Header

struct Header: View {
    @Bindable var model: ChatModel

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "xmark", help: "Close (Esc)") { model.onHide?() }
            if model.showingHistory {
                IconButton(symbol: "chevron.left", help: "Back to Chat") { model.toggleHistory() }
            } else if model.openedFromHistory {
                IconButton(symbol: "chevron.left", help: "Back to History") { model.backToHistory() }
            }
            if let banner = model.banner {
                Label(banner, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                if model.chat.isTemporary && !model.showingHistory {
                    Image(systemName: "eye.slash").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 4)
                }
                Text(model.showingHistory ? "History" : model.chat.isTemporary ? "Temporary Chat" : (model.chat.title.isEmpty ? "New Chat" : model.chat.title))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 8)
            IconButton(symbol: "square.and.pencil", help: "New Chat (⌘N)") { model.newChat() }
        }
        .animation(.easeOut(duration: 0.2), value: model.banner)
        .padding(.horizontal, 10)
        .frame(height: 34)
        // Room from the window's top edge; the space below stays tight.
        .padding(.top, 3)
    }
}

// "+": a small menu with Choose Files… and Import from iPhone (Continuity
// Camera: take a photo, scan a document or sketch on the iPhone, and it's
// attached; the composer's text view receives it, see ComposerNSTextView).
struct AddButton: View {
    let model: ChatModel
    let editing: Bool
    @State private var anchor = ImportAnchor.Box()

    var body: some View {
        IconButton(symbol: "plus", help: "Add Files or Import from iPhone", size: 14) { show() }
            .background(ImportAnchor(box: anchor) { [model] pb in model.importFromDevice(pb) })
    }

    private func show() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Choose Files…") { model.chooseFiles(toEdit: editing) })
        // macOS fills this in with the nearby iPhones and what each can do
        // (take a photo, scan documents, add a sketch).
        let device = NSMenuItem(title: "Import from iPhone", action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(device)
        anchor.view?.present(menu)
        // Typing goes back to the composer afterwards.
        DispatchQueue.main.async { model.focusToken += 1 }
    }
}

// An invisible view behind "+" that owns its menu and takes what comes back
// from the iPhone. AppKit fills in Import from iPhone only in a context menu
// for a view that has focus and says it takes images (a pop-up menu is never
// asked; a text view's context menu gets AutoFill and the like instead).
struct ImportAnchor: NSViewRepresentable {
    final class Box { weak var view: RequestView? }

    // The types TapChat can take from (and give to) other apps' services.
    // Text views register their own list when the first one is made, which
    // replaces any earlier registration: so this runs again before the menu
    // opens, with the text types and the image types together.
    static func registerTypes() {
        let text: [NSPasteboard.PasteboardType] = [.string, .rtf, .rtfd, .init("NSStringPboardType"), .init("NeXT Rich Text Format v1.0 pasteboard type")]
        NSApp.registerServicesMenuSendTypes(text, returnTypes: text + Attachments.deviceImportTypes)
    }

    final class RequestView: NSView, NSServicesMenuRequestor {
        var onImport: ((NSPasteboard) -> Bool)?
        override var acceptsFirstResponder: Bool { true }

        // Photos and sketches come as images, scans as a PDF (or other
        // document types, which readSelection turns down if unreadable).
        // What AppKit asked (debug hook probe-import).
        static var asked: [String] = []

        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
            Self.asked.append("\(sendType?.rawValue ?? "nil")→\(returnType?.rawValue ?? "nil")")
            if sendType == nil, let returnType, let type = UTType(returnType.rawValue) ?? UTType(filenameExtension: returnType.rawValue),
               type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .data) && !type.conforms(to: .text) {
                return self
            }
            if sendType == nil, let returnType, Attachments.deviceImportTypes.contains(returnType) { return self }
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }

        func readSelection(from pboard: NSPasteboard) -> Bool { onImport?(pboard) ?? false }

        func present(_ menu: NSMenu) {
            guard let window else { return }
            window.makeFirstResponder(self)
            let at = convert(NSPoint(x: 0, y: isFlipped ? 0 : bounds.height), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    let box: Box
    let onImport: (NSPasteboard) -> Bool

    func makeNSView(context: Context) -> RequestView {
        let v = RequestView()
        v.onImport = onImport
        box.view = v
        return v
    }

    func updateNSView(_ v: RequestView, context: Context) {
        v.onImport = onImport
        box.view = v
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 13
    var diameter: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// Copy and the like: the icon turns into a checkmark for a moment, with a tap.
struct FeedbackButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 10
    var diameter: CGFloat = 22
    let action: () -> Void
    @State private var done = false
    @State private var hovering = false

    var body: some View {
        Button {
            action()
            Haptics.confirm()
            withAnimation(.spring(duration: 0.25)) { done = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { withAnimation(.easeOut(duration: 0.2)) { done = false } }
        } label: {
            Image(systemName: done ? "checkmark" : symbol)
                .font(.system(size: size, weight: done ? .bold : .medium))
                .foregroundStyle(done ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Composer

// The message field with its placeholder; grows with the text, smoothly.
struct MessageField: View {
    @Binding var text: String
    var placeholder: String
    var maxHeight: CGFloat
    var focusToken: Int
    var folder: () -> URL
    var onSubmit: () -> Void
    var onAttach: ([Attachment]) -> Void
    var onEscape: () -> Void
    var onUpWhenEmpty: (() -> Void)?
    @State private var height: CGFloat = ComposerTextView.lineHeight

    var body: some View {
        ComposerTextView(
            text: $text, height: $height, maxHeight: maxHeight,
            focusToken: focusToken, onSubmit: onSubmit, onAttach: onAttach,
            attachmentFolder: folder, onEscape: onEscape, onUpWhenEmpty: onUpWhenEmpty
        )
        .frame(height: height)
    }
}

// One line: [+] text … controls. When the text no longer fits on the line,
// it moves up over the full width and the same controls sit below it.
// Custom layout, so the text view stays the same view (no lost cursor).
struct ComposerLayout: SwiftUI.Layout {
    var expanded: Bool
    var spacing: CGFloat = 4
    var rowGap: CGFloat = 6
    static let leftInset: CGFloat = 9
    static let textInsets: CGFloat = 9 + 5

    private func compactFieldWidth(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        let lead = subviews[0].sizeThatFits(.unspecified).width
        let trail = subviews[2].sizeThatFits(.unspecified).width
        return max(40, width - lead - trail - spacing * 2)
    }

    private func isExpanded(_ width: CGFloat, _ subviews: Subviews) -> Bool { expanded }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let lead = subviews[0].sizeThatFits(.unspecified)
        let trail = subviews[2].sizeThatFits(.unspecified)
        let row = max(lead.height, trail.height)
        if isExpanded(width, subviews) {
            let field = subviews[1].sizeThatFits(ProposedViewSize(width: width - Self.textInsets, height: nil))
            return CGSize(width: width, height: field.height + rowGap + row)
        }
        let field = subviews[1].sizeThatFits(ProposedViewSize(width: compactFieldWidth(width, subviews), height: nil))
        return CGSize(width: width, height: max(field.height, row))
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lead = subviews[0].sizeThatFits(.unspecified)
        let trail = subviews[2].sizeThatFits(.unspecified)
        if isExpanded(b.width, subviews) {
            // In line with the + below, and a little room on the right.
            let fw = b.width - Self.textInsets
            let field = subviews[1].sizeThatFits(ProposedViewSize(width: fw, height: nil))
            subviews[1].place(at: CGPoint(x: b.minX + Self.leftInset, y: b.minY), proposal: ProposedViewSize(width: fw, height: field.height))
            let row = max(lead.height, trail.height)
            let y = b.minY + field.height + rowGap
            subviews[0].place(at: CGPoint(x: b.minX, y: y + (row - lead.height) / 2), proposal: .unspecified)
            subviews[2].place(at: CGPoint(x: b.maxX - trail.width, y: y + (row - trail.height) / 2), proposal: .unspecified)
        } else {
            let fw = compactFieldWidth(b.width, subviews)
            let field = subviews[1].sizeThatFits(ProposedViewSize(width: fw, height: nil))
            subviews[0].place(at: CGPoint(x: b.minX, y: b.midY - lead.height / 2), proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: b.minX + lead.width + spacing, y: b.midY - field.height / 2),
                              proposal: ProposedViewSize(width: fw, height: field.height))
            subviews[2].place(at: CGPoint(x: b.maxX - trail.width, y: b.midY - trail.height / 2), proposal: .unspecified)
        }
    }
}

// The bar, the reply box and the edit box: the same controls in the same places.
struct ComposerBox: View {
    @Bindable var model: ChatModel
    var editing = false

    // One line or several. Changed in one animation, so the box, the text
    // and the controls all move together.
    @State private var expanded = false
    @State private var boxWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    private var text: Binding<String> { editing ? $model.editText : $model.draft }
    private var hint: String {
        editing ? "Message" : model.chat.messages.isEmpty ? (model.chat.isTemporary ? "Temporary chat" : "Ask anything") : "Reply…"
    }
    private var attachments: [Attachment] { editing ? model.editAttachments : model.draftAttachments }

    private func updateExpanded() {
        guard boxWidth > 0 else { return }
        let t = text.wrappedValue
        let textWidth = ceil((t as NSString).size(withAttributes: [.font: composerFont]).width)
        let room = boxWidth - 28 - trailingWidth - 8
        // A little slack before going back to one line, so it doesn't flicker.
        let want = t.contains("\n") || textWidth > room - (expanded ? 24 : 6)
        guard want != expanded else { return }
        withAnimation(.smooth(duration: 0.3)) { expanded = want }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments) { a in
                    if editing { model.editAttachments.removeAll { $0.id == a.id } } else { model.draftAttachments.removeAll { $0.id == a.id } }
                }
            }
            ComposerLayout(expanded: expanded) {
                AddButton(model: model, editing: editing)
                MessageField(
                    text: text,
                    placeholder: hint,
                    maxHeight: editing ? 220 : 180,
                    focusToken: editing ? model.focusToken + 1000 : model.focusToken,
                    folder: { Paths.folder(for: model.chat) },
                    onSubmit: { editing ? model.saveEdit() : model.send() },
                    onAttach: { model.attach($0, toEdit: editing) },
                    onEscape: { editing ? model.cancelEdit() : model.onHide?() },
                    onUpWhenEmpty: editing ? nil : { model.editLast() })
                trailing
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0; updateExpanded() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0; updateExpanded() }
            // The hint is its own label, pinned where one-line text sits. The box
            // only grows upwards from its bottom edge, so the hint never moves:
            // it fades in on the spot when the text is gone, and goes at once on typing.
            .overlay(alignment: .bottomLeading) {
                Text(hint)
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.top, (28 - ComposerTextView.lineHeight) / 2 + ComposerTextView.inset)
                    .frame(height: 28, alignment: .topLeading)
                    .padding(.leading, 28 + 4)
                    .opacity(text.wrappedValue.isEmpty ? 1 : 0)
                    .animation(text.wrappedValue.isEmpty ? .easeOut(duration: 0.12) : nil, value: text.wrappedValue.isEmpty)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: text.wrappedValue) { updateExpanded() }
        .onAppear { updateExpanded() }
    }

    private var trailing: some View {
        HStack(spacing: 2) {
            if !editing {
                if let banner = model.banner, model.layout != .expanded {
                    Label(banner, systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor).lineLimit(1).padding(.trailing, 4)
                }
                UsageBadge(model: model)
                if model.isRunning {
                    IconButton(symbol: "stop.circle.fill", help: "Stop (⌘.)", size: 16) { model.stop() }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            HStack(spacing: 0) {
                ModelMenu(model: model)
                ReasoningButton(model: model)
            }
            if editing {
                IconButton(symbol: "xmark", help: "Cancel (Esc)", size: 12) { model.cancelEdit() }
                IconButton(symbol: "arrow.up.circle.fill", help: "Send (↩)", size: 18) { model.saveEdit() }
            } else {
                TemporaryButton(model: model)
                HistoryButton(model: model)
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.isRunning)
    }
}

struct Composer: View {
    @Bindable var model: ChatModel

    var body: some View {
        // One view that becomes the reply card in a chat (no second copy
        // sliding in): only its padding and card background change.
        let card = model.layout == .expanded
        ComposerBox(model: model)
            .padding(card ? 6 : 0)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(card ? 0.055 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(card ? 0.13 : 0), lineWidth: 1))
            .padding(.horizontal, card ? 8 : 10)
            .padding(.top, card ? 2 : 8)
            .padding(.bottom, 8)
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.13), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}

// Shown only near a limit: easy to ignore, details on hover.
struct UsageBadge: View {
    let model: ChatModel

    var body: some View {
        let notes = model.usageNotes
        if !notes.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text(notes.map { u in u.limitReached ? "limit" : "\(Int(u.fiveHourPercent.rounded()))%" }.joined(separator: " · "))
            }
            .font(.system(size: 11))
            // A pale orange: noticeable without shouting.
            .foregroundStyle(Color(red: 1.0, green: 0.80, blue: 0.62).opacity(0.85))
            .help(notes.map(\.summary).joined(separator: "\n"))
            .frame(height: 28)
            .padding(.trailing, 2)
        }
    }
}

// A view's frame on screen, for placing menus next to it.
func screenRect(_ r: CGRect) -> NSRect {
    guard let w = NSApp.windows.first(where: { $0 is ChatPanel }) else { return .zero }
    return NSRect(x: w.frame.minX + r.minX, y: w.frame.maxY - r.maxY, width: r.width, height: r.height)
}

// Opens upwards from a button: right-aligned (so submenus open to the right) or left-aligned.
func popUpAbove(_ menu: NSMenu, _ button: NSRect, alignRight: Bool) {
    let size = menu.size
    let x = alignRight ? button.maxX - size.width : button.minX
    menu.popUp(positioning: nil, at: NSPoint(x: x, y: button.maxY + size.height + 4), in: nil)
}

struct ModelMenu: View {
    @Bindable var model: ChatModel
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        Button(action: show) {
            HStack(spacing: 3) {
                Text(model.modelTitle).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.leading, 6).padding(.trailing, 2)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Model")
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }

    private func show() {
        let menu = NSMenu()
        for p in [Provider.claude, .codex] { addSection(p, to: menu) }
        // Hold Option: Settings… shows at the bottom (a menu can't watch keys
        // itself, so the Option key is checked while the menu is open).
        let separator = NSMenuItem.separator()
        let settings = ClosureMenuItem(title: "Settings…") { [model] in model.openSettings?() }
        menu.addItem(separator)
        menu.addItem(settings)
        let showSettings = { (on: Bool) in
            guard settings.isHidden == on else { return }
            separator.isHidden = !on
            settings.isHidden = !on
        }
        settings.isHidden = true
        separator.isHidden = true
        showSettings(NSEvent.modifierFlags.contains(.option))
        let watch = Timer(timeInterval: 0.05, repeats: true) { _ in showSettings(NSEvent.modifierFlags.contains(.option)) }
        RunLoop.main.add(watch, forMode: .common)
        popUpAbove(menu, screenRect(frame), alignRight: true)
        watch.invalidate()
    }

    // Current models first, older ones under More; the header shows that
    // provider's usage, with the reset time on a line of its own.
    private func addSection(_ p: Provider, to menu: NSMenu) {
        let all = model.models.filter { $0.provider == p }
        guard !all.isEmpty else { return }
        menu.addItem(headerItem(p))
        // Main: Opus and Sonnet; Codex's GPT 6 models (not Terra or Luna). The rest under More.
        let main = p == .claude
            ? all.filter { !$0.value.contains("-") && !["haiku", "fable"].contains($0.value) }
            : all.filter { $0.value.contains("gpt-6") && !$0.value.contains("terra") && !$0.value.contains("luna") }
        let more = all.filter { !main.contains($0) }
        for m in main.isEmpty ? all : main { menu.addItem(item(m)) }
        if !more.isEmpty && !main.isEmpty {
            let sub = NSMenu()
            for m in more { sub.addItem(item(m)) }
            let moreItem = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
            moreItem.submenu = sub
            menu.addItem(moreItem)
        }
    }

    // "Claude · 15% used" in the section-header style, then the reset time,
    // smaller and dimmer, on the same line.
    private func headerItem(_ p: Provider) -> NSMenuItem {
        let title = NSMutableAttributedString(string: header(p), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        // The reset time on a small second line of the same item: explained,
        // without making the menu wider.
        if let u = model.usage[p], u.isCurrent, let reset = u.resetsAt {
            let f = DateFormatter()
            f.timeStyle = .short
            title.append(NSAttributedString(string: "\nresets \(f.string(from: reset))", attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = title
        item.isEnabled = false
        return item
    }

    private func header(_ p: Provider) -> String {
        guard let u = model.usage[p] else { return p.name }
        // After the 5-hour window resets, nothing has been used in the new one.
        guard u.isCurrent else { return "\(p.name) · 0%" }
        return u.limitReached ? "\(p.name) · limit" : "\(p.name) · \(Int(u.fiveHourPercent.rounded()))%"
    }

    private func item(_ m: ModelOption) -> NSMenuItem {
        let i = ClosureMenuItem(title: m.name) { model.select(model: m.value) }
        i.state = m.value == model.model ? .on : .off
        return i
    }
}

struct AttachmentStrip: View {
    let attachments: [Attachment]
    var onRemove: ((Attachment) -> Void)?
    // Which chip the pointer is over, worked out here from where the chips
    // are: inside this horizontal scroll view, each chip's own hover area
    // ended up one chip to the left of the chip.
    @State private var frames: [UUID: CGRect] = [:]
    @State private var hovered: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { a in
                    AttachmentChip(attachment: a, onRemove: onRemove, showRemove: hovered == a.id)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("strip")) } action: { frames[a.id] = $0 }
                }
            }
            .padding(.leading, 4)
        }
        .coordinateSpace(.named("strip"))
        .onContinuousHover(coordinateSpace: .named("strip")) { phase in
            switch phase {
            case .active(let p): hovered = attachments.first { frames[$0.id]?.contains(p) == true }?.id
            case .ended: hovered = nil
            }
        }
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    var onRemove: ((Attachment) -> Void)?
    // Set by AttachmentStrip, which tracks the pointer for its chips.
    var showRemove: Bool?
    @State private var hovering = false
    // A small cached copy of the image (Thumbnails), never the full image.
    @State private var thumbnail: NSImage?
    // The image can't be read: shown like a file.
    @State private var unreadable = false

    var body: some View {
        Group {
            if attachment.kind == .image && !unreadable {
                Group {
                    if let image = thumbnail ?? Thumbnails.cached(attachment.path) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.primary.opacity(0.07)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onAppear {
                    guard thumbnail == nil else { return }
                    Thumbnails.load(attachment.path) { image in
                        thumbnail = image
                        unreadable = image == nil
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(nsImage: Thumbnails.icon(attachment.path)).resizable().frame(width: 22, height: 22)
                    Text(attachment.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
            }
        }
        // Double-click opens the file. Only on the picture: on the remove
        // button too, every click on it waited to see if a second followed.
        .onTapGesture(count: 2) { NSWorkspace.shared.open(attachment.url) }
        .overlay(alignment: .topTrailing) {
            if let onRemove, showRemove ?? hovering {
                Button { onRemove(attachment) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
        }
        .padding(.top, 5).padding(.trailing, 5)
        .onHover { hovering = $0 }
        .help(attachment.name)
    }
}

// MARK: - Messages

struct MessagesView: View {
    @Bindable var model: ChatModel
    // Following the answer only while scrolled to the bottom.
    @State private var atBottom = true
    @State private var lastOffset: CGFloat = 0
    @State private var showJump = false
    @State private var viewport: CGFloat = 0
    @State private var heights: [UUID: CGFloat] = [:]
    // After sending, one smooth scroll runs; following the answer waits for it.
    @State private var followPausedUntil = Date.distantPast

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var fromBottom: CGFloat
        var viewport: CGFloat
    }

    // Room under the last exchange: a new question rises to about the middle
    // (not the very top), with space below for its answer. The room shrinks
    // as the answer grows and is gone once the exchange fills ~55% of the view.
    private var room: CGFloat {
        let msgs = model.chat.messages
        guard viewport > 0, let i = msgs.lastIndex(where: { $0.role == .user }) else { return 10 }
        let tail = msgs[i...]
        // Rows not measured yet count with a typical height, so the room
        // doesn't jump a frame later when they are.
        let used = tail.reduce(CGFloat(0)) { $0 + (heights[$1.id] ?? ($1.role == .user ? 40 : 24)) } + CGFloat(tail.count) * 18
        return max(10, viewport * 0.55 - used)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.chat.messages) { m in
                        MessageRow(model: model, message: m).id(m.id)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[m.id] = $0 }
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: room).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
            .scrollIndicators(.never)
            .mask(EdgeFade(size: 14))
            .onScrollGeometryChange(for: ScrollState.self) { g in
                ScrollState(offset: g.contentOffset.y, fromBottom: g.contentSize.height - g.contentOffset.y - g.containerSize.height,
                            viewport: g.containerSize.height)
            } action: { _, state in
                // Only scrolling up stops following: the answer growing a frame
                // before the follow scroll, or the chevron's own scroll, don't.
                if state.fromBottom < 40 { atBottom = true } else if state.offset < lastOffset - 1 { atBottom = false }
                lastOffset = state.offset
                viewport = state.viewport
                let jump = state.fromBottom > 140
                if jump != showJump { withAnimation(.easeOut(duration: 0.18)) { showJump = jump } }
            }
            // Back to the bottom, once scrolled up a bit.
            .overlay(alignment: .bottom) {
                if showJump {
                    Button {
                        atBottom = true
                        followPausedUntil = Date().addingTimeInterval(0.35)
                        withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.regularMaterial))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Scroll to the bottom")
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.chat.messages.count) {
                // A new question: once its rows are measured, one smooth scroll to
                // the bottom (the room below puts the question a little above the
                // middle). Nothing else scrolls until it's done: two scrolls at
                // once made the whole view dip and come back.
                followPausedUntil = Date().addingTimeInterval(0.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: model.revealed) {
                if atBottom, Date() >= followPausedUntil { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.chat.id) { atBottom = true; proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct MessageRow: View {
    @Bindable var model: ChatModel
    let message: Message
    @State private var hovering = false

    var body: some View {
        if message.role == .user { user } else { assistant }
    }

    private var user: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if model.editingId == message.id {
                ComposerBox(model: model, editing: true).modifier(CardStyle())
            } else {
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        ForEach(message.attachments) { AttachmentChip(attachment: $0) }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.08)))
                        .frame(maxWidth: 520, alignment: .trailing)
                }
                // Built only while the pointer is over the message; the row keeps their space.
                ZStack {
                    if hovering && !model.isRunning {
                        HStack(spacing: 2) {
                            FeedbackButton(symbol: "doc.on.doc", help: "Copy") { copy(message.text) }
                            IconButton(symbol: "pencil", help: "Edit", size: 10, diameter: 22) { model.startEdit(message.id) }
                            FeedbackButton(symbol: "arrow.triangle.branch", help: "Fork from here: a new chat with this message to edit") {
                                model.fork(at: message.id)
                            }
                        }
                    }
                }
                .frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering = $0 }
    }

    private var assistant: some View {
        let revealing = model.revealId == message.id
        let running = model.runningId == message.id
        let text = revealing ? model.revealed : message.text
        return VStack(alignment: .leading, spacing: 6) {
            if let note = message.note {
                Label(note, systemImage: "arrow.left.arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if running && text.isEmpty {
                // Waiting for the first words: dots, unless the model says what it's doing.
                if let status = model.status { ThinkingLabel(text: status) } else { TypingDots(paused: !model.shown) }
            } else {
                if running, let status = model.status { ThinkingLabel(text: status) }
                if !text.isEmpty { MarkdownView(text: text, id: message.id, fadeTail: revealing ? model.fadeTail : 0) }
            }
            if let error = message.error, !revealing {
                MarkdownView(text: error).foregroundStyle(.red.opacity(0.85))
            }
            if !revealing {
                // Built only while the pointer is over the message; the row keeps their space.
                ZStack {
                    if hovering && !model.isRunning {
                        HStack(spacing: 2) {
                            FeedbackButton(symbol: "doc.on.doc", help: "Copy") { copy(message.text) }
                            IconButton(symbol: "arrow.clockwise", help: "Try Again", size: 10, diameter: 22) { model.retry(message.id) }
                            FeedbackButton(symbol: "arrow.triangle.branch", help: "Fork: a new chat up to here") {
                                model.fork(at: message.id)
                            }
                            Text([message.model.map { ModelCatalog.shared.title($0) }, message.durationMs.map { String(format: "%.1f s", Double($0) / 1000) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 3)
                        }
                    }
                }
                .frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// Three dots breathing in turn, while waiting for the first words.
struct TypingDots: View {
    // While the window is hidden: no frames drawn for nobody.
    var paused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (sin((t * 5) - Double(i) * 0.8) + 1) / 2
                    Circle().fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.6 * phase)
                        .scaleEffect(0.8 + 0.25 * phase)
                }
            }
            .frame(height: 18)
        }
    }
}

struct ThinkingLabel: View {
    let text: String
    @State private var pulse = false

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .opacity(pulse ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - History and temporary chat buttons

// Highlighted while History is open, like the temporary-chat button.
struct HistoryButton: View {
    let model: ChatModel
    @State private var hovering = false

    var body: some View {
        let on = model.showingHistory
        Button { model.toggleHistory() } label: {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(on ? 0.14 : hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .help(on ? "Close History (⌘Y)" : "History (⌘Y)")
        .onHover { hovering = $0 }
    }
}

struct TemporaryButton: View {
    let model: ChatModel
    @State private var hovering = false

    var body: some View {
        let on = model.chat.isTemporary
        Button { model.toggleTemporary() } label: {
            Image(systemName: on ? "eye.slash.fill" : "eye.slash")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(on ? 0.14 : hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .help(on ? "Temporary chat: not saved to History. Click to leave (⇧⌘N)." : "Temporary Chat (⇧⌘N): not saved to History")
        .onHover { hovering = $0 }
    }
}

// MARK: - History

// The searched words in bold accent colour.
func highlighted(_ text: String, _ terms: [String]) -> AttributedString {
    var out = AttributedString(text)
    let ns = text as NSString
    for term in terms where !term.isEmpty {
        var range = NSRange(location: 0, length: ns.length)
        while true {
            let found = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: range)
            guard found.location != NSNotFound, let r = Range(found, in: text),
                  let a = AttributedString.Index(r.lowerBound, within: out),
                  let b = AttributedString.Index(r.upperBound, within: out) else { break }
            out[a..<b].foregroundColor = .accentColor
            out[a..<b].font = .system(size: 12, weight: .semibold)
            let next = found.location + found.length
            range = NSRange(location: next, length: ns.length - next)
        }
    }
    return out
}

struct HistoryList: View {
    @Bindable var model: ChatModel
    @State private var query = ""
    @State private var renaming: UUID?
    @State private var newTitle = ""
    @State private var collapsed: Set<UUID> = []
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    private struct Row: Identifiable {
        var hit: ChatStore.Hit
        var depth: Int
        var children: Int
        var isLast: Bool
        var id: UUID { hit.id }
    }

    // Forks sit under their original chat, unless searching.
    private func rows() -> [Row] {
        _ = model.history
        let hits = ChatStore.shared.search(query)
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return hits.map { Row(hit: $0, depth: 0, children: 0, isLast: false) }
        }
        let ids = Set(hits.map(\.id))
        var kids: [UUID: [ChatStore.Hit]] = [:]
        var roots: [ChatStore.Hit] = []
        for h in hits {
            if let p = h.summary.parentId, ids.contains(p) { kids[p, default: []].append(h) } else { roots.append(h) }
        }
        let latest = { (h: ChatStore.Hit) in ([h] + (kids[h.id] ?? [])).map(\.summary.updatedAt).max() ?? h.summary.updatedAt }
        var out: [Row] = []
        for root in roots.sorted(by: { latest($0) > latest($1) }) {
            let children = (kids[root.id] ?? []).sorted { $0.summary.title.localizedStandardCompare($1.summary.title) == .orderedAscending }
            out.append(Row(hit: root, depth: 0, children: children.count, isLast: false))
            if !collapsed.contains(root.id) {
                for (i, c) in children.enumerated() {
                    out.append(Row(hit: c, depth: 1, children: 0, isLast: i == children.count - 1))
                }
            }
        }
        return out
    }

    var body: some View {
        let list = rows()
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.tertiary)
                    TextField("Search chats", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                        .onSubmit { if let first = list.first { model.open(first.id) } }
                        .onExitCommand { model.toggleHistory() }
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color.primary.opacity(0.035)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(searchFocused ? 0.12 : 0.06), lineWidth: 0.5))
                if model.layout != .expanded {
                    IconButton(symbol: "square.and.pencil", help: "New Chat (⌘N)") { model.newChat() }
                }
            }
            .padding(.horizontal, 12).padding(.top, model.layout == .expanded ? 0 : 10).padding(.bottom, 4)
            if list.isEmpty {
                Text(model.history.isEmpty ? "No chats yet" : "No matches")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Room above the first chat, clear of the fade at the top
                    // (a List ignores a top content margin).
                    Color.clear.frame(height: 12)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    ForEach(list) { row in
                        rowView(row)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { model.delete(row.id) } label: { Label("Delete", systemImage: "trash") }
                                Button { startRename(row.hit.summary) } label: { Label("Rename", systemImage: "pencil") }
                                    .tint(.gray)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .contentMargins(.horizontal, 8, for: .scrollContent)
                .mask(EdgeFade())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Type to search straight away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let item = row.hit.summary
        HStack(spacing: 0) {
            if row.depth > 0 {
                // The tree line on the left, as in Claude's sidebar.
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1)
                        .frame(maxHeight: row.isLast ? 16 : .infinity, alignment: .top)
                    Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 8, height: 1).offset(y: 16)
                }
                .frame(width: 18, alignment: .leading)
                .padding(.leading, 12)
            }
            if renaming == item.id {
                TextField("Title", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($renameFocused)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6)))
                    .onSubmit { model.rename(item.id, to: newTitle); renaming = nil; searchFocused = true }
                    .onExitCommand { renaming = nil; searchFocused = true }
            } else {
                HistoryRow(model: model, hit: row.hit, children: row.children,
                           collapsed: collapsed.contains(item.id),
                           onToggle: { if collapsed.contains(item.id) { collapsed.remove(item.id) } else { collapsed.insert(item.id) } },
                           onRename: { startRename(item) })
            }
        }
    }

    private func startRename(_ item: ChatSummary) {
        newTitle = item.title
        renaming = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { renameFocused = true }
    }
}

struct HistoryRow: View {
    let model: ChatModel
    let hit: ChatStore.Hit
    let children: Int
    let collapsed: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    @State private var hovering = false

    var body: some View {
        let item = hit.summary
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(highlighted(item.title.isEmpty ? "Untitled" : item.title, hit.terms))
                        .font(.system(size: 13)).lineLimit(1)
                    if children > 0 {
                        Button(action: onToggle) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help(collapsed ? "Show \(children) fork\(children == 1 ? "" : "s")" : "Hide forks")
                    }
                }
                if let snippet = hit.snippet {
                    Text(highlighted(snippet, hit.terms))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Text(item.updatedAt, format: .relative(presentation: .named)).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, hit.snippet == nil ? 0 : 5).frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering || item.id == model.chat.id ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // One click opens at once. (A double-click gesture here made every
        // click wait out the double-click interval before opening.)
        .onTapGesture { model.open(item.id) }
        .contextMenu {
            Button("Open") { model.open(item.id) }
            Button("Rename…") { onRename() }
            Button("Delete", role: .destructive) { model.delete(item.id) }
        }
        .help("Click to open · right-click to rename · swipe left to delete")
    }
}

// Content fades out where it slides under the header and the reply box.
struct EdgeFade: View {
    var size: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: size)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: size)
        }
    }
}

// MARK: - Reasoning

let efforts = ["instant", "low", "medium", "high"]

// How hard the model thinks: a small gauge that fills with the level; a click lists the levels.
struct ReasoningButton: View {
    @Bindable var model: ChatModel
    @State private var hovering = false
    @State private var frame: CGRect = .zero

    var body: some View {
        Button(action: showMenu) {
            // Out of four steps of five, so High keeps its place on the gauge.
            EffortGauge(fraction: Double(efforts.firstIndex(of: model.effectiveEffort) ?? 2) / 4)
                .frame(width: 15, height: 15)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Reasoning: \(effortTitle(model.effectiveEffort))")
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(title: "Reasoning"))
        // Instant (no reasoning at all) exists only for Claude models.
        for e in efforts where e != "instant" || providerOf(model.model) == .claude {
            let item = ClosureMenuItem(title: effortTitle(e)) { model.effort = e }
            item.state = e == model.effectiveEffort ? .on : .off
            menu.addItem(item)
        }
        popUpAbove(menu, screenRect(frame), alignRight: false)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

// An arc open at the bottom, filled up to the level, with a needle.
struct EffortGauge: View {
    var fraction: Double

    // The scale (dim), the arc filled up to the level, and a needle with its
    // hub as one shape. The needle is turned (not redrawn), so it
    // swings to a new level along a spring.
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let lw = max(1.3, s * 0.095)
            let r = (s - lw) / 2
            ZStack {
                // The rest of the scale, dimmer. The filled part is drawn opaque
                // over it inside one flattened layer, so neither shows through.
                Circle().trim(from: 0, to: 2.0 / 3.0)
                    .stroke(Color.primary.opacity(0.32), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(150))
                Circle().trim(from: 0, to: 2.0 / 3.0 * max(fraction, 0.06))
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(150))
                GaugeNeedle(length: r * 0.72, width: lw, hub: lw * 0.95)
                    .fill(Color.primary)
                    .rotationEffect(.degrees(150 + 240 * fraction - 270))
            }
            .frame(width: g.size.width, height: g.size.height)
            .compositingGroup()
            .opacity(0.55)
            .animation(.spring(duration: 0.45, bounce: 0.25), value: fraction)
        }
    }
}

// The hub and the needle, pointing up, as a single outline (no overlap).
struct GaugeNeedle: Shape {
    var length: CGFloat
    var width: CGFloat
    var hub: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: hub, startAngle: .degrees(-70), endAngle: .degrees(250), clockwise: false)
        p.addLine(to: CGPoint(x: c.x - width / 2, y: c.y - length))
        p.addArc(center: CGPoint(x: c.x, y: c.y - length), radius: width / 2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.closeSubpath()
        return p
    }
}
