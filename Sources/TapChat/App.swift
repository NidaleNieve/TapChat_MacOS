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
    // The side chat's window, made on first use; open until dismissed.
    var side: PanelController?
    var sideOpen = false
    var statusItem: NSStatusItem!
    // Setup: until Claude or Codex is installed and signed in, the shortcut opens it instead.
    var setupWindow: SetupWindowController?
    var providerReady = true
    var settingsWindow: NSWindow?
    var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.appearance.apply()
        _ = UpdateController.shared
        panel = PanelController(model: model)
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openSideChat = { [weak self] text in self?.openSideChat(text) }
        panel.onHide = { [weak self] in self?.side?.conceal() }
        panel.onShow = { [weak self] in
            guard let self, self.sideOpen, let side = self.side else { return }
            side.reveal()
            self.panel.panel.makeKey()
        }
        // The in-window shortcuts: only while TapChat is in front.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if let side = self.side, side.panel.isVisible, ShortcutKind.dismissSide.matches(e) {
                side.hide()
                return nil
            }
            guard self.panel.panel.isKeyWindow else { return e }
            if ShortcutKind.newChat.matches(e) { self.newChat(); return nil }
            if ShortcutKind.temporaryChat.matches(e) { self.newTemporaryChat(); return nil }
            if ShortcutKind.history.matches(e) { self.toggleHistory(); return nil }
            return e
        }
        HotKeys.shared.actions[ShortcutKind.open.rawValue] = { [weak self] in
            // A menu open: it closes too. Just after one closed on the shortcut: already handled.
            guard Date() >= OpenMenu.ignoreShortcutUntil else { return }
            OpenMenu.current?.cancelTracking()
            guard let self else { return }
            // Settings left open behind other apps doesn't come along.
            if !NSApp.isActive, self.panel.panel.isVisible == false { self.settingsWindow?.orderOut(nil) }
            if self.providerReady { self.panel.toggle() } else { self.showSetup() }
            self.onboarding?.shortcutUsed()
        }
        // First run, or both providers gone: setup.
        model.checkConnected { connected in
            self.providerReady = !connected.isEmpty
            if connected.isEmpty { self.showSetup() }
        }
        OpenMenu.onShortcut = { [weak self] in self?.panel.hide() }
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
        ChatStore.shared.flush()
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
        statusItem?.menu?.items.first?.title = open.map { "Open TapChat (\($0.label))" } ?? "Open TapChat"
    }

    func setShowMenuBarIcon(_ on: Bool) {
        Settings.showMenuBarIcon = on
        statusItem.isVisible = on
    }

    func setShowInDock(_ on: Bool) {
        Settings.showInDock = on
        NSApp.setActivationPolicy(on ? .regular : .accessory)
        // Changing it makes macOS take TapChat out of the front: back to
        // where the change was made (Settings, or the onboarding).
        let window = NSApp.keyWindow ?? settingsWindow
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
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
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
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
        // Their shortcuts are TapChat's own (Settings), handled by the key monitor.
        chatMenu.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "").target = self
        chatMenu.addItem(withTitle: "Temporary Chat", action: #selector(newTemporaryChat), keyEquivalent: "").target = self
        chatMenu.addItem(withTitle: "History", action: #selector(toggleHistory), keyEquivalent: "").target = self
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

    @objc func checkForUpdates() { UpdateController.shared.check() }

    @objc func openPanel() { if providerReady { panel.show() } else { showSetup() } }

    // The setup window. Done: the chat opens, on a model of a ready provider.
    @objc func showSetup() {
        if setupWindow == nil {
            let w = SetupWindowController()
            w.onDone = { [weak self, weak w] in
                guard let self, let setup = w?.setup else { return }
                self.providerReady = true
                let ready: Provider = setup.claude == .ready ? .claude : .codex
                if setup.state(providerOf(self.model.model)) != .ready {
                    self.model.select(model: Settings.fallback(ready))
                }
                ModelCatalog.shared.refresh()
                self.model.checkConnected()
                // The first time: how to open it (they try the shortcut themselves).
                if Settings.onboarded { self.panel.show() } else { self.showOnboarding() }
            }
            setupWindow = w
        }
        setupWindow?.present()
    }

    func showOnboarding() {
        if onboarding == nil {
            let o = OnboardingWindowController()
            o.onMenuBarChange = { [weak self] on in self?.setShowMenuBarIcon(on) }
            o.onShortcutChange = { [weak self] in self?.applyHotkey() }
            o.onClose = { [weak self] in self?.onboarding = nil }
            onboarding = o
        }
        onboarding?.present()
    }

    // Ask in Side Chat: a temporary chat beside the main one, its composer
    // holding the selected text and a new line, ready to type; not sent.
    func openSideChat(_ text: String) {
        if side == nil {
            let m = ChatModel(side: true)
            m.openSettings = { [weak self] in self?.showSettings() }
            let s = PanelController(model: m, parent: panel)
            s.onDismiss = { [weak self] in self?.sideOpen = false }
            side = s
        }
        guard let side else { return }
        // In place at once: no shrinking from the last side chat, no text moving.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            side.model.newChat()
            side.model.draft = text + "\n"
        }
        sideOpen = true
        side.show()
        side.model.focusToken += 1
    }
    @objc func closePanel() {
        if settingsWindow?.isKeyWindow == true {
            settingsWindow?.close()
        } else if let side, side.panel.isKeyWindow {
            side.hide()
        } else {
            panel.hide()
        }
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
               onMenuBarChange: { [weak self] on in self?.setShowMenuBarIcon(on) },
               onSetup: { [weak self] in self?.showSetup() },
               onOnboarding: { [weak self] in
                   // Settings floats above it: out of the way first.
                   self?.settingsWindow?.close()
                   self?.showOnboarding()
               }))
            w.center()
            settingsWindow = w
        }
        // Signed in or out elsewhere since: Settings shows what's connected.
        model.checkConnected()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppAppearance {
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct SettingsView: View {
    @Bindable var model: ChatModel
    var onHotkeyChange: () -> Void
    var onDockChange: (Bool) -> Void
    var onMenuBarChange: (Bool) -> Void
    var onSetup: () -> Void = {}
    var onOnboarding: () -> Void = {}
    @State private var showInDock = Settings.showInDock
    @State private var showMenuBarIcon = Settings.showMenuBarIcon
    @State private var haptics = Settings.haptics
    @State private var hapticLevel = Double(Settings.hapticStrength.rawValue)
    @State private var extraEfforts = Settings.showExtraEfforts
    @State private var appearance = Settings.appearance
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var fallbackClaude = Settings.fallbackClaude
    @State private var fallbackCodex = Settings.fallbackCodex
    @State private var autoFallback = Settings.autoFallback
    @State private var newChatAfter = Settings.newChatAfter
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var claudePath = Settings.claudePath
    @State private var codexPath = Settings.codexPath

    // A tool's path: found by itself unless one is chosen here.
    private func toolRow(_ name: String, path: Binding<String>, found: String?, save: @escaping (String) -> Void) -> some View {
        LabeledContent(name) {
            HStack(spacing: 8) {
                Text(path.wrappedValue.isEmpty ? (found ?? "Not found") : path.wrappedValue)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(path.wrappedValue.isEmpty ? "Found automatically" : "Chosen by you")
                Button("Choose…") {
                    let open = NSOpenPanel()
                    open.message = "Choose the \(name) command-line tool"
                    open.canChooseDirectories = false
                    open.showsHiddenFiles = true
                    open.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
                    if open.runModal() == .OK, let url = open.url {
                        path.wrappedValue = url.path
                        save(url.path)
                    }
                }
                .controlSize(.small)
                if !path.wrappedValue.isEmpty {
                    Button("Automatic") { path.wrappedValue = ""; save("") }.controlSize(.small)
                }
            }
        }
    }

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Open TapChat") {
                    ShortcutRecorder(kind: .open) { onHotkeyChange() }
                }
                ForEach([ShortcutKind.newChat, .temporaryChat, .history, .dismissSide], id: \.self) { kind in
                    LabeledContent(kind.title) { ShortcutRecorder(kind: kind) { onHotkeyChange() } }
                }
                if let problem = model.hotkeyProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Chat") {
                Picker("Open a new chat after", selection: $newChatAfter) {
                    Text("Never (keep the last chat)").tag(0)
                    Text("10 minutes").tag(10)
                    Text("1 hour").tag(60)
                    Text("8 hours").tag(480)
                }
                .onChange(of: newChatAfter) { Settings.newChatAfter = newChatAfter }
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: appearance) { Settings.appearance = appearance; appearance.apply() }
                Toggle("Haptic feedback while answering", isOn: $haptics)
                    .onChange(of: haptics) { Settings.haptics = haptics }
                if haptics {
                    LabeledContent("Intensity") {
                        HStack(spacing: 8) {
                            Text("Light").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $hapticLevel, in: 0...2, step: 1).frame(width: 120)
                            Text("Strong").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: hapticLevel) { Settings.hapticStrength = HapticStrength(rawValue: Int(hapticLevel)) ?? .medium }
                }
                Toggle("Show Extra High, Max and Ultra reasoning", isOn: $extraEfforts)
                    .onChange(of: extraEfforts) { Settings.showExtraEfforts = extraEfforts; model.warmUp() }
            }
            Section("System") {
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
                    Text("To open Settings, hold Option (\(Image(systemName: "option"))) in the model menu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // Both connected: what happens when one runs out. One: its usage,
            // and connecting the other.
            let shown = [Provider.claude, .codex].filter { model.connected?.contains($0) ?? true }
            Section(shown.count == 2 ? "When a provider hits its usage limit" : "Usage") {
                if shown.count == 2 {
                    Toggle("Switch to the other provider automatically", isOn: $autoFallback)
                        .onChange(of: autoFallback) { Settings.autoFallback = autoFallback }
                    Picker("Claude is out: use", selection: $fallbackCodex) {
                        Text("Last used").tag(lastUsedModel)
                        Divider()
                        ForEach(model.models.filter { $0.provider == .codex }) { Text($0.title).tag($0.value) }
                        if fallbackCodex != lastUsedModel, !model.models.contains(where: { $0.value == fallbackCodex }) { Text(ModelCatalog.shared.title(fallbackCodex)).tag(fallbackCodex) }
                    }
                    .onChange(of: fallbackCodex) { Settings.fallbackCodex = fallbackCodex }
                    Picker("Codex is out: use", selection: $fallbackClaude) {
                        Text("Last used").tag(lastUsedModel)
                        Divider()
                        ForEach(model.models.filter { $0.provider == .claude }) { Text($0.title).tag($0.value) }
                        if fallbackClaude != lastUsedModel, !model.models.contains(where: { $0.value == fallbackClaude }) { Text(ModelCatalog.shared.title(fallbackClaude)).tag(fallbackClaude) }
                    }
                    .onChange(of: fallbackClaude) { Settings.fallbackClaude = fallbackClaude }
                }
                ForEach(shown, id: \.self) { p in
                    // Plain text, not a control: nothing to click.
                    HStack {
                        Text("\(p.name) usage")
                        Spacer()
                        Text(model.usage[p].map { $0.isCurrent ? $0.summary : "Window has reset" } ?? "No reading yet")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
                if shown.count == 1, let missing = [Provider.claude, .codex].first(where: { !shown.contains($0) }) {
                    HStack {
                        Text("Switch to \(missing.name) when \(shown[0].name) runs out").foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect \(missing.name)…", action: onSetup)
                    }
                }
            }
            UpdateSettings()
            Section("Command-line tools") {
                // Only for connected providers (the other is connected through setup).
                if model.connected?.contains(.claude) ?? true {
                    toolRow("Claude", path: $claudePath, found: ClaudeRunner.shared.binary) { Settings.claudePath = $0 }
                }
                if model.connected?.contains(.codex) ?? true {
                    toolRow("Codex", path: $codexPath, found: CodexRunner.shared.binary) { Settings.codexPath = $0 }
                }
                HStack {
                    Button("Set Up Claude or Codex…", action: onSetup)
                    Button("Refresh Model List") { ModelCatalog.shared.refresh() }
                }
            }
            Section {
                Button("Replay Onboarding", action: onOnboarding)
            }
        }
        .formStyle(.grouped)
        // Always at the bottom, under the scrolling settings.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text("TapChat runs in the background so the shortcut always works.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit TapChat") { NSApp.terminate(nil) }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            // Solid: the settings scrolling under it don't show through.
            .background(Color(nsColor: .windowBackgroundColor))
        }
        // A fixed height: the form scrolls instead of growing past the screen.
        .frame(width: 460, height: 560)
    }
}
