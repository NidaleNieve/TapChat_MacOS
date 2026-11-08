import AppKit
import SwiftUI

let composerFont = NSFont.systemFont(ofSize: 14)

// The message field: ↵ sends, ⇧↵ adds a line, pasted or dropped images and
// files become attachments, and it grows with its text up to maxHeight.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var maxHeight: CGFloat
    var focusToken: Int
    var onSubmit: () -> Void
    var onAttach: ([Attachment]) -> Void
    var attachmentFolder: () -> URL
    var onEscape: () -> Void
    var onUpWhenEmpty: (() -> Void)?

    static let inset: CGFloat = 5
    static var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: composerFont)) + inset * 2 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scroll = ComposerScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: Self.lineHeight))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none

        let tv = ComposerNSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.coordinator = context.coordinator
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = composerFont
        tv.textColor = .labelColor
        tv.insertionPointColor = .controlAccentColor
        tv.textContainerInset = NSSize(width: 0, height: Self.inset)
        tv.textContainer?.lineFragmentPadding = 0
        // Wrap at the field's width, grow downwards (Apple's text view recipe).
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])
        tv.string = text
        scroll.documentView = tv
        scroll.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.recalc() }
        context.coordinator.textView = tv
        context.coordinator.scrollView = scroll
        DispatchQueue.main.async { context.coordinator.recalc(); tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.recalc()
        }
        if context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        weak var scrollView: ComposerScrollView?
        var lastFocus = -1

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            recalc()
        }

        // The text's height at the current width; scrolling only once it's
        // taller than the field may get.
        func recalc() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let scroll = scrollView else { return }
            lm.ensureLayout(for: tc)
            let used = ceil(lm.usedRect(for: tc).height) + ComposerTextView.inset * 2
            let h = min(max(used, ComposerTextView.lineHeight), parent.maxHeight)
            let overflow = used > parent.maxHeight + 0.5
            scroll.hasVerticalScroller = overflow
            scroll.canScroll = overflow
            if !overflow {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if abs(parent.height - h) > 0.5 {
                // Animated as one change: the field, the box and the window's glass together.
                DispatchQueue.main.async { withAnimation(.smooth(duration: 0.22)) { self.parent.height = h } }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if textView.hasMarkedText() { return false }
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.moveUp(_:)):
                if textView.string.isEmpty, let up = parent.onUpWhenEmpty { up(); return true }
                return false
            default:
                return false
            }
        }

        func attachImport(from pb: NSPasteboard) -> Bool {
            let list = Attachments.fromDevice(pb, into: parent.attachmentFolder())
            guard !list.isEmpty else { return false }
            parent.onAttach(list)
            return true
        }

        func attach(from pb: NSPasteboard) -> Bool {
            let list = Attachments.fromPasteboard(pb, into: parent.attachmentFolder())
            guard !list.isEmpty else { return false }
            parent.onAttach(list)
            return true
        }
    }
}

final class ComposerScrollView: NSScrollView {
    var onWidthChange: (() -> Void)?
    var canScroll = false
    private var lastWidth: CGFloat = 0

    // The text view always spans the field's width, so wrapping follows it.
    override func layout() {
        super.layout()
        let w = contentSize.width
        if let tv = documentView, abs(tv.frame.width - w) > 0.5 {
            tv.setFrameSize(NSSize(width: w, height: tv.frame.height))
        }
        if abs(w - lastWidth) > 0.5 {
            lastWidth = w
            onWidthChange?()
        }
    }

    // Short text doesn't scroll; the wheel goes to whatever is behind.
    override func scrollWheel(with event: NSEvent) {
        if canScroll { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }
}

final class ComposerNSTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?

    // Keep the caret line in view only when the field can scroll at all.
    override func scrollRangeToVisible(_ range: NSRange) {
        if (enclosingScrollView as? ComposerScrollView)?.canScroll == true { super.scrollRangeToVisible(range) }
    }

    // Continuity Camera ("Import from iPhone"): the photo, scan or sketch
    // comes here, as an image or a PDF, and is attached.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType, Attachments.deviceImportTypes.contains(returnType), sendType == nil || sendType == .string { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        coordinator?.attachImport(from: pboard) ?? false
    }

    // A plain-text field normally greys out Paste (and ignores ⌘V) when the
    // clipboard holds only an image: it can't read one. Here an image or file
    // on the clipboard is something to attach, so Paste stays on.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + Attachments.deviceImportTypes + [.fileURL]
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Attachments.pasteboardHasAttachments(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        if Attachments.pasteboardHasAttachments(.general), coordinator?.attach(from: .general) == true { return }
        pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Attachments.pasteboardHasAttachments(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Attachments.pasteboardHasAttachments(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if Attachments.pasteboardHasAttachments(sender.draggingPasteboard) {
            return coordinator?.attach(from: sender.draggingPasteboard) ?? false
        }
        return super.performDragOperation(sender)
    }
}
