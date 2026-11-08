import Foundation

// This app was called QuickChat (bundle id local.quickchat). On first launch
// as TapChat it takes over that app's settings, chats and drafts.
enum Migration {
    static func run() {
        let d = UserDefaults.standard
        if !d.bool(forKey: "migratedFromQuickChat") {
            if let old = d.persistentDomain(forName: "local.quickchat"), !old.isEmpty {
                for (key, value) in old where d.object(forKey: key) == nil { d.set(value, forKey: key) }
                // Open at Login was registered for the old app: register this one.
                d.set(false, forKey: "loginItemConfigured")
            }
            d.set(true, forKey: "migratedFromQuickChat")
        }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("QuickChat")
        let new = base.appendingPathComponent("TapChat")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do { try fm.moveItem(at: old, to: new) } catch { return }
        // Attachments are stored with absolute paths inside the chats and drafts.
        var files = [new.appendingPathComponent("drafts.json")]
        let chats = new.appendingPathComponent("chats")
        for id in (try? fm.contentsOfDirectory(atPath: chats.path)) ?? [] {
            files.append(chats.appendingPathComponent(id).appendingPathComponent("chat.json"))
        }
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let fixed = text
                .replacingOccurrences(of: "Application Support\\/QuickChat\\/", with: "Application Support\\/TapChat\\/")
                .replacingOccurrences(of: "Application Support/QuickChat/", with: "Application Support/TapChat/")
            if fixed != text { try? fixed.write(to: file, atomically: true, encoding: .utf8) }
        }
    }
}
