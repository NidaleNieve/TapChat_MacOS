import AppKit
import ServiceManagement
import SwiftUI

@main
enum Main {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            selfTest(Array(CommandLine.arguments[(i + 1)...]))
            return
        }
        // Writing to a CLI that already exited must not end the app.
        signal(SIGPIPE, SIG_IGN)
        Migration.run()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ChatModel()
    var panel: PanelController!
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(model: model)
        model.openSettings = { [weak self] in self?.showSettings() }
        HotKeys.shared.actions[ShortcutKind.open.rawValue] = { [weak self] in
            // A menu open: it closes too. Just after one closed on the shortcut: already handled.
            guard Date() >= OpenMenu.ignoreShortcutUntil else { return }
            OpenMenu.current?.cancelTracking()
            self?.panel.toggle()
        }
        OpenMenu.onShortcut = { [weak self] in self?.panel.hide() }
        HotKeys.shared.actions[ShortcutKind.history.rawValue] = { [weak self] in self?.panel.toggleHistory() }
        if Settings.showInDock { NSApp.setActivationPolicy(.regular) }
        buildMainMenu()
        buildStatusItem()
        ModelCatalog.shared.refreshIfStale()
        DebugHooks.install(self)
        setUpLoginItem()
        // Opened by hand (Spotlight, Launchpad, Finder): show the window. At
        // login it stays out of the way until the shortcut.
        if model.hotkeyProblem != nil || ProcessInfo.processInfo.systemUptime > 180 { panel.show() }
    }

    // Open at Login is on unless turned off in Settings.
    private func setUpLoginItem() {
        guard !Settings.loginItemConfigured else { return }
        Settings.loginItemConfigured = true
        do {
            try SMAppService.mainApp.register()
            log("login item registered status=\(SMAppService.mainApp.status.rawValue)")
        } catch {
            log("login item failed: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.writeDrafts()
    }

    // Opening the app while it runs (Spotlight, Finder, Launchpad) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applyHotkey() {
        let open = ShortcutKind.open.current
        if HotKeys.shared.register(.open, open) {
            model.hotkeyProblem = nil
        } else {
            model.hotkeyProblem = "\(open?.label ?? "The shortcut") is used by another app (ChatGPT, Raycast or Spotlight?). Free it there, or record another shortcut in Settings."
        }
        HotKeys.shared.register(.history, ShortcutKind.history.current)
        statusItem?.menu?.items.first?.title = open.map { "Open TapChat (\($0.label))" } ?? "Open TapChat"
    }

    func setShowMenuBarIcon(_ on: Bool) {
        Settings.showMenuBarIcon = on
        statusItem.isVisible = on
    }

    func setShowInDock(_ on: Bool) {
        Settings.showInDock = on
        NSApp.setActivationPolicy(on ? .regular : .accessory)
        DispatchQueue.main.async { self.panel.show() }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image
        let menu = NSMenu()
        menu.addItem(withTitle: "Open TapChat", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Temporary Chat", action: #selector(newTemporaryChat), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TapChat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.isVisible = Settings.showMenuBarIcon
        applyHotkey()
    }

    // An accessory app shows no menu bar, but these key equivalents (and the
    // Edit menu's copy/paste/undo) only work through a main menu.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Close Window", action: #selector(closePanel), keyEquivalent: "w").target = self
        appMenu.addItem(withTitle: "Quit TapChat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let chatItem = NSMenuItem()
        let chatMenu = NSMenu(title: "Chat")
        chatMenu.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "n").target = self
        let temp = chatMenu.addItem(withTitle: "Temporary Chat", action: #selector(newTemporaryChat), keyEquivalent: "n")
        temp.keyEquivalentModifierMask = [.command, .shift]
        temp.target = self
        chatMenu.addItem(withTitle: "History", action: #selector(toggleHistory), keyEquivalent: "y").target = self
        chatMenu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: ".").target = self
        // Continuity Camera only takes over an Import from iPhone item that's
        // in the main menu when it's set; one made later for a pop-up menu is
        // never filled in and stays greyed out. "+" shows a copy of this one;
        // this one is hidden (macOS retitles it "<<Import From Device -
        // unlocalized>>" here, which would show with Show in Dock on).
        let device = NSMenuItem(title: "Import from iPhone", action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        chatMenu.addItem(device)
        device.isHidden = true
        ImportAnchor.mainMenuItem = device
        chatItem.submenu = chatMenu
        main.addItem(chatItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func openPanel() { panel.show() }
    @objc func closePanel() {
        if settingsWindow?.isKeyWindow == true { settingsWindow?.close() } else { panel.hide() }
    }
    @objc func newChat() { model.newChat(); panel.show() }
    // ⇧⌘N: temporary chat on, or back off.
    @objc func newTemporaryChat() { model.toggleTemporary(); panel.show() }
    @objc func toggleHistory() { model.toggleHistory() }
    @objc func stop() { model.stop() }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "TapChat Settings"
            w.isReleasedWhenClosed = false
            w.level = .floating + 1
            w.contentViewController = NSHostingController(rootView: SettingsView(model: model, onHotkeyChange: { [weak self] in
                self?.applyHotkey()
            }, onDockChange: { [weak self] on in self?.setShowInDock(on) },
               onMenuBarChange: { [weak self] on in self?.setShowMenuBarIcon(on) }))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable var model: ChatModel
    var onHotkeyChange: () -> Void
    var onDockChange: (Bool) -> Void
    var onMenuBarChange: (Bool) -> Void
    @State private var showInDock = Settings.showInDock
    @State private var showMenuBarIcon = Settings.showMenuBarIcon
    @State private var haptics = Settings.haptics
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var fallbackClaude = Settings.fallbackClaude
    @State private var fallbackCodex = Settings.fallbackCodex
    @State private var autoFallback = Settings.autoFallback
    @State private var newChatAfter = Settings.newChatAfter
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var claudePath = Settings.claudePath
    @State private var codexPath = Settings.codexPath

    var body: some View {
        Form {
            Section {
                LabeledContent("Open TapChat") {
                    ShortcutRecorder(kind: .open) { onHotkeyChange() }
                }
                LabeledContent("Open History") {
                    ShortcutRecorder(kind: .history) { onHotkeyChange() }
                }
                if let problem = model.hotkeyProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                Picker("Open a new chat after", selection: $newChatAfter) {
                    Text("Never (keep the last chat)").tag(0)
                    Text("10 minutes").tag(10)
                    Text("1 hour").tag(60)
                    Text("8 hours").tag(480)
                }
                .onChange(of: newChatAfter) { Settings.newChatAfter = newChatAfter }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                        loginStatus = SMAppService.mainApp.status
                    }
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("macOS needs your OK in Login Items.").font(.caption).foregroundStyle(.orange)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                    }
                }
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { onDockChange(showInDock) }
                Toggle("Show in menu bar", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { onMenuBarChange(showMenuBarIcon) }
                if !showMenuBarIcon {
                    Text("To open Settings, hold Option in the model menu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Haptic ticks while answering", isOn: $haptics)
                    .onChange(of: haptics) { Settings.haptics = haptics }
            }
            Section("When a provider hits its usage limit") {
                Toggle("Switch to the other provider automatically", isOn: $autoFallback)
                    .onChange(of: autoFallback) { Settings.autoFallback = autoFallback }
                Picker("Claude is out: use", selection: $fallbackCodex) {
                    ForEach(model.models.filter { $0.provider == .codex }) { Text($0.title).tag($0.value) }
                    if !model.models.contains(where: { $0.value == fallbackCodex }) { Text(ModelCatalog.shared.title(fallbackCodex)).tag(fallbackCodex) }
                }
                .onChange(of: fallbackCodex) { Settings.fallbackCodex = fallbackCodex }
                Picker("Codex is out: use", selection: $fallbackClaude) {
                    ForEach(model.models.filter { $0.provider == .claude }) { Text($0.title).tag($0.value) }
                    if !model.models.contains(where: { $0.value == fallbackClaude }) { Text(ModelCatalog.shared.title(fallbackClaude)).tag(fallbackClaude) }
                }
                .onChange(of: fallbackClaude) { Settings.fallbackClaude = fallbackClaude }
                ForEach([Provider.claude, .codex], id: \.self) { p in
                    LabeledContent(p.name, value: model.usage[p].map { $0.isCurrent ? $0.summary : "\(p.name) — window has reset" } ?? "No reading yet")
                        .font(.caption)
                }
            }
            Section("Command-line tools") {
                TextField("Claude", text: $claudePath, prompt: Text(ClaudeRunner.shared.binary ?? "Not found"))
                    .onChange(of: claudePath) { Settings.claudePath = claudePath }
                TextField("Codex", text: $codexPath, prompt: Text(CodexRunner.shared.binary ?? "Not found"))
                    .onChange(of: codexPath) { Settings.codexPath = codexPath }
                Button("Refresh Model List") { ModelCatalog.shared.refresh() }
            }
            Section {
                HStack {
                    Text("TapChat runs in the background so the shortcut always works.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit TapChat") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
