import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum Attachments {
    private static let maxImageSide: CGFloat = 2048
    private static let maxTextChars = 200_000

    // Several files at once, in parallel (each image is decoded and encoded
    // on its own core); the result keeps their order.
    static func importFiles(_ urls: [URL], into folder: URL) -> [Attachment] {
        guard urls.count > 1 else { return urls.compactMap { importFile($0, into: folder) } }
        var results = [Attachment?](repeating: nil, count: urls.count)
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in out[i] = importFile(urls[i], into: folder) }
        }
        return results.compactMap { $0 }
    }

    // Copies a dropped or pasted file into the chat's folder. Images are
    // stored as PNG or JPEG (what both CLIs read), at most 2048 px wide.
    static func importFile(_ url: URL, into folder: URL) -> Attachment? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let a = importImageFile(url, into: folder) { return a }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let dest = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }
        return Attachment(name: url.lastPathComponent, kind: .file, path: dest.path)
    }

    // An image file, through ImageIO: a PNG or JPEG that's small enough,
    // upright and without a location is copied as it is; anything else is decoded straight at its
    // final size (no full-size bitmap) and saved as PNG (with transparency)
    // or JPEG.
    private static func importImageFile(_ url: URL, into folder: URL) -> Attachment? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let base = url.deletingPathExtension().lastPathComponent.isEmpty ? "image" : url.deletingPathExtension().lastPathComponent
        let upright = (props[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        // A photo's location would go to the model with it: re-encoded, it's dropped.
        let located = props[kCGImagePropertyGPSDictionary] != nil
        let type = CGImageSourceGetType(src) as String?
        if max(w, h) <= Int(maxImageSide), upright, !located, type == UTType.png.identifier || type == UTType.jpeg.identifier {
            let ext = type == UTType.png.identifier ? "png" : "jpg"
            let dest = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(base).\(ext)")
            do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }
            return Attachment(name: "\(base).\(ext)", kind: .image, path: dest.path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(Int(maxImageSide), max(w, h)),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return save(cg, name: base, alpha: hasAlpha(cg), into: folder)
    }

    static func importImage(_ image: NSImage, name: String, into folder: URL) -> Attachment? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let alpha = hasAlpha(cg)
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxImageSide / max(w, h))
        var out = cg
        if scale < 1 {
            let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
            let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(origin: .zero, size: size))
            guard let scaled = ctx.makeImage() else { return nil }
            out = scaled
        }
        return save(out, name: (name as NSString).deletingPathExtension, alpha: alpha, into: folder)
    }

    private static func hasAlpha(_ cg: CGImage) -> Bool {
        cg.alphaInfo != .none && cg.alphaInfo != .noneSkipLast && cg.alphaInfo != .noneSkipFirst
    }

    // PNG when the image has transparency, JPEG otherwise; also makes its thumbnail.
    private static func save(_ cg: CGImage, name: String, alpha: Bool, into folder: URL) -> Attachment? {
        let base = name.isEmpty ? "image" : name
        let ext = alpha ? "png" : "jpg"
        let dest = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(base).\(ext)")
        let type = (alpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, type, 1, nil) else { return nil }
        // PNG: one fixed row filter instead of trying all five per row, the
        // slowest part of writing a PNG; files come out a little larger.
        let properties: [CFString: Any] = alpha
            ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: IMAGEIO_PNG_FILTER_SUB]]
            : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(out, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(out) else { return nil }
        Thumbnails.store(cg, for: dest.path)
        return Attachment(name: "\(base).\(ext)", kind: .image, path: dest.path)
    }

    // Files and images on the pasteboard (copied in Finder, or a screenshot).
    static func fromPasteboard(_ pb: NSPasteboard, into folder: URL) -> [Attachment] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return importFiles(urls, into: folder)
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

// Small images for attachment chips, made once per file: a chip never
// decodes the full image. Emptied when the window has been hidden a while.
enum Thumbnails {
    // Twice the chip's 54 pt, for Retina, on the short side.
    private static let side: CGFloat = 108
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()
    private static let icons = NSCache<NSString, NSImage>()
    private static let queue = DispatchQueue(label: "TapChat.thumbnails", qos: .userInitiated)

    static func cached(_ path: String) -> NSImage? { cache.object(forKey: path as NSString) }

    // Made off the main thread; `done` runs on the main thread.
    static func load(_ path: String, done: @escaping (NSImage?) -> Void) {
        if let image = cached(path) { return done(image) }
        queue.async {
            let image = make(path)
            DispatchQueue.main.async {
                if let image { cache.setObject(image, forKey: path as NSString) }
                done(image)
            }
        }
    }

    // From an image already in memory (just imported).
    static func store(_ cg: CGImage, for path: String) {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, side / min(w, h))
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        guard let small = ctx.makeImage() else { return }
        cache.setObject(NSImage(cgImage: small, size: NSSize(width: size.width / 2, height: size.height / 2)), forKey: path as NSString)
    }

    private static func make(_ path: String) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        // The long side that gives a short side of `side`.
        let long = Int((max(w, h) * min(1, side / min(w, h))).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, long),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }

    // A file's icon: one per file type, or per file when it has no extension.
    static func icon(_ path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        let key = (ext.isEmpty ? path : ext) as NSString
        if let icon = icons.object(forKey: key) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(icon, forKey: key)
        return icon
    }

    static func removeAll() {
        cache.removeAllObjects()
        icons.removeAllObjects()
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
