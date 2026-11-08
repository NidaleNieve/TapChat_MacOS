import AppKit
import PDFKit
import UniformTypeIdentifiers

enum Attachments {
    private static let maxImageSide: CGFloat = 2048
    private static let maxTextChars = 200_000

    // Copies a dropped or pasted file into the chat's folder. Images are
    // stored as PNG or JPEG (what both CLIs read), at most 2048 px wide.
    static func importFile(_ url: URL, into folder: URL) -> Attachment? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
            return importImage(image, name: url.lastPathComponent, into: folder)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let dest = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }
        return Attachment(name: url.lastPathComponent, kind: .file, path: dest.path)
    }

    static func importImage(_ image: NSImage, name: String, into folder: URL) -> Attachment? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxImageSide / max(w, h))
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let hasAlpha = cg.alphaInfo != .none && cg.alphaInfo != .noneSkipLast && cg.alphaInfo != .noneSkipFirst
        let base = (name as NSString).deletingPathExtension.isEmpty ? "image" : (name as NSString).deletingPathExtension
        let ext = hasAlpha ? "png" : "jpg"
        let data = hasAlpha
            ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        guard let data else { return nil }
        let dest = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(base).\(ext)")
        do { try data.write(to: dest) } catch { return nil }
        return Attachment(name: "\(base).\(ext)", kind: .image, path: dest.path)
    }

    // Files and images on the pasteboard (copied in Finder, or a screenshot).
    static func fromPasteboard(_ pb: NSPasteboard, into folder: URL) -> [Attachment] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap { importFile($0, into: folder) }
        }
        if let image = NSImage(pasteboard: pb), pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]) != nil {
            return importImage(image, name: "Pasted Image", into: folder).map { [$0] } ?? []
        }
        return []
    }

    static func pasteboardHasAttachments(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        // Text copied from rich apps often comes with an image of it too; text wins.
        if pb.availableType(from: [.string]) != nil { return false }
        return pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]) != nil
    }
}

// The text the model gets for a file attachment.
func extractText(_ url: URL) -> String {
    let limit = 200_000
    var text: String?
    let ext = url.pathExtension.lowercased()
    if ext == "pdf" {
        text = PDFDocument(url: url)?.string
    } else if ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive", "wordml"].contains(ext) {
        text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
    }
    if text == nil, let data = try? Data(contentsOf: url) {
        if data.prefix(8000).contains(0) {
            return "(Binary file; its contents can't be read as text.)"
        }
        text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
    guard let text, !text.isEmpty else { return "(No text could be read from this file.)" }
    return text.count > limit ? String(text.prefix(limit)) + "\n…(truncated)" : text
}
