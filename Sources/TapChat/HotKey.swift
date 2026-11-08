import AppKit
import Carbon
import SwiftUI

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var label: String
}

enum ShortcutKind: UInt32, CaseIterable {
    case open = 1, history = 2, dismissSide = 3

    var title: String {
        switch self {
        case .open: "Open TapChat"
        case .history: "Open History"
        case .dismissSide: "Dismiss Side Chat"
        }
    }
    var defaultShortcut: Shortcut? {
        switch self {
        case .open: Shortcut(keyCode: kVK_Space, modifiers: optionKey, label: "⌥ Space")
        case .history: nil
        case .dismissSide: Shortcut(keyCode: kVK_ANSI_W, modifiers: cmdKey, label: "⌘ W")
        }
    }
    // Only while TapChat is in front (a system-wide ⌘W would take it from
    // every other app): handled by the app, not registered with the system.
    var isLocal: Bool { self == .dismissSide }

    // nil: none set.
    var current: Shortcut? {
        get {
            let d = UserDefaults.standard
            if let data = d.data(forKey: "shortcut.\(rawValue)") {
                return try? JSONDecoder().decode(Shortcut?.self, from: data)
            }
            if self == .open, let code = d.object(forKey: "hotkeyCode") as? Int {
                return Shortcut(keyCode: code, modifiers: d.integer(forKey: "hotkeyModifiers"),
                                label: d.string(forKey: "hotkeyLabel") ?? "⌥ Space")
            }
            return defaultShortcut
        }
        nonmutating set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "shortcut.\(rawValue)")
        }
    }
}

// System-wide shortcuts via Carbon's RegisterEventHotKey: no Accessibility
// permission needed, and nothing runs until the keys are pressed.
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.shared.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    // False if another app already has this shortcut.
    @discardableResult
    func register(_ kind: ShortcutKind, _ shortcut: Shortcut?) -> Bool {
        if kind.isLocal { return true }
        unregister(kind)
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5143_4854), id: kind.rawValue)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[kind.rawValue] = ref }
        return status == noErr
    }

    func unregister(_ kind: ShortcutKind) {
        if kind.isLocal { return }
        if let ref = refs.removeValue(forKey: kind.rawValue) { UnregisterEventHotKey(ref) }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    static func label(keyCode: Int, flags: NSEvent.ModifierFlags, characters: String?) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        let key = names[keyCode] ?? (characters ?? "?").uppercased()
        return s.isEmpty ? key : "\(s) \(key)"
    }

    static func isFunctionKey(_ keyCode: Int) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
         kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19].contains(keyCode)
    }
}

// Click, then press the new shortcut. Esc cancels.
struct ShortcutRecorder: View {
    let kind: ShortcutKind
    var onChange: () -> Void
    @State private var current: Shortcut?
    @State private var recording = false
    @State private var problem: String?
    @State private var monitor: Any?

    init(kind: ShortcutKind, onChange: @escaping () -> Void) {
        self.kind = kind
        self.onChange = onChange
        _current = State(initialValue: kind.current)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    Text(recording ? "Press a shortcut…" : current?.label ?? "Record Shortcut")
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 130)
                }
                .buttonStyle(.bordered)
                if !recording, current != nil, current != kind.defaultShortcut {
                    Button(kind.defaultShortcut == nil ? "Clear" : "Reset") { save(kind.defaultShortcut) }
                        .buttonStyle(.borderless)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        problem = nil
        recording = true
        // Let the current shortcut reach the recorder too.
        HotKeys.shared.unregister(kind)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let code = Int(event.keyCode)
            if code == kVK_Escape, flags.isEmpty {
                stop()
                return nil
            }
            guard !flags.subtracting(.shift).isEmpty || HotKeys.isFunctionKey(code) else {
                problem = "Use at least one of ⌘ ⌥ ⌃ (or a function key)."
                return nil
            }
            save(Shortcut(keyCode: code, modifiers: HotKeys.carbonModifiers(flags),
                          label: HotKeys.label(keyCode: code, flags: flags, characters: event.charactersIgnoringModifiers)))
            return nil
        }
    }

    private func save(_ shortcut: Shortcut?) {
        stopMonitor()
        recording = false
        let other = ShortcutKind.allCases.first { $0 != kind && $0.current != nil && $0.current?.keyCode == shortcut?.keyCode && $0.current?.modifiers == shortcut?.modifiers }
        if let other {
            problem = "Already used for \(other.title)."
            HotKeys.shared.register(kind, kind.current)
        } else if HotKeys.shared.register(kind, shortcut) {
            kind.current = shortcut
            current = shortcut
            problem = nil
            onChange()
        } else {
            problem = "\(shortcut?.label ?? "That") is used by another app. Try another."
            HotKeys.shared.register(kind, kind.current)
        }
    }

    private func stop() {
        stopMonitor()
        if recording { HotKeys.shared.register(kind, kind.current) }
        recording = false
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
